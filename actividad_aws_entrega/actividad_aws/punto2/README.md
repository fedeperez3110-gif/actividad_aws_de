# Punto 2 — Despliegue con Terraform, Boto3 y AWS CLI

Despliegue de la misma infraestructura con tres herramientas, en secuencia y eliminando los recursos de cada versión antes de iniciar la siguiente: un bucket de S3, una instancia EC2, una instancia RDS PostgreSQL con contraseña administrada en Secrets Manager y los componentes de red necesarios. Región `us-east-2` (Ohio), usuario de IAM `user_cli`.

## Contenido

| Carpeta o archivo | Descripción |
|---|---|
| `terraform/` | Archivos de Terraform: `providers.tf`, `variables.tf`, `data.tf`, `network.tf`, `ec2.tf`, `rds.tf`, `s3.tf`, `outputs.tf` |
| `boto3/despliegue_boto3.py` | Versión con el SDK de Python (`crear`, `estado`, `destruir`) |
| `cli/despliegue_cli.sh` | Versión con AWS CLI (`crear`, `estado`, `secreto`, `destruir`) |
| `evidencias/` | Salidas de creación y eliminación de las tres versiones (ID de cuenta enmascarado) |

No se incluyen `terraform.tfstate`, `terraform.tfstate.backup` ni la carpeta `.terraform/`.

## Herramientas

| Herramienta | Versión |
|---|---|
| Terraform | 1.17.0, proveedor `hashicorp/aws` `~> 6.0` |
| AWS CLI | 2.36.47 |
| Python | 3.12.14 |
| Boto3 | 1.43.99 |

Se ejecutaron en Ubuntu sobre WSL2.

## Infraestructura

Las tres versiones crean los mismos recursos, con prefijos distintos (`fp-taller-p2`, `fp-taller-p2-boto3` y `fp-taller-p2-cli`) y la etiqueta `Metodo` con el nombre de la herramienta.

| Recurso | Configuración |
|---|---|
| Red | VPC por defecto y sus tres subredes, que se consultan y no se crean |
| Grupo de seguridad de la EC2 | Sin reglas de entrada; salida a `0.0.0.0/0` |
| Grupo de seguridad de RDS | Entrada TCP 5432 solo desde el grupo de seguridad de la EC2 |
| Grupo de subredes de RDS | Las tres subredes de la VPC por defecto |
| EC2 | Amazon Linux 2023, `t3.micro`, sin IPv4 pública, créditos `standard`, IMDSv2 obligatorio, disco gp3 de 8 GB cifrado |
| RDS | PostgreSQL 17, `db.t4g.micro`, 20 GB gp3 cifrado, sin acceso público, Single-AZ, sin backups, sin instantánea final, **contraseña administrada en Secrets Manager** |
| S3 | Bucket que se elimina aunque contenga objetos |

## Comparación de los métodos

| Aspecto | Terraform | Boto3 | AWS CLI |
|---|---|---|---|
| Estilo | Declarativo | Imperativo (Python) | Imperativo (bash) |
| Estado | `terraform.tfstate` | No tiene; busca los recursos por nombre | No tiene; busca los recursos por nombre |
| Orden y dependencias | Los deduce de las referencias | Escritos a mano | Escritos a mano |
| Esperas | Automáticas | *Waiters* (`instance_running`, `db_instance_available`) | `aws ec2 wait`, `aws rds wait` |
| Ejecutarlo dos veces | No duplica nada | No duplica: revisa si cada recurso existe | Falla al encontrar recursos con el mismo nombre |
| Vista previa | `terraform plan` | No | No |
| Eliminación | `terraform destroy` | Función `destruir` en orden inverso, con reintentos | Modo `destruir` en orden inverso, con reintentos |
| Parámetros complejos | HCL legible | Diccionarios de Python | JSON dentro de comillas |
| Creación medida | Cerca de 5 min | 4 min 57 s | 4 min 50 s |
| Eliminación medida | 1 min 53 s | 1 min 35 s | 1 min 46 s |

## Contraseña de RDS en Secrets Manager

PostgreSQL en RDS admite contraseñas administradas por Secrets Manager, así que las tres versiones las usan: `manage_master_user_password = true` en Terraform, `ManageMasterUserPassword=True` en Boto3 y `--manage-master-user-password` en la CLI. RDS genera la contraseña, crea el secreto `rds!db-…` y lo elimina junto con la instancia. Cada versión creó su propio secreto:

