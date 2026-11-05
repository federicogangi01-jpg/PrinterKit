import copy
import io
import json
import os
import sys
import tempfile
import unittest

QUI = os.path.dirname(os.path.abspath(__file__))
RADICE = os.path.dirname(os.path.dirname(QUI))
sys.path.insert(0, os.path.join(RADICE, "manutenzione"))

import comune  # noqa: E402
import controllo_link  # noqa: E402
import genera_indice_xp  # noqa: E402
import recupero_link  # noqa: E402
import rete  # noqa: E402
import applica_risultati  # noqa: E402

ESEMPIO = os.path.join(RADICE, "tests", "fixtures", "drivers-esempio.json")


class TestDomini(unittest.TestCase):
    def test_dominio_e_sottodominio(self):
        d = ["kyoceradocumentsolutions.eu", "kyostatics.net"]
        self.assertTrue(comune.dominio_ufficiale("https://www.kyoceradocumentsolutions.eu/a.zip", d))
        self.assertTrue(comune.dominio_ufficiale("https://cdn.kyostatics.net/a.zip", d))

    def test_rifiuta_imitazioni_e_http(self):
        d = ["hp.com"]
        self.assertFalse(comune.dominio_ufficiale("https://hp.com.evil.io/a.exe", d))
        self.assertFalse(comune.dominio_ufficiale("https://nothp.com/a.exe", d))
        self.assertFalse(comune.dominio_ufficiale("http://ftp.hp.com/a.exe", d))
        self.assertFalse(comune.dominio_ufficiale("https://evil.io/ftp.hp.com/a.exe", d))


class TestSchema(unittest.TestCase):
    def test_catalogo_reale_valido(self):
        cat = comune.leggi_json(comune.CATALOGO)
        self.assertEqual(comune.valida(cat, comune.leggi_json(comune.SCHEMA_CATALOGO)), [])
        self.assertEqual(comune.controlli_extra_catalogo(cat), [])

    def test_pagine_ufficiali_valide_e_complete(self):
        cat = comune.leggi_json(comune.CATALOGO)
        pag = comune.leggi_json(comune.PAGINE)
        self.assertEqual(comune.valida(pag, comune.leggi_json(comune.SCHEMA_PAGINE)), [])
        self.assertEqual(comune.controlli_extra_pagine(pag, cat), [])
        marche = {m["id"] for m in cat["manufacturers"]}
        coperte = {p["manufacturer"] for p in pag["pagine"]}
        self.assertEqual(marche, coperte, "ogni marca del §5 deve avere almeno una pagina")
        for p in pag["pagine"]:
            if p["stato"] == "da_verificare":
                self.assertTrue(p.get("notes"), f"voce da_verificare senza motivo: {p['pageUrl']}")

    def test_esempio_valido(self):
        cat = comune.leggi_json(ESEMPIO)
        self.assertEqual(comune.valida(cat, comune.leggi_json(comune.SCHEMA_CATALOGO)), [])

    def test_errori_rilevati(self):
        cat = comune.leggi_json(ESEMPIO)
        rotto = copy.deepcopy(cat)
        rotto["manufacturers"][0]["packages"].append({"id": "x"})
        self.assertTrue(comune.valida(rotto, comune.leggi_json(comune.SCHEMA_CATALOGO)))
        senza_url = copy.deepcopy(cat)
        k = next(m for m in senza_url["manufacturers"] if m["id"] == "kyocera")
        k["packages"][0]["url"] = None
        self.assertTrue(comune.valida(senza_url, comune.leggi_json(comune.SCHEMA_CATALOGO)), "status ok senza url")
        fuori = copy.deepcopy(cat)
        k = next(m for m in fuori["manufacturers"] if m["id"] == "kyocera")
        k["packages"][0]["url"] = "https://driver-gratis.example/kx.zip"
        self.assertTrue(comune.controlli_extra_catalogo(fuori))


