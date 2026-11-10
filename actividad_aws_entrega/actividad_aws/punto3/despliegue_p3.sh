#!/usr/bin/env bash
# Punto 3 - Infraestructura de DocumentDB con AWS CLI
#   - SG de la EC2 del túnel: SSH (22) solo desde tu IP pública
#   - SG de DocumentDB: 27017 solo desde el SG de la EC2
#   - Grupo de subredes + clúster DocumentDB 8.0 Serverless (0.5-1 DCU)
#     con contraseña administrada en Secrets Manager
#   - EC2 t3.micro con IP pública para el túnel SSH
#
# Uso:
#   bash despliegue_p3.sh crear
#   bash despliegue_p3.sh estado
#   bash despliegue_p3.sh destruir
#
# Requisito previo: el par de llaves "fp-taller-p3-llave" creado en EC2
# y su archivo ~/.ssh/fp-taller-p3-llave.pem en este computador.

set -euo pipefail

export AWS_DEFAULT_REGION="us-east-2"
PREFIJO="fp-taller-p3"

SG_EC2_NOMBRE="${PREFIJO}-sg-tunel"
SG_DOCDB_NOMBRE="${PREFIJO}-sg-docdb"
SUBNET_GROUP="${PREFIJO}-subnets"
CLUSTER_ID="${PREFIJO}-docdb"
INSTANCIA_ID="${PREFIJO}-docdb-1"
EC2_NOMBRE="${PREFIJO}-tunel"
LLAVE="${PREFIJO}-llave"

TAGS_EC2="{Key=Proyecto,Value=taller-aws},{Key=Punto,Value=3}"
TAGS_DOCDB="Key=Proyecto,Value=taller-aws Key=Punto,Value=3"

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

buscar_ec2() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${EC2_NOMBRE}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text
}

estado_cluster() {
  aws docdb describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
    --query "DBClusters[0].Status" --output text 2>/dev/null || echo "no-existe"
}

# --- Crear -------------------------------------------------------------------
crear() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"

  MI_IP=$(curl -s https://checkip.amazonaws.com)
  VPC_ID=$(vpc_por_defecto)
  SUBREDES=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "sort_by(Subnets,&AvailabilityZone)[].SubnetId" --output text)
  SUBRED_EC2=$(echo "$SUBREDES" | awk '{print $1}')
  read -r AMI_ID DISPOSITIVO_RAIZ < <(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
    --query "sort_by(Images,&CreationDate)[-1].[ImageId,RootDeviceName]" --output text)
  log "VPC: ${VPC_ID} | AMI: ${AMI_ID} | SSH permitido solo desde tu IP"

  # 1. Grupos de seguridad
  SG_EC2=$(aws ec2 create-security-group \
    --group-name "$SG_EC2_NOMBRE" \
    --description "EC2 del tunel SSH hacia DocumentDB" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_EC2_NOMBRE}},${TAGS_EC2}]" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_EC2" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MI_IP}/32,Description=SSH desde mi computador}]" \
    >/dev/null
  log "SG ${SG_EC2_NOMBRE} creado: ${SG_EC2} (entrada 22 desde tu IP)"

  SG_DOCDB=$(aws ec2 create-security-group \
    --group-name "$SG_DOCDB_NOMBRE" \
    --description "DocumentDB del punto 3" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_DOCDB_NOMBRE}},${TAGS_EC2}]" \
    --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_DOCDB" \
    --ip-permissions "IpProtocol=tcp,FromPort=27017,ToPort=27017,UserIdGroupPairs=[{GroupId=${SG_EC2},Description=DocumentDB desde la EC2 del tunel}]" \
    >/dev/null
  log "SG ${SG_DOCDB_NOMBRE} creado: ${SG_DOCDB} (entrada 27017 desde el SG del túnel)"

  # 2. Grupo de subredes
  # shellcheck disable=SC2086
  aws docdb create-db-subnet-group \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --db-subnet-group-description "Subredes de la VPC por defecto para DocumentDB" \
    --subnet-ids $SUBREDES \
    --tags $TAGS_DOCDB >/dev/null
  log "Grupo de subredes ${SUBNET_GROUP} creado"

  # 3. Clúster Serverless con contraseña administrada en Secrets Manager
  # shellcheck disable=SC2086
  aws docdb create-db-cluster \
    --db-cluster-identifier "$CLUSTER_ID" \
    --engine docdb --engine-version 8.0.2 \
    --master-username taller_admin \
    --manage-master-user-password \
    --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=1 \
    --storage-type standard \
    --storage-encrypted \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids "$SG_DOCDB" \
    --backup-retention-period 1 \
    --no-deletion-protection \
    --tags $TAGS_DOCDB >/dev/null
  log "Clúster ${CLUSTER_ID} en creación"

  # shellcheck disable=SC2086
  aws docdb create-db-instance \
    --db-instance-identifier "$INSTANCIA_ID" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --db-instance-class db.serverless \
    --engine docdb \
    --tags $TAGS_DOCDB >/dev/null
  log "Instancia ${INSTANCIA_ID} (db.serverless) en creación"

  # 4. EC2 del túnel, con IP pública para recibir el SSH
  EC2_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" --instance-type t3.micro --count 1 \
    --key-name "$LLAVE" \
    --network-interfaces "[{\"DeviceIndex\":0,\"SubnetId\":\"${SUBRED_EC2}\",\"Groups\":[\"${SG_EC2}\"],\"AssociatePublicIpAddress\":true}]" \
    --credit-specification CpuCredits=standard \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --block-device-mappings "[{\"DeviceName\":\"${DISPOSITIVO_RAIZ}\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${EC2_NOMBRE}},${TAGS_EC2}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${EC2_NOMBRE}},${TAGS_EC2}]" \
    --query "Instances[0].InstanceId" --output text)
  log "EC2 ${EC2_NOMBRE} en creación: ${EC2_ID}"

  # 5. Esperas
  aws ec2 wait instance-running --instance-ids "$EC2_ID"
  log "EC2 en ejecución"
  log "Esperando a DocumentDB (suele tardar 10-15 minutos)..."
  aws docdb wait db-instance-available --db-instance-identifier "$INSTANCIA_ID"
  log "DocumentDB disponible"

  estado
}

