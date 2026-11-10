"""
Punto 3 - DocumentDB desde Python a través del túnel SSH.

1. Recupera la contraseña de DocumentDB desde Secrets Manager (sin escribirla en el código).
2. Se conecta a DocumentDB por el túnel (localhost:27018) con TLS.
3. Crea la base de datos `taller` y la colección `pedidos`, e inserta 12 documentos.
4. Ejecuta una búsqueda con filtro, una ordenación y una agregación.

Requisitos:
  - Túnel abierto en otra terminal:
      ssh -i ~/.ssh/fp-taller-p3-llave.pem -N -L 27018:<endpoint-clúster>:27017 ec2-user@<DNS-EC2>
  - global-bundle.pem en la misma carpeta (o la ruta en la variable DOCDB_CA_FILE)
  - pip install boto3 pymongo

Uso:
  python3 docdb_consultas.py
"""

import json
import os
from datetime import datetime

import boto3
from pymongo import MongoClient

REGION = "us-east-2"
CLUSTER_ID = "fp-taller-p3-docdb"
PUERTO_LOCAL = int(os.environ.get("DOCDB_PUERTO_LOCAL", "27018"))
CA_FILE = os.environ.get("DOCDB_CA_FILE", "global-bundle.pem")


def titulo(texto):
    print(f"\n{'=' * 70}\n{texto}\n{'=' * 70}")


# ---------------------------------------------------------------------------
# 1. Credenciales desde Secrets Manager
# ---------------------------------------------------------------------------
def obtener_credenciales():
    """Busca el ARN del secreto administrado del clúster y lo lee en ejecución."""
    docdb = boto3.client("docdb", region_name=REGION)
    cluster = docdb.describe_db_clusters(DBClusterIdentifier=CLUSTER_ID)["DBClusters"][0]
    arn = cluster["MasterUserSecret"]["SecretArn"]

    secrets = boto3.client("secretsmanager", region_name=REGION)
    secreto = json.loads(secrets.get_secret_value(SecretId=arn)["SecretString"])
    print(f"Secreto recuperado de Secrets Manager: usuario={secreto['username']}, "
          f"contraseña=(oculta, {len(secreto['password'])} caracteres)")
    return secreto["username"], secreto["password"]


# ---------------------------------------------------------------------------
# 2. Conexión
# ---------------------------------------------------------------------------
def conectar(usuario, contrasena):
    cliente = MongoClient(
        host="localhost",
        port=PUERTO_LOCAL,
        username=usuario,
        password=contrasena,
        tls=True,
        tlsCAFile=CA_FILE,
        tlsAllowInvalidHostnames=True,  # el certificado es para *.docdb.amazonaws.com, no para localhost
        directConnection=True,          # no intentar usar las IP privadas de los miembros del clúster
        retryWrites=False,              # DocumentDB no soporta escrituras reintentables
        serverSelectionTimeoutMS=10000,
    )
    info = cliente.server_info()
    print(f"Conectado a DocumentDB por localhost:{PUERTO_LOCAL} (versión de API {info['version']})")
    return cliente


