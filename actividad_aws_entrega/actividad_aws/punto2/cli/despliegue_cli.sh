#!/usr/bin/env bash
# Punto 2 - Versión AWS CLI
# Crea y elimina la misma infraestructura que las versiones Terraform y Boto3.
#
# Uso:
#   bash despliegue_cli.sh crear
#   bash despliegue_cli.sh estado
#   bash despliegue_cli.sh secreto
#   bash despliegue_cli.sh destruir
#
# Credenciales: AWS CLI usa el perfil `default` (~/.aws/credentials).
# No hay contraseñas en este script: RDS genera la suya y la guarda en Secrets Manager.

set -euo pipefail

# --- Configuración (equivale a variables.tf) ---------------------------------
export AWS_DEFAULT_REGION="us-east-2"
PREFIJO="fp-taller-p2-cli"

SG_EC2_NOMBRE="${PREFIJO}-sg-ec2"
SG_RDS_NOMBRE="${PREFIJO}-sg-rds"
SUBNET_GROUP="${PREFIJO}-subnets"
RDS_ID="${PREFIJO}-rds"
EC2_NOMBRE="${PREFIJO}-ec2"

# Etiquetas en los dos formatos que usa la CLI
TAGS_EC2="{Key=Proyecto,Value=taller-aws},{Key=Punto,Value=2},{Key=Metodo,Value=cli}"
TAGS_RDS="Key=Proyecto,Value=taller-aws Key=Punto,Value=2 Key=Metodo,Value=cli"

log() { echo "[$(date +%H:%M:%S)] $*"; }

cuenta()  { aws sts get-caller-identity --query Account --output text; }
bucket()  { echo "${PREFIJO}-$(cuenta)"; }

# --- Búsquedas (equivale a data.tf) ------------------------------------------
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

existe_rds() {
  aws rds describe-db-instances --db-instance-identifier "$RDS_ID" >/dev/null 2>&1
}

# --- Crear -------------------------------------------------------------------
crear() {
  log "Identidad: $(aws sts get-caller-identity --query Arn --output text)"

  # 1. Red existente
  VPC_ID=$(vpc_por_defecto)
  SUBREDES=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "sort_by(Subnets,&AvailabilityZone)[].SubnetId" --output text)
  SUBRED_EC2=$(echo "$SUBREDES" | awk '{print $1}')
  read -r AMI_ID DISPOSITIVO_RAIZ < <(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
    --query "sort_by(Images,&CreationDate)[-1].[ImageId,RootDeviceName]" --output text)
  log "VPC: ${VPC_ID} | subredes: ${SUBREDES} | AMI: ${AMI_ID}"

  # 2. Grupos de seguridad (equivale a network.tf)
  #    Un SG nuevo ya trae la regla de salida 0.0.0.0/0.
  SG_EC2=$(aws ec2 create-security-group \
    --group-name "$SG_EC2_NOMBRE" \
    --description "Grupo de seguridad de la instancia EC2 del punto 2" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_EC2_NOMBRE}},${TAGS_EC2}]" \
    --query GroupId --output text)
  log "SG ${SG_EC2_NOMBRE} creado: ${SG_EC2}"

  SG_RDS=$(aws ec2 create-security-group \
    --group-name "$SG_RDS_NOMBRE" \
    --description "Grupo de seguridad de RDS PostgreSQL del punto 2" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_RDS_NOMBRE}},${TAGS_EC2}]" \
    --query GroupId --output text)
  log "SG ${SG_RDS_NOMBRE} creado: ${SG_RDS}"

  aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${SG_EC2},Description=PostgreSQL desde la EC2}]" \
    >/dev/null
  log "Regla RDS <- EC2:5432 creada"

  # 3. Subnet group + RDS (equivale a rds.tf)
  # shellcheck disable=SC2086  # SUBREDES se separa en varios argumentos a propósito
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --db-subnet-group-description "Subredes de la VPC por defecto para RDS del punto 2" \
    --subnet-ids $SUBREDES \
    --tags $TAGS_RDS >/dev/null
  log "DB subnet group ${SUBNET_GROUP} creado"

  # shellcheck disable=SC2086
  aws rds create-db-instance \
    --db-instance-identifier "$RDS_ID" \
    --engine postgres --engine-version 17 \
    --db-instance-class db.t4g.micro \
    --allocated-storage 20 --storage-type gp3 --storage-encrypted \
    --db-name taller --master-username taller_admin \
    --manage-master-user-password \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids "$SG_RDS" \
    --no-publicly-accessible --no-multi-az \
    --backup-retention-period 0 --no-deletion-protection \
    --tags $TAGS_RDS >/dev/null
  log "RDS ${RDS_ID} en creación"

  # 4. EC2 (equivale a ec2.tf)
  EC2_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" --instance-type t3.micro --count 1 \
    --network-interfaces "[{\"DeviceIndex\":0,\"SubnetId\":\"${SUBRED_EC2}\",\"Groups\":[\"${SG_EC2}\"],\"AssociatePublicIpAddress\":false}]" \
    --credit-specification CpuCredits=standard \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --block-device-mappings "[{\"DeviceName\":\"${DISPOSITIVO_RAIZ}\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${EC2_NOMBRE}},${TAGS_EC2}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${EC2_NOMBRE}},${TAGS_EC2}]" \
    --query "Instances[0].InstanceId" --output text)
  log "EC2 ${EC2_NOMBRE} en creación: ${EC2_ID}"

  # 5. S3 (equivale a s3.tf). Fuera de us-east-1 hay que indicar la región.
  BUCKET=$(bucket)
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_DEFAULT_REGION" >/dev/null
  aws s3api put-bucket-tagging --bucket "$BUCKET" \
    --tagging "TagSet=[${TAGS_EC2}]"
  log "Bucket ${BUCKET} creado"

  # 6. Esperar a que todo quede listo
  log "Esperando a que la EC2 esté en ejecución..."
  aws ec2 wait instance-running --instance-ids "$EC2_ID"
  log "EC2 en ejecución"

  log "Esperando a que RDS esté disponible (suele tardar 5-15 minutos)..."
  aws rds wait db-instance-available --db-instance-identifier "$RDS_ID"
  log "RDS disponible"

  estado
  comprobar_secreto
}