# --- Estado ------------------------------------------------------------------
estado() {
  local vpc
  vpc=$(vpc_por_defecto)
  echo
  echo "===== Estado de los recursos (punto 3) ====="
  echo "SG túnel      : $(buscar_sg "$SG_EC2_NOMBRE" "$vpc" | sed 's/^$/-/')"
  echo "SG DocumentDB : $(buscar_sg "$SG_DOCDB_NOMBRE" "$vpc" | sed 's/^$/-/')"
  if [[ "$(estado_cluster)" != "no-existe" ]]; then
    aws docdb describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
      --query "DBClusters[0].[Status,Endpoint,EngineVersion,ServerlessV2ScalingConfiguration.MinCapacity,ServerlessV2ScalingConfiguration.MaxCapacity]" \
      --output text | awk '{print "Clúster       : "$1" | "$2" | motor "$3" | "$4"-"$5" DCU"}'
    aws docdb describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
      --query "DBClusters[0].MasterUserSecret.[SecretArn,SecretStatus]" \
      --output text | awk '{print "Secreto       : "$1" | "$2}'
    aws docdb describe-db-instances --db-instance-identifier "$INSTANCIA_ID" \
      --query "DBInstances[0].[DBInstanceClass,DBInstanceStatus]" --output text 2>/dev/null |
      awk '{print "Instancia     : "$1" | "$2}' || true
  else
    echo "Clúster       : -"
  fi
  local ec2_id
  ec2_id=$(buscar_ec2)
  if [[ -n "$ec2_id" ]]; then
    aws ec2 describe-instances --instance-ids "$ec2_id" \
      --query "Reservations[0].Instances[0].[InstanceId,State.Name,PublicDnsName]" \
      --output text | awk '{print "EC2 túnel     : "$1" | "$2" | "$3}'
  else
    echo "EC2 túnel     : -"
  fi
  echo "============================================"
  echo
}

# --- Destruir ----------------------------------------------------------------
borrar_sg() {  # $1 = nombre, $2 = vpc
  local id
  id=$(buscar_sg "$1" "$2")
  if [[ -z "$id" ]]; then log "SG $1 no existe"; return; fi
  for intento in $(seq 1 20); do
    if aws ec2 delete-security-group --group-id "$id" >/dev/null 2>&1; then
      log "SG $1 eliminado"; return
    fi
    log "SG $1 aún en uso, reintento ${intento}/20 en 15 s"
    sleep 15
  done
  log "No se pudo eliminar $1"; exit 1
}

destruir() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"
  local vpc ec2_id
  vpc=$(vpc_por_defecto)

  ec2_id=$(buscar_ec2)
  if [[ -n "$ec2_id" ]]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ec2_id >/dev/null
    log "EC2 en terminación: ${ec2_id}"
  fi

  if aws docdb describe-db-instances --db-instance-identifier "$INSTANCIA_ID" >/dev/null 2>&1; then
    aws docdb delete-db-instance --db-instance-identifier "$INSTANCIA_ID" >/dev/null
    log "Instancia ${INSTANCIA_ID} en eliminación..."
    aws docdb wait db-instance-deleted --db-instance-identifier "$INSTANCIA_ID"
    log "Instancia eliminada"
  fi

  if [[ "$(estado_cluster)" != "no-existe" ]]; then
    aws docdb delete-db-cluster --db-cluster-identifier "$CLUSTER_ID" \
      --skip-final-snapshot >/dev/null
    log "Clúster ${CLUSTER_ID} en eliminación (su secreto administrado se borra con él)..."
    while [[ "$(estado_cluster)" != "no-existe" ]]; do sleep 20; done
    log "Clúster eliminado"
  fi

  if [[ -n "$ec2_id" ]]; then
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $ec2_id
    log "EC2 terminada"
  fi

  if aws docdb delete-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" 2>/dev/null; then
    log "Grupo de subredes ${SUBNET_GROUP} eliminado"
  else
    log "Grupo de subredes ${SUBNET_GROUP} no existe"
  fi

  borrar_sg "$SG_DOCDB_NOMBRE" "$vpc"
  borrar_sg "$SG_EC2_NOMBRE" "$vpc"

  estado
}

case "${1:-}" in
  crear)    crear ;;
  estado)   estado ;;
  destruir) destruir ;;
  *) echo "Uso: bash $0 [crear|estado|destruir]"; exit 1 ;;
esac
