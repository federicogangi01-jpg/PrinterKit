# Download, verifica di ufficialità, estrazione e installazione del driver (§2, §7.4).
# Compatibile con PowerShell 2.0.

$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'
# Firmatario dei cataloghi .cat certificati WHQL: Microsoft firma il pacchetto inviato dal produttore.
$script:WhqlSigners = @('Microsoft Windows Hardware Compatibility Publisher', 'Microsoft Windows Third Party Component CA')

function Get-PKFieldValue {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($Object -is [Collections.IDictionary]) { if ($Object.ContainsKey($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }; return $Default }
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $v = $Object.PSObject.Properties[$Name].Value; if ($null -ne $v) { return $v } }
    return $Default
}

function Get-PKFileSha256 {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { $hash = $sha.ComputeHash($fs) } finally { $fs.Close() }
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLower()
}

function Test-PKDomainList {
    param([string]$Url, [object[]]$Domains)
    try { $u = New-Object Uri($Url) } catch { return $false }
    if ($u.Scheme -ne 'https') { return $false }
    $h = $u.Host.ToLower()
    foreach ($d in $Domains) { $d = "$d".ToLower(); if ($h -eq $d -or $h.EndsWith('.' + $d)) { return $true } }
    return $false
}

# ---------- Firma digitale ----------

function Test-PKSignerName {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate, [object[]]$Names)
    if (-not $Certificate) { return $false }
    $subject = $Certificate.Subject
    foreach ($n in $Names) {
        $n = "$n"
        # Confronto su CN e O del certificato, senza distinzione di maiuscole.
        if ($subject -match ('(^|,\s*)(CN|O)="?' + [regex]::Escape($n) + '"?(,|$)')) { return $true }
        if ($subject.ToLower().Contains(('cn=' + $n).ToLower()) -or $subject.ToLower().Contains(('o=' + $n).ToLower())) { return $true }
    }
    return $false
}

function Get-PKSignerDisplay {
    param($Certificate)
    if (-not $Certificate) { return '' }
    if ($Certificate.Subject -match 'CN="?([^",]+)') { return $matches[1] }
    return $Certificate.Subject
}

function Test-PKFileSignature {
    # Authenticode: stato Valid (catena integra e attendibile) e firmatario tra quelli ammessi.
    param([string]$Path, [object[]]$SignerNames, [switch]$AllowWhql)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $cert = $sig.SignerCertificate
    $r = New-Object PSObject -Property @{ Path = $Path; Valid = $false; Signer = (Get-PKSignerDisplay $cert); Whql = $false; Message = '' }
    if ($sig.Status -ne 'Valid') { $r.Message = 'firma ' + $sig.Status + ': ' + $sig.StatusMessage; return $r }
    if (Test-PKSignerName $cert $SignerNames) { $r.Valid = $true; $r.Message = 'valida'; return $r }
    if ($AllowWhql -and (Test-PKSignerName $cert $script:WhqlSigners)) { $r.Valid = $true; $r.Whql = $true; $r.Message = 'valida (WHQL Microsoft)'; return $r }
    $r.Message = 'firmatario non ammesso: ' + $r.Signer
    return $r
}

function Get-PKInfProvider {
    param([string]$InfPath)
    $inf = Read-PKInf $InfPath
    $prov = ''
    if ($inf.Sections.ContainsKey('version')) {
        foreach ($l in $inf.Sections['version']) { if ($l -match '^\s*Provider\s*=\s*(.+)$') { $prov = Resolve-PKInfString $matches[1] $inf.Strings } }
    }
    return $prov
}