comprobar_secreto() {
  # Recupera el secreto de RDS en tiempo de ejecución sin mostrar la contraseña
  local arn
  arn=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
    --query "DBInstances[0].MasterUserSecret.SecretArn" --output text)
  aws secretsmanager get-secret-value --secret-id "$arn" \
    --query SecretString --output text |
    python3 -c 'import json,sys,time; s=json.load(sys.stdin); u=s["username"]; n=len(s["password"]); t=time.strftime("%H:%M:%S"); print(f"[{t}] Secreto recuperado de Secrets Manager: usuario={u}, contraseña=(oculta, {n} caracteres)")'
}

# --- Estado (evidencias) -----------------------------------------------------
estado() {
  local vpc
  vpc=$(vpc_por_defecto)
  echo
  echo "===== Estado de los recursos (Metodo=cli) ====="
  echo "SG EC2       : $(buscar_sg "$SG_EC2_NOMBRE" "$vpc" | sed 's/^$/-/')"
  echo "SG RDS       : $(buscar_sg "$SG_RDS_NOMBRE" "$vpc" | sed 's/^$/-/')"
  if aws rds describe-db-subnet-groups --db-subnet-group-name "$SUBNET_GROUP" >/dev/null 2>&1; then
    echo "Subnet group : ${SUBNET_GROUP}"
  else
    echo "Subnet group : -"
  fi
  if existe_rds; then
    aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
      --query "DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Endpoint.Address]" \
      --output text | awk '{print "RDS          : "$1" | "$2" | "$3}'
    aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
      --query "DBInstances[0].MasterUserSecret.[SecretArn,SecretStatus]" \
      --output text | awk '{print "Secreto RDS  : "$1" | "$2}'
  else
    echo "RDS          : -"
  fi
  local ec2_ids
  ec2_ids=$(buscar_ec2)
  echo "EC2          : ${ec2_ids:--}"
  if aws s3api head-bucket --bucket "$(bucket)" >/dev/null 2>&1; then
    echo "Bucket S3    : $(bucket)"
  else
    echo "Bucket S3    : -"
  fi
  echo "==============================================="
  echo
}

# --- Destruir (orden inverso) ------------------------------------------------
borrar_sg() {  # $1 = nombre, $2 = vpc. Reintenta mientras AWS libera las interfaces de red.
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
  local vpc ec2_ids
  vpc=$(vpc_por_defecto)

  # 1. EC2 y RDS en paralelo
  ec2_ids=$(buscar_ec2)
  if [[ -n "$ec2_ids" ]]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ec2_ids >/dev/null
    log "EC2 en terminación: ${ec2_ids}"
  fi

  if existe_rds; then
    aws rds delete-db-instance --db-instance-identifier "$RDS_ID" \
      --skip-final-snapshot --delete-automated-backups >/dev/null
    log "RDS ${RDS_ID} en eliminación (su secreto administrado se borra con ella)"
  fi

  if [[ -n "$ec2_ids" ]]; then
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $ec2_ids
    log "EC2 terminada (su volumen gp3 se borra con ella)"
  fi

  log "Esperando a que RDS se elimine..."
  aws rds wait db-instance-deleted --db-instance-identifier "$RDS_ID"
  log "RDS eliminada"

  # 2. Subnet group
  if aws rds delete-db-subnet-group --db-subnet-group-name "$SUBNET_GROUP" 2>/dev/null; then
    log "DB subnet group ${SUBNET_GROUP} eliminado"
  else
    log "DB subnet group ${SUBNET_GROUP} no existe"
  fi

  # 3. Grupos de seguridad: primero el de RDS, que referencia al de la EC2
  borrar_sg "$SG_RDS_NOMBRE" "$vpc"
  borrar_sg "$SG_EC2_NOMBRE" "$vpc"

  # 4. Bucket: vaciar y borrar
  local b
  b=$(bucket)
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    aws s3 rb "s3://${b}" --force >/dev/null
    log "Bucket ${b} eliminado"
  else
    log "Bucket ${b} no existe"
  fi

  estado
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  crear)    crear ;;
  estado)   estado ;;
  secreto)  comprobar_secreto ;;
  destruir) destruir ;;
  *) echo "Uso: bash $0 [crear|estado|secreto|destruir]"; exit 1 ;;
esac
