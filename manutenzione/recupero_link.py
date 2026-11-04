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
import urllib.error
import urllib.parse
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


class QuotaEsaurita(Exception):
    """Quota del piano gratuito finita: le pagine restanti passano alla prossima esecuzione."""


def errore(msg):
    """Messaggio visibile anche come annotazione sulla pagina del workflow."""
    print(("::error::" if os.environ.get("GITHUB_ACTIONS") else "ERRORE: ") + msg)


def chiedi_gemini(prompt, chiave, modello, temperatura=0.1, apri=urllib.request.urlopen, attese=(15, 45, 120)):
    corpo = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": temperatura, "responseMimeType": "application/json",
                             "responseSchema": SCHEMA_RISPOSTA},
    }
    req = urllib.request.Request(API.format(model=modello), data=json.dumps(corpo).encode(),
                                 headers={"Content-Type": "application/json", "x-goog-api-key": chiave})
    # 429 (limite al minuto) e 5xx (modello sovraccarico) sono temporanei: nuovi tentativi con attese crescenti.
    for tentativo, pausa in enumerate(list(attese) + [None]):
        try:
            with apri(req, timeout=180) as r:
                risposta = json.loads(r.read().decode())
            break
        except urllib.error.HTTPError as e:
            # Il corpo spiega il motivo (quota, modello inesistente, chiave non valida); la chiave è nell'header, non qui.
            dettaglio = e.read().decode(errors="replace")[:300].replace("\n", " ")
            if pausa is not None and (e.code == 429 or e.code >= 500):
                print(f"Gemini HTTP {e.code}, nuovo tentativo tra {pausa} s")
                time.sleep(pausa)
                continue
            if e.code == 429 and "quota" in dettaglio.lower():
                raise QuotaEsaurita(f"quota Gemini esaurita: {dettaglio}") from None
            raise RuntimeError(f"HTTP {e.code} da Gemini: {dettaglio}") from None
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
Testo della pagina (estratto): {testo[:2500]}
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
    breve = __import__("hashlib").sha1(p["url"].encode()).hexdigest()[:6]
    return base.strip("-")[:72] + "-" + breve


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


# ---------- Ricerca senza AI ----------
# I link diretti ai file sui domini ufficiali diventano candidati. Non è la ricerca a garantire che siano
# driver giusti: lo garantisce la verifica successiva (download, firma del produttore, INF per architettura).

ESCLUSI = re.compile(r"manual|guida|guide|firmware|utilit|scan|twain|wia|fax|readme|release.?note|brochure|"
                     r"datasheet|leaflet|\.pdf\b|font|sdk|tool|monitor|status|setup.?guide", re.I)
INDIZI_DRIVER = re.compile(r"driver|pcl|postscript|\bps\b|\bupd\b|universal|\bkx\b|\bgpd\b|printer|stampa|ppd|ufr", re.I)
ARCH_URL = (("arm64", re.compile(r"arm64|aarch64", re.I)),
            ("x64", re.compile(r"x64|amd64|64.?bit|win64|w64", re.I)),
            ("x86", re.compile(r"x86|i386|32.?bit|win32|w32", re.I)))
MAX_PER_PAGINA = int(os.environ.get("PK_MAX_PER_PAGINA", "6"))


