"""Genera cache/indice-xp.txt: il catalogo in forma piatta (TAB) per la versione XP in VBScript,
che non sa leggere il JSON. Contiene i pacchetti Windows con osMin <= 5.2 e una riga per ogni marca."""
import os
import re
import sys

from comune import CATALOGO, RADICE, leggi_json

CAMPI = "marca-id, marca, match, pacchetto-id, famiglia, versione, osMin, osMax, arch, modelli, tipo, infHint, driverName, sha256, status"


def _ver(v):
    return [int(x) for x in re.findall(r"\d+", v or "0")] or [0]


def _vbs_regex(rx):
    # VBScript RegExp non conosce i gruppi non catturanti con flag inline: li togliamo se presenti.
    return rx.replace("(?i)", "")


def righe(catalogo):
    out = []
    for m in catalogo["manufacturers"]:
        base = [m["id"], m["name"], _vbs_regex(m["match"])]
        pacchetti = [p for p in m["packages"] if p["os"] == "windows" and _ver(p["osMin"]) <= [5, 2]]
        pacchetti.sort(key=lambda p: _ver(p.get("version")), reverse=True)
        for p in pacchetti:
            out.append(base + [p["id"], p["driverFamily"], p.get("version") or "", p["osMin"], p.get("osMax") or "",
                               ",".join(p["arch"]), _vbs_regex(p["models"]), p["fileType"], p.get("infHint") or "",
                               p.get("driverName") or "", p.get("sha256") or "", p["status"]])
        out.append(base + ["", "", "", "", "", "", "", "", "", "", "", "marca"])
    for r in out:
        for campo in r:
            if "\t" in campo or "\n" in campo:
                raise ValueError(f"carattere non ammesso nel campo {campo!r}")
    return out


def main(dest=None):
    dest = dest or os.path.join(RADICE, "cache", "indice-xp.txt")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    rr = righe(leggi_json(CATALOGO))
    with open(dest, "w", encoding="cp1252", errors="replace", newline="\r\n") as f:
        f.write("# Generato da manutenzione/genera_indice_xp.py - non modificare a mano\n")
        f.write("# " + CAMPI + "\n")
        for r in rr:
            f.write("\t".join(r) + "\n")
    print(f"Scritto {dest} ({len(rr)} righe)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