class TestControlloLink(unittest.TestCase):
    P = {"etag": '"a"', "lastModified": "x", "size": 10, "sha256": "f" * 64}

    def r(self, **k):
        base = {"status": 200, "finale": "https://www.hp.com/a.exe", "tipo": "application/octet-stream",
                "etag": '"a"', "data": "x", "dimensione": 10, "errore": None}
        base.update(k)
        return base

    def test_invariato(self):
        self.assertEqual(controllo_link.valuta(self.P, self.r(), ["hp.com"]), ("ok", False, "raggiungibile"))

    def test_cambiato(self):
        self.assertTrue(controllo_link.valuta(self.P, self.r(etag='"b"'), ["hp.com"])[1])
        self.assertTrue(controllo_link.valuta(self.P, self.r(dimensione=11), ["hp.com"])[1])

    def test_rotto(self):
        self.assertEqual(controllo_link.valuta(self.P, self.r(status=404, errore="HTTP 404"), ["hp.com"])[0], "link_rotto")
        self.assertEqual(controllo_link.valuta(self.P, self.r(finale="https://altro.com/a.exe"), ["hp.com"])[0], "link_rotto")
        self.assertEqual(controllo_link.valuta(self.P, self.r(tipo="text/html; charset=utf-8"), ["hp.com"])[0], "link_rotto")


class TestEstrazioneLink(unittest.TestCase):
    def test_link_assoluti_e_testo(self):
        html = '<a href="/dl/kx.zip">KX Driver 8.4</a> <a href="javascript:x()">no</a><a href="https://x.com/y">Y</a>'
        link, testo = rete.estrai_link(html, "https://www.kyoceradocumentsolutions.eu/it/pagina.html")
        urls = [l["url"] for l in link]
        self.assertIn("https://www.kyoceradocumentsolutions.eu/dl/kx.zip", urls)
        self.assertNotIn("javascript:x()", urls)
        self.assertEqual(link[0]["testo"], "KX Driver 8.4")
        self.assertIn("KX Driver", testo)

    def test_captcha(self):
        self.assertTrue(rete.sembra_captcha("<div class='g-recaptcha'>captcha</div>"))
        self.assertFalse(rete.sembra_captcha("<a href='x.zip'>driver</a>"))


PAGINA = """<html><body><h1>KX Driver</h1>
<a href="https://www.kyoceradocumentsolutions.eu/dl/KX_8.5_x64.zip">KX 8.5 Windows 64 bit</a>
<a href="https://www.kyoceradocumentsolutions.eu/dl/manuale.pdf">Manuale</a>
<a href="https://www.kyoceradocumentsolutions.eu/dl/Kyocera_Mac.pkg">Mac</a>
<a href="https://mirror-driver.example/KX_8.5_x64.zip">mirror</a></body></html>"""


KX_URL = "https://www.kyoceradocumentsolutions.eu/dl/KX_8.5_x64.zip"


class TestRicercaSenzaAI(unittest.TestCase):
    MARCA = {"id": "kyocera", "officialDomains": ["kyoceradocumentsolutions.eu"]}
    VOCE = {"os": ["windows-10", "windows-11", "windows-7", "macos"], "arch": ["x64", "x86", "intel", "applesilicon"]}

    def proposte(self, link):
        return recupero_link.proposte_senza_ai([{"url": u, "testo": t} for u, t in link], self.MARCA, self.VOCE)

    def test_file_driver_riconosciuti(self):
        p = self.proposte([
            ("https://d.kyoceradocumentsolutions.eu/KX_Driver_8.4.1716_x64.zip", "KX Driver 8.4 Windows 64 bit"),
            ("https://d.kyoceradocumentsolutions.eu/KX_Driver_8.4.1716_x86.zip", "KX Driver 8.4 Windows 32 bit"),
            ("https://d.kyoceradocumentsolutions.eu/Kyocera_OSX_Driver_5.4.pkg", "Mac printer driver"),
        ])
        self.assertEqual([x["arch"] for x in p], [["x64"], ["x86"], ["intel", "applesilicon"]])
        self.assertEqual(p[0]["version"], "8.4.1716")
        self.assertEqual(p[0]["osMin"], "6.1", "la pagina copre anche Windows 7")
        self.assertEqual(p[2]["os"], "macos")

    def test_esclusi_manuali_firmware_utility(self):
        p = self.proposte([
            ("https://d.kyoceradocumentsolutions.eu/manual.zip", "Manuale d'uso"),
            ("https://d.kyoceradocumentsolutions.eu/fw_2.1.zip", "Firmware update"),
            ("https://d.kyoceradocumentsolutions.eu/scan_twain.exe", "TWAIN scanner driver"),
            ("https://d.kyoceradocumentsolutions.eu/app.pkg", "Mac utility"),
            ("https://d.kyoceradocumentsolutions.eu/pagina.html", "Driver"),
        ])
        self.assertEqual(p, [])

    def test_sistema_non_richiesto_dalla_pagina(self):
        p = recupero_link.proposte_senza_ai([{"url": "https://x.kyoceradocumentsolutions.eu/drv.pkg", "testo": "Mac driver"}],
                                           self.MARCA, {"os": ["windows-11"], "arch": ["x64"]})
        self.assertEqual(p, [])

    def test_limite_per_pagina(self):
        p = self.proposte([(f"https://d.kyoceradocumentsolutions.eu/driver_{i}_x64.zip", "driver") for i in range(20)])
        self.assertEqual(len(p), recupero_link.MAX_PER_PAGINA)

    def test_id_univoci(self):
        a = recupero_link.id_pacchetto("kyocera", {"driverFamily": "KX", "os": "windows", "arch": ["x64"], "url": "https://a/1.zip"})
        b = recupero_link.id_pacchetto("kyocera", {"driverFamily": "KX", "os": "windows", "arch": ["x64"], "url": "https://a/2.zip"})
        self.assertNotEqual(a, b)
        self.assertRegex(a, r"^[a-z0-9.-]+$")


