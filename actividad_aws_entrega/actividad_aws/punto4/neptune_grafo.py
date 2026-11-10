"""
Punto 4 - Grafo en Amazon Neptune consultado desde el computador local.

Conexión: endpoint público de Neptune (puerto 8182, TLS) con autenticación IAM.
El cliente `neptunedata` de Boto3 firma cada petición (SigV4) con las credenciales
de user_cli, así que no existe usuario ni contraseña de base de datos.

1. Borra el grafo y carga 14 vértices y 24 relaciones con openCypher.
2. Ejecuta tres consultas que recorren relaciones.

Uso:
  python3 neptune_grafo.py
"""

import json

import boto3

REGION = "us-east-2"
CLUSTER_ID = "fp-taller-p4-neptune"


def titulo(texto):
    print(f"\n{'=' * 70}\n{texto}\n{'=' * 70}")


def cliente_neptune():
    """Obtiene el endpoint del clúster y crea el cliente que firma con IAM."""
    neptune = boto3.client("neptune", region_name=REGION)
    cluster = neptune.describe_db_clusters(DBClusterIdentifier=CLUSTER_ID)["DBClusters"][0]
    url = f"https://{cluster['Endpoint']}:{cluster['Port']}"
    print(f"Endpoint público: {url}")
    print(f"Autenticación IAM activada: {cluster['IAMDatabaseAuthenticationEnabled']}")
    print(f"Identidad que firma las peticiones: {boto3.client('sts').get_caller_identity()['Arn'].split(':')[-1]}")
    return boto3.client("neptunedata", region_name=REGION, endpoint_url=url)


def cypher(cliente, consulta, parametros=None):
    argumentos = {"openCypherQuery": consulta}
    if parametros:
        argumentos["parameters"] = json.dumps(parametros)
    return cliente.execute_open_cypher_query(**argumentos)["results"]


# ---------------------------------------------------------------------------
# Modelo del grafo
# ---------------------------------------------------------------------------
PERSONAS = [("Ana", "Ingeniera de datos"), ("Luis", "Analista"), ("María", "Científica de datos"),
            ("Carlos", "Arquitecto cloud"), ("Sofía", "Desarrolladora"), ("Jorge", "Ingeniero DevOps")]
EMPRESAS = [("DataCo", "Bogotá"), ("CloudLab", "Medellín")]
CIUDADES = ["Bogotá", "Medellín"]
TECNOLOGIAS = ["Python", "SQL", "AWS", "Spark"]

TRABAJA_EN = [("Ana", "DataCo", 2021), ("Luis", "DataCo", 2023), ("María", "DataCo", 2020),
              ("Carlos", "CloudLab", 2019), ("Sofía", "CloudLab", 2024), ("Jorge", "CloudLab", 2022)]
CONOCE = [("Ana", "Luis"), ("Luis", "Carlos"), ("Carlos", "Sofía"), ("María", "Jorge"), ("Ana", "María")]
SABE = [("Ana", "Python", "avanzado"), ("Ana", "SQL", "avanzado"), ("Luis", "SQL", "intermedio"),
        ("María", "Python", "avanzado"), ("María", "AWS", "intermedio"), ("María", "Spark", "intermedio"),
        ("Carlos", "AWS", "avanzado"), ("Carlos", "Spark", "básico"), ("Sofía", "Python", "intermedio"),
        ("Jorge", "SQL", "intermedio"), ("Jorge", "AWS", "avanzado")]