function Test-PKPackageAuthenticity {
    # Regole (vedi docs/VERIFICA.md):
    #  - ogni .exe/.msi di primo livello deve essere firmato dal produttore;
    #  - ogni .cat dei driver deve avere firma valida del produttore o WHQL Microsoft;
    #  - con firma WHQL, il Provider dell'INF deve corrispondere alla marca (regex 'match').
    param([string]$PackageFile, [string]$ExtractedDir, [object]$Manufacturer, [string[]]$Infs)
    $signers = @(Get-PKFieldValue $Manufacturer 'signerNames' @())
    $match = Get-PKFieldValue $Manufacturer 'match' '.'
    $details = New-Object System.Collections.ArrayList
    $signerShown = ''
    $ext = [IO.Path]::GetExtension($PackageFile).ToLower()
    if ($ext -eq '.exe' -or $ext -eq '.msi') {
        $s = Test-PKFileSignature $PackageFile $signers
        [void]$details.Add(('{0}: {1}' -f [IO.Path]::GetFileName($PackageFile), $s.Message))
        if (-not $s.Valid) { return New-Object PSObject -Property @{ Ok = $false; Signer = $s.Signer; Message = 'pacchetto non firmato dal produttore (' + $s.Message + ')'; Details = $details } }
        $signerShown = $s.Signer
    }
    if ($ExtractedDir -and (Test-Path -LiteralPath $ExtractedDir)) {
        foreach ($exe in @(Get-ChildItem -LiteralPath $ExtractedDir -Include '*.exe', '*.msi' -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Select-Object -First 20)) {
            $s = Test-PKFileSignature $exe.FullName $signers -AllowWhql
            if (-not $s.Valid) { return New-Object PSObject -Property @{ Ok = $false; Signer = $s.Signer; Message = ('file non firmato dal produttore: {0} ({1})' -f $exe.Name, $s.Message); Details = $details } }
        }
        $infDirs = @{}
        foreach ($i in $Infs) { $infDirs[(Split-Path $i -Parent).ToLower()] = $i }
        $cats = @(Get-ChildItem -LiteralPath $ExtractedDir -Filter '*.cat' -Recurse -ErrorAction SilentlyContinue | Where-Object { $infDirs.ContainsKey($_.DirectoryName.ToLower()) })
        if ($cats.Count -eq 0) { return New-Object PSObject -Property @{ Ok = $false; Signer = ''; Message = 'nessun catalogo firmato (.cat) accanto agli INF del driver'; Details = $details } }
        foreach ($c in $cats) {
            $s = Test-PKFileSignature $c.FullName $signers -AllowWhql
            [void]$details.Add(('{0}: {1} ({2})' -f $c.Name, $s.Message, $s.Signer))
            if (-not $s.Valid) { return New-Object PSObject -Property @{ Ok = $false; Signer = $s.Signer; Message = ('catalogo {0} non valido: {1}' -f $c.Name, $s.Message); Details = $details } }
            if ($s.Whql) {
                $inf = $infDirs[$c.DirectoryName.ToLower()]
                $prov = Get-PKInfProvider $inf
                if (-not ($prov -match $match)) { return New-Object PSObject -Property @{ Ok = $false; Signer = $s.Signer; Message = ('INF con Provider "{0}" non riconducibile al produttore' -f $prov); Details = $details } }
            } elseif (-not $signerShown) { $signerShown = $s.Signer }
            if (-not $signerShown) { $signerShown = $s.Signer + ' (WHQL, provider ' + (Get-PKInfProvider $infDirs[$c.DirectoryName.ToLower()]) + ')' }
        }
    }
    return New-Object PSObject -Property @{ Ok = $true; Signer = $signerShown; Message = 'valida'; Details = $details }
}

# ---------- Download e cache ----------

function Get-PKCacheDir {
    param([string]$KitRoot, [string]$ManufacturerId, [string]$PackageId)
    return (Join-Path (Join-Path (Join-Path $KitRoot 'cache') $ManufacturerId) $PackageId)
}

