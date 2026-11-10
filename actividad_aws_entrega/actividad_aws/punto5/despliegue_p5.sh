#!/usr/bin/env bash
# Punto 5 - Infraestructura de Amazon Redshift Serverless con AWS CLI
#   - Bucket S3 para los archivos CSV
#   - Rol de IAM que Redshift asume para leer el bucket (COPY)
#   - Grupo de seguridad sin reglas de entrada (se usa la API de datos, no conexiones directas)
#   - Namespace con contraseña de administración administrada en Secrets Manager
#   - Workgroup de 4 RPU (base y máximo), sin acceso público
#
# Uso:
#   bash despliegue_p5.sh crear
#   bash despliegue_p5.sh estado
#   bash despliegue_p5.sh destruir

set -euo pipefail

export AWS_DEFAULT_REGION="us-east-2"
PREFIJO="fp-taller-p5"

NAMESPACE="${PREFIJO}-ns"
WORKGROUP="${PREFIJO}-wg"
ROL="${PREFIJO}-redshift-s3"
SG_NOMBRE="${PREFIJO}-sg-redshift"

TAGS_EC2="{Key=Proyecto,Value=taller-aws},{Key=Punto,Value=5}"
TAGS_RS="key=Proyecto,value=taller-aws key=Punto,value=5"

log() { echo "[$(date +%H:%M:%S)] $*"; }

cuenta() { aws sts get-caller-identity --query Account --output text; }
bucket() { echo "${PREFIJO}-$(cuenta)"; }

vpc_por_defecto() {
  aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query "Vpcs[0].VpcId" --output text
}

buscar_sg() {  # $1 = vpc
  local id
  id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NOMBRE}" "Name=vpc-id,Values=$1" \
    --query "SecurityGroups[0].GroupId" --output text)
  [[ "$id" == "None" ]] && echo "" || echo "$id"
}

estado_namespace() {
  aws redshift-serverless get-namespace --namespace-name "$NAMESPACE" \
    --query "namespace.status" --output text 2>/dev/null || echo "no-existe"
}

estado_workgroup() {
  aws redshift-serverless get-workgroup --workgroup-name "$WORKGROUP" \
    --query "workgroup.status" --output text 2>/dev/null || echo "no-existe"
}

esperar() {  # $1 = función de estado, $2 = estado esperado, $3 = descripción
  local actual
  while true; do
    actual=$($1)
    [[ "$actual" == "$2" ]] && break
    log "$3: ${actual}, esperando 20 s..."
    sleep 20
  done
}

# --- Crear -------------------------------------------------------------------
crear() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"

  VPC_ID=$(vpc_por_defecto)
  SUBREDES=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "sort_by(Subnets,&AvailabilityZone)[].SubnetId" --output text)
  BUCKET=$(bucket)

  # 1. Bucket para los CSV
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_DEFAULT_REGION" >/dev/null
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[${TAGS_EC2}]"
  log "Bucket ${BUCKET} creado"

  # 2. Rol que Redshift asume para leer el bucket durante el COPY
  aws iam create-role --role-name "$ROL" \
    --description "Permite a Redshift Serverless leer los CSV del punto 5" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": ["redshift.amazonaws.com", "redshift-serverless.amazonaws.com"]},
        "Action": "sts:AssumeRole"
      }]
    }' \
    --tags Key=Proyecto,Value=taller-aws Key=Punto,Value=5 >/dev/null
  aws iam put-role-policy --role-name "$ROL" --policy-name leer-bucket-p5 \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {\"Effect\": \"Allow\", \"Action\": [\"s3:ListBucket\", \"s3:GetBucketLocation\"], \"Resource\": \"arn:aws:s3:::${BUCKET}\"},
        {\"Effect\": \"Allow\", \"Action\": \"s3:GetObject\", \"Resource\": \"arn:aws:s3:::${BUCKET}/*\"}
      ]
    }"
  ROL_ARN=$(aws iam get-role --role-name "$ROL" --query Role.Arn --output text)
  log "Rol ${ROL} creado (solo lectura del bucket): ${ROL_ARN}"
  sleep 15  # IAM tarda unos segundos en propagar un rol nuevo

  # 3. Grupo de seguridad sin reglas de entrada
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NOMBRE" \
    --description "Redshift Serverless del punto 5 sin entrada: se usa la API de datos" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NOMBRE}},${TAGS_EC2}]" \
    --query GroupId --output text)
  log "SG ${SG_NOMBRE} creado: ${SG_ID} (sin reglas de entrada)"

  # 4. Namespace con la contraseña de administración en Secrets Manager
  # shellcheck disable=SC2086
  aws redshift-serverless create-namespace \
    --namespace-name "$NAMESPACE" \
    --admin-username taller_admin \
    --manage-admin-password \
    --db-name taller \
    --iam-roles "$ROL_ARN" \
    --default-iam-role-arn "$ROL_ARN" \
    --tags $TAGS_RS >/dev/null
  log "Namespace ${NAMESPACE} en creación"
  esperar estado_namespace AVAILABLE "Namespace"
  log "Namespace disponible"

  # 5. Workgroup de 4 RPU sin acceso público
  # shellcheck disable=SC2086
  aws redshift-serverless create-workgroup \
    --workgroup-name "$WORKGROUP" \
    --namespace-name "$NAMESPACE" \
    --base-capacity 4 --max-capacity 4 \
    --subnet-ids $SUBREDES \
    --security-group-ids "$SG_ID" \
    --no-publicly-accessible \
    --tags $TAGS_RS >/dev/null
  log "Workgroup ${WORKGROUP} (4 RPU) en creación"
  esperar estado_workgroup AVAILABLE "Workgroup"
  log "Workgroup disponible"

  estado
}

