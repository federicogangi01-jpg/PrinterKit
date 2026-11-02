<#
.SYNOPSIS
  PrinterKit - installazione stampanti di rete con soli driver ufficiali del produttore.
.DESCRIPTION
  Finestra grafica (predefinita) o riga di comando:
    PrinterKit.ps1 -NoGui -Range 192.168.1.1-254 -InstallAll [-TestPage] [-ScanFolder]
    PrinterKit.ps1 -NoGui -IP 192.168.1.50,192.168.1.51 -InstallAll
    PrinterKit.ps1 -VerifyCatalog
    PrinterKit.ps1 -PrepareCache [-CacheFor windows-xp,windows-7]
      scarica e verifica i driver per XP/7 e li mette nella cache della chiavetta.
  -WhatIf esegue tutto tranne le modifiche al sistema e scrive nel log cosa farebbe.
  Compatibile con PowerShell 2.0 (Windows 7) e 5.1 (Windows 8.1/10/11).
#>
param(
    [switch]$NoGui,
    [string]$Range,
    [string[]]$IP,
    [switch]$InstallAll,
    [switch]$TestPage,
    [switch]$SetDefault,
    [switch]$ScanFolder,
    [string[]]$ScanUsers,
    [switch]$VerifyCatalog,
    [switch]$PrepareCache,
    [string[]]$CacheFor = @('windows-xp', 'windows-7'),
    [switch]$Offline,
    [switch]$Compat,
    [switch]$WhatIf,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$ScriptPath = $MyInvocation.MyCommand.Path
$WinDir = Split-Path $ScriptPath -Parent
$KitRoot = Split-Path $WinDir -Parent

function Get-PKPassArgs {
    # Ricostruisce gli argomenti originali per rilanciare lo script (Sysnative o UAC).
    param([hashtable]$Bound)
    $pass = New-Object System.Collections.ArrayList
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { [void]$pass.Add("-$k") } }
        elseif ($v -is [Array]) { [void]$pass.Add("-$k"); [void]$pass.Add('"' + ([string]::Join(',', [string[]]$v)) + '"') }
        else { [void]$pass.Add("-$k"); [void]$pass.Add('"' + $v + '"') }
    }
    return [string]::Join(' ', [string[]]$pass.ToArray())
}

# ---------- Processo a 32 bit su Windows a 64 bit: rilancio da Sysnative ----------
if ([IntPtr]::Size -eq 4 -and $env:PROCESSOR_ARCHITEW6432) {
    $ps64 = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $ps64) {
        $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, (Get-PKPassArgs $PSBoundParameters)
        $p = Start-Process -FilePath $ps64 -ArgumentList $a -Wait -PassThru -NoNewWindow
        exit $p.ExitCode
    }
}

foreach ($m in @('Log', 'SystemInfo', 'Discovery', 'Catalog', 'DriverInstall', 'PrinterSetup', 'RecipeEngine', 'ScanToFolder')) {
    Import-Module (Join-Path $WinDir "modules\$m.psm1") -Force -DisableNameChecking -Global
}

# ---------- Elevazione automatica (UAC) ----------
if (-not (Test-PKAdmin) -and -not $WhatIf) {
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1} -Elevated' -f $ScriptPath, (Get-PKPassArgs $PSBoundParameters)
    try { Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $a -Verb RunAs | Out-Null }
    catch { Write-Host 'Servono i diritti di amministratore: avvio annullato.' -ForegroundColor Red }
    exit
}

# ---------- Configurazione e stato ----------
$Config = Read-PKJsonFile (Join-Path $KitRoot 'config.json')
function Cfg([string]$k, $d) { $v = Get-PKField $Config $k $d; if ($null -eq $v) { return $d }; return $v }

$Sys = Get-PKSystemInfo
if ($Compat) { $Sys.Mode = 'compat' }
$SessionUser = Get-PKSessionUser
$Downloads = Get-PKDownloadsFolder -User $SessionUser -OsVersion $Sys.Version
$null = Start-PKSessionLog $Downloads
Write-PKLog ('Sistema: {0} - PowerShell {1} - modalità {2}' -f $Sys.LogLabel, $Sys.PSVersion, @{ main = 'principale'; compat = 'compatibilità' }[$Sys.Mode])
Write-PKLog ('Utente di sessione: {0} - cartella Download: {1}' -f $SessionUser.FullName, $Downloads)
if ($Sys.Tls12 -eq $false) { Write-PKLog 'TLS 1.2 non disponibile: i driver verranno presi solo dalla cache del kit (aggiornamento KB3140245 per Windows 7)' 'avviso' }
if ($WhatIf) { Write-PKLog 'MODALITÀ PROVA: nessuna modifica al sistema' 'avviso' }

