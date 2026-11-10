"""
Punto 6 - Corrección del esquema en Glue Data Catalog y consultas con Athena.

Uso:
  python3 glue_athena.py muestra     # 3 filas con los tipos que Athena está usando
  python3 glue_athena.py corregir    # corrige tipos en la tabla y en todas sus particiones
  python3 glue_athena.py consultas   # filtro, agrupación y conteo por mes
  python3 glue_athena.py manual      # crea la tabla a mano (DDL) y la compara con la del crawler

Athena escribe los resultados de cada consulta en s3://<bucket>/athena-resultados/.
No se usa ninguna contraseña: Glue, Athena y S3 se autorizan con IAM.
"""

import sys
import time

import boto3

REGION = "us-east-2"
BASE_DE_DATOS = "taller_p6"
TABLA = "ventas"

sts = boto3.client("sts", region_name=REGION)
glue = boto3.client("glue", region_name=REGION)
athena = boto3.client("athena", region_name=REGION)

BUCKET = f"fp-taller-p6-{sts.get_caller_identity()['Account']}"
RESULTADOS = f"s3://{BUCKET}/athena-resultados/"

# Tipos corregidos: columna -> (tipo inferido por el crawler, tipo correcto, motivo)
CORRECCIONES = {
    "fecha": ("string", "date", "son fechas ISO (AAAA-MM-DD); como texto no se pueden comparar ni agrupar por fecha"),
    "codigo_postal": ("bigint", "string", "es un identificador, no una cantidad; como número pierde el 0 inicial (050001 -> 50001)"),
}


def titulo(texto):
    print(f"\n{'=' * 78}\n{texto}\n{'=' * 78}")


# ---------------------------------------------------------------------------
# Athena: enviar, esperar y recuperar
# ---------------------------------------------------------------------------
def athena_sql(sql, mostrar=True):
    if mostrar:
        print("  SQL> " + " ".join(sql.split()))
    ejecucion_id = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": BASE_DE_DATOS},
        ResultConfiguration={"OutputLocation": RESULTADOS},
        WorkGroup="primary",
    )["QueryExecutionId"]

    while True:
        ejecucion = athena.get_query_execution(QueryExecutionId=ejecucion_id)["QueryExecution"]
        estado = ejecucion["Status"]["State"]
        if estado in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)

    estadisticas = ejecucion.get("Statistics", {})
    escaneado = estadisticas.get("DataScannedInBytes", 0)
    if estado != "SUCCEEDED":
        raise RuntimeError(f"Consulta {estado}: {ejecucion['Status'].get('StateChangeReason')}")
    print(f"  -> {estado} en {estadisticas.get('TotalExecutionTimeInMillis', 0) / 1000:.2f} s | "
          f"datos escaneados: {escaneado:,} bytes")

    filas = []
    for pagina in athena.get_paginator("get_query_results").paginate(QueryExecutionId=ejecucion_id):
        for fila in pagina["ResultSet"]["Rows"]:
            filas.append([c.get("VarCharValue", "") for c in fila["Data"]])
    if not filas:
        return [], []
    return filas[0], filas[1:]


def imprimir(columnas, filas):
    if not columnas:
        return
    anchos = [max(len(c), *(len(f[i]) for f in filas)) if filas else len(c) for i, c in enumerate(columnas)]
    print("  " + " | ".join(c.ljust(a) for c, a in zip(columnas, anchos)))
    print("  " + "-+-".join("-" * a for a in anchos))
    for fila in filas:
        print("  " + " | ".join(v.ljust(a) for v, a in zip(fila, anchos)))


# ---------------------------------------------------------------------------
# Glue: corrección del esquema
# ---------------------------------------------------------------------------
def campos_permitidos(nombre_forma):
    modelo = glue.meta.service_model.shape_for(nombre_forma)
    return set(modelo.members)


def corregir_columnas(columnas):
    cambios = []
    for columna in columnas:
        if columna["Name"] in CORRECCIONES:
            anterior, nuevo, _ = CORRECCIONES[columna["Name"]]
            if columna["Type"] != nuevo:
                cambios.append((columna["Name"], columna["Type"], nuevo))
                columna["Type"] = nuevo
    return cambios


def mostrar_esquema(columnas, particiones):
    for c in columnas:
        print(f"  {c['Name']:<16} {c['Type']}")
    for p in particiones:
        print(f"  {p['Name']:<16} {p['Type']}  (partición)")