# --- Estado ------------------------------------------------------------------
estado() {
  local vpc b
  vpc=$(vpc_por_defecto)
  b=$(bucket)
  echo
  echo "===== Estado de los recursos (punto 5) ====="
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    echo "Bucket S3     : ${b}"
  else
    echo "Bucket S3     : -"
  fi
  echo "Rol IAM       : $(aws iam get-role --role-name "$ROL" --query Role.Arn --output text 2>/dev/null || echo -)"
  echo "SG Redshift   : $(buscar_sg "$vpc" | sed 's/^$/-/')"
  if [[ "$(estado_namespace)" != "no-existe" ]]; then
    aws redshift-serverless get-namespace --namespace-name "$NAMESPACE" \
      --query "namespace.[status,dbName,adminUsername]" --output text |
      awk '{print "Namespace     : '"$NAMESPACE"' | "$1" | base "$2" | admin "$3}'
    echo "Secreto admin : $(aws redshift-serverless get-namespace --namespace-name "$NAMESPACE" \
      --query "namespace.adminPasswordSecretArn" --output text)"
  else
    echo "Namespace     : -"
  fi
  if [[ "$(estado_workgroup)" != "no-existe" ]]; then
    aws redshift-serverless get-workgroup --workgroup-name "$WORKGROUP" \
      --query "workgroup.[status,baseCapacity,maxCapacity,publiclyAccessible]" --output text |
      awk '{print "Workgroup     : '"$WORKGROUP"' | "$1" | "$2"-"$3" RPU | público="$4}'
  else
    echo "Workgroup     : -"
  fi
  echo "============================================"
  echo
}

# --- Destruir ----------------------------------------------------------------
destruir() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"
  local vpc sg_id b
  vpc=$(vpc_por_defecto)

  if [[ "$(estado_workgroup)" != "no-existe" ]]; then
    aws redshift-serverless delete-workgroup --workgroup-name "$WORKGROUP" >/dev/null
    log "Workgroup ${WORKGROUP} en eliminación..."
    esperar estado_workgroup no-existe "Workgroup"
    log "Workgroup eliminado"
  fi

  if [[ "$(estado_namespace)" != "no-existe" ]]; then
    # Sin --final-snapshot-name: no se crea una instantánea final que siga cobrando
    aws redshift-serverless delete-namespace --namespace-name "$NAMESPACE" >/dev/null
    log "Namespace ${NAMESPACE} en eliminación (su secreto administrado se borra con él)..."
    esperar estado_namespace no-existe "Namespace"
    log "Namespace eliminado"
  fi

  sg_id=$(buscar_sg "$vpc")
  if [[ -n "$sg_id" ]]; then
    for intento in $(seq 1 20); do
      if aws ec2 delete-security-group --group-id "$sg_id" >/dev/null 2>&1; then
        log "SG ${SG_NOMBRE} eliminado"; break
      fi
      log "SG aún en uso, reintento ${intento}/20 en 15 s"; sleep 15
    done
  else
    log "SG ${SG_NOMBRE} no existe"
  fi

  if aws iam get-role --role-name "$ROL" >/dev/null 2>&1; then
    aws iam delete-role-policy --role-name "$ROL" --policy-name leer-bucket-p5 2>/dev/null || true
    aws iam delete-role --role-name "$ROL"
    log "Rol ${ROL} eliminado"
  else
    log "Rol ${ROL} no existe"
  fi

  b=$(bucket)
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    aws s3 rb "s3://${b}" --force >/dev/null
    log "Bucket ${b} eliminado"
  else
    log "Bucket ${b} no existe"
  fi

  estado
}

case "${1:-}" in
  crear)    crear ;;
  estado)   estado ;;
  destruir) destruir ;;
  *) echo "Uso: bash $0 [crear|estado|destruir]"; exit 1 ;;
esac
