"""
Punto 2 - Versión Boto3
Crea y elimina la misma infraestructura que la versión Terraform:
  - 2 grupos de seguridad (EC2 y RDS) en la VPC por defecto
  - DB subnet group + RDS PostgreSQL 17 con contraseña administrada en Secrets Manager
  - Instancia EC2 t3.micro sin IP pública
  - Bucket S3

Uso:
  python despliegue_boto3.py crear      # crea todo y espera a que quede listo
  python despliegue_boto3.py estado     # muestra qué existe
  python despliegue_boto3.py destruir   # elimina todo en orden inverso

Credenciales: Boto3 las toma del perfil `default` de AWS CLI (~/.aws/credentials).
No hay contraseñas en este código: RDS genera la suya y la guarda en Secrets Manager.
"""

import json
import sys
import time

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Configuración (equivale a variables.tf)
# ---------------------------------------------------------------------------
REGION = "us-east-2"
PREFIJO = "fp-taller-p2-boto3"

ETIQUETAS = {"Proyecto": "taller-aws", "Punto": "2", "Metodo": "boto3"}

NOMBRE_SG_EC2 = f"{PREFIJO}-sg-ec2"
NOMBRE_SG_RDS = f"{PREFIJO}-sg-rds"
NOMBRE_SUBNET_GROUP = f"{PREFIJO}-subnets"
ID_RDS = f"{PREFIJO}-rds"
NOMBRE_EC2 = f"{PREFIJO}-ec2"

ec2 = boto3.client("ec2", region_name=REGION)
rds = boto3.client("rds", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
secrets = boto3.client("secretsmanager", region_name=REGION)
sts = boto3.client("sts", region_name=REGION)


def log(mensaje):
    print(f"[{time.strftime('%H:%M:%S')}] {mensaje}", flush=True)


def etiquetas_ec2(nombre=None):
    """Formato de etiquetas que usa EC2: lista de {Key, Value}."""
    tags = [{"Key": k, "Value": v} for k, v in ETIQUETAS.items()]
    if nombre:
        tags.append({"Key": "Name", "Value": nombre})
    return tags


def nombre_bucket():
    """Nombre único y predecible: el modo destruir lo calcula igual."""
    cuenta = sts.get_caller_identity()["Account"]
    return f"{PREFIJO}-{cuenta}"


# ---------------------------------------------------------------------------
# Búsquedas (equivale a data.tf)
# ---------------------------------------------------------------------------
def vpc_por_defecto():
    vpcs = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"]
    if not vpcs:
        sys.exit("No hay VPC por defecto en la región.")
    return vpcs[0]["VpcId"]


def subredes_de(vpc_id):
    subredes = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"]
    subredes.sort(key=lambda s: s["AvailabilityZone"])
    return [s["SubnetId"] for s in subredes]


def ami_amazon_linux():
    imagenes = ec2.describe_images(
        Owners=["amazon"],
        Filters=[
            {"Name": "name", "Values": ["al2023-ami-2023.*-x86_64"]},
            {"Name": "state", "Values": ["available"]},
        ],
    )["Images"]
    mas_reciente = max(imagenes, key=lambda i: i["CreationDate"])
    return mas_reciente["ImageId"], mas_reciente["RootDeviceName"]


def buscar_sg(nombre, vpc_id):
    grupos = ec2.describe_security_groups(
        Filters=[
            {"Name": "group-name", "Values": [nombre]},
            {"Name": "vpc-id", "Values": [vpc_id]},
        ]
    )["SecurityGroups"]
    return grupos[0]["GroupId"] if grupos else None


def buscar_ec2():
    reservas = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [NOMBRE_EC2]},
            {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]},
        ]
    )["Reservations"]
    return [i["InstanceId"] for r in reservas for i in r["Instances"]]


def buscar_rds():
    try:
        return rds.describe_db_instances(DBInstanceIdentifier=ID_RDS)["DBInstances"][0]
    except ClientError as e:
        if e.response["Error"]["Code"] == "DBInstanceNotFound":
            return None
        raise


