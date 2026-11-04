"""Funzioni comuni agli script di manutenzione del catalogo.

Solo libreria standard: gli script girano su GitHub Actions e in locale senza pip.
"""
import json
import os
import re
import urllib.parse

RADICE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGO = os.path.join(RADICE, "catalogo", "drivers.json")
PAGINE = os.path.join(RADICE, "catalogo", "pagine_ufficiali.json")
SCHEMA_CATALOGO = os.path.join(RADICE, "catalogo", "schema.json")
SCHEMA_PAGINE = os.path.join(RADICE, "catalogo", "pagine_ufficiali.schema.json")

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/128.0 Safari/537.36 PrinterKit-manutenzione"
)


def leggi_json(percorso):
    # utf-8-sig: i file scritti da Windows PowerShell 5.1 iniziano con il BOM.
    with open(percorso, encoding="utf-8-sig") as f:
        return json.load(f)


def scrivi_json(percorso, dati):
    with open(percorso, "w", encoding="utf-8") as f:
        json.dump(dati, f, indent=2, ensure_ascii=False)
        f.write("\n")


def dominio_ufficiale(url, domini):
    """True se l'host di `url` è uno dei domini o un loro sottodominio (solo https)."""
    try:
        p = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    if p.scheme != "https" or not p.hostname:
        return False
    host = p.hostname.lower().rstrip(".")
    for d in domini:
        d = d.lower().strip(".")
        if host == d or host.endswith("." + d):
            return True
    return False


def produttore(catalogo, id_marca):
    for m in catalogo["manufacturers"]:
        if m["id"] == id_marca:
            return m
    return None


# --- Validatore JSON Schema minimale (sottoinsieme usato dai nostri schemi) ---

_TIPI = {
    "object": dict, "array": list, "string": str, "boolean": bool,
    "integer": int, "number": (int, float), "null": type(None),
}


def _tipo_ok(valore, tipo):
    if tipo == "integer" and isinstance(valore, bool):
        return False
    if tipo == "number" and isinstance(valore, bool):
        return False
    return isinstance(valore, _TIPI[tipo])


def valida(dati, schema, radice=None, percorso="$"):
    """Restituisce l'elenco degli errori (vuoto se valido)."""
    radice = radice or schema
    errori = []
    if "$ref" in schema:
        ref = schema["$ref"]
        nodo = radice
        for parte in ref.lstrip("#/").split("/"):
            nodo = nodo[parte]
        return valida(dati, nodo, radice, percorso)
    if "type" in schema:
        tipi = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_tipo_ok(dati, t) for t in tipi):
            return [f"{percorso}: tipo {type(dati).__name__} non ammesso ({tipi})"]
    if "const" in schema and dati != schema["const"]:
        errori.append(f"{percorso}: deve valere {schema['const']!r}")
    if "enum" in schema and dati not in schema["enum"]:
        errori.append(f"{percorso}: {dati!r} non è tra {schema['enum']}")
    if isinstance(dati, str):
        if "minLength" in schema and len(dati) < schema["minLength"]:
            errori.append(f"{percorso}: testo troppo corto")
        if "pattern" in schema and not re.search(schema["pattern"], dati):
            errori.append(f"{percorso}: {dati!r} non rispetta {schema['pattern']}")
    if isinstance(dati, list):
        if "minItems" in schema and len(dati) < schema["minItems"]:
            errori.append(f"{percorso}: servono almeno {schema['minItems']} elementi")
        if "items" in schema:
            for i, el in enumerate(dati):
                errori += valida(el, schema["items"], radice, f"{percorso}[{i}]")
    if isinstance(dati, dict):
        for r in schema.get("required", []):
            if r not in dati:
                errori.append(f"{percorso}: manca il campo obbligatorio '{r}'")
        props = schema.get("properties", {})
        for k, v in dati.items():
            if k in props:
                errori += valida(v, props[k], radice, f"{percorso}.{k}")
            elif schema.get("additionalProperties") is False:
                errori.append(f"{percorso}: campo non previsto '{k}'")
    for sotto in schema.get("allOf", []):
        if "if" in sotto:
            if not valida(dati, sotto["if"], radice, percorso):
                errori += valida(dati, sotto.get("then", {}), radice, percorso)
        else:
            errori += valida(dati, sotto, radice, percorso)
    return errori


def controlli_extra_catalogo(catalogo):
    """Regole che lo schema da solo non esprime."""
    errori = []
    ids = set()
    for m in catalogo["manufacturers"]:
        try:
            re.compile(m["match"])
        except re.error as e:
            errori.append(f"{m['id']}: regex 'match' non valida ({e})")
        for p in m["packages"]:
            if p["id"] in ids:
                errori.append(f"pacchetto duplicato: {p['id']}")
            ids.add(p["id"])
            if p.get("url") and not dominio_ufficiale(p["url"], m["officialDomains"]):
                errori.append(f"{p['id']}: url fuori dai domini ufficiali di {m['id']}")
            if not dominio_ufficiale(p["sourcePage"], m["officialDomains"]):
                errori.append(f"{p['id']}: sourcePage fuori dai domini ufficiali di {m['id']}")
            if p["models"] != "*":
                try:
                    re.compile(p["models"])
                except re.error as e:
                    errori.append(f"{p['id']}: regex 'models' non valida ({e})")
    return errori


def controlli_extra_pagine(pagine, catalogo):
    errori = []
    for i, v in enumerate(pagine["pagine"]):
        m = produttore(catalogo, v["manufacturer"])
        if m is None:
            errori.append(f"pagine[{i}]: marca sconosciuta '{v['manufacturer']}'")
            continue
        if not dominio_ufficiale(v["pageUrl"], m["officialDomains"]):
            errori.append(f"pagine[{i}]: {v['pageUrl']} non è un dominio ufficiale di {m['id']}")
    return errori
