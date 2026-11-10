#!/usr/bin/env bash
# Punto 6 - AWS Glue Data Catalog, crawler y Athena con AWS CLI
#   - Bucket S3 con los datos particionados por mes (datos/ventas/mes=AAAA-MM/)
#     y una carpeta para los resultados de Athena (athena-resultados/)
#   - Rol de IAM para el crawler (servicio Glue + lectura del bucket)
#   - Base de datos del catálogo `taller_p6`
#   - Crawler sobre s3://<bucket>/datos/ventas/
#
# Uso:
#   bash despliegue_p6.sh crear            # crea todo, sube sep y oct, y ejecuta el crawler
#   bash despliegue_p6.sh crawler          # vuelve a ejecutar el crawler y espera a que termine
#   bash despliegue_p6.sh agregar          # sube los registros nuevos (mes=2026-11)
#   bash despliegue_p6.sh estado
#   bash despliegue_p6.sh destruir

set -euo pipefail

export AWS_DEFAULT_REGION="us-east-2"
PREFIJO="fp-taller-p6"
BASE_DE_DATOS="taller_p6"
CRAWLER="${PREFIJO}-crawler"
ROL="${PREFIJO}-glue-crawler"
CARPETA="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }

cuenta() { aws sts get-caller-identity --query Account --output text; }
bucket() { echo "${PREFIJO}-$(cuenta)"; }

existe_crawler() { aws glue get-crawler --name "$CRAWLER" >/dev/null 2>&1; }

# --- Crawler: ejecutar y esperar ---------------------------------------------
ejecutar_crawler() {
  aws glue start-crawler --name "$CRAWLER"
  log "Crawler ${CRAWLER} iniciado"
  local estado
  sleep 10
  while true; do
    estado=$(aws glue get-crawler --name "$CRAWLER" --query "Crawler.State" --output text)
    [[ "$estado" == "READY" ]] && break
    log "Crawler: ${estado}, esperando 15 s..."
    sleep 15
  done
  aws glue get-crawler --name "$CRAWLER" \
    --query "Crawler.LastCrawl.[Status,StartTime]" --output text |
    awk '{print "['"$(date +%H:%M:%S)"'] Última ejecución: "$1" (inicio "$2")"}'
  aws glue get-crawler-metrics --crawler-name-list "$CRAWLER" \
    --query "CrawlerMetricsList[0].[LastRuntimeSeconds,TablesCreated,TablesUpdated]" --output text |
    awk '{print "['"$(date +%H:%M:%S)"'] Duración: "$1" s | tablas creadas: "$2" | tablas actualizadas: "$3}'
}

# --- Crear -------------------------------------------------------------------
crear() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"
  local b rol_arn
  b=$(bucket)

  # 1. Bucket con los datos de septiembre y octubre
  aws s3api create-bucket --bucket "$b" \
    --create-bucket-configuration LocationConstraint="$AWS_DEFAULT_REGION" >/dev/null
  aws s3api put-bucket-tagging --bucket "$b" \
    --tagging "TagSet=[{Key=Proyecto,Value=taller-aws},{Key=Punto,Value=6}]"
  aws s3 cp "${CARPETA}/datos/ventas/" "s3://${b}/datos/ventas/" --recursive --only-show-errors \
    --exclude "*" --include "*.csv"
  log "Bucket ${b} creado; archivos cargados:"
  aws s3 ls "s3://${b}/datos/ventas/" --recursive | awk '{print "    "$4" ("$3" bytes)"}'

  # 2. Rol del crawler
  aws iam create-role --role-name "$ROL" \
    --description "Rol del crawler de Glue del punto 6" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{"Effect": "Allow", "Principal": {"Service": "glue.amazonaws.com"}, "Action": "sts:AssumeRole"}]
    }' \
    --tags Key=Proyecto,Value=taller-aws Key=Punto,Value=6 >/dev/null
  aws iam attach-role-policy --role-name "$ROL" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
  aws iam put-role-policy --role-name "$ROL" --policy-name leer-datos-p6 \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {\"Effect\": \"Allow\", \"Action\": \"s3:ListBucket\", \"Resource\": \"arn:aws:s3:::${b}\"},
        {\"Effect\": \"Allow\", \"Action\": \"s3:GetObject\", \"Resource\": \"arn:aws:s3:::${b}/datos/*\"}
      ]
    }"
  rol_arn=$(aws iam get-role --role-name "$ROL" --query Role.Arn --output text)
  log "Rol ${ROL} creado (AWSGlueServiceRole + lectura de datos/)"
  sleep 15  # propagación del rol en IAM

  # 3. Base de datos del catálogo
  aws glue create-database --database-input \
    "{\"Name\": \"${BASE_DE_DATOS}\", \"Description\": \"Taller AWS - punto 6\"}"
  log "Base de datos del catálogo ${BASE_DE_DATOS} creada"

  # 4. Crawler
  #    UpdateBehavior=LOG: en ejecuciones posteriores no sobrescribe el esquema corregido a mano.
  #    InheritFromTable: las particiones nuevas toman el esquema (corregido) de la tabla.
  aws glue create-crawler \
    --name "$CRAWLER" \
    --role "$rol_arn" \
    --database-name "$BASE_DE_DATOS" \
    --targets "{\"S3Targets\": [{\"Path\": \"s3://${b}/datos/ventas/\", \"Exclusions\": [\"**Zone.Identifier\"]}]}" \
    --schema-change-policy UpdateBehavior=LOG,DeleteBehavior=LOG \
    --configuration '{"Version": 1.0, "CrawlerOutput": {"Partitions": {"AddOrUpdateBehavior": "InheritFromTable"}}}' \
    --tags Proyecto=taller-aws,Punto=6
  log "Crawler ${CRAWLER} creado"

  # 5. Primera ejecución
  ejecutar_crawler
  estado
}

