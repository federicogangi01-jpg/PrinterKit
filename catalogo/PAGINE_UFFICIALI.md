# Pagine ufficiali di download driver

Generato da `manutenzione/genera_riepilogo.py`: non modificare a mano, modifica `pagine_ufficiali.json`.

Da far controllare al committente prima del primo avvio. Legenda: ✅ pagina aperta e confermata;
⚠️ non confermata (motivo nelle note); ⛔ il produttore non offre driver per quel sistema.

Totale: ⚠️ da verificare: 33, ⛔ nessun driver: 3, ✅ ok: 10

## HP

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11 | x64, arm64 | [link](https://support.hp.com/it-it/drivers/hp-universal-print-driver-series-for-windows/503548) (JavaScript) | ⚠️ da verificare | Raggiunta da https://www.hp.com/go/upd (redirect 301 ufficiale). Pagina dinamica: il download automatico è andato in timeout; scegliere 'PCL6' nell'elenco. |
| universale | windows-7 | x86, x64 | [link](https://support.hp.com/it-it/drivers/hp-universal-print-driver-series-for-windows/503548) (JavaScript) | ⚠️ da verificare | Le versioni UPD per Windows 7 sono nella sezione versioni precedenti della stessa pagina: da confermare. |
| universale | windows-xp | x86 | [link](https://support.hp.com/it-it/drivers/hp-universal-print-driver-series-for-windows/503548) (JavaScript) | ⚠️ da verificare | HP ha distribuito UPD 5.x per XP; non confermato che sia ancora scaricabile. Se assente → nessun_driver. |
| modello | macos | intel, applesilicon | [link](https://support.hp.com/it-it/drivers) (JavaScript) | ⚠️ da verificare | Per macOS HP pubblica pacchetti per modello (HP Easy Start / driver di stampa). AirPrint escluso dalle regole del kit. |

## Canon

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11, windows-7 | x86, x64 | [link](https://www.canon-europe.com/support/business-product-support/) (JavaScript) | ⚠️ da verificare | Generic Plus UFR II / PCL6 si scaricano dalla scheda 'Driver' della pagina del modello (es. imageRUNNER ADVANCE). Il sito canon.it ha risposto 403 all'accesso automatico. File su gdlp01.c-wss.com (CDN Canon). |
| universale | windows-xp | x86 | [link](https://www.canon-europe.com/support/business-product-support/) (JavaScript) | ⚠️ da verificare | Versioni Generic Plus per XP presenti solo per modelli vecchi: verificare per modello. |
| universale | macos | intel, applesilicon | [link](https://www.canon-europe.com/support/business-product-support/) (JavaScript) | ⚠️ da verificare | UFR II/UFRII LT Printer Driver & Utilities for Mac, per modello. |

## Kyocera

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11, windows-7 | x86, x64, arm64 | [link](https://www.kyoceradocumentsolutions.eu/en/support/downloads.html) (JavaScript) | ✅ ok | Pagina download Europa verificata; rimanda al 'User Support Page' globale (kyoceradocumentsolutions.com/support_product) dove si sceglie il modello. KX Driver universale v8.4 (Windows 10/11). |
| universale | windows-xp | x86 | [link](https://www.kyoceradocumentsolutions.eu/en/support/downloads.html) (JavaScript) | ⚠️ da verificare | KX 7.x supportava XP per i modelli vecchi; da confermare per modello. |
| universale | macos | intel, applesilicon | [link](https://www.kyoceradocumentsolutions.eu/en/support/downloads.html) (JavaScript) | ⚠️ da verificare | Kyocera OS X driver (pkg) per modello. |

## Ricoh

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11 | x86, x64 | [link](https://support.ricoh.com/bb/html/dr_ut_e/sav/model/mpc60/mpc60en.htm) | ✅ ok | Pagina verificata: 'PCL6 Driver for Universal Print' 4.46.0.0 (06/10/2026) per Windows 10/11 64 bit e Windows 10 32 bit; file su support.ricoh.com. Esiste anche la versione V4 su op-drv-ds1.support.ricoh.com. |
| universale | windows-7 | x86, x64 | [link](https://support.ricoh.com/bb/html/dr_ut_e/sav/model/mpc60/mpc60en.htm) | ⚠️ da verificare | La pagina verificata non elenca più Windows 7: cercare su pagine di modelli più vecchi o archivio Ricoh. |
| universale | windows-xp | x86 | [link](https://support.ricoh.com/bb/html/dr_ut_e/sav/model/mpc60/mpc60en.htm) | ⛔ nessun driver | Windows XP non elencato sulla pagina verificata. |
| universale | macos | intel, applesilicon | [link](https://support.ricoh.com/bb/html/dr_ut_e/sav/model/mpc60/mpc60en.htm) | ✅ ok | Pagina verificata: 'PPD Installer' 3.8.0.0 per macOS 13–26 (nessun driver PCL per Mac). |

## Xerox

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11 | x64, arm64 | [link](https://support.xerox.com/en-cy/content/157400) (JavaScript) | ✅ ok | Pagina verificata: Global Print Driver 5.1076.4.0 (23/06/2026), Windows 10/11 x64 e Windows 11 ARM64. Il pulsante Download si attiva solo dopo l'accettazione dei termini: il link diretto non è nel codice HTML. |
| universale | windows-7 | x86, x64 | [link](https://www.support.xerox.com/en-us/product/global-printer-driver/content/127244) (JavaScript) | ⚠️ da verificare | Pagina ufficiale per sistemi precedenti (Windows 7/8/8.1/Vista) segnalata dalla ricerca, non aperta. |
| universale | windows-xp | x86 | [link](https://www.support.xerox.com/en-us/product/global-printer-driver/content/127244) (JavaScript) | ⚠️ da verificare | XP non confermato. |
| modello | macos | intel, applesilicon | [link](https://www.support.xerox.com/it-it) (JavaScript) | ⚠️ da verificare | Per macOS Xerox pubblica il pacchetto per modello (es. VersaLink → Downloads). |

## Brother

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| serie – HL-L | windows-10, windows-11, windows-7 | x86, x64 | [link](https://support.brother.com/g/b/productsearch.aspx?c=it&lang=it) (JavaScript) | ⚠️ da verificare | Stampanti laser HL-L: cercare il modello e scaricare 'Driver della stampante' (non il pacchetto completo). L'accesso automatico alla pagina download ha dato errore: verificare dal browser. |
| serie – MFC-L | windows-10, windows-11, windows-7 | x86, x64 | [link](https://support.brother.com/g/b/productsearch.aspx?c=it&lang=it) (JavaScript) | ⚠️ da verificare | Multifunzione laser MFC-L: cercare il modello e scaricare 'Driver della stampante' (non il pacchetto completo). L'accesso automatico alla pagina download ha dato errore: verificare dal browser. |
| serie – DCP-L | windows-10, windows-11, windows-7 | x86, x64 | [link](https://support.brother.com/g/b/productsearch.aspx?c=it&lang=it) (JavaScript) | ⚠️ da verificare | Multifunzione laser DCP-L: cercare il modello e scaricare 'Driver della stampante' (non il pacchetto completo). L'accesso automatico alla pagina download ha dato errore: verificare dal browser. |
| serie – MFC-J | windows-10, windows-11, windows-7 | x86, x64 | [link](https://support.brother.com/g/b/productsearch.aspx?c=it&lang=it) (JavaScript) | ⚠️ da verificare | Inkjet MFC-J (ufficio): cercare il modello e scaricare 'Driver della stampante' (non il pacchetto completo). L'accesso automatico alla pagina download ha dato errore: verificare dal browser. |
| serie – HL-L/MFC-L/DCP-L | windows-xp | x86 | [link](https://support.brother.com/g/b/productsearch.aspx?c=it&lang=it) (JavaScript) | ⚠️ da verificare | XP disponibile solo per alcuni modelli più vecchi. |
| serie – HL-L/MFC-L/DCP-L | macos | intel, applesilicon | [link](https://support.brother.com/g/b/productsearch.aspx?c=it&lang=it) (JavaScript) | ⚠️ da verificare | Brother per macOS recenti pubblica spesso solo il pacchetto AirPrint (escluso): in quel caso nessun_driver per il modello. |

## Epson

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale – WorkForce Pro / WorkForce Enterprise / AM-C | windows-10, windows-11 | x64, x86 | [link](https://www.epson.it/it_IT/assistenza) (JavaScript) | ✅ ok | Pagina verificata: ricerca per modello. Per WorkForce Pro e AM-C esiste 'EPSON Universal Print Driver' (PCL), nella scheda download del modello. |
| serie – EcoTank / WorkForce | windows-10, windows-11, windows-7 | x86, x64 | [link](https://www.epson.it/it_IT/assistenza) (JavaScript) | ✅ ok | Driver per modello (ESC/P-R). |
| serie – tutte | windows-xp | x86 | [link](https://www.epson.it/it_IT/assistenza) (JavaScript) | ⚠️ da verificare | XP solo per modelli vecchi. |
| serie – tutte | macos | intel, applesilicon | [link](https://www.epson.it/it_IT/assistenza) (JavaScript) | ⚠️ da verificare | Driver Mac per modello; per WorkForce Pro anche il pacchetto PS3. |

## Konica Minolta

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11, windows-7 | x86, x64 | [link](https://www.konicaminolta.eu/eu-en/support/download-centre) (JavaScript) | ✅ ok | Pagina verificata (Download Centre). Selezione del modello dinamica; Universal Printer Driver (UPD) PCL6/PS e versione V4. Vale anche per Develop/ineo. |
| universale | windows-xp | x86 | [link](https://www.konicaminolta.eu/eu-en/support/download-centre) (JavaScript) | ⚠️ da verificare | UPD per XP solo versioni vecchie. |
| modello | macos | intel, applesilicon | [link](https://www.konicaminolta.eu/eu-en/support/download-centre) (JavaScript) | ⚠️ da verificare | Driver Mac per modello bizhub. |

## Lexmark

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11, windows-7 | x86, x64 | [link](https://www.lexmark.com/en_gb/support/universal-print-driver.html) | ✅ ok | Pagina verificata: UPD 'Complete drivers and software' e pacchetti PCL XL/PS3 (32/64 bit WHQL, Windows Vista o successivo) su downloads.lexmark.com. Per ARM64: 'Generic v4 XL' su support.lexmark.com. |
| universale | windows-xp | x86 | [link](https://www.lexmark.com/en_gb/support/universal-print-driver.html) | ⛔ nessun driver | La UPD attuale richiede Vista o successivo. |
| universale | macos | intel, applesilicon | [link](https://www.lexmark.com/en_gb/support/universal-print-driver.html) | ✅ ok | Pagina verificata: pacchetti DMG colore e mono (Intel e ARM) su downloads.lexmark.com. |

## Sharp

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11, windows-7 | x86, x64 | [link](https://www.sharp.eu/download-centre) (JavaScript) | ✅ ok | Pagina verificata: elenco dei Download Centre per paese su SharpONE; per l'Italia scegliere 'Italy' e filtrare per modello. Driver PCL6/PS e 'SHARP UD3' universale. |
| universale | windows-xp | x86 | [link](https://www.sharp.eu/download-centre) (JavaScript) | ⚠️ da verificare | XP solo per modelli MX vecchi. |
| modello | macos | intel, applesilicon | [link](https://www.sharp.eu/download-centre) (JavaScript) | ⚠️ da verificare | Driver PPD/Mac per modello; PostScript solo con kit PS installato su alcuni modelli. |

## Toshiba

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11, windows-7 | x86, x64 | [link](https://www.toshibatec.eu/support/drivers/) (JavaScript) | ⚠️ da verificare | Driver 'TOSHIBA Universal Printer 2'. L'accesso automatico è fallito per un errore di certificato TLS del sito: verificare dal browser. |
| universale | windows-xp | x86 | [link](https://www.toshibatec.eu/support/drivers/) (JavaScript) | ⚠️ da verificare | Non confermato. |
| modello | macos | intel, applesilicon | [link](https://www.toshibatec.eu/support/drivers/) (JavaScript) | ⚠️ da verificare | Non confermato. |

## OKI

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11, windows-7 | x86, x64 | [link](https://www.oki.com/it/printing/support/drivers-and-utilities/) (JavaScript) | ⚠️ da verificare | Driver 'Universal PCL6' 1.1.3 elencato nelle pagine dei modelli (es. /it/printing/support/drivers-and-utilities/mono/45762042/). Il sito ha risposto 403 all'accesso automatico: lo script dovrà usare il browser headless. |
| universale | windows-xp | x86 | [link](https://www.oki.com/it/printing/support/drivers-and-utilities/) (JavaScript) | ⛔ nessun driver | OKI dichiara di non garantire più XP. |
| modello | macos | intel, applesilicon | [link](https://www.oki.com/it/printing/support/drivers-and-utilities/) (JavaScript) | ⚠️ da verificare | Driver Mac per modello. |

## Samsung (driver HP)

| Ambito | Sistemi | Arch. | Pagina | Stato | Note |
|---|---|---|---|---|---|
| universale | windows-10, windows-11, windows-7 | x86, x64 | [link](https://support.hp.com/it-it/drivers) (JavaScript) | ⚠️ da verificare | Samsung ha ceduto le stampanti a HP: driver 'Samsung Universal Print Driver 3' distribuito su support.hp.com (cercare il modello Samsung). |
| universale | windows-xp | x86 | [link](https://support.hp.com/it-it/drivers) (JavaScript) | ⚠️ da verificare | Solo per modelli vecchi, da confermare. |
| universale | macos | intel, applesilicon | [link](https://support.hp.com/it-it/drivers) (JavaScript) | ⚠️ da verificare | Samsung UPD per Mac su support.hp.com, da confermare. |