| Versión | Secreto |
|---|---|
| Terraform | `rds!db-07e296a3-…` |
| Boto3 | `rds!db-3fa3ffb1-…` |
| AWS CLI | `rds!db-01b385c8-…` |

Las versiones de Boto3 y de la CLI recuperan el secreto durante su ejecución para demostrar que es accesible, y muestran solo el usuario y la longitud de la contraseña: `usuario=taller_admin, contraseña=(oculta, 28 caracteres)`. En Terraform, el estado guardó `"password": null`.

## Reproducción

**Requisitos.** Las herramientas de la tabla anterior y las credenciales de `user_cli` en el perfil `default` con la región `us-east-2`.

**Terraform**
```bash
cd terraform
terraform init
terraform plan
terraform apply
terraform output
terraform destroy
```

**Boto3**
```bash
python3 boto3/despliegue_boto3.py crear
python3 boto3/despliegue_boto3.py estado
python3 boto3/despliegue_boto3.py destruir
```

**AWS CLI**
```bash
bash cli/despliegue_cli.sh crear
bash cli/despliegue_cli.sh secreto
bash cli/despliegue_cli.sh destruir
```

Después de cada eliminación se verificó que no quedaran componentes facturables:
```bash
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query "Reservations[].Instances[].InstanceId" --output json
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier" --output json
aws rds describe-db-snapshots --query "DBSnapshots[].DBSnapshotIdentifier" --output json
aws ec2 describe-volumes --query "Volumes[].VolumeId" --output json
aws secretsmanager list-secrets --query "SecretList[].Name" --output json
```

## Costos

| Componente | Precio | Por hora | Por semana |
|---|---|---|---|
| EC2 `t3.micro` | $0,0104/h | $0,0104 | $1,75 |
| EBS gp3 8 GB | $0,08/GB-mes | $0,0009 | $0,15 |
| RDS `db.t4g.micro` | ≈ $0,016/h | $0,0160 | $2,69 |
| Almacenamiento RDS gp3 20 GB | ≈ $0,115/GB-mes | $0,0032 | $0,53 |
| Secreto de RDS | $0,40/mes | $0,0005 | $0,09 |
| Grupos de seguridad, grupo de subredes, bucket vacío | — | $0 | $0 |
| **Total** | | **≈ $0,031** | **≈ $5,20** |

| Versión | Tiempo activo | Costo estimado |
|---|---|---|
| Terraform | ≈ 269 h (27 de octubre al 7 de noviembre) | ≈ $8,30 |
| Boto3 | ≈ 1 h 15 min | ≈ $0,04 |
| AWS CLI | Dos despliegues entre las 14:28 y las 16:24 | ≈ $0,06 |

Las decisiones de diseño reducen el costo: la EC2 no tiene IPv4 pública, que costaría 0,005 dólares por hora; RDS es Single-AZ, que cuesta la mitad que Multi-AZ; no se guardan backups ni instantánea final, que seguirían cobrando almacenamiento tras la eliminación; y la EC2 usa créditos `standard`, que nunca generan cargos extra por CPU.

## Evidencias

| Evidencia | Archivo |
|---|---|
| Identidad de `user_cli` y sus políticas | `evidencias/identidad_user_cli.txt` |
| Versiones de las herramientas | `evidencias/versiones.txt` |
| Terraform: estado, salidas, secreto y contraseña ausente del estado | `evidencias/tf_creacion.txt` |
| Terraform: eliminación | `evidencias/tf_destroy.txt` |
| Boto3: creación y eliminación | `evidencias/boto3_crear.txt`, `evidencias/boto3_destruir.txt` |
| AWS CLI: creación, secreto y eliminación | `evidencias/cli_crear.txt`, `evidencias/cli_secreto.txt`, `evidencias/cli_destruir.txt` |

La versión CLI se desplegó dos veces: después de la primera creación se eliminó y se volvió a crear, sin errores. Por eso los identificadores de `cli_destruir.txt` corresponden al segundo despliegue. La verificación posterior a cada eliminación devolvió listas vacías para instancias EC2 activas, instancias y snapshots de RDS, volúmenes EBS y secretos.