function Invoke-PKDownload {
    # Download in streaming: controlla anche il dominio finale dopo eventuali redirect.
    param([string]$Url, [string]$Destination, [object[]]$Domains)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = $script:UserAgent; $req.Timeout = 60000; $req.ReadWriteTimeout = 120000; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    try {
        $final = $resp.ResponseUri.AbsoluteUri
        if (-not (Test-PKDomainList $final $Domains)) { throw ('il download è stato reindirizzato fuori dai domini ufficiali: ' + $final) }
        $ctype = "$($resp.ContentType)".ToLower()
        if ($ctype.StartsWith('text/html')) { throw 'il server ha restituito una pagina web invece del file (link probabilmente cambiato)' }
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($Destination)
        try {
            $buf = New-Object byte[] 65536
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n) }
        } finally { $out.Close(); $in.Close() }
        return $final
    } finally { $resp.Close() }
}

function Get-PKDriverPackageFile {
    # Prima la cache del kit (verificata via sha256), poi l'URL del catalogo. Un nuovo tentativo in caso di errore.
    param([object]$Manufacturer, [object]$Package, [string]$KitRoot, [string]$WorkDir, [object]$System)
    $mid = Get-PKFieldValue $Manufacturer 'id'; $pkid = Get-PKFieldValue $Package 'id'
    $domains = @(Get-PKFieldValue $Manufacturer 'officialDomains' @())
    $url = Get-PKFieldValue $Package 'url'
    $expected = "$(Get-PKFieldValue $Package 'sha256' '')".ToLower()
    $fileName = 'pacchetto.' + (Get-PKFieldValue $Package 'fileType' 'zip')
    if ($url) { try { $n = [IO.Path]::GetFileName((New-Object Uri($url)).AbsolutePath); if ($n) { $fileName = $n } } catch { } }
    $cacheDir = Get-PKCacheDir $KitRoot $mid $pkid
    $cached = Join-Path $cacheDir $fileName
    if (Test-Path -LiteralPath $cached) {
        $h = Get-PKFileSha256 $cached
        $manifest = Join-Path $cacheDir 'verificato.txt'
        $manifestHash = ''
        if (Test-Path -LiteralPath $manifest) { foreach ($l in (Get-Content -LiteralPath $manifest)) { if ($l -match '^sha256=(\w+)') { $manifestHash = $matches[1].ToLower() } } }
        if (($expected -and $h -eq $expected) -or (-not $expected -and $manifestHash -and $h -eq $manifestHash)) {
            return New-Object PSObject -Property @{ Path = $cached; Source = 'cache del kit'; Url = $url; Sha256 = $h; FromCache = $true }
        }
        Write-PKLog ("Copia in cache di $pkid non corrispondente all'hash: viene ignorata") 'avviso'
    }
    if (-not $url) { throw 'il catalogo non riporta un link di download per questo pacchetto' }
    if (-not (Test-PKDomainList $url $domains)) { throw ('link fuori dai domini ufficiali: ' + $url) }
    if ($System -and $System.Tls12 -eq $false) {
        throw ("Il sito {0} non è raggiungibile da questo PC: protocollo TLS 1.2 non supportato. Usa la cache del kit (scarica il driver da un PC aggiornato) o aggiorna Windows 7 (KB3140245)." -f (Get-PKFieldValue $Manufacturer 'name'))
    }
    $dest = Join-Path $WorkDir $fileName
    $final = $null
    for ($try = 1; $try -le 2; $try++) {
        try { $final = Invoke-PKDownload -Url $url -Destination $dest -Domains $domains; break }
        catch {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
            if ($try -eq 2 -or $_.Exception.Message -match 'domini ufficiali|pagina web') { throw ('download non riuscito: ' + $_.Exception.Message) }
            Write-PKLog 'Download interrotto, nuovo tentativo...' 'avviso'
            Start-Sleep -Seconds 2
        }
    }
    $h = Get-PKFileSha256 $dest
    if ($expected -and $h -ne $expected) {
        Remove-Item -LiteralPath $dest -Force
        throw ('SHA-256 diverso da quello del catalogo (atteso {0}, ottenuto {1}): file scartato' -f $expected, $h)
    }
    return New-Object PSObject -Property @{ Path = $dest; Source = $final; Url = $url; Sha256 = $h; FromCache = $false }
}

