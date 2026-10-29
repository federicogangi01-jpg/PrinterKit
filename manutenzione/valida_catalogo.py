"""Valida drivers.json e pagine_ufficiali.json. Esce con codice 1 se ci sono errori."""
import sys

from comune import (CATALOGO, PAGINE, SCHEMA_CATALOGO, SCHEMA_PAGINE, controlli_extra_catalogo,
                    controlli_extra_pagine, leggi_json, valida)


def main():
    catalogo = leggi_json(CATALOGO)
    pagine = leggi_json(PAGINE)
    errori = valida(catalogo, leggi_json(SCHEMA_CATALOGO))
    errori += valida(pagine, leggi_json(SCHEMA_PAGINE))
    if not errori:
        errori += controlli_extra_catalogo(catalogo)
        errori += controlli_extra_pagine(pagine, catalogo)
    for e in errori:
        print("ERRORE:", e)
    if errori:
        print(f"{len(errori)} errori.")
        return 1
    n = sum(len(m["packages"]) for m in catalogo["manufacturers"])
    print(f"Catalogo valido: {len(catalogo['manufacturers'])} marche, {n} pacchetti, "
          f"{len(pagine['pagine'])} pagine ufficiali.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
