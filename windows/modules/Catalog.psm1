# Catalogo driver: lettura, validazione, scelta del pacchetto, verifica dei link (§5, §7.3).
# Compatibile con PowerShell 2.0: il JSON si legge con JavaScriptSerializer (niente ConvertFrom-Json).

$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36'

function ConvertFrom-PKJson {
    param([string]$Text)
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 67108864
    return $ser.DeserializeObject($Text)
}

function ConvertTo-PKJson {
    param([object]$Object)
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 67108864
    return $ser.Serialize($Object)
}

function Read-PKJsonFile {
    param([string]$Path)
    return ConvertFrom-PKJson ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
}

function Get-PKField {
    # Lettura sicura di un campo da un Dictionary del serializer.
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.ContainsKey($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Enable-PKTls12 {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }
}

function New-PKWebClient {
    Enable-PKTls12
    $wc = New-Object Net.WebClient
    $wc.Headers.Add('User-Agent', $script:UserAgent)
    $wc.Encoding = [Text.Encoding]::UTF8
    return $wc
}

# ---------- Validazione ----------

function Test-PKCatalog {
    # Stesse regole essenziali di catalogo/schema.json. Restituisce l'elenco degli errori.
    param([object]$Catalog)
    $err = New-Object System.Collections.ArrayList
    if ($null -eq $Catalog -or -not ($Catalog -is [Collections.IDictionary])) { [void]$err.Add('il catalogo non è un oggetto JSON'); return ,($err.ToArray()) }
    if ((Get-PKField $Catalog 'schemaVersion') -ne 1) { [void]$err.Add('schemaVersion diverso da 1') }
    $mans = @(Get-PKField $Catalog 'manufacturers' @())
    if ($mans.Count -eq 0) { [void]$err.Add('elenco manufacturers mancante'); return ,($err.ToArray()) }
    $okOs = @('windows', 'macos'); $okStatus = @('ok', 'link_rotto', 'da_verificare', 'nessun_driver')
    foreach ($m in $mans) {
        foreach ($f in @('id', 'name', 'match', 'officialDomains', 'signerNames', 'packages')) {
            if ($null -eq (Get-PKField $m $f)) { [void]$err.Add("marca senza campo '$f'") }
        }
        try { [void](New-Object Text.RegularExpressions.Regex((Get-PKField $m 'match' 'x'))) } catch { [void]$err.Add("regex match non valida per $(Get-PKField $m 'id')") }
        foreach ($p in @(Get-PKField $m 'packages' @())) {
            $pkgId = Get-PKField $p 'id' '?'
            foreach ($f in @('id', 'driverFamily', 'os', 'osMin', 'arch', 'models', 'sourcePage', 'fileType', 'status')) {
                if ($null -eq (Get-PKField $p $f)) { [void]$err.Add("pacchetto $pkgId senza campo '$f'") }
            }
            if ($okOs -notcontains (Get-PKField $p 'os')) { [void]$err.Add("pacchetto ${pkgId}: os non valido") }
            if ($okStatus -notcontains (Get-PKField $p 'status')) { [void]$err.Add("pacchetto ${pkgId}: status non valido") }
            $url = Get-PKField $p 'url'
            if ((Get-PKField $p 'status') -eq 'ok' -and -not $url) { [void]$err.Add("pacchetto ${pkgId}: status ok senza url") }
            if ($url -and -not (Test-PKOfficialDomain $url (Get-PKField $m 'officialDomains' @()))) { [void]$err.Add("pacchetto ${pkgId}: url fuori dai domini ufficiali") }
        }
    }
    return ,($err.ToArray())
}

function Get-PKCatalog {
    # Prima il catalogo su GitHub, poi la copia locale del kit. Mai un catalogo non valido.
    param([string]$RemoteUrl, [string]$LocalPath, [switch]$Offline)
    $local = $null; $remote = $null; $note = ''
    if ($RemoteUrl -and -not $Offline) {
        try {
            $wc = New-PKWebClient
            $text = $wc.DownloadString($RemoteUrl)
            $remote = ConvertFrom-PKJson $text
            $errs = Test-PKCatalog $remote
            if ($errs.Length -gt 0) {
                $note = 'Catalogo online non valido (' + $errs[0] + '): uso la copia locale.'
                $remote = $null
            } else {
                # Aggiorna la copia locale del kit, così XP/7 e l'uso offline restano aggiornati.
                try { [IO.File]::WriteAllText($LocalPath, $text, (New-Object Text.UTF8Encoding($false))) } catch { }
                return New-Object PSObject -Property @{ Data = $remote; Source = 'online'; Note = '' ; UpdatedAt = (Get-PKField $remote 'updatedAt') }
            }
        } catch {
            $note = 'Catalogo online non raggiungibile (' + $_.Exception.Message + '): uso la copia locale.'
        }
    }
    if (-not (Test-Path -LiteralPath $LocalPath)) { throw "Copia locale del catalogo assente: $LocalPath" }
    $local = Read-PKJsonFile $LocalPath
    $errs = Test-PKCatalog $local
    if ($errs.Length -gt 0) { throw ('Anche la copia locale del catalogo non è valida: ' + $errs[0]) }
    return New-Object PSObject -Property @{ Data = $local; Source = 'locale'; Note = $note; UpdatedAt = (Get-PKField $local 'updatedAt') }
}

# ---------- Domini e versioni ----------

function Test-PKOfficialDomain {
    param([string]$Url, [object[]]$Domains)
    try { $u = New-Object Uri($Url) } catch { return $false }
    if ($u.Scheme -ne 'https') { return $false }
    $h = $u.Host.ToLower().TrimEnd('.')
    foreach ($d in $Domains) {
        $d = "$d".ToLower().Trim('.')
        if ($h -eq $d -or $h.EndsWith('.' + $d)) { return $true }
    }
    return $false
}

function Compare-PKVersion {
    # -1, 0, 1. Le parti non numeriche ("x.y.z") valgono 0.
    param([string]$A, [string]$B)
    $pa = @("$A" -split '[^0-9]+' | Where-Object { $_ -ne '' })
    $pb = @("$B" -split '[^0-9]+' | Where-Object { $_ -ne '' })
    $n = [math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { $x = [int64]$pa[$i] }
        if ($i -lt $pb.Count) { $y = [int64]$pb[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

# ---------- Marca e pacchetto ----------

function Find-PKManufacturer {
    # Prima voce del catalogo la cui regex 'match' corrisponde a modello + descrizione.
    param([object]$Catalog, [string]$Model, [string]$Description)
    $text = ("$Model $Description").Trim()
    if (-not $text) { return $null }
    foreach ($m in (Get-PKField $Catalog 'manufacturers' @())) {
        $rx = New-Object Text.RegularExpressions.Regex((Get-PKField $m 'match'), 'IgnoreCase')
        if ($rx.IsMatch($text)) { return $m }
    }
    return $null
}

function Test-PKPackageForSystem {
    param([object]$Package, [object]$System)
    if ((Get-PKField $Package 'os') -ne $System.Family) { return $false }
    if ((Compare-PKVersion $System.Version (Get-PKField $Package 'osMin' '0')) -lt 0) { return $false }
    $max = Get-PKField $Package 'osMax'
    if ($max -and (Compare-PKVersion $System.Version $max) -gt 0) { return $false }
    $bmin = Get-PKField $Package 'buildMin'
    if ($bmin -and $System.Build -lt [int]$bmin) { return $false }
    $bmax = Get-PKField $Package 'buildMax'
    if ($bmax -and $System.Build -gt [int]$bmax) { return $false }
    $arch = @(Get-PKField $Package 'arch' @())
    if ($arch -notcontains $System.Arch) { return $false }
    return $true
}

function Test-PKPackageForModel {
    param([object]$Package, [string]$Model)
    $models = Get-PKField $Package 'models' '*'
    if ($models -eq '*') { return $true }
    if (-not $Model) { return $false }
    try { return (New-Object Text.RegularExpressions.Regex($models, 'IgnoreCase')).IsMatch($Model) } catch { return $false }
}

function Select-PKDriverPackage {
    # Filtra per sistema, versione, architettura, stato e modelli. Nessun ripiego generico.
    # Ordine: specifico per modello > universale; poi linguaggio preferito; poi versione più recente.
    param([object]$Manufacturer, [object]$System, [string]$Model, [string[]]$Languages = @(), [string]$PreferLanguage = '')
    $why = ''
    $all = @(Get-PKField $Manufacturer 'packages' @())
    $forSystem = @($all | Where-Object { Test-PKPackageForSystem $_ $System })
    $noDriver = @($forSystem | Where-Object { (Get-PKField $_ 'status') -eq 'nessun_driver' -and (Test-PKPackageForModel $_ $Model) })
    $candidates = @($forSystem | Where-Object { (Get-PKField $_ 'status') -eq 'ok' -and (Test-PKPackageForModel $_ $Model) })
    if (-not $PreferLanguage) { if ($System.Family -eq 'macos') { $PreferLanguage = 'ps' } else { $PreferLanguage = 'pcl6' } }
    # Se si conoscono i linguaggi della stampante, si scartano i driver per linguaggi che non ha.
    if ($Languages -and $Languages.Count -gt 0) {
        $compatible = @($candidates | Where-Object {
            $lang = Get-PKField $_ 'language'
            (-not $lang) -or ($lang -eq 'altro') -or ($lang -eq 'gdi') -or ($Languages -contains $lang) -or ($lang -eq 'pcl6' -and $Languages -contains 'pcl5')
        })
        if ($compatible.Count -gt 0) { $candidates = $compatible }
    }
    if ($candidates.Count -eq 0) {
        $name = Get-PKField $Manufacturer 'name'
        $sysText = $System.Name
        if ($System.Arch) { $sysText += ' ' + @{ x64 = '64 bit'; x86 = '32 bit'; arm64 = 'ARM64'; intel = 'Intel'; applesilicon = 'Apple Silicon' }[$System.Arch] }
        if ($noDriver.Count -gt 0) { $why = "Il produttore non offre un driver $name ufficiale per $sysText" }
        elseif (@($forSystem | Where-Object { (Get-PKField $_ 'status') -eq 'link_rotto' }).Count -gt 0) { $why = "Driver $name per $sysText con link non funzionante (in correzione sul catalogo)" }
        else { $why = "Nessun driver $name ufficiale per $sysText" }
        return New-Object PSObject -Property @{ Package = $null; Reason = $why }
    }
    $sorted = @($candidates | Sort-Object -Property `
        @{ Expression = { if ((Get-PKField $_ 'models' '*') -eq '*') { 1 } else { 0 } } }, `
        @{ Expression = { if ((Get-PKField $_ 'language') -eq $PreferLanguage) { 0 } else { 1 } } }, `
        @{ Expression = { ConvertTo-PKSortableVersion (Get-PKField $_ 'version' '0') }; Descending = $true })
    return New-Object PSObject -Property @{ Package = $sorted[0]; Reason = '' }
}

function ConvertTo-PKSortableVersion {
    # "8.4.1716" -> "000000008.000000004.000001716" (ordinabile come testo).
    param([string]$Version)
    $parts = @("$Version" -split '[^0-9]+' | Where-Object { $_ -ne '' })
    while ($parts.Count -lt 4) { $parts += '0' }
    return [string]::Join('.', [string[]]($parts | ForEach-Object { ([int64]$_).ToString('000000000') }))
}

# ---------- Verifica catalogo ----------

function Test-PKLink {
    param([string]$Url, [object[]]$Domains, [int]$TimeoutMs = 15000)
    Enable-PKTls12
    $r = New-Object PSObject -Property @{ Url = $Url; Ok = $false; Status = 0; FinalUrl = ''; Message = '' }
    if (-not (Test-PKOfficialDomain $Url $Domains)) { $r.Message = 'dominio non nella whitelist'; return $r }
    foreach ($method in @('HEAD', 'GET')) {
        try {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.Method = $method; $req.UserAgent = $script:UserAgent; $req.Timeout = $TimeoutMs
            $req.AllowAutoRedirect = $true
            if ($method -eq 'GET') { $req.AddRange(0, 0) }
            $resp = $req.GetResponse()
            $r.Status = [int]$resp.StatusCode; $r.FinalUrl = $resp.ResponseUri.AbsoluteUri
            $resp.Close()
            if (-not (Test-PKOfficialDomain $r.FinalUrl $Domains)) { $r.Message = 'il redirect porta fuori dai domini ufficiali: ' + $r.FinalUrl; return $r }
            $r.Ok = $true; $r.Message = 'raggiungibile'
            return $r
        } catch {
            $ex = $_.Exception
            while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
            if ($ex -and $ex.Response) { $r.Status = [int]$ex.Response.StatusCode }
            $r.Message = 'non raggiungibile: ' + $_.Exception.Message
        }
    }
    return $r
}

function Invoke-PKCatalogCheck {
    param([object]$Catalog, [scriptblock]$OnResult)
    $out = New-Object System.Collections.ArrayList
    foreach ($m in (Get-PKField $Catalog 'manufacturers' @())) {
        $domains = @(Get-PKField $m 'officialDomains' @())
        foreach ($p in @(Get-PKField $m 'packages' @())) {
            $url = Get-PKField $p 'url'
            if (-not $url) { continue }
            $res = Test-PKLink $url $domains
            $res | Add-Member NoteProperty Package (Get-PKField $p 'id')
            $res | Add-Member NoteProperty Manufacturer (Get-PKField $m 'name')
            [void]$out.Add($res)
            if ($OnResult) { & $OnResult $res }
        }
    }
    return ,($out.ToArray())
}

Export-ModuleMember -Function *-PK*
