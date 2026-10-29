"""Controllo notturno dei link del catalogo (§15.2), senza AI.

Per ogni pacchetto con url: HEAD/GET parziale, codice HTTP, dominio finale nella whitelist,
tipo di contenuto, confronto di ETag / Last-Modified / dimensione con l'ultima esecuzione.
Scrive:
  - il catalogo aggiornato (solo stato, date, etag/dimensione: modifiche meccaniche);
  - out/cambiati.json  : pacchetti il cui file è cambiato (da riscaricare e rifirmare);
  - out/rotti.json     : pacchetti con link rotto (avviano "recupero-link").
"""
import argparse
import datetime
import os
import sys

from comune import CATALOGO, dominio_ufficiale, leggi_json, scrivi_json
import rete


def valuta(pacchetto, risposta, domini):
    """Restituisce (nuovo_status, cambiato, motivo)."""
    if risposta["errore"] or not (200 <= risposta["status"] < 400):
        return "link_rotto", False, risposta["errore"] or f"HTTP {risposta['status']}"
    if not dominio_ufficiale(risposta["finale"], domini):
        return "link_rotto", False, f"redirect fuori dai domini ufficiali: {risposta['finale']}"
    if risposta["tipo"].lower().startswith("text/html"):
        return "link_rotto", False, "il link restituisce una pagina web invece del file"
    cambiato = False
    for campo, chiave in (("etag", "etag"), ("lastModified", "data"), ("size", "dimensione")):
        vecchio, nuovo = pacchetto.get(campo), risposta.get(chiave)
        if vecchio is not None and nuovo is not None and str(vecchio) != str(nuovo):
            cambiato = True
    if not pacchetto.get("sha256"):
        cambiato = True  # mai verificato: va scaricato e firmato
    return "ok", cambiato, "raggiungibile"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalogo", default=CATALOGO)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    a = ap.parse_args(argv)
    cat = leggi_json(a.catalogo)
    oggi = datetime.date.today().isoformat()
    cambiati, rotti = [], []
    for m in cat["manufacturers"]:
        for p in m["packages"]:
            if not p.get("url") or p["status"] == "nessun_driver":
                continue
            r = rete.testa(p["url"])
            stato, cambiato, motivo = valuta(p, r, m["officialDomains"])
            print(f"{m['id']}/{p['id']}: {stato} ({motivo})")
            p["lastChecked"] = oggi
            if stato == "link_rotto":
                if p["status"] != "da_verificare":
                    p["status"] = "link_rotto"
                rotti.append({"manufacturer": m["id"], "package": p["id"], "motivo": motivo})
                continue
            if p["status"] == "link_rotto":
                p["status"] = "ok" if p.get("sha256") else "da_verificare"
            for campo, chiave in (("etag", "etag"), ("lastModified", "data"), ("size", "dimensione")):
                if r.get(chiave) is not None:
                    p[campo] = r[chiave]
            if cambiato:
                cambiati.append({"manufacturer": m["id"], "package": p["id"], "url": p["url"],
                                 "fileType": p["fileType"], "os": p["os"], "arch": p["arch"],
                                 "signerNames": m["signerNames"], "macSignerNames": m.get("macSignerNames", m["signerNames"]),
                                 "officialDomains": m["officialDomains"], "match": m["match"]})
    cat["updatedAt"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    scrivi_json(a.catalogo, cat)
    os.makedirs(a.out, exist_ok=True)
    scrivi_json(os.path.join(a.out, "cambiati.json"), cambiati)
    scrivi_json(os.path.join(a.out, "rotti.json"), rotti)
    print(f"{len(cambiati)} cambiati, {len(rotti)} rotti")
    gh = os.environ.get("GITHUB_OUTPUT")
    if gh:
        with open(gh, "a") as f:
            f.write(f"cambiati={len(cambiati)}\nrotti={len(rotti)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
