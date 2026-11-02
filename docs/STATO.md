# Stato del progetto (02/11/2026)

## Provato
- Script di manutenzione Python: 19 test automatici passati (`python3 -m unittest discover -s tests/python`),
  comprese risposte Gemini simulate con link inventati, non ufficiali o con architettura sbagliata (scartate).
- Validazione di `drivers.json` e `pagine_ufficiali.json` con gli schemi.
- Funzioni del catalogo per Mac (`macos/catalogo.js`) eseguite con osascript sul catalogo di esempio.
- Sintassi dello script zsh (`zsh -n`) e controllo strutturale di tutti i file PowerShell.
- Test Pester dei moduli Windows passati su `windows-latest` (Windows PowerShell 5.1) nel workflow `valida`:
  intervalli IP, SNMP/BER, parser INF, scelta del pacchetto, validazione del catalogo, nomi delle cartelle
  di log, ricette. Hanno fatto emergere e correggere quattro errori reali (array annidati nei campi del
  catalogo, `Contains` assente sui dizionari JSON, catalogo con `packages: []` rifiutato, file senza BOM
  letti come ANSI).

## Non provato (nessun Windows/stampante disponibile durante lo sviluppo)
- L'app Windows, la versione XP e l'esecuzione reale su Mac: il codice è completo ma va collaudato
  con i test di `docs/TEST_MANUALI.md` (installazione reale, interfaccia, Windows 7/XP, Mac).
- **Ricette scanner Sharp e Kyocera e ricette NAS**: struttura e motore sono completi, ma indirizzi delle
  pagine e nomi dei campi delle interfacce web sono da confermare su macchine reali. Per questo hanno
  `"validata": false` e l'app chiede conferma prima di scrivere (dopo il backup della rubrica).
  Procedura: prova a secco (`-WhatIf`), correzione con `richiesta_ricetta_<modello>.json`, poi
  `"validata": true` e `"collaudo": "<modello> firmware <x>"`.
- Workflow `controllo-link` e `recupero-link`: caricati e validi, ma non ancora eseguiti davvero (servono la chiave Gemini e un catalogo con pacchetti).

## Da fare
- Catalogo iniziale: `drivers.json` contiene le 13 marche con domini e firmatari, ma **nessun pacchetto**
  ancora: si popola con `recupero-link` in modalità `popola` (vedi `MESSA_IN_FUNZIONE.md`). Non ho
  inserito link a mano per non mettere URL non verificati.
- Pagine ufficiali: 10 confermate, 33 da verificare (pagine dinamiche, blocchi 403 o errori TLS
  dall'accesso automatico), 3 "nessun driver". Dettaglio in `catalogo/PAGINE_UFFICIALI.md`.
- Ricette scanner per Ricoh, Canon, Konica Minolta, HP, Brother, Xerox, Epson (§10.2).
- Scansione WSD di riserva (§10.5): solo proposta, non implementata.