function Save-PKToCache {
    # Solo pacchetti già verificati entrano nella cache (usata poi da XP e Windows 7).
    param([string]$File, [string]$KitRoot, [string]$ManufacturerId, [string]$PackageId, [string]$Sha256, [string]$Signer, [string]$Url)
    try {
        $dir = Get-PKCacheDir $KitRoot $ManufacturerId $PackageId
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $target = Join-Path $dir ([IO.Path]::GetFileName($File))
        if ($target -ne $File) { Copy-Item -LiteralPath $File -Destination $target -Force }
        $lines = @(('sha256=' + $Sha256), ('firma=' + $Signer), ('url=' + $Url), ('data=' + (Get-Date -Format 'yyyy-MM-dd HH:mm')), ('pc=' + $env:COMPUTERNAME))
        Set-Content -LiteralPath (Join-Path $dir 'verificato.txt') -Value $lines -Encoding ASCII
    } catch { Write-PKLog ('Impossibile copiare il driver nella cache del kit: ' + $_.Exception.Message) 'avviso' }
}

function Remove-PKFromCache {
    param([string]$KitRoot, [string]$ManufacturerId, [string]$PackageId)
    $dir = Get-PKCacheDir $KitRoot $ManufacturerId $PackageId
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------- Estrazione ----------

function Expand-PKDriverPackage {
    param([string]$File, [string]$Destination, [object]$Package, [string]$KitRoot)
    if (-not (Test-Path -LiteralPath $Destination)) { [void](New-Item -ItemType Directory -Path $Destination -Force) }
    $type = "$(Get-PKFieldValue $Package 'fileType' '')".ToLower()
    if (-not $type) { $type = [IO.Path]::GetExtension($File).TrimStart('.').ToLower() }
    $seven = Join-Path $KitRoot 'tools\7zip\7z.exe'
    switch ($type) {
        'zip' {
            $done = $false
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                [IO.Compression.ZipFile]::ExtractToDirectory($File, $Destination); $done = $true
            } catch { }
            if (-not $done) {
                # Windows 7 / .NET 3.5: estrazione con la shell di Windows.
                $shell = New-Object -ComObject Shell.Application
                $zip = $shell.NameSpace($File)
                if (-not $zip) { throw 'archivio zip non leggibile' }
                $shell.NameSpace($Destination).CopyHere($zip.Items(), 0x614)
            }
        }
        'cab' { & "$env:WINDIR\System32\expand.exe" -F:* $File $Destination | Out-Null }
        'inf' { Copy-Item -LiteralPath $File -Destination $Destination }
        'exe' {
            $xargs = Get-PKFieldValue $Package 'extractArgs'
            if ($xargs) {
                $a = $xargs.Replace('{dest}', $Destination)
                $p = Start-Process -FilePath $File -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
                if ($p.ExitCode -ne 0) { Write-PKLog ('Estrazione: codice di uscita ' + $p.ExitCode) 'avviso' }
            } elseif (Test-Path -LiteralPath $seven) {
                & $seven x -y ('-o' + $Destination) $File | Out-Null
            } else {
                throw 'pacchetto .exe senza extractArgs nel catalogo e 7-Zip assente nel kit (tools\7zip\7z.exe)'
            }
        }
        default { throw ('tipo di pacchetto non gestito su Windows: ' + $type) }
    }
    return $Destination
}

# ---------- INF ----------

