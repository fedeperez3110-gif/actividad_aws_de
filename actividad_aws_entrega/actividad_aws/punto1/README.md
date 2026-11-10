# Punto 1 — AWS Secrets Manager

Creación de un secreto de prueba con un usuario y una contraseña ficticios, una política de IAM que permite leer únicamente ese secreto, un programa en Python que lo recupera con Boto3, la actualización de su valor sin modificar el código y su eliminación. Región `us-east-2` (Ohio).

## Contenido

| Archivo | Descripción |
|---|---|
| `punto1.py` | Recupera el secreto con Boto3 y muestra su versión |
| `sudo_read.json` | Política de IAM que solo permite leer el secreto de prueba (ID de cuenta enmascarado) |

## Secreto de prueba

Se creó el secreto `sudo` en Secrets Manager, de tipo *Other type of secret*, con un JSON de dos campos ficticios:

```json
{"username": "<usuario ficticio>", "password": "<contraseña ficticia>"}
```

Se cifró con la llave administrada por AWS para Secrets Manager (`aws/secretsmanager`), que no tiene costo adicional. AWS le asignó el ARN `arn:aws:secretsmanager:us-east-2:XXXXXXXXXXXX:secret:sudo-AEoP3S`; el sufijo `-AEoP3S` lo agrega Secrets Manager automáticamente.

## Política de acceso

`sudo_read.json`:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "secretsmanager:GetSecretValue",
            "Resource": "arn:aws:secretsmanager:us-east-2:XXXXXXXXXXXX:secret:sudo-AEoP3S"
        }
    ]
}
```

La política aplica mínimo privilegio en dos sentidos: permite una sola acción, `GetSecretValue`, que es lo único que necesita el programa, y la limita al ARN exacto del secreto de prueba, incluido su sufijo aleatorio. No incluye `kms:Decrypt` porque, con la llave administrada por AWS, Secrets Manager descifra el valor en nombre de quien tiene permiso de lectura.

La política se asignó a un usuario de IAM dedicado, `lector_secreto`, que no tenía ningún otro permiso. Asignarla a `user_cli` no habría demostrado la restricción, porque ese usuario tiene `AdministratorAccess` y puede leer cualquier secreto.

## Programa

`punto1.py` recibe el nombre o el ARN del secreto como argumento:

```bash
python3 punto1.py sudo
```

Crea el cliente de Secrets Manager sin credenciales en el código, porque Boto3 las obtiene del perfil configurado, y llama a `get_secret_value` sin indicar versión. Muestra el `VersionId` y las etiquetas de la versión recibida, el usuario y solo los últimos seis caracteres de la contraseña, suficientes para comprobar un cambio sin exponer el valor completo. Si AWS rechaza la solicitud, por ejemplo por falta de permisos, muestra el código de error.

## Actualización del secreto

El valor se modificó desde la consola: Secrets Manager → `sudo` → *Retrieve secret value* → *Edit*, cambiando la contraseña ficticia. Ese cambio equivale a `PutSecretValue`: Secrets Manager crea una versión nueva del secreto, le asigna `AWSCURRENT` y mueve la versión anterior a `AWSPREVIOUS`.

Al ejecutar de nuevo `punto1.py` sin modificarlo, el programa recibió la versión nueva, con un `VersionId` distinto y los últimos caracteres de la contraseña nueva. Esto ocurre porque el programa solo conoce el identificador del secreto, nunca su contenido, y al no pedir una versión concreta Secrets Manager entrega siempre la etiquetada como `AWSCURRENT`.

Las salidas de ambas ejecuciones no se conservaron, por lo que esta sección describe el procedimiento y el resultado observado.

## Estimación de costos

| Concepto | Precio | Uso | Costo |
|---|---|---|---|
| Almacenamiento del secreto | $0,40 al mes, prorrateado por hora (≈ $0,013 por día) | Varios días | Unos centavos (≈ $0,09 por una semana) |
| Llamadas a la API | $0,05 por 10.000 | Algunas decenas | ≈ $0 |
| Llave KMS administrada por AWS | Sin costo | — | $0 |

## Eliminación

El secreto se eliminó al terminar la prueba, y el usuario `lector_secreto` también. La verificación incluye los secretos programados para eliminación, para confirmar que no quedó ninguno pendiente que siguiera existiendo:

```
$ aws secretsmanager list-secrets --include-planned-deletion --query "SecretList[].[Name,DeletedDate]" --output json
[]
```