# --- Agregar registros -------------------------------------------------------
agregar() {
  local b
  b=$(bucket)
  aws s3 cp "${CARPETA}/datos_nuevos/ventas/" "s3://${b}/datos/ventas/" --recursive --only-show-errors \
    --exclude "*" --include "*.csv"
  log "Registros nuevos cargados:"
  aws s3 ls "s3://${b}/datos/ventas/" --recursive | awk '{print "    "$4" ("$3" bytes)"}'
}

# --- Estado ------------------------------------------------------------------
estado() {
  local b
  b=$(bucket)
  echo
  echo "===== Estado de los recursos (punto 6) ====="
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    echo "Bucket S3     : ${b} ($(aws s3 ls "s3://${b}" --recursive | wc -l) objetos)"
  else
    echo "Bucket S3     : -"
  fi
  echo "Rol IAM       : $(aws iam get-role --role-name "$ROL" --query Role.RoleName --output text 2>/dev/null || echo -)"
  if aws glue get-database --name "$BASE_DE_DATOS" >/dev/null 2>&1; then
    echo "Base catálogo : ${BASE_DE_DATOS} | tablas: $(aws glue get-tables --database-name "$BASE_DE_DATOS" \
      --query "TableList[].Name" --output text | tr '\t' ' ')"
  else
    echo "Base catálogo : -"
  fi
  if existe_crawler; then
    echo "Crawler       : ${CRAWLER} | $(aws glue get-crawler --name "$CRAWLER" \
      --query "[Crawler.State, Crawler.LastCrawl.Status]" --output text | tr '\t' ' ')"
  else
    echo "Crawler       : -"
  fi
  echo "============================================"
  echo
}

# --- Destruir ----------------------------------------------------------------
destruir() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"
  local b
  b=$(bucket)

  if existe_crawler; then
    aws glue delete-crawler --name "$CRAWLER"
    log "Crawler ${CRAWLER} eliminado"
  fi

  if aws glue get-database --name "$BASE_DE_DATOS" >/dev/null 2>&1; then
    aws glue delete-database --name "$BASE_DE_DATOS"   # elimina también sus tablas y particiones
    log "Base de datos ${BASE_DE_DATOS} eliminada (con sus tablas)"
  fi

  if aws iam get-role --role-name "$ROL" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "$ROL" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
    aws iam delete-role-policy --role-name "$ROL" --policy-name leer-datos-p6
    aws iam delete-role --role-name "$ROL"
    log "Rol ${ROL} eliminado"
  fi

  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    aws s3 rb "s3://${b}" --force >/dev/null
    log "Bucket ${b} eliminado (datos y resultados de Athena)"
  fi

  estado
}

case "${1:-}" in
  crear)    crear ;;
  crawler)  ejecutar_crawler ;;
  agregar)  agregar ;;
  estado)   estado ;;
  destruir) destruir ;;
  *) echo "Uso: bash $0 [crear|crawler|agregar|estado|destruir]"; exit 1 ;;
esac