# ---------------------------------------------------------------------------
# Crear
# ---------------------------------------------------------------------------
def crear_sg(nombre, descripcion, vpc_id):
    existente = buscar_sg(nombre, vpc_id)
    if existente:
        log(f"SG {nombre} ya existe: {existente}")
        return existente
    sg_id = ec2.create_security_group(
        GroupName=nombre,
        Description=descripcion,
        VpcId=vpc_id,
        TagSpecifications=[{"ResourceType": "security-group", "Tags": etiquetas_ec2(nombre)}],
    )["GroupId"]
    log(f"SG {nombre} creado: {sg_id}")
    return sg_id


def crear():
    log(f"Identidad: {sts.get_caller_identity()['Arn']}")

    # 1. Red existente
    vpc_id = vpc_por_defecto()
    subredes = subredes_de(vpc_id)
    ami_id, dispositivo_raiz = ami_amazon_linux()
    log(f"VPC: {vpc_id} | subredes: {subredes} | AMI: {ami_id}")

    # 2. Grupos de seguridad (equivale a network.tf)
    #    Un SG nuevo ya trae la regla de salida 0.0.0.0/0, igual a la que define Terraform.
    sg_ec2 = crear_sg(NOMBRE_SG_EC2, "Grupo de seguridad de la instancia EC2 del punto 2", vpc_id)
    sg_rds = crear_sg(NOMBRE_SG_RDS, "Grupo de seguridad de RDS PostgreSQL del punto 2", vpc_id)

    try:
        ec2.authorize_security_group_ingress(
            GroupId=sg_rds,
            IpPermissions=[{
                "IpProtocol": "tcp",
                "FromPort": 5432,
                "ToPort": 5432,
                "UserIdGroupPairs": [{"GroupId": sg_ec2, "Description": "PostgreSQL desde la EC2"}],
            }],
        )
        log("Regla RDS <- EC2:5432 creada")
    except ClientError as e:
        if e.response["Error"]["Code"] != "InvalidPermission.Duplicate":
            raise
        log("Regla RDS <- EC2:5432 ya existía")

    # 3. Subnet group + RDS (equivale a rds.tf)
    try:
        rds.create_db_subnet_group(
            DBSubnetGroupName=NOMBRE_SUBNET_GROUP,
            DBSubnetGroupDescription="Subredes de la VPC por defecto para RDS del punto 2",
            SubnetIds=subredes,
            Tags=[{"Key": k, "Value": v} for k, v in ETIQUETAS.items()],
        )
        log(f"DB subnet group {NOMBRE_SUBNET_GROUP} creado")
    except ClientError as e:
        if e.response["Error"]["Code"] != "DBSubnetGroupAlreadyExists":
            raise
        log(f"DB subnet group {NOMBRE_SUBNET_GROUP} ya existía")

    if buscar_rds():
        log(f"RDS {ID_RDS} ya existe")
    else:
        rds.create_db_instance(
            DBInstanceIdentifier=ID_RDS,
            Engine="postgres",
            EngineVersion="17",
            DBInstanceClass="db.t4g.micro",
            AllocatedStorage=20,
            StorageType="gp3",
            StorageEncrypted=True,
            DBName="taller",
            MasterUsername="taller_admin",
            ManageMasterUserPassword=True,  # RDS crea y guarda la contraseña en Secrets Manager
            DBSubnetGroupName=NOMBRE_SUBNET_GROUP,
            VpcSecurityGroupIds=[sg_rds],
            PubliclyAccessible=False,
            MultiAZ=False,
            BackupRetentionPeriod=0,
            DeletionProtection=False,
            Tags=[{"Key": k, "Value": v} for k, v in ETIQUETAS.items()],
        )
        log(f"RDS {ID_RDS} en creación")

    # 4. EC2 (equivale a ec2.tf)
    instancias = buscar_ec2()
    if instancias:
        instancia_id = instancias[0]
        log(f"EC2 {NOMBRE_EC2} ya existe: {instancia_id}")
    else:
        instancia_id = ec2.run_instances(
            ImageId=ami_id,
            InstanceType="t3.micro",
            MinCount=1,
            MaxCount=1,
            NetworkInterfaces=[{
                "DeviceIndex": 0,
                "SubnetId": subredes[0],
                "Groups": [sg_ec2],
                "AssociatePublicIpAddress": False,  # sin IPv4 pública
            }],
            CreditSpecification={"CpuCredits": "standard"},
            MetadataOptions={"HttpTokens": "required", "HttpEndpoint": "enabled"},  # IMDSv2
            BlockDeviceMappings=[{
                "DeviceName": dispositivo_raiz,
                "Ebs": {
                    "VolumeSize": 8,
                    "VolumeType": "gp3",
                    "Encrypted": True,
                    "DeleteOnTermination": True,
                },
            }],
            TagSpecifications=[
                {"ResourceType": "instance", "Tags": etiquetas_ec2(NOMBRE_EC2)},
                {"ResourceType": "volume", "Tags": etiquetas_ec2(NOMBRE_EC2)},
            ],
        )["Instances"][0]["InstanceId"]
        log(f"EC2 {NOMBRE_EC2} en creación: {instancia_id}")

    # 5. S3 (equivale a s3.tf). Fuera de us-east-1 hay que indicar la región.
    bucket = nombre_bucket()
    try:
        s3.create_bucket(
            Bucket=bucket,
            CreateBucketConfiguration={"LocationConstraint": REGION},
        )
        log(f"Bucket {bucket} creado")
    except ClientError as e:
        if e.response["Error"]["Code"] != "BucketAlreadyOwnedByYou":
            raise
        log(f"Bucket {bucket} ya existía")
    s3.put_bucket_tagging(
        Bucket=bucket,
        Tagging={"TagSet": [{"Key": k, "Value": v} for k, v in ETIQUETAS.items()]},
    )

    # 6. Esperar a que todo quede listo
    log("Esperando a que la EC2 esté en ejecución...")
    ec2.get_waiter("instance_running").wait(InstanceIds=[instancia_id])
    log("EC2 en ejecución")

    log("Esperando a que RDS esté disponible (suele tardar 5-15 minutos)...")
    rds.get_waiter("db_instance_available").wait(
        DBInstanceIdentifier=ID_RDS,
        WaiterConfig={"Delay": 30, "MaxAttempts": 60},
    )
    log("RDS disponible")

    estado()
    comprobar_secreto()


