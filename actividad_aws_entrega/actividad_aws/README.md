# Ingeniería de Datos — Actividad AWS 2026-2

Desarrollo de los seis puntos de la actividad en una sola región de AWS, `us-east-2` (Ohio), con el usuario de IAM `user_cli`. Cada carpeta tiene su propio README con el código, las instrucciones para reproducir el punto, los resultados y las evidencias de creación y eliminación. Las respuestas a las preguntas de cada punto están en el documento [`respuestas.docx`](respuestas.docx).

| Punto | Tema | Herramientas | Costo aproximado |
|---|---|---|---|
| [1](punto1/README.md) | AWS Secrets Manager | Consola, Boto3 | Unos centavos |
| [2](punto2/README.md) | Despliegue de S3, EC2 y RDS | Terraform, Boto3, AWS CLI | ≈ $8,40 |
| [3](punto3/README.md) | Amazon DocumentDB Serverless con túnel SSH | AWS CLI, Compass, PyMongo | ≈ $0,11 |
| [4](punto4/README.md) | Amazon Neptune con endpoint público | AWS CLI, Boto3 (`neptunedata`), openCypher | ≈ $0,18 |
| [5](punto5/README.md) | Amazon Redshift Serverless | AWS CLI, Boto3 (`redshift-data`) | ≈ $0,03 |
| [6](punto6/README.md) | AWS Glue Data Catalog y Amazon Athena | AWS CLI, Boto3 | < $0,50 |

Casi todo el costo del punto 2 corresponde a la versión Terraform, que permaneció activa unos once días antes de eliminarse. En los demás puntos, los recursos se mantuvieron solo durante las pruebas.

## Requisitos generales

- AWS CLI 2, Python 3 con `boto3` y, para los puntos 2 y 3, Terraform y `pymongo`.
- Credenciales de `user_cli` en el perfil `default` de `~/.aws/credentials`, con `us-east-2` como región.
- Los puntos 3, 4 y 5 requieren que la cuenta esté en el plan de pago de AWS: DocumentDB, Neptune y Redshift no están disponibles en el plan gratuito.

## Secretos y credenciales

Ninguna contraseña está escrita en el código. Las bases de datos que la necesitan la administran con Secrets Manager: RDS en el punto 2, DocumentDB en el punto 3 y Redshift en el punto 5. Los programas la recuperan durante la ejecución o pasan el ARN del secreto a la API correspondiente. Neptune (punto 4) y Glue con Athena (punto 6) no usan contraseñas, porque se autorizan con IAM. Las claves de acceso de `user_cli` no se guardan en Secrets Manager, porque se necesitan para autenticarse antes de poder leer cualquier secreto.

## Lo que no se incluye

El repositorio no contiene archivos de estado de Terraform, claves de IAM, llaves privadas, valores de secretos ni capturas con credenciales. En las evidencias, el número de cuenta de AWS aparece enmascarado como `XXXXXXXXXXXX` y la IP pública del computador local como `X.X.X.X`.