$CatalogInfo = Get-PKCatalog -RemoteUrl (Cfg 'catalogSource' '') -LocalPath (Join-Path $KitRoot 'catalogo\drivers.json') -Offline:($Offline -or $Sys.Tls12 -eq $false)
$Catalog = $CatalogInfo.Data
if ($CatalogInfo.Note) { Write-PKLog $CatalogInfo.Note 'avviso' }
Write-PKLog ('Catalogo {0}, aggiornato il {1}' -f $CatalogInfo.Source, $CatalogInfo.UpdatedAt)
$Community = Cfg 'snmpCommunity' 'public'
$WorkRoot = Join-Path $env:TEMP ('PrinterKit_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
[void](New-Item -ItemType Directory -Path $WorkRoot -Force)

# ---------- Logica per stampante ----------

function New-PKRow {
    param([string]$IpAddr, [int[]]$Ports, [string]$Model, [string]$Descr, [string[]]$Langs)
    $row = New-Object PSObject -Property @{
        Selected = $false; IP = $IpAddr; Ports = $Ports; Model = $Model; Description = $Descr; Languages = $Langs
        Manufacturer = $null; Brand = ''; Package = $null; PackageText = ''; Reason = ''; QueueName = ''; Status = ''; Existing = @()
    }
    Update-PKRow $row
    return $row
}

function Update-PKRow {
    # Ricalcola marca e pacchetto (anche dopo la modifica a mano del modello).
    param([object]$Row)
    $Row.Manufacturer = Find-PKManufacturer $Catalog $Row.Model $Row.Description
    $Row.Package = $null; $Row.Reason = ''
    if ($Row.Manufacturer) {
        $Row.Brand = Get-PKField $Row.Manufacturer 'name'
        $sel = Select-PKDriverPackage -Manufacturer $Row.Manufacturer -System $Sys -Model $Row.Model -Languages $Row.Languages
        $Row.Package = $sel.Package; $Row.Reason = $sel.Reason
    } else {
        $Row.Brand = ''
        if ($Row.Model) { $Row.Reason = 'Modello non presente nel catalogo' } else { $Row.Reason = 'Modello sconosciuto: scrivilo nella colonna Modello' }
    }
    if ($Row.Package) {
        $v = Get-PKField $Row.Package 'version' ''
        $Row.PackageText = ('{0} {1} ({2})' -f (Get-PKField $Row.Package 'driverFamily'), $v, (Get-PKField $Row.Package 'id')).Replace('  ', ' ')
    } elseif ($Row.Manufacturer) { $Row.PackageText = 'Non disponibile per questo sistema' }
    else { $Row.PackageText = '-' }
    if (-not $Row.QueueName) {
        $brand = $Row.Brand; if ($brand -match '^Samsung') { $brand = 'Samsung' }
        $mod = $Row.Model
        if ($brand -and $mod.ToUpper().StartsWith($brand.ToUpper())) { $brand = '' }
        $Row.QueueName = ('{0} {1} ({2})' -f $brand, $mod, $Row.IP).Trim() -replace '\s+', ' '
        if (-not $mod) { $Row.QueueName = 'Stampante ' + $Row.IP }
    }
    $Row.Existing = Get-PKExistingPrinterByIP $Row.IP
    if ($Row.Existing.Length -gt 0) { $Row.Status = 'Già installata (' + $Row.Existing[0] + ')'; $Row.Selected = $false }
    elseif (-not $Row.Package) { $Row.Status = $Row.Reason; $Row.Selected = $false }
    else { $Row.Status = 'Pronta'; }
}

function Get-PKIssueUrl {
    param([object]$Row)
    $repo = Cfg 'githubRepo' ''
    if (-not $repo -or $repo -match '^UTENTE/') { return $null }
    $title = 'Modello non in catalogo: ' + $Row.Model
    $body = "Marca: $($Row.Brand)`nModello: $($Row.Model)`nDescrizione SNMP: $($Row.Description)`nSistema: $($Sys.LogLabel)`nIP: $($Row.IP)`n`n" +
            'Per aggiungerlo: inserire la pagina driver ufficiale in catalogo/pagine_ufficiali.json (vedi catalogo/MODELLO_VOCE.md).'
    return ('https://github.com/{0}/issues/new?title={1}&body={2}' -f $repo, [Uri]::EscapeDataString($title), [Uri]::EscapeDataString($body))
}

function Install-PKRow {
    # Installa una stampante. Ogni stampante è indipendente: gli errori non fermano le altre.
    param([object]$Row, [bool]$DoTestPage, [bool]$DoDefault)
    $date = Get-Date
    $folder = Join-Path $Downloads (Get-PKInterventionFolderName -Brand $Row.Brand -Model $Row.Model -IP $Row.IP)
    $data = @{
        Date = $date; Computer = $env:COMPUTERNAME; User = $SessionUser.Name; System = $Sys.LogLabel
        Printer = (("$($Row.Brand) $($Row.Model)").Trim()); IP = $Row.IP; Ports = ([string]::Join(', ', [string[]]($Row.Ports | ForEach-Object { "$_" })))
        Details = New-Object System.Collections.ArrayList; Changes = New-Object System.Collections.ArrayList; Result = 'ERRORE'
    }
    if (-not $data.Printer) { $data.Printer = 'sconosciuta' }
    try {
        if (-not $Row.Package) { throw $Row.Reason }
        $pkg = $Row.Package; $man = $Row.Manufacturer
        $pkgId = Get-PKField $pkg 'id'; $manId = Get-PKField $man 'id'
        $data.Driver = ('{0} {1} ({2})' -f (Get-PKField $pkg 'driverFamily'), (Get-PKField $pkg 'version' ''), $pkgId)
        Write-PKLog ("[{0}] Driver previsto: {1}" -f $Row.IP, $data.Driver)
        $work = Join-Path $WorkRoot ($pkgId + '_' + $Row.IP.Replace('.', '_'))
        [void](New-Item -ItemType Directory -Path $work -Force)

        # Driver già installato? Si riusa senza scaricare.
        $driverName = $null
        $catName = Get-PKField $pkg 'driverName' ''
        if ($catName) { $driverName = Find-PKInstalledDriver @($catName) }
        $src = $null
        if ($driverName) {
            Write-PKLog ("[{0}] Driver ""{1}"" già installato: lo riuso" -f $Row.IP, $driverName) 'ok'
            $data.Source = 'driver già presente nel sistema'; $data.Signature = 'non ricontrollata (già installato)'; $data.Sha256 = '-'
        } else {
            $src = Get-PKDriverPackageFile -Manufacturer $man -Package $pkg -KitRoot $KitRoot -WorkDir $work -System $Sys
            Write-PKLog ("[{0}] Pacchetto da {1}" -f $Row.IP, $src.Source)
            $ext = Join-Path $work 'estratto'
            [void](Expand-PKDriverPackage -File $src.Path -Destination $ext -Package $pkg -KitRoot $KitRoot)
            $infs = Find-PKPrinterInfs -Directory $ext -Arch $Sys.Arch -InfHint (Get-PKField $pkg 'infHint' '')
            if ($infs.Length -eq 0) { throw ("nel pacchetto non c'è un INF di stampante per {0}" -f $Sys.Arch) }
            $auth = Test-PKPackageAuthenticity -PackageFile $src.Path -ExtractedDir $ext -Manufacturer $man -Infs $infs
            foreach ($d in $auth.Details) { [void]$data.Details.Add($d) }
            if (-not $auth.Ok) {
                Remove-Item -LiteralPath $src.Path -Force -ErrorAction SilentlyContinue
                if ($src.FromCache) { Remove-PKFromCache $KitRoot $manId $pkgId }
                throw ('verifica di ufficialità fallita: ' + $auth.Message + '. File scartato.')
            }
            $data.Source = $src.Url; $data.Signature = $auth.Signer + ' - valida'; $data.Sha256 = $src.Sha256
            Write-PKLog ("[{0}] Firma: {1} - valida" -f $Row.IP, $auth.Signer) 'ok'
            if (-not $src.FromCache -and -not $WhatIf) { Save-PKToCache -File $src.Path -KitRoot $KitRoot -ManufacturerId $manId -PackageId $pkgId -Sha256 $src.Sha256 -Signer $auth.Signer -Url $src.Url }
            if (-not $WhatIf) {
                if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
                Copy-Item -LiteralPath $src.Path -Destination $folder -Force
            }
            # Nome driver: dal catalogo, altrimenti dai modelli dichiarati negli INF.
            $installedFrom = $null
            foreach ($inf in $infs) {
                $names = Get-PKInfModelNames $inf $Sys.Arch
                $candidates = @()
                if ($catName) { $candidates = @($names | Where-Object { $_ -ieq $catName }) }
                if ($candidates.Count -eq 0) { $candidates = Get-PKDriverNameCandidates -Names $names -Model $Row.Model }
                if ($candidates.Count -eq 0) { continue }
                Install-PKDriverToStore -InfPath $inf -System $Sys -WhatIf:$WhatIf | Out-Null
                $driverName = Add-PKPrinterDriver -Candidates ([string[]]($candidates | Select-Object -First 8)) -InfPath $inf -System $Sys -WhatIf:$WhatIf
                if ($driverName) { $installedFrom = $inf; break }
            }
            if (-not $driverName) { throw 'nessun nome di driver del pacchetto è stato accettato da Windows' }
            [void]$data.Changes.Add(('driver "{0}" installato da {1}' -f $driverName, (Split-Path $installedFrom -Leaf)))
            Write-PKLog ("[{0}] Driver installato: {1}" -f $Row.IP, $driverName) 'ok'
        }
        $proto = Select-PKPortProtocol $Row.Ports
        $port = New-PKPrinterPort -IP $Row.IP -Protocol $proto -Community $Community -System $Sys -WhatIf:$WhatIf
        $data.Port = $port.Description
        if ($port.Created) { [void]$data.Changes.Add('porta ' + $port.Description + ' creata') }
        $queue = New-PKPrinterQueue -Name $Row.QueueName -DriverName $driverName -Port $port -System $Sys -WhatIf:$WhatIf
        $data.Queue = $queue
        $isDefault = $false
        if ($DoDefault) { $isDefault = Set-PKDefaultPrinter $queue -WhatIf:$WhatIf }
        $data.Default = @{ $true = 'sì'; $false = 'no' }[[bool]$isDefault]
        if ($DoTestPage) { $data.TestPage = Send-PKTestPage $queue -WhatIf:$WhatIf } else { $data.TestPage = 'non richiesta' }
        $data.Result = 'OK'
        $Row.Status = 'Installata'
        Write-PKLog ("[{0}] Stampante ""{1}"" creata" -f $Row.IP, $queue) 'ok'
    } catch {
        $msg = $_.Exception.Message
        $data.Result = 'NON INSTALLATA - ' + $msg
        $Row.Status = 'Errore: ' + $msg
        Write-PKLog ("[{0}] {1}" -f $Row.IP, $msg) 'errore'
    }
    if (-not $WhatIf) {
        try { $f = Write-PKInterventionLog -Folder $folder -Data $data; Write-PKLog ('Log di intervento: ' + $f) }
        catch { Write-PKLog ('Log di intervento non scritto: ' + $_.Exception.Message) 'errore' }
    } else { Write-PKLog ("[prova] log di intervento:`r`n" + (Format-PKInterventionLog $data)) }
    return $data
}

function Invoke-PKScan {
    param([string]$RangeText, [scriptblock]$Progress)
    if (-not $RangeText) { $RangeText = [string]::Join(',', [string[]](Get-PKLocalRanges)) }
    Write-PKLog ('Scansione di ' + $RangeText)
    $found = Find-PKPrinters -Range $RangeText -Community $Community -TimeoutMs ([int](Cfg 'tcpTimeoutMs' 1000)) -Progress $Progress
    $rows = New-Object System.Collections.ArrayList
    foreach ($f in $found) {
        $r = New-PKRow -IpAddr $f.IP -Ports $f.Ports -Model $f.Model -Descr $f.Description -Langs $f.Languages
        if ($r.Package -and $r.Existing.Length -eq 0) { $r.Selected = $true }
        [void]$rows.Add($r)
        Write-PKLog ('Trovata {0} - {1} [{2}] - {3}' -f $f.IP, ($f.Model, '(modello sconosciuto)' | Where-Object { $_ } | Select-Object -First 1), ([string]::Join(',', [string[]]($f.Ports | ForEach-Object { "$_" }))), $r.Status)
    }
    Write-PKLog ('{0} dispositivi trovati' -f $rows.Count) 'ok'
    return ,($rows.ToArray())
}

# ---------- Scanner: logica comune GUI / riga di comando ----------

function Invoke-PKScannerSetup {
    # $Ui fornisce le domande: ChooseDestination, AskUsers, AskCredential, AskAdminPassword, Confirm, Info, ChooseShare, AskExistingPassword
    param([object]$Row, [hashtable]$Ui)
    $folder = Join-Path $Downloads (Get-PKInterventionFolderName -Brand $Row.Brand -Model $Row.Model -IP $Row.IP)
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    $changes = New-Object System.Collections.ArrayList; $notes = New-Object System.Collections.ArrayList
    $shareName = Cfg 'scanShareName' 'Scansioni'
    $scanUser = Cfg 'scanUserDefault' 'scanner'

    # Passo 1: destinazione
    $dest = & $Ui.ChooseDestination
    if (-not $dest) { Write-PKLog 'Configurazione scanner annullata'; return }
    # Passo 2: utenti
    $users = & $Ui.AskUsers
    $userFolders = ConvertTo-PKUserFolders $users
    if ($userFolders.Length -eq 0) { Write-PKLog 'Nessun utente indicato: configurazione scanner annullata' 'avviso'; return }

    $hostIP = $null; $sharePath = $shareName; $unc = $null; $localRoot = $null; $acct = $null; $pw = $null; $domain = ''
    if ($dest.Kind -eq 'pc') {
        $local = Get-PKLocalAddresses
        # IP del PC sulla stessa rete della multifunzione.
        $prefix = [string]::Join('.', $Row.IP.Split('.')[0..2])
        $hostIP = ($local | Where-Object { $_.IP.StartsWith($prefix + '.') } | Select-Object -First 1).IP
        if (-not $hostIP) { $hostIP = $local[0].IP }
        $u = New-PKLocalScanUser -Name $scanUser -AskExistingPassword $Ui.AskExistingPassword -WhatIf:$WhatIf
        foreach ($c in $u.Changes) { [void]$changes.Add($c) }
        $acct = $u.Name; $pw = $u.Password; $domain = $env:COMPUTERNAME
        $localRoot = Cfg 'scanFolderDefault' 'C:\Scansioni'
        foreach ($c in (New-PKLocalScanShare -Root $localRoot -ShareName $shareName -UserFolders $userFolders -ScanUser $acct -System $Sys -WhatIf:$WhatIf)) { [void]$changes.Add($c) }
        foreach ($c in (Enable-PKFileSharingFirewall -System $Sys -WhatIf:$WhatIf)) { [void]$changes.Add($c) }
        foreach ($c in (Set-PKNetworkPrivate -WhatIf:$WhatIf)) { [void]$changes.Add($c) }
        $warn = Get-PKDhcpWarning $hostIP
        if ($warn) { [void]$notes.Add($warn); & $Ui.Info $warn }
        if ([version]$Sys.Version -lt [version]'6.0') { [void]$notes.Add('Destinazione Windows XP: è possibile solo SMB1.') }
        $unc = '\\{0}\{1}' -f $hostIP, $shareName
    } elseif ($dest.Kind -eq 'server') {
        $hostIP = $dest.IP
        $cred = & $Ui.AskCredential ("Amministratore del server $hostIP")
        if (-not $cred) { return }
        $r = Invoke-PKServerShare -Server $hostIP -Credential $cred -UserFolders $userFolders -ShareName $shareName -ScanUser $scanUser -WhatIf:$WhatIf
        foreach ($c in $r.Changes) { [void]$changes.Add("server ${hostIP}: $c") }
        $acct = $r.User; $pw = $r.Password
        if (-not $pw) { $pw = & $Ui.AskExistingPassword $scanUser; Register-PKSecret $pw }
        if ($acct -match '\\') { $domain = $acct.Split('\')[0]; $acct = $acct.Split('\')[1] }
        $unc = '\\{0}\{1}' -f $hostIP, $shareName
    } else {
        $hostIP = $dest.IP
        $cred = & $Ui.AskCredential ("Amministratore del NAS $hostIP")
        if (-not $cred) { return }
        $r = Invoke-PKNasShare -IP $hostIP -Kind $dest.Kind -Credential $cred -UserFolders $userFolders -ShareName $shareName -ScanUser $scanUser -KitRoot $KitRoot -ChooseShare $Ui.ChooseShare -Confirm $Ui.Confirm -WhatIf:$WhatIf
        foreach ($c in $r.Changes) { [void]$changes.Add($c) }
        $acct = $r.User; $pw = $r.Password; $sharePath = $r.SharePath; $unc = $r.Unc
    }
    & $Ui.Info "Con Everyone in lettura e scrittura, chiunque sia collegato alla rete può aprire e cancellare le scansioni."

    # Collegamenti
    try {
        $desk = Get-PKDesktopFolder -User $SessionUser
        $target = $unc; if ($localRoot) { $target = $localRoot }
        if (-not $WhatIf) { New-PKShortcut -LinkPath (Join-Path $desk 'Scansioni.lnk') -Target $target; New-PKShortcutKit -Folder $folder -Unc $unc }
        [void]$changes.Add('collegamento "Scansioni" sul Desktop di ' + $SessionUser.Name)
    } catch { Write-PKLog ('Collegamento non creato: ' + $_.Exception.Message) 'avviso' }

    # Verifica scrittura con le credenziali della multifunzione
    $userForTest = $acct; if ($domain) { $userForTest = $domain + '\' + $acct }
    $w = Test-PKShareWrite -Unc $unc -UserFolders $userFolders -User $userForTest -Password $pw -WhatIf:$WhatIf
    if ($w.Ok) { Write-PKLog ('Scrittura verificata in tutte le sottocartelle di ' + $unc) 'ok' }
    else { foreach ($e in $w.Errors) { Write-PKLog $e 'errore' }; [void]$notes.Add('verifica di scrittura fallita: ' + [string]::Join('; ', [string[]]$w.Errors)) }

    # Multifunzione
    $brandId = Get-PKField $Row.Manufacturer 'id' ''
    $recipes = Read-PKRecipes -Folder (Join-Path $KitRoot 'scanner-ricette') -Brand $brandId
    $match = Find-PKRecipe -Recipes $recipes -Model $Row.Model -IP $Row.IP
    $mfpDone = $false
    if ($match) {
        $entries = Get-PKAddressEntries -Recipe $match.Recipe -HostIP $hostIP -SharePath $sharePath -UserFolders $userFolders -ScanUser $acct -Password $pw -Domain $domain
        try {
            $mc = Invoke-PKMfpConfiguration -IP $Row.IP -Model $Row.Model -Match $match -Entries $entries -OutDir $folder -AskAdminPassword $Ui.AskAdminPassword -Confirm $Ui.Confirm -WhatIf:$WhatIf
            foreach ($c in $mc) { [void]$changes.Add($c) }
            $mfpDone = $true
        } catch {
            Write-PKLog ('Configurazione della multifunzione non riuscita: ' + $_.Exception.Message) 'errore'
            [void]$notes.Add('multifunzione non configurata: ' + $_.Exception.Message)
        }
    } else {
        Write-PKLog 'Ricetta non disponibile per questo modello: il lato PC è pronto, la rubrica va compilata a mano' 'avviso'
        $req = Save-PKRecipeRequest -IP $Row.IP -Model $Row.Model -Description $Row.Description -OutDir $folder
        [void]$notes.Add('ricetta non disponibile; dati per crearla in ' + $req)
        $text = "Host: $hostIP`r`nPercorso: $unc\<utente>`r`nUtente: $acct`r`nPassword: $pw`r`nVoci: " + [string]::Join(', ', [string[]]($userFolders | ForEach-Object { $_.Name }))
        try { Add-Type -AssemblyName System.Windows.Forms; [Windows.Forms.Clipboard]::SetText($text) } catch { }
        if (-not $WhatIf) { Start-Process ('http://' + $Row.IP) }
        & $Ui.Info 'Ricetta non disponibile per questo modello. Ho aperto la pagina web della macchina e copiato negli appunti host, percorso, utente e password.'
    }

    # Scansione di prova
    if ($mfpDone -and -not $WhatIf -and $localRoot) {
        & $Ui.Info ('Fai ora una scansione di prova verso "{0}" dalla multifunzione. Attendo fino a 2 minuti.' -f $userFolders[0].Name)
        $file = Wait-PKScanFile -Folders @($userFolders | ForEach-Object { Join-Path $localRoot $_.Folder }) -Seconds ([int](Cfg 'scanVerifySeconds' 120))
        if ($file) { Write-PKLog ('Scansione verificata: ' + $file) 'ok'; [void]$notes.Add('Scansione verificata') }
        else {
            $m = 'Nessuna scansione arrivata. Cause probabili: firewall, SMB disattivato sulla macchina, credenziali, IP del PC cambiato.'
            Write-PKLog $m 'avviso'; [void]$notes.Add($m)
        }
    }
    $card = Write-PKScannerCard -Folder $folder -Info @{
        Model = $Row.Model; IP = $Row.IP; Destination = $dest.Label; Unc = $unc; User = $userForTest; Password = $pw
        Users = @($userFolders | ForEach-Object { $_.Name }); Changes = $changes; Notes = $notes
    }
    Write-PKLog ('Scheda scanner: ' + $card)
    foreach ($c in $changes) { Write-PKLog ('Modifica: ' + $c) }
    return ('cartella {0} (utente: {1}){2}' -f $unc, $userForTest, @{ $true = ''; $false = ' - multifunzione da configurare a mano' }[$mfpDone])
}

# =====================================================================
# Riga di comando
# =====================================================================

if ($VerifyCatalog) {
    Write-PKLog ('Verifica catalogo - aggiornato il ' + $CatalogInfo.UpdatedAt)
    $res = Invoke-PKCatalogCheck $Catalog -OnResult { param($r) $lvl = 'ok'; if (-not $r.Ok) { $lvl = 'errore' }; Write-PKLog ('{0} / {1}: {2}' -f $r.Manufacturer, $r.Package, $r.Message) $lvl }
    $bad = @($res | Where-Object { -not $_.Ok })
    Write-PKLog ('{0} link controllati, {1} con problemi' -f $res.Length, $bad.Count)
    exit ([int]($bad.Count -gt 0))
}

if ($PrepareCache) {
    # Da un PC aggiornato: scarica, verifica (dominio, firma, sha256) e mette in cache i pacchetti
    # dei sistemi che non possono scaricarli da soli.
    $targets = @($CacheFor | ForEach-Object { $_.Split(',') } | Where-Object { $_ })
    $ranges = @{ 'windows-xp' = @('5.1', '5.2'); 'windows-7' = @('6.1', '6.1'); 'windows-8.1' = @('6.3', '6.3'); 'windows-10' = @('10.0', '10.0') }
    $done = 0; $failed = 0
    foreach ($m in (Get-PKField $Catalog 'manufacturers' @())) {
        foreach ($p in @(Get-PKField $m 'packages' @())) {
            if ((Get-PKField $p 'os') -ne 'windows' -or (Get-PKField $p 'status') -ne 'ok') { continue }
            $want = $false
            foreach ($t in $targets) {
                $r = $ranges[$t]; if (-not $r) { continue }
                $min = Get-PKField $p 'osMin' '0'; $max = Get-PKField $p 'osMax' '99'
                if ((Compare-PKVersion $min $r[1]) -le 0 -and (Compare-PKVersion $max $r[0]) -ge 0) { $want = $true }
            }
            if (-not $want) { continue }
            $pkgId = Get-PKField $p 'id'; $manId = Get-PKField $m 'id'
            try {
                $work = Join-Path $WorkRoot $pkgId; [void](New-Item -ItemType Directory -Path $work -Force)
                $src = Get-PKDriverPackageFile -Manufacturer $m -Package $p -KitRoot $KitRoot -WorkDir $work -System $Sys
                if ($src.FromCache) { Write-PKLog "$pkgId già in cache" 'ok'; $done++; continue }
                $ext = Join-Path $work 'estratto'
                [void](Expand-PKDriverPackage -File $src.Path -Destination $ext -Package $p -KitRoot $KitRoot)
                $infs = @()
                foreach ($a in @(Get-PKField $p 'arch' @())) { $infs += Find-PKPrinterInfs -Directory $ext -Arch $a }
                $auth = Test-PKPackageAuthenticity -PackageFile $src.Path -ExtractedDir $ext -Manufacturer $m -Infs ([string[]]($infs | Select-Object -Unique))
                if (-not $auth.Ok) { throw $auth.Message }
                Save-PKToCache -File $src.Path -KitRoot $KitRoot -ManufacturerId $manId -PackageId $pkgId -Sha256 $src.Sha256 -Signer $auth.Signer -Url $src.Url
                Write-PKLog "$pkgId verificato ($($auth.Signer)) e copiato nella cache" 'ok'; $done++
            } catch { Write-PKLog "${pkgId}: $($_.Exception.Message)" 'errore'; $failed++ }
        }
    }
    Write-PKLog ('Cache: {0} pacchetti pronti, {1} non riusciti' -f $done, $failed)
    exit ([int]($failed -gt 0))
}

$CliUi = @{
    ChooseDestination = { @{ Kind = 'pc'; Label = 'Questo PC (disco C:)' } }
    AskUsers = { if ($ScanUsers) { $ScanUsers } else { (Read-Host 'Nomi degli utenti per la scansione, separati da virgola').Split(',') } }
    AskCredential = { param($t) Get-Credential -Message $t }
    AskAdminPassword = { param($u) $p = Read-Host "Password amministratore della multifunzione ($u)" -AsSecureString; @{ User = $u; Password = (New-Object Management.Automation.PSCredential('x', $p)).GetNetworkCredential().Password } }
    Confirm = { param($t) (Read-Host ($t + ' [s/n]')) -match '^s' }
    Info = { param($t) Write-PKLog $t 'avviso' }
    ChooseShare = { param($list) Write-Host ([string]::Join(', ', $list)); Read-Host 'Condivisione da usare' }
    AskExistingPassword = { param($n) $p = Read-Host "L'utente $n esiste già. Password (Invio per crearne uno nuovo)" -AsSecureString; (New-Object Management.Automation.PSCredential('x', $p)).GetNetworkCredential().Password }
}

if ($NoGui) {
    $rows = @()
    if ($IP) {
        $list = @($IP | ForEach-Object { $_.Split(',') } | Where-Object { $_ })
        $open = Test-PKTcpPorts -Hosts $list -TimeoutMs ([int](Cfg 'tcpTimeoutMs' 1000))
        foreach ($x in $list) {
            $ports = @(); if ($open.ContainsKey($x)) { $ports = [int[]]$open[$x] }
            $id = Get-PKPrinterIdentity -IP $x -Community $Community -OpenPorts $ports
            $r = New-PKRow -IpAddr $x -Ports $ports -Model $id.Model -Descr $id.Description -Langs $id.Languages
            if ($r.Package -and $r.Existing.Length -eq 0) { $r.Selected = $true }
            $rows += $r
        }
    } else {
        $rr = $Range; if (-not $rr) { $rr = Cfg 'defaultRange' '' }
        $rows = Invoke-PKScan $rr
    }
    $ok = 0; $ko = 0
    foreach ($r in $rows) {
        if (-not $InstallAll -or -not $r.Selected) {
            Write-PKLog ('{0}: {1}' -f $r.IP, $r.Status)
            if ($r.Reason -eq 'Modello non presente nel catalogo') { $u = Get-PKIssueUrl $r; if ($u) { Write-PKLog ('Segnala su GitHub: ' + $u) } }
            continue
        }
        $d = Install-PKRow -Row $r -DoTestPage $TestPage -DoDefault $SetDefault
        if ($d.Result -eq 'OK') {
            $ok++
            if ($ScanFolder) { try { [void](Invoke-PKScannerSetup -Row $r -Ui $CliUi) } catch { Write-PKLog ('Scanner: ' + $_.Exception.Message) 'errore' } }
        } else { $ko++ }
    }
    Write-PKLog ('Fine: {0} installate, {1} non installate' -f $ok, $ko) 'ok'
    if ([bool](Cfg 'logCopyToKit' $true)) { Copy-PKSessionLogToKit $KitRoot }
    Clear-PKTrustedHosts
    exit ([int]($ko -gt 0))
}

# =====================================================================
# Interfaccia grafica (WinForms)
# =====================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'PrinterKit'
$form.Size = New-Object Drawing.Size(1180, 760)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.MinimumSize = New-Object Drawing.Size(900, 600)

# --- Barra superiore ---
$top = New-Object Windows.Forms.Panel; $top.Dock = 'Top'; $top.Height = 74
$lblSys = New-Object Windows.Forms.Label
$lblSys.Text = ('Sistema rilevato: {0}     Catalogo: {1} ({2})' -f $Sys.Label, $CatalogInfo.UpdatedAt, $CatalogInfo.Source)
$lblSys.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$lblSys.Location = New-Object Drawing.Point(12, 8); $lblSys.AutoSize = $true
$lblRange = New-Object Windows.Forms.Label; $lblRange.Text = 'Intervallo IP:'; $lblRange.Location = New-Object Drawing.Point(12, 42); $lblRange.AutoSize = $true
$txtRange = New-Object Windows.Forms.TextBox; $txtRange.Location = New-Object Drawing.Point(95, 39); $txtRange.Width = 360
$r0 = Cfg 'defaultRange' ''; if (-not $r0) { $r0 = [string]::Join(', ', [string[]](Get-PKLocalRanges)) }; $txtRange.Text = $r0
$btnScan = New-Object Windows.Forms.Button; $btnScan.Text = 'Scansiona'; $btnScan.Location = New-Object Drawing.Point(465, 37); $btnScan.Width = 100
$btnAdd = New-Object Windows.Forms.Button; $btnAdd.Text = 'Aggiungi IP'; $btnAdd.Location = New-Object Drawing.Point(570, 37); $btnAdd.Width = 100
$btnCheck = New-Object Windows.Forms.Button; $btnCheck.Text = 'Verifica catalogo'; $btnCheck.Location = New-Object Drawing.Point(675, 37); $btnCheck.Width = 120
$btnReport = New-Object Windows.Forms.Button; $btnReport.Text = 'Segnala su GitHub'; $btnReport.Location = New-Object Drawing.Point(800, 37); $btnReport.Width = 130; $btnReport.Enabled = $false
$top.Controls.AddRange(@($lblSys, $lblRange, $txtRange, $btnScan, $btnAdd, $btnCheck, $btnReport))

# --- Tabella ---
$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'; $grid.AllowUserToAddRows = $false; $grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'; $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [Drawing.Color]::White
$colSel = New-Object Windows.Forms.DataGridViewCheckBoxColumn; $colSel.HeaderText = ''; $colSel.FillWeight = 4
[void]$grid.Columns.Add($colSel)
foreach ($c in @(@('IP', 11, $true), @('Porte', 9, $true), @('Marca', 10, $true), @('Modello', 18, $false), @('Driver ufficiale previsto', 22, $true), @('Nome stampante', 20, $false), @('Stato', 22, $true))) {
    $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $c[0]; $col.FillWeight = $c[1]; $col.ReadOnly = $c[2]
    [void]$grid.Columns.Add($col)
}

# --- Parte inferiore ---
$bottom = New-Object Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 250
$chkTest = New-Object Windows.Forms.CheckBox; $chkTest.Text = 'Stampa pagina di prova'; $chkTest.Checked = $true; $chkTest.Location = New-Object Drawing.Point(12, 10); $chkTest.AutoSize = $true
$chkDef = New-Object Windows.Forms.CheckBox; $chkDef.Text = 'Imposta come predefinita'; $chkDef.Location = New-Object Drawing.Point(190, 10); $chkDef.AutoSize = $true
$chkScan = New-Object Windows.Forms.CheckBox; $chkScan.Text = 'Configura scansione su cartella'; $chkScan.Location = New-Object Drawing.Point(375, 10); $chkScan.AutoSize = $true
$chkWhat = New-Object Windows.Forms.CheckBox; $chkWhat.Text = 'Solo prova (nessuna modifica)'; $chkWhat.Location = New-Object Drawing.Point(590, 10); $chkWhat.AutoSize = $true; $chkWhat.Checked = [bool]$WhatIf
$btnInstall = New-Object Windows.Forms.Button; $btnInstall.Text = 'Installa selezionate'; $btnInstall.Location = New-Object Drawing.Point(12, 38); $btnInstall.Size = New-Object Drawing.Size(180, 32)
$btnInstall.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$btnFolder = New-Object Windows.Forms.Button; $btnFolder.Text = 'Apri cartella log'; $btnFolder.Location = New-Object Drawing.Point(200, 38); $btnFolder.Size = New-Object Drawing.Size(130, 32)
$bar = New-Object Windows.Forms.ProgressBar; $bar.Location = New-Object Drawing.Point(340, 44); $bar.Size = New-Object Drawing.Size(800, 20); $bar.Anchor = 'Top,Left,Right'
$logBox = New-Object Windows.Forms.RichTextBox; $logBox.Location = New-Object Drawing.Point(12, 78); $logBox.Size = New-Object Drawing.Size(1140, 162)
$logBox.Anchor = 'Top,Left,Right,Bottom'; $logBox.ReadOnly = $true; $logBox.Font = New-Object Drawing.Font('Consolas', 9); $logBox.BackColor = [Drawing.Color]::FromArgb(250, 250, 250)
$bottom.Controls.AddRange(@($chkTest, $chkDef, $chkScan, $chkWhat, $btnInstall, $btnFolder, $bar, $logBox))

$form.Controls.Add($grid); $form.Controls.Add($bottom); $form.Controls.Add($top)

Set-PKLogCallback {
    param($line, $level)
    $color = @{ info = [Drawing.Color]::Black; ok = [Drawing.Color]::DarkGreen; avviso = [Drawing.Color]::DarkOrange; errore = [Drawing.Color]::Firebrick }[$level]
    $logBox.SelectionStart = $logBox.TextLength; $logBox.SelectionColor = $color
    $logBox.AppendText($line + "`r`n"); $logBox.ScrollToCaret()
    [Windows.Forms.Application]::DoEvents()
}
Write-PKLog 'Pronto. Premi "Scansiona" per cercare le stampanti.'

$script:Rows = New-Object System.Collections.ArrayList

function Show-PKRows {
    $grid.Rows.Clear()
    foreach ($r in $script:Rows) {
        $i = $grid.Rows.Add($r.Selected, $r.IP, ([string]::Join(', ', [string[]]($r.Ports | ForEach-Object { "$_" }))), $r.Brand, $r.Model, $r.PackageText, $r.QueueName, $r.Status)
        $gr = $grid.Rows[$i]
        if ($r.Existing.Length -gt 0) { $gr.DefaultCellStyle.ForeColor = [Drawing.Color]::Gray }
        elseif (-not $r.Package) { $gr.DefaultCellStyle.ForeColor = [Drawing.Color]::Firebrick }
        if ($r.Status -eq 'Installata') { $gr.DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(230, 245, 230) }
    }
}

function Read-PKGridEdits {
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        $r = $script:Rows[$i]; $g = $grid.Rows[$i]
        $r.Selected = [bool]$g.Cells[0].Value
        $r.QueueName = "$($g.Cells[6].Value)".Trim()
    }
}

$grid.add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit('CurrentCellChange') } })
$grid.add_CellEndEdit({
    param($s, $e)
    $r = $script:Rows[$e.RowIndex]
    if ($e.ColumnIndex -eq 4) {
        # Modello modificato a mano: si ricalcola la corrispondenza col catalogo.
        $new = "$($grid.Rows[$e.RowIndex].Cells[4].Value)".Trim()
        if ($new -ne $r.Model) {
            $r.Model = $new; $r.QueueName = ''
            Update-PKRow $r
            if ($r.Package -and $r.Existing.Length -eq 0) { $r.Selected = $true }
            $form.BeginInvoke([Windows.Forms.MethodInvoker]{ Show-PKRows }) | Out-Null
        }
    }
})
$grid.add_SelectionChanged({
    $btnReport.Enabled = $false
    if ($grid.SelectedRows.Count -gt 0) {
        $r = $script:Rows[$grid.SelectedRows[0].Index]
        if ($r -and $r.Reason -eq 'Modello non presente nel catalogo' -and (Get-PKIssueUrl $r)) { $btnReport.Enabled = $true }
    }
})