def comprobar_secreto():
    """Recupera el secreto de RDS en tiempo de ejecución, sin mostrar la contraseña."""
    instancia = buscar_rds()
    if not instancia or "MasterUserSecret" not in instancia:
        log("RDS no tiene secreto administrado")
        return
    arn = instancia["MasterUserSecret"]["SecretArn"]
    valor = json.loads(secrets.get_secret_value(SecretId=arn)["SecretString"])
    log(f"Secreto recuperado de Secrets Manager: usuario={valor['username']}, "
        f"contraseña=(oculta, {len(valor['password'])} caracteres)")


# ---------------------------------------------------------------------------
# Estado (evidencias)
# ---------------------------------------------------------------------------
def estado():
    vpc_id = vpc_por_defecto()
    bucket = nombre_bucket()
    print("\n===== Estado de los recursos (Metodo=boto3) =====")
    print(f"SG EC2       : {buscar_sg(NOMBRE_SG_EC2, vpc_id) or '-'}")
    print(f"SG RDS       : {buscar_sg(NOMBRE_SG_RDS, vpc_id) or '-'}")

    try:
        rds.describe_db_subnet_groups(DBSubnetGroupName=NOMBRE_SUBNET_GROUP)
        print(f"Subnet group : {NOMBRE_SUBNET_GROUP}")
    except ClientError:
        print("Subnet group : -")

    instancia = buscar_rds()
    if instancia:
        endpoint = instancia.get("Endpoint", {}).get("Address", "(aún sin endpoint)")
        secreto = instancia.get("MasterUserSecret", {})
        print(f"RDS          : {ID_RDS} | {instancia['DBInstanceStatus']} | {endpoint}")
        print(f"Secreto RDS  : {secreto.get('SecretArn', '-')} | {secreto.get('SecretStatus', '-')}")
    else:
        print("RDS          : -")

    for i in buscar_ec2() or ["-"]:
        print(f"EC2          : {i}")

    try:
        s3.head_bucket(Bucket=bucket)
        print(f"Bucket S3    : {bucket}")
    except ClientError:
        print("Bucket S3    : -")
    print("=================================================\n")


