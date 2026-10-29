# Come aggiungere una pagina driver (marca o serie nuova)

1. Su GitHub apri `catalogo/pagine_ufficiali.json` e premi la matita (Modifica).
2. Dentro l'elenco `"pagine": [ … ]` aggiungi una voce copiando questo modello
   (attenzione alla virgola tra una voce e l'altra):

```json
{
  "manufacturer": "kyocera",
  "scope": "serie",
  "series": "ECOSYS MA",
  "os": ["windows-10", "windows-11"],
  "arch": ["x64"],
  "pageUrl": "https://www.kyoceradocumentsolutions.eu/…",
  "needsBrowser": true,
  "notes": "selezionare il modello dall'elenco",
  "stato": "da_verificare",
  "verificatoIl": null
}
```

Campi:

| Campo | Valori |
|---|---|
| `manufacturer` | id della marca come in `drivers.json`: `hp`, `canon`, `kyocera`, `ricoh`, `xerox`, `brother`, `epson`, `konicaminolta`, `lexmark`, `sharp`, `toshiba`, `oki`, `samsung` |
| `scope` | `universale`, `serie` o `modello` |
| `series` | nome della serie (es. `HL-L`), oppure `null` |
| `os` | uno o più tra `windows-11`, `windows-10`, `windows-8.1`, `windows-7`, `windows-xp`, `macos` |
| `arch` | uno o più tra `x86`, `x64`, `arm64` (Windows) e `intel`, `applesilicon` (Mac) |
| `pageUrl` | indirizzo della pagina **ufficiale** del produttore (solo `https://`) |
| `needsBrowser` | `true` se la pagina mostra i driver solo dopo il caricamento (JavaScript) |
| `stato` | lascia `da_verificare`: lo aggiorna l'automazione |

3. Premi **Commit changes**. Entro pochi minuti:
   - lo schema viene controllato;
   - il workflow "recupero-link" legge solo la voce nuova;
   - arriva una **Pull Request** con i pacchetti trovati e verificati, oppure una **Issue** se qualcosa non torna.

Regole: solo siti del produttore, mai siti di terze parti o archivi di driver.
Il dominio della pagina deve essere tra gli `officialDomains` della marca in `drivers.json`.