$btnScan.add_Click({
    $btnScan.Enabled = $false; $btnInstall.Enabled = $false
    try {
        $bar.Value = 0
        $rows = Invoke-PKScan $txtRange.Text -Progress { param($done, $tot) if ($tot -gt 0) { $bar.Value = [math]::Min(100, [int](100 * $done / $tot)) }; [Windows.Forms.Application]::DoEvents() }
        $script:Rows.Clear(); foreach ($r in $rows) { [void]$script:Rows.Add($r) }
        Show-PKRows; $bar.Value = 100
    } catch { Write-PKLog $_.Exception.Message 'errore' }
    finally { $btnScan.Enabled = $true; $btnInstall.Enabled = $true }
})

function Read-PKInput {
    param([string]$Title, [string]$Prompt, [string]$Default = '', [switch]$Password, [switch]$Multiline)
    $f = New-Object Windows.Forms.Form; $f.Text = $Title; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.Font = $form.Font
    $h = 150; if ($Multiline) { $h = 300 }
    $f.Size = New-Object Drawing.Size(460, $h)
    $l = New-Object Windows.Forms.Label; $l.Text = $Prompt; $l.Location = New-Object Drawing.Point(12, 10); $l.Size = New-Object Drawing.Size(420, 36)
    $t = New-Object Windows.Forms.TextBox; $t.Location = New-Object Drawing.Point(12, 48); $t.Width = 420; $t.Text = $Default
    if ($Password) { $t.UseSystemPasswordChar = $true }
    if ($Multiline) { $t.Multiline = $true; $t.Height = 150; $t.ScrollBars = 'Vertical'; $t.AcceptsReturn = $true }
    $ok = New-Object Windows.Forms.Button; $ok.Text = 'OK'; $ok.DialogResult = 'OK'; $ok.Location = New-Object Drawing.Point(276, ($h - 75)); $ok.Width = 75
    $ca = New-Object Windows.Forms.Button; $ca.Text = 'Annulla'; $ca.DialogResult = 'Cancel'; $ca.Location = New-Object Drawing.Point(357, ($h - 75)); $ca.Width = 75
    $f.Controls.AddRange(@($l, $t, $ok, $ca)); $f.CancelButton = $ca
    if (-not $Multiline) { $f.AcceptButton = $ok }
    if ($f.ShowDialog($form) -eq 'OK') { return $t.Text }
    return $null
}

