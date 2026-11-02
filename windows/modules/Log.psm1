# Log di intervento (§9). Compatibile con PowerShell 2.0.

$script:SessionLines = New-Object System.Collections.ArrayList
$script:SessionFile = $null
$script:LogCallback = $null
$script:Secrets = New-Object System.Collections.ArrayList

function Set-PKLogCallback {
    param([scriptblock]$Callback)
    $script:LogCallback = $Callback
}

function Register-PKSecret {
    # Ogni segreto registrato viene mascherato in tutti i log.
    param([string]$Value)
    if ($Value -and $Value.Length -ge 3) { [void]$script:Secrets.Add($Value) }
}

function Protect-PKText {
    param([string]$Text)
    if ($null -eq $Text) { return $Text }
    foreach ($s in $script:Secrets) { $Text = $Text.Replace($s, (Get-PKMasked $s)) }
    return $Text
}

function Get-PKMasked {
    param([string]$Value)
    if (-not $Value) { return '' }
    return ('*' * 8)
}

function Write-PKLog {
    param(
        [string]$Message,
        [ValidateSet('info', 'ok', 'avviso', 'errore')][string]$Level = 'info'
    )
    $Message = Protect-PKText $Message
    $prefix = @{ info = '   '; ok = 'OK '; avviso = '!! '; errore = 'XX ' }[$Level]
    $line = '{0} {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $prefix, $Message
    [void]$script:SessionLines.Add($line)
    if ($script:SessionFile) {
        try { Add-Content -LiteralPath $script:SessionFile -Value $line -Encoding UTF8 } catch { }
    }
    if ($script:LogCallback) { & $script:LogCallback $line $Level }
    else {
        $color = @{ info = 'Gray'; ok = 'Green'; avviso = 'Yellow'; errore = 'Red' }[$Level]
        Write-Host $line -ForegroundColor $color
    }
}

function ConvertTo-PKFolderName {
    # Ripulisce un testo per usarlo come nome di cartella Windows/macOS.
    param([string]$Name)
    if (-not $Name) { return '' }
    $clean = $Name -replace '[\\/:*?"<>|\x00-\x1F]', ' '
    $clean = ($clean -replace '\s+', ' ').Trim().TrimEnd('.').Trim()
    $reserved = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
    if ($clean -match $reserved) { $clean = '_' + $clean }
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 120).Trim() }
    return $clean
}

function Get-PKInterventionFolderName {
    param([string]$Brand, [string]$Model, [string]$IP)
    $model = "$Model".Trim()
    if (-not $model) { return ConvertTo-PKFolderName ("Driver $IP") }
    $brand = "$Brand".Trim()
    # Evita "Driver Kyocera KYOCERA ECOSYS…" quando il modello SNMP contiene già la marca.
    if ($brand -and $model.ToLower().StartsWith($brand.ToLower())) { $brand = '' }
    if ($brand -and $model.ToUpper().StartsWith($brand.ToUpper().Split(' ')[0])) { $brand = '' }
    $text = ('Driver ' + (($brand + ' ' + $model).Trim()))
    return ConvertTo-PKFolderName $text
}