class TestRecuperoLinkConGeminiSimulato(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["GEMINI_API_KEY"] = "finta"

    def esegui(self, risposta, modo="--popola"):
        def gemini(prompt, chiave, modello):
            self.assertIn("Non inventare", prompt)
            self.assertNotIn("mirror-driver.example", prompt, "i link non ufficiali non vanno mandati a Gemini")
            return risposta
        def pagina(url, browser=False):
            return PAGINA, "https://www.kyoceradocumentsolutions.eu/en/support/downloads.html"
        orig_cat, orig_pag = recupero_link.CATALOGO, recupero_link.PAGINE
        pag = os.path.join(self.tmp, "pagine.json")
        comune.scrivi_json(pag, {"schemaVersion": 1, "pagine": [{
            "manufacturer": "kyocera", "scope": "universale", "series": None, "os": ["windows-10", "windows-11", "macos"],
            "arch": ["x64"], "pageUrl": "https://www.kyoceradocumentsolutions.eu/en/support/downloads.html",
            "needsBrowser": False, "notes": None, "stato": "ok", "verificatoIl": None}]})
        recupero_link.CATALOGO, recupero_link.PAGINE = ESEMPIO, pag
        try:
            recupero_link.main([modo, "--out", self.tmp, "--attesa", "0"], gemini=gemini, apri_pagina=pagina)
        finally:
            recupero_link.CATALOGO, recupero_link.PAGINE = orig_cat, orig_pag
        return (comune.leggi_json(os.path.join(self.tmp, "candidati.json")),
                comune.leggi_json(os.path.join(self.tmp, "scartati.json")))

    @staticmethod
    def url(c):
        return [x["package"]["url"] for x in c]

    def test_link_valido_accettato(self):
        c, s = self.esegui({"pacchetti": [{"url": "https://www.kyoceradocumentsolutions.eu/dl/KX_8.5_x64.zip",
                                           "driverFamily": "KX Driver", "version": "8.5", "os": "windows", "osMin": "10.0",
                                           "arch": ["x64"], "language": "pcl6", "fileType": "zip", "motivazione": "ok"}]})
        self.assertEqual(len(c), 1, "stesso file da Gemini e senza AI: un solo candidato")
        self.assertEqual(c[0]["package"]["status"], "da_verificare", "resta da verificare finché la firma non è controllata")
        self.assertIn("Gemini", c[0]["package"]["notes"])

    def test_link_inventato_scartato(self):
        c, s = self.esegui({"pacchetti": [{"url": "https://www.kyoceradocumentsolutions.eu/dl/KX_9.0_x64.zip",
                                           "driverFamily": "KX", "os": "windows", "osMin": "10.0", "arch": ["x64"],
                                           "fileType": "zip", "motivazione": "inventato"}]})
        self.assertEqual(self.url(c), [KX_URL], "resta solo il file vero trovato senza AI")
        self.assertIn("inventato", s[0]["motivo"])

    def test_link_non_ufficiale_scartato(self):
        c, s = self.esegui({"pacchetti": [{"url": "https://mirror-driver.example/KX_8.5_x64.zip", "driverFamily": "KX",
                                           "os": "windows", "osMin": "10.0", "arch": ["x64"], "fileType": "zip", "motivazione": "x"}]})
        self.assertNotIn("https://mirror-driver.example/KX_8.5_x64.zip", self.url(c))

    def test_architettura_incoerente_scartata(self):
        c, s = self.esegui({"pacchetti": [{"url": "https://www.kyoceradocumentsolutions.eu/dl/Kyocera_Mac.pkg", "driverFamily": "Mac",
                                           "os": "macos", "osMin": "12.0", "arch": ["x64"], "fileType": "pkg", "motivazione": "x"}]})
        self.assertNotIn("https://www.kyoceradocumentsolutions.eu/dl/Kyocera_Mac.pkg", self.url(c))
        self.assertIn("architettura", s[0]["motivo"])

    def test_errore_di_gemini_registrato(self):
        def gemini(prompt, chiave, modello):
            raise RuntimeError("HTTP 429 quota superata")
        pag = os.path.join(self.tmp, "pagine.json")
        comune.scrivi_json(pag, {"schemaVersion": 1, "pagine": [{
            "manufacturer": "kyocera", "scope": "universale", "series": None, "os": ["windows-10"], "arch": ["x64"],
            "pageUrl": "https://www.kyoceradocumentsolutions.eu/x.html", "needsBrowser": False, "notes": None,
            "stato": "ok", "verificatoIl": None}]})
        orig = recupero_link.CATALOGO, recupero_link.PAGINE
        recupero_link.CATALOGO, recupero_link.PAGINE = ESEMPIO, pag
        try:
            recupero_link.main(["--popola", "--out", self.tmp, "--attesa", "0"], gemini=gemini,
                               apri_pagina=lambda u, b=False: (PAGINA, "https://www.kyoceradocumentsolutions.eu/x.html"))
        finally:
            recupero_link.CATALOGO, recupero_link.PAGINE = orig
        c = comune.leggi_json(os.path.join(self.tmp, "candidati.json"))
        self.assertEqual(self.url(c), [KX_URL], "senza Gemini resta la ricerca senza AI")
        self.assertIn("senza AI", c[0]["package"]["notes"])

    def test_risposta_vuota_o_errata(self):
        c, s = self.esegui({"pacchetti": []})
        self.assertEqual(self.url(c), [KX_URL])
        c, s = self.esegui({"pacchetti": [{"url": None, "os": "linux"}, "testo"]})
        self.assertEqual(self.url(c), [KX_URL])


class TestGeminiTentativi(unittest.TestCase):
    def test_riprova_su_503_poi_risponde(self):
        import urllib.error
        chiamate = []

        class Risposta(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *a): return False

        def apri(req, timeout=0):
            chiamate.append(req.full_url)
            self.assertNotIn("key=", req.full_url, "la chiave va nell'header, non nell'URL")
            if len(chiamate) < 3:
                raise urllib.error.HTTPError(req.full_url, 503, "busy", {}, io.BytesIO(b'{"error":"busy"}'))
            corpo = {"candidates": [{"content": {"parts": [{"text": '{"pacchetti": []}'}]}}]}
            return Risposta(json.dumps(corpo).encode())
        r = recupero_link.chiedi_gemini("p", "k", "m", apri=apri, attese=(0, 0, 0))
        self.assertEqual(r, {"pacchetti": []})
        self.assertEqual(len(chiamate), 3)

    def test_errore_definitivo_non_riprova(self):
        import urllib.error
        n = []
        def apri(req, timeout=0):
            n.append(1)
            raise urllib.error.HTTPError(req.full_url, 404, "no", {}, io.BytesIO(b'{"error":"modello"}'))
        with self.assertRaises(RuntimeError):
            recupero_link.chiedi_gemini("p", "k", "m", apri=apri, attese=(0, 0))
        self.assertEqual(len(n), 1)


class TestApplicaRisultati(unittest.TestCase):
    @staticmethod
    def scrivi_con_bom(percorso, dati):
        with open(percorso, "w", encoding="utf-8-sig") as f:
            json.dump(dati, f)

    def test_solo_firme_valide_entrano(self):
        tmp = tempfile.mkdtemp()
        cat_path = os.path.join(tmp, "drivers.json")
        cat = comune.leggi_json(ESEMPIO)
        comune.scrivi_json(cat_path, cat)
        pk = lambda i, url: {"manufacturer": "kyocera", "sostituisce": None, "officialDomains": ["kyoceradocumentsolutions.eu"],
                             "signerNames": ["KYOCERA Document Solutions Inc."], "match": "KYOCERA",
                             "package": {**cat["manufacturers"][2]["packages"][0], "id": f"nuovo-{i}", "url": url, "status": "da_verificare"}}
        elenco = [pk(0, "https://www.kyoceradocumentsolutions.eu/a.zip"), pk(1, "https://www.kyoceradocumentsolutions.eu/b.zip")]
        e = os.path.join(tmp, "candidati.json"); comune.scrivi_json(e, elenco)
        w = os.path.join(tmp, "w"); os.makedirs(w)
        comune.scrivi_json(os.path.join(w, "scaricati.json"), [{"indice": 0, "file": "a", "sha256": "a" * 64, "errore": None},
                                                                {"indice": 1, "file": "b", "sha256": "b" * 64, "errore": None}])
        # Scritto come fa Windows PowerShell 5.1 (Set-Content -Encoding UTF8): con il BOM.
        self.scrivi_con_bom(os.path.join(w, "verificati_windows.json"), [{"indice": 0, "ok": True, "firma": "KYOCERA Document Solutions Inc.", "motivo": "firma valida"},
                                                                         {"indice": 1, "ok": False, "firma": "Altro", "motivo": "firmatario non ammesso"}])
        applica_risultati.main(["--candidati", e, w, os.path.join(tmp, "m"), "--out", tmp, "--catalogo", cat_path])
        nuovo = comune.leggi_json(cat_path)
        ids = {p["id"]: p for m in nuovo["manufacturers"] for p in m["packages"]}
        self.assertEqual(ids["nuovo-0"]["status"], "ok")
        self.assertEqual(ids["nuovo-0"]["sha256"], "a" * 64)
        self.assertNotIn("nuovo-1", ids)
        self.assertIn("firmatario non ammesso", open(os.path.join(tmp, "issue.md")).read())
        self.assertEqual(comune.valida(nuovo, comune.leggi_json(comune.SCHEMA_CATALOGO)), [])


class TestIndiceXP(unittest.TestCase):
    def test_solo_pacchetti_xp_e_righe_marca(self):
        rr = genera_indice_xp.righe(comune.leggi_json(ESEMPIO))
        ids = [r[3] for r in rr if r[3]]
        self.assertIn("kyocera-kx-xp", ids)
        self.assertNotIn("kyocera-kx-win-x64", ids)
        self.assertTrue(all(len(r) == 15 for r in rr))
        self.assertEqual(len([r for r in rr if r[14] == "marca"]), 13)


class TestRicette(unittest.TestCase):
    def test_ricette_valide(self):
        schema = comune.leggi_json(os.path.join(RADICE, "scanner-ricette", "schema.json"))
        trovate = 0
        for cart in ("scanner-ricette", "nas-ricette"):
            for base, _, files in os.walk(os.path.join(RADICE, cart)):
                for f in files:
                    if f.endswith(".json") and f != "schema.json":
                        r = comune.leggi_json(os.path.join(base, f))
                        self.assertEqual(comune.valida(r, schema), [], f)
                        trovate += 1
                        for chiave in ("login", "addEntry", "createShare"):
                            for st in r.get(chiave, []):
                                if st.get("method", "GET") == "POST" and chiave != "login":
                                    self.assertTrue(st.get("writes"), f"{f}: passo di scrittura senza writes=true")
        self.assertGreaterEqual(trovate, 4)


if __name__ == "__main__":
    unittest.main()


class TestTestoInf(unittest.TestCase):
    def test_stringa_come_oggetto_powershell(self):
        import applica_risultati as a
        self.assertEqual(a.testo({"value": " RICOH PCL6 UniversalDriver V4.46 ", "Length": 30}), "RICOH PCL6 UniversalDriver V4.46")
        self.assertEqual(a.testo("x"), "x")
        self.assertIsNone(a.testo(""))
        self.assertIsNone(a.testo(None))
