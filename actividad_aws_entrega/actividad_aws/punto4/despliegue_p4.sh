#!/usr/bin/env bash
# Punto 4 - Infraestructura de Amazon Neptune con AWS CLI
#   - SG de Neptune: puerto 8182 solo desde tu IP pública
#   - Grupo de subredes con las subredes públicas de la VPC por defecto
#   - Clúster Neptune 1.4.8.1 con autenticación IAM (obligatoria para endpoint público)
#   - Instancia db.t4g.medium con endpoint público
#
# Uso:
#   bash despliegue_p4.sh crear
#   bash despliegue_p4.sh estado
#   bash despliegue_p4.sh destruir

set -euo pipefail

export AWS_DEFAULT_REGION="us-east-2"
PREFIJO="fp-taller-p4"
VERSION_MOTOR="1.4.8.1"

SG_NOMBRE="${PREFIJO}-sg-neptune"
SUBNET_GROUP="${PREFIJO}-subnets"
CLUSTER_ID="${PREFIJO}-neptune"
INSTANCIA_ID="${PREFIJO}-neptune-1"

TAGS_EC2="{Key=Proyecto,Value=taller-aws},{Key=Punto,Value=4}"
TAGS_NEPTUNE="Key=Proyecto,Value=taller-aws Key=Punto,Value=4"

log() { echo "[$(date +%H:%M:%S)] $*"; }

vpc_por_defecto() {
  aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query "Vpcs[0].VpcId" --output text
}

buscar_sg() {  # $1 = nombre, $2 = vpc
  local id
  id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$2" \
    --query "SecurityGroups[0].GroupId" --output text)
  [[ "$id" == "None" ]] && echo "" || echo "$id"
}

estado_cluster() {
  aws neptune describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
    --query "DBClusters[0].Status" --output text 2>/dev/null || echo "no-existe"
}

# --- Crear -------------------------------------------------------------------
crear() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"

  MI_IP=$(curl -s https://checkip.amazonaws.com)
  VPC_ID=$(vpc_por_defecto)
  SUBREDES=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "sort_by(Subnets,&AvailabilityZone)[].SubnetId" --output text)

  # Un endpoint público requiere subredes con ruta 0.0.0.0/0 hacia un internet gateway
  IGW_RUTA=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=true" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text)
  log "VPC: ${VPC_ID} | ruta 0.0.0.0/0 de la tabla principal -> ${IGW_RUTA}"
  if [[ "$IGW_RUTA" != igw-* ]]; then
    log "Las subredes no tienen ruta a un internet gateway: el endpoint público no funcionaría"; exit 1
  fi

  # 1. Grupo de seguridad
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NOMBRE" \
    --description "Neptune del punto 4 con endpoint publico" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NOMBRE}},${TAGS_EC2}]" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=8182,ToPort=8182,IpRanges=[{CidrIp=${MI_IP}/32,Description=Neptune desde mi computador}]" \
    >/dev/null
  log "SG ${SG_NOMBRE} creado: ${SG_ID} (entrada 8182 solo desde tu IP)"

  # 2. Grupo de subredes
  # shellcheck disable=SC2086
  aws neptune create-db-subnet-group \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --db-subnet-group-description "Subredes publicas de la VPC por defecto para Neptune" \
    --subnet-ids $SUBREDES \
    --tags $TAGS_NEPTUNE >/dev/null
  log "Grupo de subredes ${SUBNET_GROUP} creado"

  # 3. Clúster con autenticación IAM (no hay usuario ni contraseña)
  # shellcheck disable=SC2086
  aws neptune create-db-cluster \
    --db-cluster-identifier "$CLUSTER_ID" \
    --engine neptune --engine-version "$VERSION_MOTOR" \
    --enable-iam-database-authentication \
    --storage-encrypted \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids "$SG_ID" \
    --backup-retention-period 1 \
    --no-deletion-protection \
    --tags $TAGS_NEPTUNE >/dev/null
  log "Clúster ${CLUSTER_ID} (motor ${VERSION_MOTOR}, IAM activada) en creación"

  # 4. Instancia aprovisionada con endpoint público
  # shellcheck disable=SC2086
  aws neptune create-db-instance \
    --db-instance-identifier "$INSTANCIA_ID" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --db-instance-class db.t4g.medium \
    --engine neptune \
    --publicly-accessible \
    --tags $TAGS_NEPTUNE >/dev/null
  log "Instancia ${INSTANCIA_ID} (db.t4g.medium, pública) en creación"

  log "Esperando a Neptune (suele tardar 10-15 minutos)..."
  aws neptune wait db-instance-available --db-instance-identifier "$INSTANCIA_ID"
  log "Neptune disponible"

  estado
}

# --- Estado ------------------------------------------------------------------
estado() {
  local vpc
  vpc=$(vpc_por_defecto)
  echo
  echo "===== Estado de los recursos (punto 4) ====="
  echo "SG Neptune    : $(buscar_sg "$SG_NOMBRE" "$vpc" | sed 's/^$/-/')"
  if [[ "$(estado_cluster)" != "no-existe" ]]; then
    aws neptune describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
      --query "DBClusters[0].[Status,Endpoint,Port,EngineVersion,IAMDatabaseAuthenticationEnabled]" \
      --output text | awk '{print "Clúster       : "$1" | "$2":"$3" | motor "$4" | IAM="$5}'
    aws neptune describe-db-instances --db-instance-identifier "$INSTANCIA_ID" \
      --query "DBInstances[0].[DBInstanceClass,DBInstanceStatus,PubliclyAccessible]" \
      --output text 2>/dev/null | awk '{print "Instancia     : "$1" | "$2" | pública="$3}' || true
  else
    echo "Clúster       : -"
  fi
  echo "============================================"
  echo
}

# --- Destruir ----------------------------------------------------------------
destruir() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"
  local vpc sg_id
  vpc=$(vpc_por_defecto)

  if aws neptune describe-db-instances --db-instance-identifier "$INSTANCIA_ID" >/dev/null 2>&1; then
    aws neptune delete-db-instance --db-instance-identifier "$INSTANCIA_ID" >/dev/null
    log "Instancia ${INSTANCIA_ID} en eliminación..."
    aws neptune wait db-instance-deleted --db-instance-identifier "$INSTANCIA_ID"
    log "Instancia eliminada"
  fi

  if [[ "$(estado_cluster)" != "no-existe" ]]; then
    aws neptune delete-db-cluster --db-cluster-identifier "$CLUSTER_ID" --skip-final-snapshot >/dev/null
    log "Clúster ${CLUSTER_ID} en eliminación..."
    while [[ "$(estado_cluster)" != "no-existe" ]]; do sleep 20; done
    log "Clúster eliminado"
  fi

  if aws neptune delete-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" 2>/dev/null; then
    log "Grupo de subredes ${SUBNET_GROUP} eliminado"
  else
    log "Grupo de subredes ${SUBNET_GROUP} no existe"
  fi

  sg_id=$(buscar_sg "$SG_NOMBRE" "$vpc")
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

  estado
}

case "${1:-}" in
  crear)    crear ;;
  estado)   estado ;;
  destruir) destruir ;;
  *) echo "Uso: bash $0 [crear|estado|destruir]"; exit 1 ;;
esac