function Get-PKSessionUser {
    # Utente che ha aperto la sessione (non l'amministratore usato per l'elevazione).
    $name = $null
    try { $name = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
    if (-not $name) { $name = "$env:USERDOMAIN\$env:USERNAME" }
    $sid = $null
    try {
        $acc = New-Object System.Security.Principal.NTAccount($name)
        $sid = $acc.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { }
    $short = $name
    if ($name -match '\\') { $short = $name.Split('\')[1] }
    return New-Object PSObject -Property @{ FullName = $name; Name = $short; Sid = $sid }
}

function Get-PKUserShellFolder {
    # Restituisce il percorso di una known folder dell'utente di sessione.
    param([string]$ValueName, [string]$Fallback, [object]$User)
    if (-not $User) { $User = Get-PKSessionUser }
    $profilePath = $null
    if ($User.Sid) {
        try {
            $profilePath = (Get-ItemProperty -LiteralPath ("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + $User.Sid) -ErrorAction Stop).ProfileImagePath
            $profilePath = [Environment]::ExpandEnvironmentVariables($profilePath)
        } catch { }
    }
    if (-not $profilePath) { $profilePath = $env:USERPROFILE }
    $value = $null
    if ($User.Sid) {
        if (-not (Test-Path 'HKU:\')) { [void](New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction SilentlyContinue) }
        $key = 'HKU:\' + $User.Sid + '\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        try {
            # Lettura senza espansione: %USERPROFILE% va sostituito con il profilo dell'utente di sessione.
            $reg = Get-Item -LiteralPath $key -ErrorAction Stop
            $value = $reg.GetValue($ValueName, $null, 'DoNotExpandEnvironmentNames')
        } catch { }
    }
    if ($value) {
        $value = $value -replace '%USERPROFILE%', $profilePath
        $value = [Environment]::ExpandEnvironmentVariables($value)
        return $value
    }
    return (Join-Path $profilePath $Fallback)
}

function Get-PKDownloadsFolder {
    param([object]$User, [string]$OsVersion)
    if ($OsVersion -and ([version]$OsVersion) -lt ([version]'6.0')) {
        # Windows XP non ha la cartella Download.
        if (-not $User) { $User = Get-PKSessionUser }
        $p = Get-PKUserShellFolder -ValueName 'Personal' -Fallback 'Documenti' -User $User
        $profileRoot = Split-Path $p -Parent
        return (Join-Path $profileRoot 'Download')
    }
    return Get-PKUserShellFolder -ValueName '{374DE290-123F-4565-9164-39C4925E467B}' -Fallback 'Downloads' -User $User
}

function Get-PKDesktopFolder {
    param([object]$User)
    return Get-PKUserShellFolder -ValueName 'Desktop' -Fallback 'Desktop' -User $User
}

function Start-PKSessionLog {
    param([string]$DownloadsFolder)
    $dir = Join-Path $DownloadsFolder 'PrinterKit'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $script:SessionFile = Join-Path $dir ('sessione_{0}.txt' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    $header = '=== PrinterKit - sessione del {0} ===' -f (Get-Date -Format 'dd/MM/yyyy HH:mm')
    Set-Content -LiteralPath $script:SessionFile -Value $header -Encoding UTF8
    foreach ($l in $script:SessionLines) { Add-Content -LiteralPath $script:SessionFile -Value $l -Encoding UTF8 }
    return $script:SessionFile
}

function Get-PKSessionLogPath { return $script:SessionFile }

function Copy-PKSessionLogToKit {
    param([string]$KitRoot)
    if (-not $script:SessionFile) { return }
    try {
        $dest = Join-Path $KitRoot 'log'
        if (-not (Test-Path -LiteralPath $dest)) { [void](New-Item -ItemType Directory -Path $dest -Force) }
        Copy-Item -LiteralPath $script:SessionFile -Destination $dest -Force
    } catch { Write-PKLog ("Copia del log nella chiavetta non riuscita: " + $_.Exception.Message) 'avviso' }
}

function Format-PKInterventionLog {
    # Testo del log di intervento con i campi minimi del §9.
    param([hashtable]$Data)
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add(('=== PrinterKit - intervento del {0} ===' -f $Data.Date.ToString('dd/MM/yyyy HH:mm')))
    [void]$L.Add(('PC: {0}   Utente: {1}   Sistema: {2}' -f $Data.Computer, $Data.User, $Data.System))
    [void]$L.Add(('Stampante: {0}   IP: {1}   Porte aperte: {2}' -f $Data.Printer, $Data.IP, $Data.Ports))
    if ($Data.Driver) {
        [void]$L.Add(('Driver: {0}' -f $Data.Driver))
        [void]$L.Add(('  Fonte: {0}   Firma: {1}' -f $Data.Source, $Data.Signature))
        [void]$L.Add(('  SHA-256: {0}' -f $Data.Sha256))
    } else {
        [void]$L.Add('Driver: nessuno')
    }
    if ($Data.Port) { [void]$L.Add(('Porta creata: {0}' -f $Data.Port)) }
    if ($Data.Queue) { [void]$L.Add(('Stampante creata: "{0}" - predefinita: {1}' -f $Data.Queue, $Data.Default)) }
    if ($Data.TestPage) { [void]$L.Add(('Pagina di prova: {0}' -f $Data.TestPage)) }
    if ($Data.Scanner) { [void]$L.Add(('Scanner: {0}' -f $Data.Scanner)) }
    if ($Data.Changes) { foreach ($c in $Data.Changes) { [void]$L.Add(('Modifica: {0}' -f $c)) } }
    if ($Data.Details) { foreach ($d in $Data.Details) { [void]$L.Add(('  ' + $d)) } }
    [void]$L.Add(('Esito: {0}' -f $Data.Result))
    [void]$L.Add('')
    return (Protect-PKText ([string]::Join("`r`n", [string[]]$L.ToArray())))
}

function Write-PKInterventionLog {
    param([string]$Folder, [hashtable]$Data)
    if (-not (Test-Path -LiteralPath $Folder)) { [void](New-Item -ItemType Directory -Path $Folder -Force) }
    $file = Join-Path $Folder ('log_{0}_{1}.txt' -f $Data.Date.ToString('yyyy-MM-dd'), $Data.Computer)
    # Stesso giorno: in coda al file esistente.
    Add-Content -LiteralPath $file -Value (Format-PKInterventionLog $Data) -Encoding UTF8
    return $file
}

Export-ModuleMember -Function *-PK*
