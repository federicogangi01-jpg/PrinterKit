"""Genera catalogo/PAGINE_UFFICIALI.md da pagine_ufficiali.json."""
import os

from comune import CATALOGO, PAGINE, RADICE, leggi_json, produttore

STATI = {"ok": "✅ ok", "da_verificare": "⚠️ da verificare", "nessun_driver": "⛔ nessun driver"}


def main():
    catalogo = leggi_json(CATALOGO)
    pagine = leggi_json(PAGINE)["pagine"]
    righe = [
        "# Pagine ufficiali di download driver",
        "",
        "Generato da `manutenzione/genera_riepilogo.py`: non modificare a mano, modifica `pagine_ufficiali.json`.",
        "",
        "Da far controllare al committente prima del primo avvio. Legenda: ✅ pagina aperta e confermata;",
        "⚠️ non confermata (motivo nelle note); ⛔ il produttore non offre driver per quel sistema.",
        "",
    ]
    conteggi = {}
    for marca in catalogo["manufacturers"]:
        voci = [p for p in pagine if p["manufacturer"] == marca["id"]]
        righe += [f"## {marca['name']}", "", "| Ambito | Sistemi | Arch. | Pagina | Stato | Note |",
                  "|---|---|---|---|---|---|"]
        for v in voci:
            conteggi[v["stato"]] = conteggi.get(v["stato"], 0) + 1
            ambito = v["scope"] + (f" – {v['series']}" if v.get("series") else "")
            js = " (JavaScript)" if v["needsBrowser"] else ""
            note = (v.get("notes") or "").replace("|", "/")
            righe.append(f"| {ambito} | {', '.join(v['os'])} | {', '.join(v['arch'])} | "
                         f"[link]({v['pageUrl']}){js} | {STATI[v['stato']]} | {note} |")
        if not voci:
            righe.append("| – | – | – | – | ⚠️ nessuna pagina | da aggiungere |")
        righe.append("")
    righe.insert(7, "Totale: " + ", ".join(f"{STATI[k]}: {n}" for k, n in sorted(conteggi.items())) + "\n")
    for p in pagine:
        assert produttore(catalogo, p["manufacturer"]), p["manufacturer"]
    with open(os.path.join(RADICE, "catalogo", "PAGINE_UFFICIALI.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(righe))
    print("Scritto catalogo/PAGINE_UFFICIALI.md")


if __name__ == "__main__":
    main()
