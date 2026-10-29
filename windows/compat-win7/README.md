# Modalità compatibilità Windows 7

Windows 7 SP1 (x86/x64) usa **lo stesso motore** dell'app principale (`windows/PrinterKit.ps1`),
avviato da `Avvia.bat` con l'opzione `-Compat`. Tutti i moduli in `windows/modules/` sono scritti
in modo compatibile con PowerShell 2.0, quindi non serve una copia separata del codice.

Differenze rispetto all'app principale:

| Funzione | Windows 8.1/10/11 | Windows 7 (compatibilità) |
|---|---|---|
| Lettura JSON | `JavaScriptSerializer` | `JavaScriptSerializer` (.NET 3.5) |
| Porta di stampa | `Add-PrinterPort` | WMI `Win32_TCPIPPrinterPort` (equivalente a `prnport.vbs`) |
| Driver nel driver store | `pnputil /add-driver … /install` | `pnputil -a` |
| Installazione driver | `Add-PrinterDriver` | `printui.dll /ia /m … /f …` |
| Coda di stampa | `Add-Printer` | WMI `Win32_Printer` |
| Estrazione zip | `System.IO.Compression` | `Shell.Application` |
| Condivisione scanner | `New-SmbShare` | `net share … /GRANT:` |
| Download | TLS 1.2 | TLS 1.2 se presente (KB3140245 + .NET aggiornato), altrimenti **solo cache del kit** |

Se il PC non riesce a collegarsi in TLS 1.2, l'app lo dice e usa la cache del kit (`cache/`):
prepara la chiavetta installando una volta la stessa stampante da un PC Windows 10/11, così il
pacchetto verificato viene copiato nella cache.

Avvio manuale:

```
powershell -ExecutionPolicy Bypass -File windows\PrinterKit.ps1 -Compat
```
