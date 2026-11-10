import json
import sys

import boto3
from botocore.exceptions import ClientError


def obtener_secreto(nombre_secreto: str) -> dict:
    # 1. Cliente de Secrets Manager. No lleva credenciales:
    #    Boto3 las busca solo (variables de entorno, ~/.aws/, rol, etc.)
    cliente = boto3.client("secretsmanager")

    # 2. Pedir la versión actual del secreto (etiqueta AWSCURRENT por defecto)
    respuesta = cliente.get_secret_value(SecretId=nombre_secreto)

    # 3. El valor viene como texto; si guardaste un JSON, hay que convertirlo
    datos = json.loads(respuesta["SecretString"])

    # Datos de la versión, útiles como evidencia del punto 4
    print(f"VersionId: {respuesta['VersionId']}")
    print(f"Etiquetas: {respuesta['VersionStages']}")
    return datos


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Uso: python leer_secreto.py <nombre-o-ARN-del-secreto>")
        sys.exit(1)

    try:
        secreto = obtener_secreto(sys.argv[1])
    except ClientError as error:
        codigo = error.response["Error"]["Code"]
        print(f"Error de AWS: {codigo}")
        sys.exit(1)

    print(f"Usuario: {secreto['username']}")
    # Nunca imprimas la contraseña completa: solo una pista para verificar el cambio
    print(f"Contraseña: {'*' * 4}{secreto['password'][-6:]}")