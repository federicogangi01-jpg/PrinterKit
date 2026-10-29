# PrinterKit

Kit per tecnico stampanti: da un'unica cartella (chiavetta USB o cartella di rete) trova le stampanti
in rete, ne riconosce marca e modello, installa **solo il driver ufficiale del produttore** dopo averne
verificato dominio, firma digitale e hash, crea porta e coda, stampa la pagina di prova, configura
facoltativamente la scansione su cartella e scrive il log di intervento nella cartella Download
dell'utente.

## Formato scelto: kit portatile su chiavetta (nessuna installazione)

Ho scelto un **kit portatile da avviare dalla chiavetta**, non un'app da installare, perché:

- sul PC del cliente non resta nessun programma: restano solo la stampante, il driver ufficiale e i log;
- funziona con quello che c'è già su ogni sistema (PowerShell / VBScript su Windows, zsh e
  JavaScript for Automation su Mac): niente runtime da installare, niente dipendenze;
- un solo supporto copre Windows XP → 11 e macOS Intel/Apple Silicon (`Avvia.bat` / `Avvia.command`
  scelgono da soli il motore giusto);
- la cartella `cache/` della chiavetta porta con sé i driver già verificati, indispensabili per XP e per
  i Windows 7 senza TLS 1.2, e utili in cantieri senza internet;
- i log di ogni intervento si accumulano anche nella chiavetta (`log/`), così il tecnico li ha sempre con sé;
- catalogo e ricette si aggiornano da GitHub a ogni avvio: la chiavetta non va mai "riflashata".

Consigli per la chiavetta: formattarla in **exFAT** (leggibile da Windows e Mac); copiare il kit
estraendo lo zip *dopo* averlo sbloccato (Proprietà → Sblocca) per evitare gli avvisi di Windows su
file scaricati; facoltativo, firmare gli script con un certificato di firma del codice aziendale se
l'antivirus del cliente blocca PowerShell.

## Uso

**Windows** – doppio clic su `Avvia.bat` (chiede da solo i diritti di amministratore):

1. in alto il sistema rilevato e l'intervallo IP (la /24 di ogni scheda di rete);
2. **Scansiona** → tabella con IP, porte, marca, modello (modificabile), driver ufficiale previsto,
   nome stampante (modificabile), stato. Le stampanti già installate con lo stesso IP sono grigie e
   deselezionate; quelle senza driver ufficiale per il sistema sono rosse con il motivo;
3. spunta le stampanti, scegli le opzioni (pagina di prova, predefinita, scansione su cartella,
   *solo prova*) e premi **Installa selezionate**.

Riga di comando (installazioni in serie):

```
windows\PrinterKit.ps1 -NoGui -Range 192.168.1.1-254 -InstallAll [-TestPage] [-ScanFolder -ScanUsers Mario,Contabilità]
windows\PrinterKit.ps1 -NoGui -IP 192.168.1.50,192.168.1.51 -InstallAll
windows\PrinterKit.ps1 -VerifyCatalog
windows\PrinterKit.ps1 -PrepareCache -CacheFor windows-xp,windows-7   # da un PC aggiornato
... -WhatIf   # prova a secco: esegue tutto tranne le modifiche e scrive nel log cosa farebbe
```

**Mac** – doppio clic su `Avvia.command` (chiede la password con `sudo`); opzioni
`--range`, `--ip`, `--tutte`, `--scanner`, `--prova-a-secco`.

**Windows XP** – `Avvia.bat` avvia la versione leggera (VBScript): chiede gli IP, ricava il modello
dalla pagina web della stampante e installa **solo dalla cache del kit**.

## Dove finiscono i log

```
C:\Users\<utente>\Downloads\Driver <Marca> <Modello>\
   ├─ log_<AAAA-MM-GG>_<NOMEPC>.txt
   ├─ <pacchetto driver ufficiale>          (copia per reinstallazioni future)
   ├─ scheda_scanner.txt                    (se configurata la scansione: contiene la password di "scanner")
   ├─ Collegamento Scansioni.lnk, crea_collegamento.bat
   └─ rubrica_backup_*.html, richiesta_ricetta_<modello>.json (se servono)
C:\Users\<utente>\Downloads\PrinterKit\sessione_<data>_<ora>.txt   (tutte le stampanti della sessione)
<chiavetta>\log\                                                   (copia, se logCopyToKit = true)
```

L'utente è quello che ha aperto la sessione (non l'amministratore usato per l'elevazione); su XP la
cartella è `%USERPROFILE%\Download`.

## Struttura

| Percorso | Contenuto |
|---|---|
| `Avvia.bat`, `Avvia.command` | lanciatori |
| `config.json` | URL di catalogo e ricette, community SNMP, valori predefiniti scanner |
| `catalogo/drivers.json` | catalogo driver unico (schema in `schema.json`) |
| `catalogo/pagine_ufficiali.json` | pagine ufficiali di download per marca/serie; riepilogo in `PAGINE_UFFICIALI.md` |
| `windows/PrinterKit.ps1` + `windows/modules/` | app Windows 7–11 (PowerShell 2.0 compatibile) |
| `windows/legacy-xp/` | versione leggera XP (VBScript) |
| `macos/` | app Mac (zsh + JavaScript for Automation) |
| `scanner-ricette/`, `nas-ricette/` | ricette per multifunzione e NAS |
| `manutenzione/`, `.github/workflows/` | manutenzione automatica del catalogo (GitHub Actions + Gemini) |
| `cache/` | driver verificati per uso offline/XP/7 (+ `indice-xp.txt`) |
| `tests/` | test Python (manutenzione) e Pester (moduli Windows), fixture |
| `docs/` | regole di verifica, test manuali, messa in funzione |

## Messa in funzione (una volta)

Vedi [docs/MESSA_IN_FUNZIONE.md](docs/MESSA_IN_FUNZIONE.md): creare il repository GitHub pubblico,
mettere `GEMINI_API_KEY` nei Secrets, sostituire `UTENTE/PrinterKit` in `config.json`, controllare
`catalogo/PAGINE_UFFICIALI.md`, lanciare il workflow **recupero-link** in modalità `popola` e approvare
la Pull Request con il catalogo iniziale.

## Stato del progetto

Vedi [docs/STATO.md](docs/STATO.md) per cosa è stato provato, cosa no e cosa manca.
