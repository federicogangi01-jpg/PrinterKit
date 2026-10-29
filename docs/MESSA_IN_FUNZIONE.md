# Messa in funzione

1. **Repository GitHub** (consigliato pubblico: Actions gratuito senza limiti di minuti).
   Caricare tutto il contenuto di questa cartella. Nessun dato di clienti va nel repository
   (`log/`, `cache/*/` e `manutenzione/out/` sono esclusi da `.gitignore`).
2. **config.json**: sostituire `UTENTE/PrinterKit` con `<proprietario>/<repository>` in
   `catalogSource`, `recipesSource`, `nasRecipesSource`, `githubRepo`.
3. **Gemini**: creare una chiave gratuita su Google AI Studio e salvarla in
   *Settings → Secrets and variables → Actions → New repository secret* con nome `GEMINI_API_KEY`.
   Facoltative, in *Variables*: `GEMINI_MODEL` (predefinito `gemini-2.5-flash`), `PK_MAX_PAGINE`
   (pagine per esecuzione, predefinito 20), `PK_ATTESA_SEC` (attesa tra le richieste, predefinito 7).
4. **Permessi Actions**: *Settings → Actions → General → Workflow permissions*: "Read and write" e
   "Allow GitHub Actions to create and approve pull requests".
5. **Controllo delle pagine**: leggere `catalogo/PAGINE_UFFICIALI.md` e correggere
   `catalogo/pagine_ufficiali.json` dove serve (dopo ogni modifica:
   `python3 manutenzione/genera_riepilogo.py`).
6. **Catalogo iniziale**: *Actions → recupero-link → Run workflow* con `modo = popola`. Arriva una
   Pull Request unica con i pacchetti trovati e verificati, più una Issue con le voci da controllare.
   Con il piano gratuito le pagine sono elaborate a lotti (`PK_MAX_PAGINE`): rilanciare finché
   `rinviati.json` è vuoto.
7. **Chiavetta**: copiare il kit su una chiavetta exFAT. Da un PC Windows 10/11 aggiornato eseguire
   `windows\PrinterKit.ps1 -PrepareCache -CacheFor windows-xp,windows-7` per portare nella cache i driver
   per i sistemi vecchi. Facoltativo: mettere `7z.exe` e `7z.dll` ufficiali in `tools\7zip\` per i
   pacchetti `.exe` autoestraenti senza `extractArgs`.

Da quel momento: ogni notte il workflow **controllo-link** ricontrolla i link; se uno si rompe avvia
**recupero-link**, che apre una Pull Request da approvare o una Issue (GitHub manda un'e-mail).
Per aggiungere una marca o una serie: vedi `catalogo/MODELLO_VOCE.md`.