function Read-PKInf {
    param([string]$Path)
    $sections = @{}; $strings = @{}
    $current = $null
    foreach ($raw in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $line = $raw
        # Rimuove i commenti ; fuori dalle virgolette.
        $inQ = $false; $cut = -1
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($ch -eq '"') { $inQ = -not $inQ }
            elseif ($ch -eq ';' -and -not $inQ) { $cut = $i; break }
        }
        if ($cut -ge 0) { $line = $line.Substring(0, $cut) }
        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line -match '^\[(.+)\]$') {
            $current = $matches[1].Trim().ToLower()
            if (-not $sections.ContainsKey($current)) { $sections[$current] = New-Object System.Collections.ArrayList }
            continue
        }
        if ($current) { [void]$sections[$current].Add($line) }
    }
    # [Strings] e [Strings.<lingua>]: la sezione generica ha priorità, le altre riempiono i vuoti.
    $stringSections = @($sections.Keys | Where-Object { $_ -eq 'strings' -or $_ -like 'strings.*' } | Sort-Object { if ($_ -eq 'strings') { 0 } else { 1 } })
    foreach ($s in $stringSections) {
        foreach ($l in $sections[$s]) {
            if ($l -match '^([^=]+?)\s*=\s*(.*)$') {
                $k = $matches[1].Trim().ToLower(); $v = $matches[2].Trim().Trim('"')
                if (-not $strings.ContainsKey($k)) { $strings[$k] = $v }
            }
        }
    }
    return @{ Sections = $sections; Strings = $strings }
}

function Resolve-PKInfString {
    param([string]$Text, [hashtable]$Strings)
    $t = $Text.Trim()
    $res = $t
    foreach ($m in [regex]::Matches($t, '%([^%]+)%')) {
        $k = $m.Groups[1].Value.ToLower()
        if ($Strings.ContainsKey($k)) { $res = $res.Replace($m.Value, $Strings[$k]) }
    }
    return $res.Trim().Trim('"')
}

function Test-PKPrinterInf {
    param([hashtable]$Inf)
    if (-not $Inf.Sections.ContainsKey('version')) { return $false }
    foreach ($l in $Inf.Sections['version']) {
        if ($l -match '^\s*Class\s*=\s*(.+)$' -and $matches[1].Trim().Trim('"') -ieq 'Printer') { return $true }
        if ($l -match '^\s*ClassGuid\s*=\s*\{?4D36E979-E325-11CE-BFC1-08002BE10318\}?' ) { return $true }
    }
    return $false
}

function Get-PKInfModelNames {
    # Nomi dei modelli dichiarati nell'INF per l'architettura richiesta, con i token %…% risolti.
    param([string]$Path, [string]$Arch = 'x64')
    $inf = Read-PKInf $Path
    $names = New-Object System.Collections.ArrayList
    if (-not (Test-PKPrinterInf $inf)) { return ,($names.ToArray()) }
    $decor = @{ x64 = 'ntamd64'; x86 = 'ntx86'; arm64 = 'ntarm64' }[$Arch]
    if (-not $inf.Sections.ContainsKey('manufacturer')) { return ,($names.ToArray()) }
    foreach ($l in $inf.Sections['manufacturer']) {
        if ($l -notmatch '=') { continue }
        $right = $l.Substring($l.IndexOf('=') + 1).Split(',') | ForEach-Object { $_.Trim() }
        $base = @($right)[0]
        $decorations = @($right | Select-Object -Skip 1)
        $sectionNames = @()
        if ($decorations.Count -eq 0) {
            if ($Arch -eq 'x86') { $sectionNames = @($base) }
        } else {
            foreach ($d in $decorations) {
                $dl = $d.ToLower()
                # NTamd64.10.0 e simili: conta solo la parte di architettura.
                if ($dl -eq $decor -or $dl.StartsWith($decor + '.')) { $sectionNames += ($base + '.' + $d) }
                if ($Arch -eq 'x86' -and ($dl -eq 'nt' -or $dl.StartsWith('nt.'))) { $sectionNames += ($base + '.' + $d) }
            }
            if ($Arch -eq 'x86' -and $sectionNames.Count -eq 0) { $sectionNames = @($base) }
        }
        foreach ($sn in $sectionNames) {
            $key = $sn.ToLower()
            if (-not $inf.Sections.ContainsKey($key)) { continue }
            foreach ($ml in $inf.Sections[$key]) {
                if ($ml -match '^(.+?)\s*=') {
                    $n = Resolve-PKInfString $matches[1] $inf.Strings
                    if ($n -and -not $names.Contains($n)) { [void]$names.Add($n) }
                }
            }
        }
    }
    return ,([string[]]$names.ToArray())
}

