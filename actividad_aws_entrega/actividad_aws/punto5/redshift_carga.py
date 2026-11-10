"""
Punto 5 - Carga y consultas en Amazon Redshift Serverless con la API de datos.

1. Sube datos/clientes.csv y datos/pedidos.csv al bucket S3.
2. Crea las tablas `clientes` y `pedidos` (relacionadas por cliente_id).
3. Carga los datos con COPY usando el rol de IAM asociado al namespace.
4. Ejecuta consultas con filtro, unión y agregación.

Todas las instrucciones SQL se envían con la API de datos (`redshift-data`):
ExecuteStatement para enviarlas, DescribeStatement para comprobar que terminaron
y GetStatementResult para recuperar las filas. La autenticación usa el secreto
administrado por Redshift en Secrets Manager (se pasa su ARN, nunca la contraseña).

Uso:
  python3 redshift_carga.py
"""

import time
from pathlib import Path

import boto3

REGION = "us-east-2"
NAMESPACE = "fp-taller-p5-ns"
WORKGROUP = "fp-taller-p5-wg"
BASE_DE_DATOS = "taller"
CARPETA_DATOS = Path(__file__).parent / "datos"

sts = boto3.client("sts", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
serverless = boto3.client("redshift-serverless", region_name=REGION)
datos = boto3.client("redshift-data", region_name=REGION)

BUCKET = f"fp-taller-p5-{sts.get_caller_identity()['Account']}"


def titulo(texto):
    print(f"\n{'=' * 78}\n{texto}\n{'=' * 78}")


# ---------------------------------------------------------------------------
# API de datos: enviar, esperar y recuperar
# ---------------------------------------------------------------------------
def ejecutar(sql, secreto_arn, mostrar_sql=True):
    """Envía una instrucción, espera a que termine y devuelve sus filas (si las hay)."""
    if mostrar_sql:
        print("  SQL> " + " ".join(sql.split()))
    respuesta = datos.execute_statement(
        WorkgroupName=WORKGROUP,
        Database=BASE_DE_DATOS,
        SecretArn=secreto_arn,
        Sql=sql,
    )
    id_instruccion = respuesta["Id"]

    while True:
        estado = datos.describe_statement(Id=id_instruccion)
        if estado["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            break
        time.sleep(1)

    if estado["Status"] != "FINISHED":
        raise RuntimeError(f"La instrucción {id_instruccion} terminó en {estado['Status']}: "
                           f"{estado.get('Error')}")

    duracion = estado["Duration"] / 1e9  # nanosegundos -> segundos
    print(f"  -> {estado['Status']} en {duracion:.2f} s | filas afectadas: {estado.get('ResultRows', 0)} "
          f"| id {id_instruccion[:8]}…")

    if not estado.get("HasResultSet"):
        return [], []

    columnas, filas, token = [], [], None
    while True:
        argumentos = {"Id": id_instruccion}
        if token:
            argumentos["NextToken"] = token
        pagina = datos.get_statement_result(**argumentos)
        columnas = [c["name"] for c in pagina["ColumnMetadata"]]
        for registro in pagina["Records"]:
            filas.append([list(campo.values())[0] if campo and "isNull" not in campo else None
                          for campo in registro])
        token = pagina.get("NextToken")
        if not token:
            break
    return columnas, filas


def imprimir_tabla(columnas, filas):
    anchos = [max(len(str(c)), *(len(formato(f[i])) for f in filas)) for i, c in enumerate(columnas)]
    print("  " + " | ".join(str(c).ljust(a) for c, a in zip(columnas, anchos)))
    print("  " + "-+-".join("-" * a for a in anchos))
    for fila in filas:
        print("  " + " | ".join(formato(v).ljust(a) for v, a in zip(fila, anchos)))


def formato(valor):
    if isinstance(valor, float):
        return f"{valor:,.0f}"
    if isinstance(valor, int) and valor >= 10000:
        return f"{valor:,}"
    if isinstance(valor, str) and valor.replace(".", "", 1).isdigit() and "." in valor:
        return f"{float(valor):,.0f}"
    return str(valor)


# ---------------------------------------------------------------------------
# Pasos
# ---------------------------------------------------------------------------
def configuracion():
    namespace = serverless.get_namespace(namespaceName=NAMESPACE)["namespace"]
    secreto_arn = namespace["adminPasswordSecretArn"]
    rol_arn = namespace["defaultIamRoleArn"]
    print(f"Workgroup: {WORKGROUP} | base de datos: {BASE_DE_DATOS}")
    print(f"Autenticación: secreto de Secrets Manager {secreto_arn.split(':')[-1]}")
    print(f"Rol para COPY: {rol_arn.split('/')[-1]}")
    return secreto_arn, rol_arn


def subir_archivos():
    for archivo in ("clientes.csv", "pedidos.csv"):
        ruta = CARPETA_DATOS / archivo
        s3.upload_file(str(ruta), BUCKET, f"datos/{archivo}")
        filas = sum(1 for _ in ruta.open(encoding="utf-8")) - 1
        print(f"  s3://{BUCKET}/datos/{archivo} ({filas} filas)")


def crear_tablas(secreto_arn):
    ejecutar("DROP TABLE IF EXISTS pedidos", secreto_arn)
    ejecutar("DROP TABLE IF EXISTS clientes", secreto_arn)
    ejecutar("""
        CREATE TABLE clientes (
            cliente_id     INTEGER     NOT NULL PRIMARY KEY,
            nombre         VARCHAR(60) NOT NULL,
            ciudad         VARCHAR(30) NOT NULL,
            segmento       VARCHAR(20) NOT NULL,
            fecha_registro DATE        NOT NULL
        )
        DISTSTYLE ALL""", secreto_arn)
    ejecutar("""
        CREATE TABLE pedidos (
            pedido_id       INTEGER       NOT NULL PRIMARY KEY,
            cliente_id      INTEGER       NOT NULL REFERENCES clientes (cliente_id),
            fecha           DATE          NOT NULL,
            categoria       VARCHAR(20)   NOT NULL,
            producto        VARCHAR(40)   NOT NULL,
            cantidad        INTEGER       NOT NULL,
            precio_unitario DECIMAL(12,2) NOT NULL
        )
        DISTKEY (cliente_id)
        SORTKEY (fecha)""", secreto_arn)


def cargar(secreto_arn, rol_arn):
    for tabla in ("clientes", "pedidos"):
        ejecutar(f"""
            COPY {tabla}
            FROM 's3://{BUCKET}/datos/{tabla}.csv'
            IAM_ROLE '{rol_arn}'
            FORMAT AS CSV
            IGNOREHEADER 1
            REGION '{REGION}'""", secreto_arn)
    columnas, filas = ejecutar("""
        SELECT 'clientes' AS tabla, COUNT(*) AS filas FROM clientes
        UNION ALL
        SELECT 'pedidos', COUNT(*) FROM pedidos""", secreto_arn)
    imprimir_tabla(columnas, filas)


CONSULTAS = [
    (
        "1) Filtro: pedidos de Tecnología de más de 2.000.000 en septiembre y octubre",
        "¿Qué compras grandes de tecnología hubo en los dos últimos meses?",
        """
        SELECT pedido_id, fecha, producto, cantidad,
               cantidad * precio_unitario AS total
        FROM pedidos
        WHERE categoria = 'Tecnología'
          AND fecha BETWEEN '2026-09-01' AND '2026-10-31'
          AND cantidad * precio_unitario > 2000000
        ORDER BY total DESC""",
    ),
    (
        "2) Unión: los 10 pedidos de mayor valor con los datos del cliente",
        "¿Quiénes hicieron los pedidos más grandes y de dónde son?",
        """
        SELECT p.pedido_id, p.fecha, c.nombre, c.ciudad, c.segmento, p.producto,
               p.cantidad * p.precio_unitario AS total
        FROM pedidos p
        JOIN clientes c ON c.cliente_id = p.cliente_id
        ORDER BY total DESC
        LIMIT 10""",
    ),
    (
        "3) Agregación: ventas por ciudad y segmento",
        "¿Dónde y en qué tipo de cliente se concentran las ventas?",
        """
        SELECT c.ciudad, c.segmento,
               COUNT(*)                                  AS pedidos,
               SUM(p.cantidad)                           AS unidades,
               SUM(p.cantidad * p.precio_unitario)       AS ventas,
               ROUND(AVG(p.cantidad * p.precio_unitario)) AS ticket_promedio
        FROM pedidos p
        JOIN clientes c ON c.cliente_id = p.cliente_id
        GROUP BY c.ciudad, c.segmento
        ORDER BY ventas DESC""",
    ),
    (
        "4) Agregación: ventas por mes y categoría",
        "¿Cómo evolucionan las ventas de cada categoría mes a mes?",
        """
        SELECT TO_CHAR(fecha, 'YYYY-MM') AS mes, categoria,
               COUNT(*)                            AS pedidos,
               SUM(cantidad * precio_unitario)     AS ventas
        FROM pedidos
        GROUP BY 1, 2
        ORDER BY 1, ventas DESC""",
    ),
]


def main():
    titulo("Configuración")
    secreto_arn, rol_arn = configuracion()

    titulo("Subida de archivos a S3")
    subir_archivos()

    titulo("Creación de tablas")
    crear_tablas(secreto_arn)

    titulo("Carga con COPY")
    cargar(secreto_arn, rol_arn)

    for nombre, pregunta, sql in CONSULTAS:
        titulo(nombre)
        print(f"  Pregunta: {pregunta}")
        columnas, filas = ejecutar(sql, secreto_arn)
        imprimir_tabla(columnas, filas)

    titulo("Consumo de cómputo registrado por Redshift Serverless")
    columnas, filas = ejecutar("""
        SELECT SUM(charged_seconds) AS rpu_segundos_cobrados,
               ROUND(SUM(charged_seconds) / 3600.0 * 0.36, 4) AS costo_usd_aprox
        FROM sys_serverless_usage""", secreto_arn)
    imprimir_tabla(columnas, filas)
    print("  (sys_serverless_usage se actualiza con algunos minutos de retraso)")


if __name__ == "__main__":
    main()