function Show-PKChoice {
    param([string]$Title, [string]$Prompt, [string[]]$Options)
    $f = New-Object Windows.Forms.Form; $f.Text = $Title; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.Font = $form.Font
    $f.Size = New-Object Drawing.Size(480, 320); $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $l = New-Object Windows.Forms.Label; $l.Text = $Prompt; $l.Location = New-Object Drawing.Point(12, 10); $l.Size = New-Object Drawing.Size(440, 36)
    $lb = New-Object Windows.Forms.ListBox; $lb.Location = New-Object Drawing.Point(12, 48); $lb.Size = New-Object Drawing.Size(440, 170)
    foreach ($o in $Options) { [void]$lb.Items.Add($o) }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
    $ok = New-Object Windows.Forms.Button; $ok.Text = 'Avanti'; $ok.DialogResult = 'OK'; $ok.Location = New-Object Drawing.Point(296, 235); $ok.Width = 75
    $ca = New-Object Windows.Forms.Button; $ca.Text = 'Annulla'; $ca.DialogResult = 'Cancel'; $ca.Location = New-Object Drawing.Point(377, 235); $ca.Width = 75
    $f.Controls.AddRange(@($l, $lb, $ok, $ca)); $f.AcceptButton = $ok; $f.CancelButton = $ca
    if ($f.ShowDialog($form) -eq 'OK' -and $lb.SelectedIndex -ge 0) { return $lb.SelectedIndex }
    return -1
}

