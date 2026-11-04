"""Unisce gli esiti delle verifiche di firma al catalogo.

  --cambiati   (controllo-link) aggiorna sha256/status dei pacchetti con file cambiato: commit diretto.
  --candidati  (recupero-link)  aggiunge/sostituisce i pacchetti validi: il workflow apre una Pull Request.
                Quelli non validi diventano 'da_verificare' e finiscono in out/issue.md.
Uso: python applica_risultati.py --cambiati|--candidati <elenco.json> <cartella-windows> <cartella-macos>
"""
import argparse
import datetime
import json
import os
import sys

from comune import CATALOGO, leggi_json, produttore, scrivi_json


def _carica(cartella, nome_ver):
    sca = os.path.join(cartella, "scaricati.json")
    ver = os.path.join(cartella, nome_ver)
    scaricati = {s["indice"]: s for s in (leggi_json(sca) if os.path.exists(sca) else [])}
    verificati = {v["indice"]: v for v in (leggi_json(ver) if os.path.exists(ver) else [])}
    return scaricati, verificati


def esiti(elenco, cart_win, cart_mac):
    sw, vw = _carica(cart_win, "verificati_windows.json")
    sm, vm = _carica(cart_mac, "verificati_macos.json")
    out = []
    for i, voce in enumerate(elenco):
        s = sw.get(i) or sm.get(i)
        v = vw.get(i) or vm.get(i)
        if s is None:
            out.append((voce, False, "pacchetto non verificato (job di firma non eseguito)", None, None, None))
        elif s.get("errore"):
            out.append((voce, False, s["errore"], None, None, None))
        elif v is None:
            out.append((voce, False, "esito della verifica di firma mancante", None, None, None))
        else:
            out.append((voce, bool(v["ok"]), v.get("motivo", ""), s.get("sha256"), v.get("firma"), v))
    return out


def applica_cambiati(cat, elenco, risultati):
    oggi = datetime.date.today().isoformat()
    problemi = []
    for voce, ok, motivo, sha, firma, esito in risultati:
        m = produttore(cat, voce["manufacturer"])
        p = next(x for x in m["packages"] if x["id"] == voce["package"])
        if ok:
            p["sha256"], p["status"], p["lastChecked"] = sha, "ok", oggi
        else:
            p["status"] = "da_verificare"
            p["notes"] = f"{oggi}: {motivo}"[:300]
            problemi.append(f"- `{p['id']}`: {motivo}")
    return problemi


def applica_candidati(cat, elenco, risultati):
    oggi = datetime.date.today().isoformat()
    aggiunti, problemi = [], []
    for voce, ok, motivo, sha, firma, esito in risultati:
        m = produttore(cat, voce["manufacturer"])
        nuovo = dict(voce["package"])
        if not ok:
            problemi.append(f"- {m['name']} `{nuovo['id']}` ({nuovo['url']}): {motivo}")
            if voce.get("sostituisce"):
                for p in m["packages"]:
                    if p["id"] == voce["sostituisce"]:
                        p["status"] = "da_verificare"
                        p["notes"] = f"{oggi}: sostituto proposto non valido ({motivo})"[:300]
            continue
        ver_inf = esito if isinstance(esito, dict) else {}
        if ver_inf.get("arch") and nuovo["os"] == "windows":
            nuovo["arch"] = [a for a in ("x86", "x64", "arm64") if a in ver_inf["arch"]]  # dagli INF del pacchetto
        # Nome, versione e linguaggio dall'INF valgono più di quelli ricavati dal link.
        if ver_inf.get("famiglia"):
            nuovo["driverFamily"] = ver_inf["famiglia"][:80]
        if ver_inf.get("versione"):
            nuovo["version"] = ver_inf["versione"]
        if ver_inf.get("linguaggio"):
            nuovo["language"] = ver_inf["linguaggio"]
        nuovo.update({"sha256": sha, "status": "ok", "lastChecked": oggi,
                      "notes": (nuovo.get("notes") or "") + f" | firma: {firma}"})
        idx = next((k for k, p in enumerate(m["packages"]) if p["id"] == nuovo["id"]), None)
        if idx is None:
            m["packages"].append(nuovo)
        else:
            m["packages"][idx] = nuovo
        aggiunti.append(f"- {m['name']} `{nuovo['id']}` {nuovo.get('version') or ''} – {nuovo['url']} (firma: {firma})")
    return aggiunti, problemi


def main(argv=None):
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--cambiati", action="store_true")
    g.add_argument("--candidati", action="store_true")
    ap.add_argument("elenco"); ap.add_argument("cart_win"); ap.add_argument("cart_mac")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    ap.add_argument("--catalogo", default=CATALOGO)
    a = ap.parse_args(argv)
    cat = leggi_json(a.catalogo)
    elenco = leggi_json(a.elenco)
    ris = esiti(elenco, a.cart_win, a.cart_mac)
    os.makedirs(a.out, exist_ok=True)
    aggiunti = []
    if a.cambiati:
        problemi = applica_cambiati(cat, elenco, ris)
    else:
        aggiunti, problemi = applica_candidati(cat, elenco, ris)
    cat["updatedAt"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    scrivi_json(a.catalogo, cat)
    with open(os.path.join(a.out, "pr.md"), "w", encoding="utf-8") as f:
        f.write("Pacchetti trovati e verificati (dominio ufficiale, download, firma digitale, architettura dagli INF):\n\n")
        f.write("\n".join(aggiunti) or "- nessuno")
        f.write("\n\nControllare prima di approvare.\n")
    with open(os.path.join(a.out, "issue.md"), "w", encoding="utf-8") as f:
        f.write("Pacchetti da controllare a mano:\n\n" + "\n".join(problemi) + "\n" if problemi else "")
    print(f"{len(aggiunti)} aggiunti, {len(problemi)} da controllare")
    gh = os.environ.get("GITHUB_OUTPUT")
    if gh:
        with open(gh, "a") as f:
            f.write(f"aggiunti={len(aggiunti)}\nproblemi={len(problemi)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