function Find-PKPrinterInfs {
    # INF con Class=Printer; scarta le cartelle chiaramente dell'altra architettura.
    param([string]$Directory, [string]$Arch = 'x64', [string]$InfHint)
    $all = @(Get-ChildItem -LiteralPath $Directory -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    $x86rx = '\\(x86|i386|32bit|32-bit|win32|w32|32)(\\|$)'
    $x64rx = '\\(x64|amd64|64bit|64-bit|win64|w64|64)(\\|$)'
    $armrx = '\\(arm64|arm)(\\|$)'
    $out = New-Object System.Collections.ArrayList
    foreach ($f in $all) {
        $rel = $f.DirectoryName.Substring($Directory.Length)
        $relL = $rel.ToLower() + '\'
        if ($Arch -eq 'x64' -and ($relL -match $x86rx -or $relL -match $armrx)) { continue }
        if ($Arch -eq 'x86' -and ($relL -match $x64rx -or $relL -match $armrx)) { continue }
        if ($Arch -eq 'arm64' -and ($relL -match $x86rx -or $relL -match $x64rx)) { continue }
        try { $inf = Read-PKInf $f.FullName } catch { continue }
        if (-not (Test-PKPrinterInf $inf)) { continue }
        if ((Get-PKInfModelNames $f.FullName $Arch).Length -eq 0) { continue }
        [void]$out.Add($f.FullName)
    }
    if ($InfHint) {
        $hint = $InfHint.Replace('/', '\').ToLower()
        $pref = @($out | Where-Object { $_.ToLower().EndsWith($hint) })
        if ($pref.Count -gt 0) { return ,([string[]](@($pref) + @($out | Where-Object { $pref -notcontains $_ }))) }
    }
    return ,([string[]]$out.ToArray())
}

function Get-PKModelCodes {
    # "KYOCERA ECOSYS M2540dn" -> M2540 ; "MX-3071" -> MX-3071, MX3071
    param([string]$Model)
    $codes = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches("$Model", '\b([A-Za-z]{1,4})[- ]?(\d{3,5})')) {
        $c1 = ($m.Groups[1].Value + $m.Groups[2].Value).ToUpper()
        $c2 = ($m.Groups[1].Value + '-' + $m.Groups[2].Value).ToUpper()
        foreach ($c in @($c1, $c2)) { if (-not $codes.Contains($c)) { [void]$codes.Add($c) } }
    }
    return ,([string[]]$codes.ToArray())
}

function Get-PKDriverNameCandidates {
    # Ordine: nome identico al modello > contiene il codice modello > PCL6 > Universal > altri.
    param([string[]]$Names, [string]$Model, [string]$PreferLanguage = 'pcl6')
    $codes = Get-PKModelCodes $Model
    $modelN = ("$Model" -replace '\s+', ' ').Trim().ToUpper()
    $scored = foreach ($n in $Names) {
        $u = $n.ToUpper()
        $uNoDash = $u.Replace('-', '').Replace(' ', '')
        $score = 50
        if ($modelN -and ($u -eq $modelN -or $modelN.EndsWith($u) -or $u.EndsWith($modelN))) { $score = 0 }
        else {
            foreach ($c in $codes) { if ($u.Contains($c) -or $uNoDash.Contains($c.Replace('-', ''))) { $score = 10; break } }
            if ($score -eq 50) {
                if ($PreferLanguage -eq 'ps' -and $u -match '\bPS\b|POSTSCRIPT|BR-SCRIPT|KPDL') { $score = 20 }
                elseif ($u -match 'PCL\s?6|PCL\s?XL|PCLXL') { $score = 20 }
                elseif ($u -match 'UNIVERSAL|GENERIC PLUS|\bUPD\b|\bGPD\b|\bKX\b') { $score = 30 }
            } elseif ($u -match 'PCL\s?6|PCLXL') { $score = 5 }
        }
        New-Object PSObject -Property @{ Name = $n; Score = $score }
    }
    return ,([string[]]@($scored | Sort-Object Score, Name | ForEach-Object { $_.Name }))
}

# ---------- Installazione ----------

function Get-PKWindowsArchName {
    param([string]$Arch)
    return @{ x64 = 'x64'; x86 = 'Intel'; arm64 = 'ARM64' }[$Arch]
}

function Get-PKInstalledDriverNames {
    $names = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-WmiObject Win32_PrinterDriver -ErrorAction SilentlyContinue)) {
        # Win32_PrinterDriver.Name = "Nome driver,3,Windows x64"
        $n = "$($d.Name)".Split(',')[0]
        if ($n -and -not $names.Contains($n)) { [void]$names.Add($n) }
    }
    return ,([string[]]$names.ToArray())
}

