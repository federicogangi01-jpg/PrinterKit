# Test manuali

Per ogni sistema: prima `-WhatIf` (o "Solo prova"), poi installazione reale. Annotare esito e log.

| # | Sistema | Passi | Atteso |
|---|---|---|---|
| 1 | Windows 11 x64 | Avvia.bat → Scansiona → seleziona una stampante di marca a catalogo → Installa con pagina di prova | Dalla scansione alla pagina di prova senza interventi; `Downloads\Driver …\log_….txt` completo |
| 2 | Windows 11 x64 | Stampante già installata con lo stesso IP | Riga grigia "Già installata", deselezionata, nulla modificato |
| 3 | Windows 11 ARM64 | Marca senza pacchetto ARM64 | "Nessun driver … ufficiale per Windows ARM64", nessuna installazione |
| 4 | Windows 10 x64 | `-NoGui -IP <ip1>,<ip2> -InstallAll -TestPage` | Due log di intervento, codice di uscita 0 |
| 5 | Windows 10 x64 | Scanner: Questo PC, utenti "Mario, Contabilità" su Kyocera/Sharp | `C:\Scansioni\…`, utente `scanner` nascosto, voci di rubrica, scansione di prova verificata |
| 6 | Windows 10 x64 | Scanner verso Synology / QNAP / Windows Server | Condivisione e utente creati sul dispositivo |
| 7 | Windows 7 x64 senza KB3140245 | Avvia.bat | Modalità compatibilità, avviso TLS 1.2, installazione dalla cache |
| 8 | Windows XP x86 | Avvia.bat con cache preparata | Versione leggera; log in `%USERPROFILE%\Download` |
| 9 | macOS Apple Silicon | Avvia.command | Firma pkgutil verificata, coda lpadmin, pagina di prova |
| 10 | macOS Intel | `Avvia.command --ip <ip> --tutte` | Come sopra |
| 11 | Qualsiasi | Pacchetto manomesso in cache (byte cambiato) | SHA-256 diverso → scartato, cache ripulita |
| 12 | Qualsiasi | Modello non a catalogo | "Modello non presente nel catalogo" + pulsante "Segnala su GitHub" |
