"""Recupero dei link con Gemini API, piano gratuito (§15.3).

Gemini NON cerca su internet: riceve l'elenco dei link presenti nella pagina ufficiale e sceglie.
Ogni risposta viene validata; nessun link inventato passa.

Modalità:
  --rotti   pacchetti con status link_rotto (dalla pagina sourcePage del pacchetto)
  --popola  tutte le voci di pagine_ufficiali.json (catalogo iniziale)
  --nuove   solo le voci aggiunte/modificate rispetto al commit precedente (§15.6)
Output: out/candidati.json (da verificare con la firma nei job Windows/macOS) e out/scartati.json.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

from comune import CATALOGO, PAGINE, dominio_ufficiale, leggi_json, produttore, scrivi_json
import rete

API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
ESTENSIONI = (".zip", ".exe", ".pkg", ".dmg", ".cab", ".msi")

SCHEMA_RISPOSTA = {
    "type": "OBJECT",
    "properties": {
        "pacchetti": {
            "type": "ARRAY",
            "items": {
                "type": "OBJECT",
                "properties": {
                    "url": {"type": "STRING"},
                    "driverFamily": {"type": "STRING"},
                    "version": {"type": "STRING"},
                    "os": {"type": "STRING", "enum": ["windows", "macos"]},
                    "osMin": {"type": "STRING"},
                    "osMax": {"type": "STRING", "nullable": True},
                    "arch": {"type": "ARRAY", "items": {"type": "STRING", "enum": ["x86", "x64", "arm64", "intel", "applesilicon"]}},
                    "language": {"type": "STRING", "enum": ["pcl6", "pcl5", "ps", "gdi", "altro"]},
                    "fileType": {"type": "STRING", "enum": ["zip", "exe", "pkg", "dmg", "cab"]},
                    "motivazione": {"type": "STRING"},
                },
                "required": ["url", "driverFamily", "os", "osMin", "arch", "fileType", "motivazione"],
            },
        }
    },
    "required": ["pacchetti"],
}

OS_MIN = {"windows-xp": "5.1", "windows-7": "6.1", "windows-8.1": "6.3", "windows-10": "10.0", "windows-11": "10.0"}


def chiedi_gemini(prompt, chiave, modello, temperatura=0.1, apri=urllib.request.urlopen):
    corpo = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": temperatura, "responseMimeType": "application/json",
                             "responseSchema": SCHEMA_RISPOSTA},
    }
    req = urllib.request.Request(API.format(model=modello), data=json.dumps(corpo).encode(),
                                 headers={"Content-Type": "application/json", "x-goog-api-key": chiave})
    with apri(req, timeout=120) as r:
        risposta = json.loads(r.read().decode())
    testo = risposta["candidates"][0]["content"]["parts"][0]["text"]
    return json.loads(testo)


def costruisci_prompt(marca, voce, link, testo, cercato=None):
    elenco = "\n".join(f"- {l['url']}  [{l['testo']}]" for l in link)
    obiettivo = (f"Cerca il pacchetto che sostituisce: {json.dumps(cercato, ensure_ascii=False)}"
                 if cercato else
                 f"Elenca i pacchetti driver di stampa per: sistemi {', '.join(voce['os'])}, architetture {', '.join(voce['arch'])}.")
    return f"""Sei un assistente che estrae link di download di driver di stampa dalla pagina ufficiale di un produttore.