def proposte_senza_ai(link, marca, voce, cercato=None):
    """Proposte nello stesso formato di quelle di Gemini, ricavate solo da URL e testo dei link."""
    os_voce = {o.split("-")[0] for o in voce["os"]}
    arch_voce = list(voce["arch"])
    proposte = []
    for l in link:
        url, testo = l["url"], l.get("testo") or ""
        percorso = urllib.parse.urlsplit(url).path
        nome = percorso.rsplit("/", 1)[-1]
        est = nome.lower().rsplit(".", 1)[-1] if "." in nome else ""
        if est not in ("zip", "exe", "pkg", "dmg", "cab"):
            continue
        tutto = f"{nome} {testo}"
        if ESCLUSI.search(tutto):
            continue
        sistema = "macos" if est in ("pkg", "dmg") else "windows"
        if sistema not in os_voce:
            continue
        # Su Mac un pacchetto firmato potrebbe essere un'utility: serve un indizio di driver nel nome o nel testo.
        if sistema == "macos" and not INDIZI_DRIVER.search(tutto):
            continue
        if sistema == "macos":
            arch = [a for a in arch_voce if a in ("intel", "applesilicon")] or ["intel", "applesilicon"]
            os_min = "12.0"
        else:
            trovate = [a for a, rx in ARCH_URL if rx.search(tutto)]
            arch = trovate[:1] or [a for a in arch_voce if a in ("x86", "x64", "arm64")] or ["x64"]
            os_min = min((OS_MIN[o] for o in voce["os"] if o in OS_MIN), key=lambda v: [int(x) for x in v.split(".")], default="10.0")
        if cercato and (sistema != cercato.get("os") or not set(cercato.get("arch") or []) <= set(arch)):
            continue
        ver = re.search(r"(?<![\d.])(\d+\.\d+(?:\.\d+){0,2})(?![\d.])", tutto)
        lingua = "ps" if re.search(r"postscript|\bps\b|kpdl|br-?script", tutto, re.I) else \
                 "pcl6" if re.search(r"pcl\s?6|pcl\s?xl|pclxl", tutto, re.I) else \
                 "pcl5" if re.search(r"pcl\s?5", tutto, re.I) else None
        da_nome = re.sub(r"[_-]+", " ", nome.rsplit(".", 1)[0]).strip()
        etichetta = re.sub(r"\s+", " ", testo).strip()
        # "Download", "Scarica", "Download PS3 emulation": il nome del file dice di più.
        if not etichetta or re.fullmatch(r"(download|scarica|download now|get file)", etichetta, re.I):
            famiglia = da_nome[:80]
        elif re.match(r"(download|scarica)\b", etichetta, re.I):
            resto = re.sub(r"^(download|scarica)\s*", "", etichetta, flags=re.I)
            famiglia = f"{da_nome} ({resto})"[:80]
        else:
            famiglia = etichetta[:80]
        proposte.append({"url": url, "driverFamily": famiglia, "version": ver.group(1) if ver else None,
                         "os": sistema, "osMin": os_min, "osMax": None, "arch": arch, "language": lingua,
                         "fileType": est, "motivazione": "link diretto a un file sulla pagina ufficiale (senza AI)"})
    # Prima quelli con un indizio di driver di stampa.
    proposte.sort(key=lambda p: 0 if INDIZI_DRIVER.search(p["url"] + " " + p["driverFamily"]) else 1)
    return proposte[:MAX_PER_PAGINA]


def elabora(m, voce, vecchio, chiave, modello, gemini, apri_pagina, candidati, scartati, stato_ai):
    """Una pagina: apre, estrae i link, proposte senza AI + (se disponibile) Gemini, validazione."""
    try:
        html, finale = apri_pagina(voce["pageUrl"], voce.get("needsBrowser", False))
    except Exception as e:
        scartati.append({"voce": voce, "motivo": f"pagina non raggiungibile: {e}"})
        return
    if rete.sembra_captcha(html):
        scartati.append({"voce": voce, "motivo": "il sito blocca l'accesso automatico (CAPTCHA): nessun aggiramento"})
        return
    link, testo = rete.estrai_link(html, finale)
    link = [l for l in link if dominio_ufficiale(l["url"], m["officialDomains"])]
    # Prima i link che sembrano file, poi gli altri (limite per non superare il contesto).
    link.sort(key=lambda l: 0 if l["url"].lower().split("?")[0].endswith(ESTENSIONI) else 1)
    link = link[:400]
    if not link:
        scartati.append({"voce": voce, "motivo": "nessun link ufficiale nella pagina (forse serve il browser)"})
        return
    cercato = None
    if vecchio:
        cercato = {k: vecchio.get(k) for k in ("driverFamily", "version", "os", "osMin", "arch", "language", "fileType")}
    proposte = proposte_senza_ai(link, m, voce, cercato)
    if stato_ai["attivo"]:
        try:
            risposta = gemini(costruisci_prompt(m, voce, link[:150], testo, cercato), chiave, modello)
            dagli_ai = [p for p in (risposta.get("pacchetti") or []) if isinstance(p, dict)]
            # Le proposte di Gemini hanno nomi e versioni migliori: sostituiscono quelle senza AI sullo stesso URL.
            urls_ai = {p.get("url") for p in dagli_ai}
            proposte = dagli_ai + [p for p in proposte if p["url"] not in urls_ai]
        except QuotaEsaurita as e:
            stato_ai["attivo"] = False
            errore(f"{e} – si prosegue senza AI")
        except Exception as e:
            stato_ai["errori"] += 1
            errore(f"Gemini non ha risposto per {voce['pageUrl']}: {e} – uso solo la ricerca senza AI")
            if stato_ai["errori"] >= 2:
                # Ogni tentativo fallito costa minuti di attesa: dopo due pagine si prosegue senza AI.
                stato_ai["attivo"] = False
                errore("Gemini non disponibile in questo giro: le altre pagine usano solo la ricerca senza AI")
    trovati = 0
    for p in proposte:
        problema = valida_proposta(p, link, m, None if vecchio else voce)
        if problema:
            scartati.append({"voce": voce, "proposta": p, "motivo": problema})
            continue
        if vecchio and (p["os"] != vecchio["os"] or not set(vecchio["arch"]) <= set(p["arch"])):
            scartati.append({"voce": voce, "proposta": p, "motivo": "non corrisponde al pacchetto da sostituire"})
            continue
        if any(c["package"]["url"] == p["url"] for c in candidati):
            continue
        origine = "senza AI" if "senza AI" in (p.get("motivazione") or "") else "Gemini"
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
                "status": "da_verificare", "notes": f"trovato {origine}: " + (p.get("motivazione") or "")[:200],
            },
            "signerNames": m["signerNames"], "macSignerNames": m.get("macSignerNames", m["signerNames"]),
            "officialDomains": m["officialDomains"], "match": m["match"],
        })
        trovati += 1
        if vecchio:
            break  # per un link rotto basta un sostituto
    if not trovati and vecchio is None:
        scartati.append({"voce": voce, "motivo": "nessun link diretto a file di driver nella pagina (pagina di ingresso o elenco caricato dopo una scelta)"})
    if vecchio and not trovati:
        scartati.append({"voce": voce, "pacchetto": vecchio["id"], "motivo": "nessun sostituto valido"})