def corregir():
    titulo("Esquema inferido por el crawler")
    tabla = glue.get_table(DatabaseName=BASE_DE_DATOS, Name=TABLA)["Table"]
    mostrar_esquema(tabla["StorageDescriptor"]["Columns"], tabla["PartitionKeys"])

    titulo("Corrección de la tabla")
    permitidos = campos_permitidos("TableInput")
    entrada = {k: v for k, v in tabla.items() if k in permitidos}
    cambios = corregir_columnas(entrada["StorageDescriptor"]["Columns"])
    for nombre, anterior, nuevo in cambios:
        print(f"  {nombre}: {anterior} -> {nuevo}  ({CORRECCIONES[nombre][2]})")
    if not cambios:
        print("  La tabla ya tenía los tipos correctos")
    glue.update_table(DatabaseName=BASE_DE_DATOS, TableInput=entrada)
    print("  Tabla actualizada en el catálogo")

    # Cada partición guarda su propia copia del esquema. Si no coincide con la tabla,
    # Athena falla con HIVE_PARTITION_SCHEMA_MISMATCH, así que se corrigen también.
    titulo("Corrección de las particiones")
    permitidos_particion = campos_permitidos("PartitionInput")
    entradas = []
    for pagina in glue.get_paginator("get_partitions").paginate(DatabaseName=BASE_DE_DATOS, TableName=TABLA):
        for particion in pagina["Partitions"]:
            entrada_p = {k: v for k, v in particion.items() if k in permitidos_particion}
            cambios_p = corregir_columnas(entrada_p["StorageDescriptor"]["Columns"])
            print(f"  mes={particion['Values'][0]}: "
                  + (", ".join(f"{n} {a}->{b}" for n, a, b in cambios_p) or "sin cambios"))
            entradas.append({"PartitionValueList": particion["Values"], "PartitionInput": entrada_p})
    if entradas:
        errores = glue.batch_update_partition(DatabaseName=BASE_DE_DATOS, TableName=TABLA,
                                              Entries=entradas).get("Errors", [])
        print(f"  {len(entradas)} particiones actualizadas, errores: {len(errores)}")

    titulo("Esquema corregido")
    tabla = glue.get_table(DatabaseName=BASE_DE_DATOS, Name=TABLA)["Table"]
    mostrar_esquema(tabla["StorageDescriptor"]["Columns"], tabla["PartitionKeys"])


# ---------------------------------------------------------------------------
# Consultas
# ---------------------------------------------------------------------------
def muestra(tabla=TABLA):
    titulo(f"Muestra de {tabla} con los tipos que usa Athena")
    imprimir(*athena_sql(f"""
        SELECT venta_id, fecha, typeof(fecha) AS tipo_fecha,
               codigo_postal, typeof(codigo_postal) AS tipo_cp, ciudad
        FROM {tabla}
        ORDER BY venta_id
        LIMIT 4"""))


def conteo_por_mes(tabla=TABLA):
    titulo(f"Registros por partición en {tabla}")
    imprimir(*athena_sql(f"""
        SELECT mes, COUNT(*) AS registros, MIN(fecha) AS primera_fecha, MAX(fecha) AS ultima_fecha
        FROM {tabla}
        GROUP BY mes
        ORDER BY mes"""))


def consultas():
    titulo("1) Filtro: ventas de Tecnología no devueltas de más de 1.000.000")
    imprimir(*athena_sql("""
        SELECT venta_id, fecha, ciudad, codigo_postal, producto, cantidad,
               cantidad * precio_unitario AS total
        FROM ventas
        WHERE categoria = 'Tecnología'
          AND NOT devuelto
          AND cantidad * precio_unitario > 1000000
        ORDER BY total DESC"""))

    titulo("2) Agrupación: ventas y devoluciones por ciudad")
    imprimir(*athena_sql("""
        SELECT ciudad, codigo_postal,
               COUNT(*) AS ventas,
               SUM(cantidad * precio_unitario) AS total,
               SUM(CASE WHEN devuelto THEN 1 ELSE 0 END) AS devoluciones
        FROM ventas
        GROUP BY ciudad, codigo_postal
        ORDER BY total DESC"""))

    conteo_por_mes()


def manual():
    titulo("Creación manual de la tabla con DDL (sin crawler)")
    athena_sql("DROP TABLE IF EXISTS ventas_manual")
    athena_sql(f"""
        CREATE EXTERNAL TABLE ventas_manual (
            venta_id        BIGINT,
            fecha           DATE,
            ciudad          STRING,
            codigo_postal   STRING,
            categoria       STRING,
            producto        STRING,
            cantidad        INT,
            precio_unitario BIGINT,
            metodo_pago     STRING,
            devuelto        BOOLEAN
        )
        PARTITIONED BY (mes STRING)
        ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
        STORED AS TEXTFILE
        LOCATION 's3://{BUCKET}/datos/ventas/'
        TBLPROPERTIES ('skip.header.line.count' = '1')""")

    titulo("Registro de particiones de la tabla manual")
    imprimir(*athena_sql("MSCK REPAIR TABLE ventas_manual"))

    muestra("ventas_manual")
    conteo_por_mes("ventas_manual")

    titulo("Comparación de las dos tablas en el catálogo")
    for nombre in (TABLA, "ventas_manual"):
        t = glue.get_table(DatabaseName=BASE_DE_DATOS, Name=nombre)["Table"]
        tipos = {c["Name"]: c["Type"] for c in t["StorageDescriptor"]["Columns"]}
        print(f"  {nombre:<14} creada por: {t.get('CreatedBy', '-').split('/')[-1]:<22} "
              f"fecha={tipos['fecha']:<7} codigo_postal={tipos['codigo_postal']:<7} "
              f"cantidad={tipos['cantidad']:<7} SerDe={t['StorageDescriptor']['SerdeInfo'].get('SerializationLibrary', '-').split('.')[-1]}")


if __name__ == "__main__":
    acciones = {"muestra": muestra, "corregir": corregir, "consultas": consultas, "manual": manual}
    if len(sys.argv) != 2 or sys.argv[1] not in acciones:
        sys.exit(f"Uso: python3 {sys.argv[0]} [{'|'.join(acciones)}]")
    acciones[sys.argv[1]]()