def cargar_grafo(cliente):
    cypher(cliente, "MATCH (n) DETACH DELETE n")  # el programa se puede ejecutar varias veces

    cypher(cliente, "UNWIND $filas AS f CREATE (:Persona {nombre: f.nombre, rol: f.rol})",
           {"filas": [{"nombre": n, "rol": r} for n, r in PERSONAS]})
    cypher(cliente, "UNWIND $filas AS nombre CREATE (:Ciudad {nombre: nombre})", {"filas": CIUDADES})
    cypher(cliente, "UNWIND $filas AS nombre CREATE (:Tecnologia {nombre: nombre})", {"filas": TECNOLOGIAS})
    cypher(cliente, "UNWIND $filas AS f CREATE (:Empresa {nombre: f.nombre})",
           {"filas": [{"nombre": n} for n, _ in EMPRESAS]})

    cypher(cliente, """
        UNWIND $filas AS f
        MATCH (e:Empresa {nombre: f.empresa}), (c:Ciudad {nombre: f.ciudad})
        CREATE (e)-[:UBICADA_EN]->(c)""",
           {"filas": [{"empresa": e, "ciudad": c} for e, c in EMPRESAS]})
    cypher(cliente, """
        UNWIND $filas AS f
        MATCH (p:Persona {nombre: f.persona}), (e:Empresa {nombre: f.empresa})
        CREATE (p)-[:TRABAJA_EN {desde: f.desde}]->(e)""",
           {"filas": [{"persona": p, "empresa": e, "desde": d} for p, e, d in TRABAJA_EN]})
    cypher(cliente, """
        UNWIND $filas AS f
        MATCH (a:Persona {nombre: f.a}), (b:Persona {nombre: f.b})
        CREATE (a)-[:CONOCE]->(b)""",
           {"filas": [{"a": a, "b": b} for a, b in CONOCE]})
    cypher(cliente, """
        UNWIND $filas AS f
        MATCH (p:Persona {nombre: f.persona}), (t:Tecnologia {nombre: f.tecnologia})
        CREATE (p)-[:SABE {nivel: f.nivel}]->(t)""",
           {"filas": [{"persona": p, "tecnologia": t, "nivel": n} for p, t, n in SABE]})

    vertices = cypher(cliente, "MATCH (n) RETURN labels(n)[0] AS tipo, count(*) AS total ORDER BY tipo")
    aristas = cypher(cliente, "MATCH ()-[r]->() RETURN type(r) AS tipo, count(*) AS total ORDER BY tipo")
    print("Vértices:   " + ", ".join(f"{v['tipo']}={v['total']}" for v in vertices)
          + f"  (total {sum(v['total'] for v in vertices)})")
    print("Relaciones: " + ", ".join(f"{a['tipo']}={a['total']}" for a in aristas)
          + f"  (total {sum(a['total'] for a in aristas)})")


# ---------------------------------------------------------------------------
# Consultas que recorren relaciones
# ---------------------------------------------------------------------------
CONSULTAS = [
    (
        "1) Amigos de amigos de Ana que todavía no conoce (2 saltos por CONOCE)",
        """
        MATCH (a:Persona {nombre: 'Ana'})-[:CONOCE]-(amigo:Persona)
        WITH a, collect(amigo) AS amigos
        MATCH (a)-[:CONOCE]-(intermedio:Persona)-[:CONOCE]-(sugerido:Persona)
        WHERE sugerido <> a AND NOT sugerido IN amigos
        RETURN sugerido.nombre AS sugerido, collect(DISTINCT intermedio.nombre) AS a_traves_de
        ORDER BY sugerido""",
    ),
    (
        "2) Personas de empresas ubicadas en Bogotá y sus tecnologías (Ciudad <- Empresa <- Persona -> Tecnología)",
        """
        MATCH (c:Ciudad {nombre: 'Bogotá'})<-[:UBICADA_EN]-(e:Empresa)<-[:TRABAJA_EN]-(p:Persona)-[s:SABE]->(t:Tecnologia)
        RETURN e.nombre AS empresa, p.nombre AS persona, collect(t.nombre + ' (' + s.nivel + ')') AS tecnologias
        ORDER BY persona""",
    ),
    (
        "3) Tecnologías que saben los colegas de Luis y que Luis no sabe (recomendación)",
        """
        MATCH (l:Persona {nombre: 'Luis'})-[:SABE]->(propia:Tecnologia)
        WITH l, collect(propia) AS propias
        MATCH (l)-[:TRABAJA_EN]->(:Empresa)<-[:TRABAJA_EN]-(colega:Persona)-[:SABE]->(t:Tecnologia)
        WHERE colega <> l AND NOT t IN propias
        RETURN t.nombre AS tecnologia, count(DISTINCT colega) AS colegas, collect(DISTINCT colega.nombre) AS quienes
        ORDER BY colegas DESC, tecnologia""",
    ),
]


def main():
    titulo("Conexión")
    cliente = cliente_neptune()

    titulo("Carga del grafo")
    cargar_grafo(cliente)

    for nombre, consulta in CONSULTAS:
        titulo(nombre)
        print("  " + " ".join(consulta.split()))
        print("  ---")
        for fila in cypher(cliente, consulta):
            print("  " + " | ".join(f"{k}={v}" for k, v in fila.items()))


if __name__ == "__main__":
    main()
