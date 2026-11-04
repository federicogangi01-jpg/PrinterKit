"""Scarica i file di out/cambiati.json o out/candidati.json (dominio controllato anche dopo i redirect)
e ne calcola lo SHA-256. Le firme le verificano poi i job Windows (Authenticode) e macOS (pkgutil).
Uso: python scarica_candidati.py <elenco.json> <cartella> <windows|macos>"""
import json
import os
import sys

import rete
from comune import leggi_json, scrivi_json


def main(elenco, cartella, sistema):
    voci = leggi_json(elenco)
    os.makedirs(cartella, exist_ok=True)
    risultati = []
    for i, v in enumerate(voci):
        p = v.get("package") or v
        if p.get("os") != sistema:
            continue
        nome = f"{i:03d}_{p.get('id') or v.get('package')}.{p['fileType']}"
        dest = os.path.join(cartella, nome)
        voce = {"indice": i, "file": nome, "sha256": None, "errore": None}
        try:
            voce["sha256"], voce["finale"] = rete.scarica(p["url"], dest, v["officialDomains"])
        except Exception as e:
            voce["errore"] = f"download non riuscito: {e}"
            if os.path.exists(dest):
                os.remove(dest)
        risultati.append(voce)
        print(nome, voce["errore"] or voce["sha256"])
    scrivi_json(os.path.join(cartella, "scaricati.json"), risultati)


if __name__ == "__main__":
    main(*sys.argv[1:4])
