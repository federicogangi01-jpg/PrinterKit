# Regole di verifica di ufficialità

Un pacchetto viene installato solo se supera **tutti** i controlli. Altrimenti quella stampante si
ferma (le altre proseguono), il file viene cancellato e, se veniva dalla cache, la cache viene ripulita.

1. **Catalogo**: esiste un pacchetto con `status = ok` per marca + sistema + versione + architettura
   (+ modello). Nessun ripiego su driver generici Microsoft/Apple o di terze parti.
2. **Dominio**: l'URL è `https://` e l'host è uno degli `officialDomains` della marca (o un suo
   sottodominio). Il controllo si ripete sull'URL finale dopo i redirect. Una risposta `text/html` è
   rifiutata (link cambiato).
3. **SHA-256**: se il catalogo lo riporta, deve coincidere. Per i file in cache si confronta anche con
   `verificato.txt`, scritto solo dopo una verifica di firma riuscita.
4. **Firma digitale – Windows (Authenticode)**:
   - un pacchetto `.exe`/`.msi` deve avere firma `Valid` (catena integra e attendibile) con CN/O del
     certificato tra i `signerNames` della marca;
   - dopo l'estrazione, ogni `.exe`/`.msi` contenuto deve essere firmato dal produttore (o WHQL);
   - ogni catalogo `.cat` accanto agli INF del driver deve avere firma `Valid` del produttore **oppure**
     WHQL Microsoft (*Microsoft Windows Hardware Compatibility Publisher*, che firma i driver certificati
     inviati dal produttore). Con firma WHQL, il `Provider` dell'INF deve corrispondere alla regex
     `match` della marca;
   - senza `.cat` firmati il pacchetto è rifiutato.
5. **Firma digitale – macOS**: `pkgutil --check-signature` con stato *signed by a developer
   certificate issued by Apple* e certificato Developer ID che contiene uno dei `macSignerNames`.
   I `.dmg` si montano in sola lettura e si verifica il `.pkg` contenuto.
6. **Architettura**: si usano solo gli INF con `Class=Printer` che dichiarano modelli per
   l'architettura del PC (`NTamd64`, `NTx86`, `NTarm64`); le cartelle chiaramente dell'altra
   architettura sono scartate. Nel workflow di recupero, ogni architettura dichiarata deve avere INF.

Windows XP non può verificare Authenticode da VBScript: usa solo pacchetti della cache, che vi sono
entrati dopo la verifica completa fatta su un PC moderno (`-PrepareCache` o una normale installazione),
e ricontrolla lo SHA-256 (con .NET; se .NET manca, decide il tecnico con un avviso esplicito).

I `signerNames` e gli `officialDomains` iniziali in `drivers.json` sono da confermare al primo
popolamento: se un pacchetto ufficiale viene rifiutato per il nome del firmatario, l'Issue aperta dal
workflow riporta il nome esatto del certificato da aggiungere.
