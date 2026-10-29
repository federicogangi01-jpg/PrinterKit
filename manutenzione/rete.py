"""Richieste HTTP per la manutenzione (solo libreria standard)."""
import hashlib
import html.parser
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from comune import USER_AGENT, dominio_ufficiale


class _SoloHttps(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.lower().startswith("https://"):
            raise urllib.error.URLError(f"redirect verso un indirizzo non https: {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_opener = urllib.request.build_opener(_SoloHttps())


def testa(url, timeout=30):
    """HEAD (con ripiego su GET parziale). Restituisce dict con status, finale, tipo, etag, data, dimensione."""
    for metodo in ("HEAD", "GET"):
        req = urllib.request.Request(url, method=metodo, headers={"User-Agent": USER_AGENT})
        if metodo == "GET":
            req.add_header("Range", "bytes=0-0")
        try:
            with _opener.open(req, timeout=timeout) as r:
                dim = r.headers.get("Content-Length")
                cr = r.headers.get("Content-Range")
                if cr and "/" in cr:
                    dim = cr.rsplit("/", 1)[1]
                return {
                    "status": r.status, "finale": r.geturl(), "tipo": r.headers.get("Content-Type", ""),
                    "etag": r.headers.get("ETag"), "data": r.headers.get("Last-Modified"),
                    "dimensione": int(dim) if dim and dim.isdigit() else None, "errore": None,
                }
        except urllib.error.HTTPError as e:
            if metodo == "HEAD" and e.code in (403, 405, 501):
                continue
            return {"status": e.code, "finale": url, "tipo": "", "etag": None, "data": None, "dimensione": None,
                    "errore": f"HTTP {e.code}"}
        except Exception as e:  # rete, TLS, redirect non https
            if metodo == "HEAD":
                continue
            return {"status": 0, "finale": url, "tipo": "", "etag": None, "data": None, "dimensione": None,
                    "errore": str(e)}
    return {"status": 0, "finale": url, "tipo": "", "etag": None, "data": None, "dimensione": None, "errore": "nessuna risposta"}


def scarica(url, destinazione, domini, timeout=120, max_byte=1_500_000_000):
    """Scarica controllando il dominio finale. Restituisce (sha256, url_finale)."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with _opener.open(req, timeout=timeout) as r:
        finale = r.geturl()
        if not dominio_ufficiale(finale, domini):
            raise ValueError(f"redirect fuori dai domini ufficiali: {finale}")
        if r.headers.get("Content-Type", "").lower().startswith("text/html"):
            raise ValueError("il link restituisce una pagina web, non un file")
        h = hashlib.sha256()
        letti = 0
        os.makedirs(os.path.dirname(destinazione) or ".", exist_ok=True)
        with open(destinazione, "wb") as f:
            while True:
                b = r.read(1 << 16)
                if not b:
                    break
                letti += len(b)
                if letti > max_byte:
                    raise ValueError("file troppo grande")
                h.update(b)
                f.write(b)
    return h.hexdigest(), finale


class _Link(html.parser.HTMLParser):
    def __init__(self, base):
        super().__init__()
        self.base = base
        self.link = []
        self.testo = []
        self._a = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for k in ("href", "data-href", "data-url", "data-download"):
            v = a.get(k)
            if v and not v.startswith(("javascript:", "mailto:", "#")):
                url = urllib.parse.urljoin(self.base, v.strip())
                self._a = url if tag == "a" else None
                self.link.append({"url": url, "testo": ""})

    def handle_data(self, data):
        t = data.strip()
        if t:
            self.testo.append(t)
            if self._a and self.link and self.link[-1]["url"] == self._a:
                self.link[-1]["testo"] = (self.link[-1]["testo"] + " " + t).strip()[:200]

    def handle_endtag(self, tag):
        if tag == "a":
            self._a = None


def estrai_link(html_testo, base):
    p = _Link(base)
    p.feed(html_testo)
    visti, unici = set(), []
    for l in p.link:
        if l["url"] not in visti:
            visti.add(l["url"])
            unici.append(l)
    return unici, " ".join(p.testo)


def apri_pagina(url, serve_browser=False, timeout=60):
    """Restituisce (html, url_finale). Con serve_browser usa Playwright se installato."""
    if serve_browser:
        try:
            from playwright.sync_api import sync_playwright  # type: ignore
        except ImportError:
            serve_browser = False
    if serve_browser:
        with sync_playwright() as pw:
            br = pw.chromium.launch()
            pg = br.new_page(user_agent=USER_AGENT)
            pg.goto(url, wait_until="networkidle", timeout=timeout * 1000)
            time.sleep(2)
            contenuto, finale = pg.content(), pg.url
            br.close()
            return contenuto, finale
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Language": "it-IT,it;q=0.9,en;q=0.8"})
    with _opener.open(req, timeout=timeout) as r:
        cs = r.headers.get_content_charset() or "utf-8"
        return r.read().decode(cs, errors="replace"), r.geturl()


def sembra_captcha(html_testo):
    t = html_testo.lower()
    return any(k in t for k in ("captcha", "cf-challenge", "are you a robot", "access denied", "verify you are human"))