# ---------------------------------------------------------------------------
# 3. Datos
# ---------------------------------------------------------------------------
PEDIDOS = [
    {"pedido": 1001, "cliente": "Ana Gómez",       "ciudad": "Bogotá",       "categoria": "Tecnología", "producto": "Portátil",      "cantidad": 1, "precio_unitario": 3200000, "fecha": "2026-10-01"},
    {"pedido": 1002, "cliente": "Luis Pérez",      "ciudad": "Medellín",     "categoria": "Hogar",      "producto": "Cafetera",      "cantidad": 2, "precio_unitario": 280000,  "fecha": "2026-10-02"},
    {"pedido": 1003, "cliente": "María Rojas",     "ciudad": "Cali",         "categoria": "Tecnología", "producto": "Audífonos",     "cantidad": 3, "precio_unitario": 150000,  "fecha": "2026-10-03"},
    {"pedido": 1004, "cliente": "Carlos Díaz",     "ciudad": "Bogotá",       "categoria": "Deportes",   "producto": "Bicicleta",     "cantidad": 1, "precio_unitario": 1450000, "fecha": "2026-10-05"},
    {"pedido": 1005, "cliente": "Sofía Martínez",  "ciudad": "Barranquilla", "categoria": "Hogar",      "producto": "Licuadora",     "cantidad": 1, "precio_unitario": 220000,  "fecha": "2026-10-06"},
    {"pedido": 1006, "cliente": "Jorge Herrera",   "ciudad": "Medellín",     "categoria": "Tecnología", "producto": "Monitor",       "cantidad": 2, "precio_unitario": 890000,  "fecha": "2026-10-08"},
    {"pedido": 1007, "cliente": "Valentina Ruiz",  "ciudad": "Bogotá",       "categoria": "Libros",     "producto": "Novela",        "cantidad": 4, "precio_unitario": 65000,   "fecha": "2026-10-09"},
    {"pedido": 1008, "cliente": "Andrés Castro",   "ciudad": "Cali",         "categoria": "Deportes",   "producto": "Balón",         "cantidad": 5, "precio_unitario": 90000,   "fecha": "2026-10-11"},
    {"pedido": 1009, "cliente": "Camila Torres",   "ciudad": "Medellín",     "categoria": "Libros",     "producto": "Libro técnico", "cantidad": 2, "precio_unitario": 120000,  "fecha": "2026-10-12"},
    {"pedido": 1010, "cliente": "Felipe Moreno",   "ciudad": "Barranquilla", "categoria": "Tecnología", "producto": "Teclado",       "cantidad": 3, "precio_unitario": 180000,  "fecha": "2026-10-14"},
    {"pedido": 1011, "cliente": "Laura Vargas",    "ciudad": "Bogotá",       "categoria": "Hogar",      "producto": "Aspiradora",    "cantidad": 1, "precio_unitario": 650000,  "fecha": "2026-10-15"},
    {"pedido": 1012, "cliente": "Daniel Ortiz",    "ciudad": "Cali",         "categoria": "Tecnología", "producto": "Tableta",       "cantidad": 1, "precio_unitario": 1300000, "fecha": "2026-10-17"},
]


def cargar_datos(coleccion):
    coleccion.drop()  # el programa se puede ejecutar varias veces con el mismo resultado
    documentos = []
    for p in PEDIDOS:
        doc = dict(p)
        doc["total"] = doc["cantidad"] * doc["precio_unitario"]
        doc["fecha"] = datetime.fromisoformat(doc["fecha"])
        documentos.append(doc)
    resultado = coleccion.insert_many(documentos)
    print(f"Insertados {len(resultado.inserted_ids)} documentos en taller.pedidos "
          f"(total en la colección: {coleccion.count_documents({})})")


def mostrar(docs, campos):
    for d in docs:
        print("  " + " | ".join(f"{c}={d.get(c)}" for c in campos))


# ---------------------------------------------------------------------------
# 4. Consultas
# ---------------------------------------------------------------------------
def consultas(coleccion):
    titulo("1) Búsqueda con filtro: pedidos de Tecnología con total >= 1.000.000")
    filtro = {"categoria": "Tecnología", "total": {"$gte": 1_000_000}}
    print(f"  filtro: {filtro}")
    mostrar(coleccion.find(filtro, {"_id": 0}), ["pedido", "cliente", "producto", "total"])

    titulo("2) Ordenación: los 5 pedidos de mayor valor")
    print("  sort: total descendente, limit 5")
    mostrar(coleccion.find({}, {"_id": 0}).sort("total", -1).limit(5),
            ["pedido", "cliente", "ciudad", "total"])

    titulo("3) Agregación: ventas por ciudad")
    pipeline = [
        {"$group": {
            "_id": "$ciudad",
            "pedidos": {"$sum": 1},
            "unidades": {"$sum": "$cantidad"},
            "ventas": {"$sum": "$total"},
            "ticket_promedio": {"$avg": "$total"},
        }},
        {"$sort": {"ventas": -1}},
    ]
    print(f"  pipeline: {pipeline}")
    for d in coleccion.aggregate(pipeline):
        print(f"  {d['_id']:<13} pedidos={d['pedidos']} unidades={d['unidades']} "
              f"ventas={d['ventas']:,} ticket_promedio={round(d['ticket_promedio']):,}")


def main():
    titulo("Conexión")
    usuario, contrasena = obtener_credenciales()
    cliente = conectar(usuario, contrasena)
    try:
        coleccion = cliente["taller"]["pedidos"]
        titulo("Carga de datos")
        cargar_datos(coleccion)
        consultas(coleccion)
    finally:
        cliente.close()


if __name__ == "__main__":
    main()