Produttore: {marca['name']}. Ambito: {voce.get('scope')} {voce.get('series') or ''}.
{obiettivo}
Regole obbligatorie:
- Rispondi SOLO con URL presi testualmente dall'elenco qui sotto. Non inventare, non modificare, non completare URL.
- Solo driver di stampa del produttore (niente utility, firmware, manuali, driver scanner, driver generici Microsoft/Apple).
- Indica os ("windows"/"macos"), osMin (versione NT: 5.1 XP, 6.1 Windows 7, 10.0 Windows 10/11; oppure versione macOS), arch, linguaggio e tipo file.
- Se non trovi nulla di adatto, restituisci "pacchetti": [].
Testo della pagina (estratto): {testo[:6000]}
Link presenti nella pagina:
{elenco}
"""


def valida_proposta(p, link_pagina, marca, voce=None):
    """Errore (stringa) oppure None. Il link deve stare nella pagina ed essere su un dominio ufficiale."""
    url = (p.get("url") or "").strip()
    if url not in {l["url"] for l in link_pagina}:
        return "link non presente nella pagina (inventato o modificato)"
    if not dominio_ufficiale(url, marca["officialDomains"]):
        return "dominio non nella whitelist"
    if p.get("os") not in ("windows", "macos"):
        return "sistema non valido"
    archs = p.get("arch") or []
    ammesse = {"windows": {"x86", "x64", "arm64"}, "macos": {"intel", "applesilicon"}}[p["os"]]
    if not archs or not set(archs) <= ammesse:
        return "architettura incoerente con il sistema"
    if not re.fullmatch(r"\d+(\.\d+)*", str(p.get("osMin", ""))):
        return "osMin non valido"
    if p.get("fileType") not in ("zip", "exe", "pkg", "dmg", "cab"):
        return "tipo file non valido"
    if p["os"] == "macos" and p["fileType"] not in ("pkg", "dmg"):
        return "pacchetto Mac che non è .pkg/.dmg"
    if voce is not None:
        os_voce = {o.split("-")[0] for o in voce["os"]}
        if p["os"] not in os_voce:
            return "sistema non richiesto da questa pagina"
    return None


def id_pacchetto(marca_id, p):
    base = re.sub(r"[^a-z0-9]+", "-", f"{marca_id}-{p['driverFamily']}-{p['os']}-{'-'.join(sorted(p['arch']))}".lower())
    return base.strip("-")[:80]


def obiettivi(modo, cat, pagine, rif_git="HEAD~1"):
    """Elenco di (marca, voce pagina, pacchetto da sostituire o None)."""
    out = []
    if modo == "rotti":
        for m in cat["manufacturers"]:
            for p in m["packages"]:
                if p["status"] == "link_rotto":
                    voce = {"manufacturer": m["id"], "scope": "pacchetto", "series": p["driverFamily"],
                            "os": [p["os"]], "arch": p["arch"], "pageUrl": p["sourcePage"], "needsBrowser": True}
                    out.append((m, voce, p))
    else:
        voci = pagine["pagine"]
        if modo == "nuove":
            try:
                vecchio = json.loads(subprocess.check_output(["git", "show", f"{rif_git}:catalogo/pagine_ufficiali.json"], text=True))
                gia = {json.dumps(v, sort_keys=True) for v in vecchio["pagine"]}
                voci = [v for v in voci if json.dumps(v, sort_keys=True) not in gia]
            except (subprocess.CalledProcessError, FileNotFoundError, KeyError, ValueError):
                pass
        for v in voci:
            if v["stato"] == "nessun_driver":
                continue
            m = produttore(cat, v["manufacturer"])
            if m:
                out.append((m, v, None))
    return out


def main(argv=None, gemini=chiedi_gemini, apri_pagina=rete.apri_pagina):
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--rotti", action="store_true")
    g.add_argument("--popola", action="store_true")
    g.add_argument("--nuove", action="store_true")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    ap.add_argument("--max", type=int, default=int(os.environ.get("PK_MAX_PAGINE", "20")))
    ap.add_argument("--attesa", type=float, default=float(os.environ.get("PK_ATTESA_SEC", "7")))
    a = ap.parse_args(argv)
    modo = "rotti" if a.rotti else "popola" if a.popola else "nuove"
    chiave = os.environ.get("GEMINI_API_KEY", "")
    modello = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
    if not chiave:
        print("GEMINI_API_KEY mancante (va nei Secrets del repository)")
        return 2
    cat, pagine = leggi_json(CATALOGO), leggi_json(PAGINE)
    lavori = obiettivi(modo, cat, pagine)
    rinviati = lavori[a.max:]
    lavori = lavori[:a.max]
    candidati, scartati = [], []
    for i, (m, voce, vecchio) in enumerate(lavori):
        if i:
            time.sleep(a.attesa)  # limiti al minuto del piano gratuito
        try:
            html, finale = apri_pagina(voce["pageUrl"], voce.get("needsBrowser", False))
        except Exception as e:
            scartati.append({"voce": voce, "motivo": f"pagina non raggiungibile: {e}"})
            continue
        if rete.sembra_captcha(html):
            scartati.append({"voce": voce, "motivo": "il sito blocca l'accesso automatico (CAPTCHA): nessun aggiramento"})
            continue
        link, testo = rete.estrai_link(html, finale)
        link = [l for l in link if dominio_ufficiale(l["url"], m["officialDomains"])]
        # Prima i link che sembrano file, poi gli altri (limite per non superare il contesto).
        link.sort(key=lambda l: 0 if l["url"].lower().split("?")[0].endswith(ESTENSIONI) else 1)
        link = link[:400]
        if not link:
            scartati.append({"voce": voce, "motivo": "nessun link ufficiale nella pagina (forse serve il browser)"})
            continue
        cercato = None
        if vecchio:
            cercato = {k: vecchio.get(k) for k in ("driverFamily", "version", "os", "osMin", "arch", "language", "fileType")}
        try:
            risposta = gemini(costruisci_prompt(m, voce, link, testo, cercato), chiave, modello)
        except Exception as e:
            scartati.append({"voce": voce, "motivo": f"Gemini non ha risposto: {e}"})
            continue
        trovati = 0
        for p in (risposta.get("pacchetti") or []):
            errore = valida_proposta(p, link, m, None if vecchio else voce)
            if errore:
                scartati.append({"voce": voce, "proposta": p, "motivo": errore})
                continue
            if vecchio and (p["os"] != vecchio["os"] or not set(vecchio["arch"]) <= set(p["arch"])):
                scartati.append({"voce": voce, "proposta": p, "motivo": "non corrisponde al pacchetto da sostituire"})
                continue
            candidati.append({
                "manufacturer": m["id"], "sostituisce": vecchio["id"] if vecchio else None,
                "package": {
                    "id": vecchio["id"] if vecchio else id_pacchetto(m["id"], p),
                    "driverFamily": p["driverFamily"], "version": p.get("version") or None, "os": p["os"],
                    "osMin": p["osMin"], "osMax": p.get("osMax") or None, "buildMin": None, "arch": p["arch"],
                    "language": p.get("language"), "models": vecchio["models"] if vecchio else "*",
                    "url": p["url"], "sourcePage": voce["pageUrl"], "sha256": None, "fileType": p["fileType"],
                    "extractArgs": vecchio.get("extractArgs") if vecchio else None, "infHint": None,
                    "driverName": vecchio.get("driverName") if vecchio else None, "lastChecked": None,
                    "status": "da_verificare", "notes": "proposto da Gemini: " + (p.get("motivazione") or "")[:200],
                },
                "signerNames": m["signerNames"], "macSignerNames": m.get("macSignerNames", m["signerNames"]),
                "officialDomains": m["officialDomains"], "match": m["match"],
            })
            trovati += 1
        if not trovati and vecchio is None and not any(s.get("voce") is voce for s in scartati):
            scartati.append({"voce": voce, "motivo": "Gemini non ha trovato pacchetti adatti nella pagina"})
        if vecchio and not trovati:
            scartati.append({"voce": voce, "pacchetto": vecchio["id"], "motivo": "nessun sostituto valido"})
    os.makedirs(a.out, exist_ok=True)
    scrivi_json(os.path.join(a.out, "candidati.json"), candidati)
    scrivi_json(os.path.join(a.out, "scartati.json"), scartati)
    scrivi_json(os.path.join(a.out, "rinviati.json"), [{"pageUrl": v["pageUrl"], "manufacturer": mm["id"]} for mm, v, _ in rinviati])
    print(f"{len(candidati)} candidati, {len(scartati)} scartati, {len(rinviati)} rinviati alla prossima esecuzione")
    return 0


if __name__ == "__main__":
    sys.exit(main())