function Find-PKInstalledDriver {
    # Driver già installato che corrisponde al pacchetto (nome dal catalogo o dagli INF).
    param([string[]]$Candidates)
    $installed = Get-PKInstalledDriverNames
    foreach ($c in $Candidates) { foreach ($i in $installed) { if ($i -ieq $c) { return $i } } }
    return $null
}

function Install-PKDriverToStore {
    param([string]$InfPath, [object]$System, [switch]$WhatIf)
    $pnputil = Join-Path $env:WINDIR 'System32\pnputil.exe'
    if ($WhatIf) { Write-PKLog ('[prova] pnputil per ' + $InfPath); return $true }
    switch ($System.PnpUtil) {
        'new' { $out = & $pnputil /add-driver $InfPath /install 2>&1 }
        'old' { $out = & $pnputil -a $InfPath 2>&1 }
        default { return $false }   # XP: nessun pnputil, si usa direttamente printui
    }
    $code = $LASTEXITCODE
    # 0 = ok, 259 = già presente nel driver store, 3010 = riavvio consigliato.
    if ($code -eq 0 -or $code -eq 259 -or $code -eq 3010) { return $true }
    throw ('pnputil ha restituito {0}: {1}' -f $code, (($out | Out-String).Trim()))
}

function Add-PKPrinterDriver {
    # Prova i candidati in ordine finché uno viene installato.
    param([string[]]$Candidates, [string]$InfPath, [object]$System, [switch]$WhatIf)
    foreach ($name in $Candidates) {
        if ($WhatIf) { Write-PKLog ('[prova] installerei il driver "' + $name + '"'); return $name }
        try {
            if ($System.HasPrintMgmt -and $System.Mode -eq 'main') {
                Add-PrinterDriver -Name $name -ErrorAction Stop
            } else {
                $arch = Get-PKWindowsArchName $System.Arch
                $printui = Join-Path $env:WINDIR 'System32\rundll32.exe'
                $a = ('printui.dll,PrintUIEntry /ia /m "{0}" /h "{1}" /v "Type 3 - User Mode" /f "{2}" /q' -f $name, $arch, $InfPath)
                if ([version]$System.Version -lt [version]'6.0') { $a = ('printui.dll,PrintUIEntry /ia /m "{0}" /f "{1}" /q' -f $name, $InfPath) }
                $p = Start-Process -FilePath $printui -ArgumentList $a -Wait -PassThru
                Start-Sleep -Seconds 2
            }
            if (Find-PKInstalledDriver @($name)) { return $name }
        } catch {
            Write-PKLog ('Driver "{0}" non installato: {1}' -f $name, $_.Exception.Message) 'avviso'
        }
    }
    return $null
}

Export-ModuleMember -Function *-PK*