$GuiUi = @{
    ChooseDestination = {
        $i = Show-PKChoice 'Scanner - passo 1 di 3' 'Dove creare la cartella condivisa?' @('Questo PC (disco C:)', 'Server', 'NAS')
        if ($i -lt 0) { return $null }
        if ($i -eq 0) { return @{ Kind = 'pc'; Label = 'Questo PC (disco C:)' } }
        Write-PKLog 'Cerco server e NAS in rete...'
        $all = Find-PKFileServers -Range $txtRange.Text
        if ($i -eq 1) { $list = @($all | Where-Object { $_.Kind -eq 'server' }) } else { $list = @($all | Where-Object { $_.Kind -ne 'server' }) }
        if ($list.Count -eq 0) { [void][Windows.Forms.MessageBox]::Show('Nessun dispositivo trovato in rete.', 'PrinterKit'); return $null }
        $labels = @($list | ForEach-Object { '{0}  {1}  ({2})' -f $_.IP, $_.Name, @{ server = 'Windows Server'; synology = 'Synology'; qnap = 'QNAP'; smb = 'NAS - marca non supportata' }[$_.Kind] })
        $j = Show-PKChoice 'Scanner - passo 1 di 3' 'Scegli il dispositivo:' $labels
        if ($j -lt 0) { return $null }
        return @{ Kind = $list[$j].Kind; IP = $list[$j].IP; Label = $labels[$j] }
    }
    AskUsers = {
        $t = Read-PKInput 'Scanner - passo 2 di 3' 'Utenti (uno per riga, es. Mario, Contabilità, Ufficio tecnico):' -Multiline
        if (-not $t) { return @() }
        return @($t -split "[`r`n,]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    AskCredential = {
        param($t)
        $u = Read-PKInput 'Scanner - passo 3 di 3' ($t + ': nome utente') 'Administrator'
        if (-not $u) { return $null }
        $p = Read-PKInput 'Scanner - passo 3 di 3' ($t + ': password') -Password
        if ($null -eq $p) { return $null }
        Register-PKSecret $p
        return New-Object Management.Automation.PSCredential($u, (ConvertTo-SecureString $p -AsPlainText -Force))
    }
    AskAdminPassword = {
        param($u)
        $p = Read-PKInput 'Multifunzione' ("La password di fabbrica non funziona. Password amministratore della multifunzione (utente $u):") -Password
        if ($null -eq $p) { return $null }
        return @{ User = $u; Password = $p }
    }
    Confirm = { param($t) [Windows.Forms.MessageBox]::Show($t, 'PrinterKit', 'YesNo', 'Question') -eq 'Yes' }
    Info = { param($t) [void][Windows.Forms.MessageBox]::Show($t, 'PrinterKit', 'OK', 'Information'); Write-PKLog $t }
    ChooseShare = { param($list) $i = Show-PKChoice 'NAS' 'Marca di NAS senza API: scegli la condivisione in cui creare la cartella Scansioni.' $list; if ($i -ge 0) { return $list[$i] }; return $null }
    AskExistingPassword = { param($n) Read-PKInput 'Utente esistente' ("L'utente $n esiste già. Inserisci la sua password, oppure lascia vuoto per crearne uno nuovo:") -Password }
}

$btnAdd.add_Click({
    $t = Read-PKInput 'Aggiungi IP' 'Indirizzi IP separati da virgola:'
    if (-not $t) { return }
    foreach ($x in ($t -split '[,;\s]+' | Where-Object { $_ })) {
        if ($x -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-PKLog "IP non valido: $x" 'errore'; continue }
        if ($script:Rows | Where-Object { $_.IP -eq $x }) { continue }
        $open = Test-PKTcpPorts -Hosts @($x) -TimeoutMs 1500
        $ports = @(); if ($open.ContainsKey($x)) { $ports = [int[]]$open[$x] }
        $id = Get-PKPrinterIdentity -IP $x -Community $Community -OpenPorts $ports
        $r = New-PKRow -IpAddr $x -Ports $ports -Model $id.Model -Descr $id.Description -Langs $id.Languages
        if ($r.Package -and $r.Existing.Length -eq 0) { $r.Selected = $true }
        [void]$script:Rows.Add($r)
        Write-PKLog ('Aggiunto {0} - {1}' -f $x, $r.Status)
    }
    Show-PKRows
})

$btnCheck.add_Click({
    $btnCheck.Enabled = $false
    try {
        Write-PKLog ('Verifica catalogo - ultimo aggiornamento: ' + $CatalogInfo.UpdatedAt)
        $res = Invoke-PKCatalogCheck $Catalog -OnResult { param($r) $lvl = 'ok'; if (-not $r.Ok) { $lvl = 'errore' }; Write-PKLog ('{0} / {1}: {2}' -f $r.Manufacturer, $r.Package, $r.Message) $lvl }
        $bad = @($res | Where-Object { -not $_.Ok }).Count
        Write-PKLog ('{0} link controllati, {1} con problemi' -f $res.Length, $bad) @{ $true = 'ok'; $false = 'avviso' }[$bad -eq 0]
        if ($res.Length -eq 0) { Write-PKLog 'Il catalogo non contiene ancora pacchetti con link: va popolato dal workflow GitHub "recupero-link".' 'avviso' }
    } finally { $btnCheck.Enabled = $true }
})

$btnReport.add_Click({
    if ($grid.SelectedRows.Count -eq 0) { return }
    $u = Get-PKIssueUrl $script:Rows[$grid.SelectedRows[0].Index]
    if ($u) { Start-Process $u }
})

$btnFolder.add_Click({ Start-Process explorer.exe (Join-Path $Downloads 'PrinterKit') })

$btnInstall.add_Click({
    Read-PKGridEdits
    $sel = @($script:Rows | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { [void][Windows.Forms.MessageBox]::Show('Nessuna stampante selezionata.', 'PrinterKit'); return }
    $script:WhatIf = [switch]$chkWhat.Checked
    $btnInstall.Enabled = $false; $btnScan.Enabled = $false
    $bar.Value = 0; $n = 0; $ok = 0
    foreach ($r in $sel) {
        $r.Status = 'Installazione...'; Show-PKRows; [Windows.Forms.Application]::DoEvents()
        $d = Install-PKRow -Row $r -DoTestPage $chkTest.Checked -DoDefault $chkDef.Checked
        if ($d.Result -eq 'OK') {
            $ok++
            if ($chkScan.Checked) {
                try { $s = Invoke-PKScannerSetup -Row $r -Ui $GuiUi; if ($s) { Write-PKLog ('Scanner: ' + $s) 'ok' } }
                catch { Write-PKLog ('Scanner: ' + $_.Exception.Message) 'errore' }
            }
        }
        $n++; $bar.Value = [int](100 * $n / $sel.Count); Show-PKRows
    }
    Write-PKLog ('Fine: {0} di {1} installate. Log in {2}' -f $ok, $sel.Count, $Downloads) 'ok'
    if ([bool](Cfg 'logCopyToKit' $true)) { Copy-PKSessionLogToKit $KitRoot }
    $btnInstall.Enabled = $true; $btnScan.Enabled = $true
})

$form.add_Shown({ $form.Activate() })
$form.add_FormClosed({ Clear-PKTrustedHosts; try { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { } })
[void]$form.ShowDialog()