# ---------------------------------------------------------------------------
# Destruir (orden inverso a la creación)
# ---------------------------------------------------------------------------
def borrar_sg_con_reintentos(nombre, vpc_id):
    """Las interfaces de red de RDS/EC2 tardan en liberarse; se reintenta."""
    sg_id = buscar_sg(nombre, vpc_id)
    if not sg_id:
        log(f"SG {nombre} no existe")
        return
    for intento in range(20):
        try:
            ec2.delete_security_group(GroupId=sg_id)
            log(f"SG {nombre} eliminado")
            return
        except ClientError as e:
            if e.response["Error"]["Code"] != "DependencyViolation":
                raise
            log(f"SG {nombre} aún en uso, reintento {intento + 1}/20 en 15 s")
            time.sleep(15)
    sys.exit(f"No se pudo eliminar {nombre}")


def destruir():
    log(f"Identidad: {sts.get_caller_identity()['Arn']}")
    vpc_id = vpc_por_defecto()

    # 1. EC2 y RDS se eliminan en paralelo; luego se espera a ambos
    instancias = buscar_ec2()
    if instancias:
        ec2.terminate_instances(InstanceIds=instancias)
        log(f"EC2 en terminación: {instancias}")

    if buscar_rds():
        rds.delete_db_instance(
            DBInstanceIdentifier=ID_RDS,
            SkipFinalSnapshot=True,  # sin snapshot final: no deja almacenamiento facturable
            DeleteAutomatedBackups=True,
        )
        log(f"RDS {ID_RDS} en eliminación (su secreto administrado se borra con ella)")

    if instancias:
        ec2.get_waiter("instance_terminated").wait(InstanceIds=instancias)
        log("EC2 terminada (su volumen gp3 se borra con ella)")

    log("Esperando a que RDS se elimine (suele tardar 5-10 minutos)...")
    rds.get_waiter("db_instance_deleted").wait(
        DBInstanceIdentifier=ID_RDS,
        WaiterConfig={"Delay": 30, "MaxAttempts": 60},
    )
    log("RDS eliminada")

    # 2. Subnet group
    try:
        rds.delete_db_subnet_group(DBSubnetGroupName=NOMBRE_SUBNET_GROUP)
        log(f"DB subnet group {NOMBRE_SUBNET_GROUP} eliminado")
    except ClientError as e:
        if e.response["Error"]["Code"] != "DBSubnetGroupNotFoundFault":
            raise
        log(f"DB subnet group {NOMBRE_SUBNET_GROUP} no existe")

    # 3. Grupos de seguridad: primero el de RDS, que referencia al de la EC2
    borrar_sg_con_reintentos(NOMBRE_SG_RDS, vpc_id)
    borrar_sg_con_reintentos(NOMBRE_SG_EC2, vpc_id)

    # 4. Bucket: vaciarlo (objetos y versiones) y borrarlo
    bucket = nombre_bucket()
    try:
        boto3.resource("s3", region_name=REGION).Bucket(bucket).object_versions.delete()
        s3.delete_bucket(Bucket=bucket)
        log(f"Bucket {bucket} eliminado")
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchBucket":
            raise
        log(f"Bucket {bucket} no existe")

    estado()


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    modos = {"crear": crear, "estado": estado, "destruir": destruir}
    if len(sys.argv) != 2 or sys.argv[1] not in modos:
        sys.exit(f"Uso: python {sys.argv[0]} [crear|estado|destruir]")
    modos[sys.argv[1]]()