def main(argv=None, gemini=chiedi_gemini, apri_pagina=rete.apri_pagina):
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--rotti", action="store_true")
    g.add_argument("--popola", action="store_true")
    g.add_argument("--nuove", action="store_true")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    ap.add_argument("--max", type=int, default=int(os.environ.get("PK_MAX_PAGINE", "20")))
    ap.add_argument("--attesa", type=float, default=float(os.environ.get("PK_ATTESA_SEC", "7")))
    ap.add_argument("--max-candidati", type=int, default=int(os.environ.get("PK_MAX_CANDIDATI", "40")))
    a = ap.parse_args(argv)
    modo = "rotti" if a.rotti else "popola" if a.popola else "nuove"
    chiave = os.environ.get("GEMINI_API_KEY", "")
    modello = os.environ.get("GEMINI_MODEL", "gemini-3.8-flash")
    stato_ai = {"attivo": bool(chiave) and os.environ.get("PK_SENZA_AI") != "1", "errori": 0}
    if not chiave:
        print("GEMINI_API_KEY assente: uso solo la ricerca senza AI")
    cat, pagine = leggi_json(CATALOGO), leggi_json(PAGINE)
    lavori = obiettivi(modo, cat, pagine)
    rinviati = lavori[a.max:]
    lavori = lavori[:a.max]
    candidati, scartati = [], []
    for i, (m, voce, vecchio) in enumerate(lavori):
        if len(candidati) >= a.max_candidati:
            # Ogni candidato va scaricato e firmato: oltre il limite si rimanda, per non allungare troppo il giro.
            rinviati = lavori[i:] + rinviati
            break
        if i and stato_ai["attivo"]:
            time.sleep(a.attesa)  # limiti al minuto del piano gratuito
        try:
            elabora(m, voce, vecchio, chiave, modello, gemini, apri_pagina, candidati, scartati, stato_ai)
        except Exception as e:  # una pagina non deve fermare le altre
            import traceback
            dettaglio = traceback.format_exc().strip().splitlines()[-3:]
            scartati.append({"voce": voce, "motivo": f"errore imprevisto: {e}"})
            errore(f"errore imprevisto su {voce['pageUrl']}: {' | '.join(dettaglio)}")
    os.makedirs(a.out, exist_ok=True)
    scrivi_json(os.path.join(a.out, "candidati.json"), candidati)
    scrivi_json(os.path.join(a.out, "scartati.json"), scartati)
    scrivi_json(os.path.join(a.out, "rinviati.json"), [{"pageUrl": v["pageUrl"], "manufacturer": mm["id"]} for mm, v, _ in rinviati])
    da_ai = sum(1 for c in candidati if "Gemini" in c["package"]["notes"])
    riepilogo = (f"{len(candidati)} candidati ({da_ai} da Gemini, {len(candidati) - da_ai} senza AI), "
                 f"{len(scartati)} scartati, {len(rinviati)} rinviati alla prossima esecuzione")
    print(("::notice::" if os.environ.get("GITHUB_ACTIONS") else "") + riepilogo)
    return 0


if __name__ == "__main__":
    sys.exit(main())
