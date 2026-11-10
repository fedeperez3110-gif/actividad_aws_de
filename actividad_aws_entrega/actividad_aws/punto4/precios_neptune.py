"""
Punto 4 - Consulta los precios bajo demanda de Neptune en Ohio
usando la API de precios de AWS (solo lectura, no crea nada).
"""
import json

import boto3

UBICACION = "US East (Ohio)"
PALABRAS = ["t3.medium", "t4g.medium", "serverless", "ncu", "storage", "i/o", "io request"]

# La API de precios solo existe en algunas regiones; us-east-1 sirve para todas.
pricing = boto3.client("pricing", region_name="us-east-1")

paginas = pricing.get_paginator("get_products").paginate(
    ServiceCode="AmazonNeptune",
    Filters=[{"Type": "TERM_MATCH", "Field": "location", "Value": UBICACION}],
)

vistos = set()
for pagina in paginas:
    for item in pagina["PriceList"]:
        producto = json.loads(item)
        for termino in producto.get("terms", {}).get("OnDemand", {}).values():
            for dimension in termino["priceDimensions"].values():
                descripcion = dimension["description"]
                precio = float(dimension["pricePerUnit"].get("USD", 0))
                if precio == 0 or not any(p in descripcion.lower() for p in PALABRAS):
                    continue
                linea = f"{precio:>10.4f} USD por {dimension['unit']:<12} {descripcion}"
                if linea not in vistos:
                    vistos.add(linea)

for linea in sorted(vistos, key=lambda l: l.split("USD por")[1]):
    print(linea)
