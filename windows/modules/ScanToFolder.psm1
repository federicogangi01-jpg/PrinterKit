# Modulo scanner: cartella condivisa (PC, Server, NAS) + rubrica della multifunzione (§10).
# Compatibile con PowerShell 2.0 (sulle funzioni SMB moderne c'è il ripiego su net share / icacls).

$script:FileSharingGroup = '@FirewallAPI.dll,-28502'   # "Condivisione file e stampanti", indipendente dalla lingua

function New-PKPassword {
    # Solo lettere e cifre: molte multifunzione rifiutano i simboli nella password SMB.
    param([int]$Length = 16)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    do {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)
        $pw = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    } until ($pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and $pw -match '\d')
    Register-PKSecret $pw
    return $pw
}

function Get-PKEveryoneName {
    # "Everyone" localizzato (Tutti/Jeder/…) a partire dal SID S-1-1-0.
    $sid = New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
    return $sid.Translate([Security.Principal.NTAccount]).Value
}

function ConvertTo-PKUserFolders {
    param([string[]]$Users)
    $out = New-Object System.Collections.ArrayList
    foreach ($u in $Users) {
        $f = ConvertTo-PKFolderName $u
        if ($f -and -not ($out | Where-Object { $_.Folder -ieq $f })) { [void]$out.Add((New-Object PSObject -Property @{ Name = $u.Trim(); Folder = $f })) }
    }
    return ,($out.ToArray())
}

# ---------- Utente tecnico "scanner" ----------

function Test-PKLocalUser {
    param([string]$Name)
    return [bool](Get-WmiObject Win32_UserAccount -Filter ("LocalAccount = TRUE AND Name = '{0}'" -f $Name) -ErrorAction SilentlyContinue)
}

function New-PKLocalScanUser {
    # Crea l'utente se manca. Se esiste già non viene toccato: si usa un nome libero (scanner2, …)
    # oppure la password esistente, se il tecnico la conosce.
    param([string]$Name = 'scanner', [scriptblock]$AskExistingPassword, [switch]$WhatIf)
    $changes = New-Object System.Collections.ArrayList
    if (Test-PKLocalUser $Name) {
        $pw = $null
        if ($AskExistingPassword) { $pw = & $AskExistingPassword $Name }
        if ($pw) { Register-PKSecret $pw; return New-Object PSObject -Property @{ Name = $Name; Password = $pw; Created = $false; Changes = $changes } }
        for ($i = 2; $i -lt 20; $i++) { if (-not (Test-PKLocalUser ($Name + $i))) { $Name = $Name + $i; break } }
    }
    $pw = New-PKPassword
    if ($WhatIf) { Write-PKLog "[prova] creerei l'utente locale $Name"; return New-Object PSObject -Property @{ Name = $Name; Password = $pw; Created = $false; Changes = $changes } }
    $out = & net.exe user $Name $pw /add /active:yes /passwordchg:no /expires:never /comment:"Utente per la scansione su cartella (PrinterKit)" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('creazione utente {0} non riuscita: {1}' -f $Name, (($out | Out-String).Trim())) }
    $acc = Get-WmiObject Win32_UserAccount -Filter ("LocalAccount = TRUE AND Name = '{0}'" -f $Name)
    if ($acc) { $acc.PasswordExpires = $false; [void]$acc.Put() }
    # Nascosto dalla schermata di accesso.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (-not (Test-Path $key)) { [void](New-Item -Path $key -Force) }
    [void](New-ItemProperty -Path $key -Name $Name -Value 0 -PropertyType DWord -Force)
    [void]$changes.Add("utente locale $Name creato (password senza scadenza, non amministratore, nascosto dall'accesso)")
    return New-Object PSObject -Property @{ Name = $Name; Password = $pw; Created = $true; Changes = $changes }
}

# ---------- Cartella e condivisione su questo PC ----------

function New-PKLocalScanShare {
    param([string]$Root = 'C:\Scansioni', [string]$ShareName = 'Scansioni', [object[]]$UserFolders, [string]$ScanUser, [object]$System, [switch]$WhatIf)
    $changes = New-Object System.Collections.ArrayList
    $everyone = Get-PKEveryoneName
    if ($WhatIf) { Write-PKLog "[prova] creerei $Root con $($UserFolders.Count) sottocartelle e la condivisione $ShareName"; return $changes }
    if (-not (Test-Path -LiteralPath $Root)) { [void](New-Item -ItemType Directory -Path $Root -Force); [void]$changes.Add("cartella $Root creata") }
    foreach ($u in $UserFolders) {
        $p = Join-Path $Root $u.Folder
        if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p -Force); [void]$changes.Add("sottocartella $p creata") }
    }
    # Permessi NTFS: Everyone e scanner in Modifica (ereditati dalle sottocartelle).
    $icacls = Join-Path $env:WINDIR 'System32\icacls.exe'
    if (Test-Path $icacls) {
        & $icacls $Root /grant '*S-1-1-0:(OI)(CI)M' | Out-Null
        & $icacls $Root /grant ("{0}\{1}:(OI)(CI)M" -f $env:COMPUTERNAME, $ScanUser) | Out-Null
    } else {
        & cacls.exe $Root /E /T /G ("{0}:C" -f $everyone) ("{0}:C" -f $ScanUser) | Out-Null   # Windows XP
    }
    [void]$changes.Add("permessi NTFS: $everyone e $ScanUser in Modifica su $Root")
    $existing = Get-WmiObject Win32_Share -Filter ("Name = '{0}'" -f $ShareName) -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Path -ne $Root) { throw ("esiste già una condivisione '{0}' su {1}: non la modifico. Scegli un altro nome nel config.json (scanShareName)." -f $ShareName, $existing.Path) }
        Write-PKLog "Condivisione $ShareName già presente su $Root: la riuso"
    } elseif (Get-Command New-SmbShare -ErrorAction SilentlyContinue) {
        [void](New-SmbShare -Name $ShareName -Path $Root -FullAccess $everyone -Description 'Scansioni (PrinterKit)' -ErrorAction Stop)
        [void]$changes.Add("condivisione \\$env:COMPUTERNAME\$ShareName (Everyone: lettura e scrittura)")
    } elseif ([version]$System.Version -ge [version]'6.1') {
        $o = & net.exe share ('{0}={1}' -f $ShareName, $Root) ('/GRANT:{0},FULL' -f $everyone) '/REMARK:Scansioni (PrinterKit)' 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('net share non riuscito: ' + ($o | Out-String)) }
        [void]$changes.Add("condivisione \\$env:COMPUTERNAME\$ShareName (Everyone: lettura e scrittura)")
    } else {
        $o = & net.exe share ('{0}={1}' -f $ShareName, $Root) '/REMARK:Scansioni (PrinterKit)' 2>&1   # XP: Everyone lettura di default
        if ($LASTEXITCODE -ne 0) { throw ('net share non riuscito: ' + ($o | Out-String)) }
        [void]$changes.Add("condivisione \\$env:COMPUTERNAME\$ShareName (XP: permessi di condivisione predefiniti, scrittura dai permessi NTFS)")
    }
    return $changes
}

function Enable-PKFileSharingFirewall {
    param([object]$System, [switch]$WhatIf)
    $changes = New-Object System.Collections.ArrayList
    if ($WhatIf) { return $changes }
    if ([version]$System.Version -lt [version]'6.0') {
        & netsh.exe firewall set service type=FILEANDPRINT mode=ENABLE scope=SUBNET | Out-Null
        [void]$changes.Add('firewall XP: condivisione file e stampanti attivata (solo sottorete)')
        return $changes
    }
    # Regole selezionate per ID risorsa: funziona con Windows in qualsiasi lingua.
    $fw = New-Object -ComObject HNetCfg.FwPolicy2
    $profiles = 0x7FFFFFFF
    if (-not $fw.IsRuleGroupEnabled(2, $script:FileSharingGroup)) {   # 2 = profilo Privato
        $fw.EnableRuleGroup(2, $script:FileSharingGroup, $true)
        [void]$changes.Add('firewall: regole "Condivisione file e stampanti" attivate sul profilo Privato')
    }
    [void]$profiles
    return $changes
}

function Set-PKNetworkPrivate {
    # Porta su Privato le reti Pubbliche connesse (Windows 7+), così il firewall non blocca SMB.
    param([switch]$WhatIf)
    $changes = New-Object System.Collections.ArrayList
    try {
        $nlm = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]'DCB00C01-570F-4A9B-8D69-199FDBA5723B'))
        foreach ($c in $nlm.GetNetworkConnections()) {
            $net = $c.GetNetwork()
            if ($net.GetCategory() -eq 0) {   # 0 = Pubblica, 1 = Privata, 2 = Dominio
                if (-not $WhatIf) { $net.SetCategory(1) }
                [void]$changes.Add(('profilo di rete "{0}" portato da Pubblico a Privato' -f $net.GetName()))
            }
        }
    } catch { Write-PKLog ('Profilo di rete non modificabile: ' + $_.Exception.Message) 'avviso' }
    return $changes
}

function Get-PKDhcpWarning {
    param([string]$IP)
    foreach ($a in (Get-PKLocalAddresses)) {
        if ($a.IP -eq $IP -and $a.Dhcp) {
            return ("Questo PC ha un indirizzo dinamico (DHCP): se cambia, la multifunzione non trova più la cartella. " +
                    "Crea una prenotazione DHCP sul router per l'indirizzo {0} con il MAC {1}." -f $a.IP, $a.Mac)
        }
    }
    return $null
}

# ---------- Collegamenti ----------

function New-PKShortcut {
    param([string]$LinkPath, [string]$Target, [string]$Description = 'Scansioni')
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($LinkPath)
    $lnk.TargetPath = $Target; $lnk.Description = $Description
    $lnk.IconLocation = "$env:WINDIR\System32\shell32.dll,3"
    $lnk.Save()
}

function New-PKShortcutKit {
    # File per gli altri PC dell'ufficio: il collegamento si crea solo sul PC dove gira l'app.
    param([string]$Folder, [string]$Unc)
    New-PKShortcut -LinkPath (Join-Path $Folder 'Collegamento Scansioni.lnk') -Target $Unc
    $bat = @(
        '@echo off',
        'rem Crea sul Desktop il collegamento alla cartella Scansioni (generato da PrinterKit)',
        'set "VBS=%TEMP%\pk_lnk.vbs"',
        '> "%VBS%" echo Set s = CreateObject("WScript.Shell")',
        '>> "%VBS%" echo Set l = s.CreateShortcut(s.SpecialFolders("Desktop") ^& "\Scansioni.lnk")',
        ('>> "%VBS%" echo l.TargetPath = "{0}"' -f $Unc),
        '>> "%VBS%" echo l.IconLocation = "%WINDIR%\System32\shell32.dll,3"',
        '>> "%VBS%" echo l.Save',
        'cscript //nologo "%VBS%"',
        'del "%VBS%"',
        'echo Collegamento "Scansioni" creato sul Desktop.',
        'pause'
    )
    Set-Content -LiteralPath (Join-Path $Folder 'crea_collegamento.bat') -Value $bat -Encoding ASCII
}

# ---------- Verifica scrittura ----------

function Test-PKShareWrite {
    # Scrive e cancella un file di prova in ogni sottocartella con le credenziali di scanner.
    param([string]$Unc, [object[]]$UserFolders, [string]$User, [string]$Password, [switch]$WhatIf)
    if ($WhatIf) { return @{ Ok = $true; Errors = @() } }
    $errors = New-Object System.Collections.ArrayList
    & net.exe use $Unc /delete /y 2>&1 | Out-Null
    $o = & net.exe use $Unc $Password ('/user:' + $User) /persistent:no 2>&1
    if ($LASTEXITCODE -ne 0) {
        [void]$errors.Add(('accesso a {0} con l''utente {1} non riuscito: {2}' -f $Unc, $User, (Protect-PKText (($o | Out-String).Trim()))))
        return @{ Ok = $false; Errors = $errors.ToArray() }
    }
    try {
        foreach ($u in $UserFolders) {
            $f = Join-Path (Join-Path $Unc $u.Folder) ('prova_printerkit_{0}.txt' -f (Get-Random))
            try {
                Set-Content -LiteralPath $f -Value 'prova di scrittura PrinterKit' -ErrorAction Stop
                Remove-Item -LiteralPath $f -Force -ErrorAction Stop
            } catch { [void]$errors.Add(('{0}: {1}' -f $u.Folder, $_.Exception.Message)) }
        }
    } finally { & net.exe use $Unc /delete /y 2>&1 | Out-Null }
    return @{ Ok = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

# ---------- Server Windows (WinRM) ----------

function Find-PKFileServers {
    # Host con SMB (445): Windows Server se risponde anche WinRM (5985), NAS dalle porte di gestione.
    param([string]$Range, [int]$TimeoutMs = 800)
    $hosts = Expand-PKIPRange $Range
    $open = Test-PKTcpPorts -Hosts $hosts -Ports @(445, 5985, 5000, 5001, 8080, 443) -TimeoutMs $TimeoutMs
    $out = New-Object System.Collections.ArrayList
    foreach ($ip in $open.Keys) {
        $p = [int[]]$open[$ip]
        if ($p -notcontains 445) { continue }
        $kind = 'smb'
        if ($p -contains 5985) { $kind = 'server' }
        elseif ($p -contains 5000 -or $p -contains 5001) { $kind = 'synology' }
        elseif ($p -contains 8080) { $kind = 'qnap' }
        $name = ''
        try { $name = [Net.Dns]::GetHostEntry($ip).HostName } catch { }
        [void]$out.Add((New-Object PSObject -Property @{ IP = $ip; Ports = $p; Kind = $kind; Name = $name }))
    }
    return ,($out.ToArray())
}

function Invoke-PKServerShare {
    # Crea cartella, sottocartelle, permessi, condivisione e utente scanner su un Windows Server remoto.
    param([string]$Server, [Management.Automation.PSCredential]$Credential, [object[]]$UserFolders, [string]$ShareName = 'Scansioni', [string]$ScanUser = 'scanner', [switch]$WhatIf)
    try { Test-WSMan -ComputerName $Server -ErrorAction Stop | Out-Null }
    catch { throw ("WinRM non raggiungibile su {0}. Sul server apri PowerShell come amministratore ed esegui: Enable-PSRemoting -Force" -f $Server) }
    $pw = New-PKPassword
    $folders = @($UserFolders | ForEach-Object { $_.Folder })
    $script = {
        param($ShareName, $ScanUser, $Password, $Folders, $WhatIf)
        $changes = @()
        $vol = Get-WmiObject Win32_LogicalDisk -Filter 'DriveType = 3' | Where-Object { $_.DeviceID -ne 'C:' } | Sort-Object FreeSpace -Descending | Select-Object -First 1
        if (-not $vol) { $vol = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID = 'C:'" }
        $root = $vol.DeviceID + '\' + $ShareName
        if ($WhatIf) { return @{ Root = $root; Changes = @('[prova] nessuna modifica'); User = $ScanUser } }
        $existing = Get-WmiObject Win32_Share -Filter ("Name = '{0}'" -f $ShareName)
        if ($existing) { $root = $existing.Path }
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null; $changes += "cartella $root creata" }
        foreach ($f in $Folders) { $p = Join-Path $root $f; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null; $changes += "sottocartella $p creata" } }
        $isDc = (Get-WmiObject Win32_ComputerSystem).DomainRole -ge 4
        $userRef = $ScanUser
        $exists = $false
        if ($isDc) {
            $exists = [bool](Get-WmiObject Win32_UserAccount -Filter ("Name = '{0}'" -f $ScanUser))
            if (-not $exists) { net user $ScanUser $Password /add /domain /passwordchg:no /expires:never | Out-Null; $changes += "utente di dominio $ScanUser creato" }
            $userRef = (Get-WmiObject Win32_ComputerSystem).Domain.Split('.')[0] + '\' + $ScanUser
        } else {
            $exists = [bool](Get-WmiObject Win32_UserAccount -Filter ("LocalAccount = TRUE AND Name = '{0}'" -f $ScanUser))
            if (-not $exists) { net user $ScanUser $Password /add /passwordchg:no /expires:never | Out-Null; $changes += "utente locale $ScanUser creato sul server" }
            $userRef = $env:COMPUTERNAME + '\' + $ScanUser
        }
        $acc = Get-WmiObject Win32_UserAccount -Filter ("Name = '{0}'" -f $ScanUser) | Select-Object -First 1
        if ($acc -and -not $exists) { $acc.PasswordExpires = $false; $acc.Put() | Out-Null }
        icacls $root /grant '*S-1-1-0:(OI)(CI)M' | Out-Null
        icacls $root /grant ($userRef + ':(OI)(CI)M') | Out-Null
        $changes += "permessi NTFS: Everyone e $userRef in Modifica"
        if (-not $existing) {
            $everyone = (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')).Translate([Security.Principal.NTAccount]).Value
            New-SmbShare -Name $ShareName -Path $root -FullAccess $everyone | Out-Null
            $changes += "condivisione \\$env:COMPUTERNAME\$ShareName creata"
        }
        return @{ Root = $root; Changes = $changes; User = $userRef; Existed = $exists }
    }
    $r = Invoke-Command -ComputerName $Server -Credential $Credential -ScriptBlock $script -ArgumentList $ShareName, $ScanUser, $pw, $folders, ([bool]$WhatIf)
    if ($r.Existed) { $pw = $null }
    return New-Object PSObject -Property @{ Root = $r.Root; Changes = $r.Changes; User = $r.User; Password = $pw; UserExisted = $r.Existed }
}

# ---------- NAS (ricette in nas-ricette/) ----------

function Invoke-PKNasShare {
    param([string]$IP, [string]$Kind, [Management.Automation.PSCredential]$Credential, [object[]]$UserFolders, [string]$ShareName,
          [string]$ScanUser, [string]$KitRoot, [scriptblock]$ChooseShare, [scriptblock]$Confirm, [switch]$WhatIf)
    $changes = New-Object System.Collections.ArrayList
    $pw = New-PKPassword
    $adminUser = $Credential.UserName
    $adminPw = $Credential.GetNetworkCredential().Password
    Register-PKSecret $adminPw
    $recipeFile = Join-Path (Join-Path $KitRoot 'nas-ricette') ($Kind + '.json')
    $shareForFolders = $ShareName; $sub = ''
    if (($Kind -eq 'synology' -or $Kind -eq 'qnap') -and (Test-Path -LiteralPath $recipeFile)) {
        $recipe = Read-PKJsonFile $recipeFile
        $vars = @{ ip = $IP; adminUser = $adminUser; adminPassword = $adminPw; share = $ShareName; user = $ScanUser; password = $pw }
        $base = $null
        foreach ($b in @(Get-PKRecipeValue $recipe 'baseUrls' @())) {
            $u = Expand-PKTemplate $b $vars
            Register-PKTrustedHost $IP
            try { [void](Invoke-PKHttp -Url $u -TimeoutMs 6000); $base = $u; break } catch { }
        }
        if (-not $base) { throw "interfaccia di amministrazione del NAS non raggiungibile su $IP" }
        $ctx = New-PKRecipeContext -BaseUrl $base -Vars $vars
        [void](Invoke-PKRecipeSteps (Get-PKRecipeValue $recipe 'login' @()) $ctx)
        if (-not [bool](Get-PKRecipeValue $recipe 'validata' $false) -and -not $WhatIf -and $Confirm) {
            if (-not (& $Confirm ('La ricetta NAS "{0}" non è ancora collaudata su un NAS reale. Procedo con la creazione di cartella e utente?' -f (Get-PKRecipeValue $recipe 'id')))) { throw 'operazione annullata dal tecnico (ricetta NAS non collaudata)' }
        }
        [void](Invoke-PKRecipeSteps (Get-PKRecipeValue $recipe 'createShare' @()) $ctx -DryRun:$WhatIf)
        [void](Invoke-PKRecipeSteps (Get-PKRecipeValue $recipe 'createUser' @()) $ctx -DryRun:$WhatIf)
        [void](Invoke-PKRecipeSteps (Get-PKRecipeValue $recipe 'setPermissions' @()) $ctx -DryRun:$WhatIf)
        [void](Invoke-PKRecipeSteps (Get-PKRecipeValue $recipe 'checkSmb' @()) $ctx -DryRun:$WhatIf)
        [void]$changes.Add("NAS ${IP}: cartella condivisa $ShareName, utente $ScanUser, permessi lettura/scrittura a tutti gli utenti")
    } else {
        # Marca non supportata: si sceglie una condivisione esistente e si crea dentro la cartella Scansioni.
        $shares = Get-PKSmbShares -IP $IP -Credential $Credential
        $chosen = & $ChooseShare $shares
        if (-not $chosen) { throw 'nessuna condivisione scelta' }
        $shareForFolders = $chosen; $sub = $ShareName
        $ScanUser = $adminUser; $pw = $adminPw
        [void]$changes.Add("NAS ${IP}: cartella $ShareName creata nella condivisione esistente $chosen (marca senza API: si usano le credenziali inserite)")
    }
    # Sottocartelle utente via SMB.
    $unc = '\\{0}\{1}' -f $IP, $shareForFolders
    if (-not $WhatIf) {
        & net.exe use $unc /delete /y 2>&1 | Out-Null
        $o = & net.exe use $unc $adminPw ('/user:' + $adminUser) /persistent:no 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('accesso SMB al NAS non riuscito: ' + (Protect-PKText ($o | Out-String))) }
        try {
            $root = $unc; if ($sub) { $root = Join-Path $unc $sub; if (-not (Test-Path $root)) { [void](New-Item -ItemType Directory -Path $root) } }
            foreach ($u in $UserFolders) { $p = Join-Path $root $u.Folder; if (-not (Test-Path $p)) { [void](New-Item -ItemType Directory -Path $p) } }
        } finally { & net.exe use $unc /delete /y 2>&1 | Out-Null }
    }
    $path = $shareForFolders; if ($sub) { $path = $shareForFolders + '\' + $sub }
    return New-Object PSObject -Property @{ Unc = ('\\{0}\{1}' -f $IP, $path); SharePath = $path; User = $ScanUser; Password = $pw; Changes = $changes }
}

function Get-PKSmbShares {
    param([string]$IP, [Management.Automation.PSCredential]$Credential)
    $pw = $Credential.GetNetworkCredential().Password
    & net.exe use ('\\' + $IP + '\IPC$') $pw ('/user:' + $Credential.UserName) /persistent:no 2>&1 | Out-Null
    $out = & net.exe view ('\\' + $IP) /all 2>&1
    & net.exe use ('\\' + $IP + '\IPC$') /delete /y 2>&1 | Out-Null
    $shares = New-Object System.Collections.ArrayList
    $inTable = $false
    foreach ($l in $out) {
        $s = "$l"
        if ($s -match '^-{5,}') { $inTable = $true; continue }
        if ($inTable -and $s -match '^(\S.*?)\s{2,}(Disk|Disco|Datenträger|Disque)') { $n = $matches[1].Trim(); if ($n -notmatch '\$$') { [void]$shares.Add($n) } }
    }
    return ,([string[]]$shares.ToArray())
}

# ---------- SMB1 (§10.6) ----------

function Enable-PKSmb1Server {
    param([object]$System, [switch]$WhatIf)
    if ($WhatIf) { return '[prova] SMB1 non attivato' }
    if (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        [void](Enable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol-Server' -NoRestart -ErrorAction SilentlyContinue)
    }
    if (Get-Command Set-SmbServerConfiguration -ErrorAction SilentlyContinue) { Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force }
    else { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name SMB1 -Value 1 -Type DWord }
    return 'SMB1 attivato sul PC di destinazione (la multifunzione non supporta SMB2/3). Potrebbe servire un riavvio.'
}

# ---------- Multifunzione ----------

function Get-PKAddressEntries {
    # Una voce di rubrica per ogni utente, nel formato percorso richiesto dalla ricetta.
    param([object]$Recipe, [string]$HostIP, [string]$SharePath, [object[]]$UserFolders, [string]$ScanUser, [string]$Password, [string]$Domain)
    $fmt = Get-PKRecipeValue $Recipe 'pathFormat' 'unc'
    $list = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($u in $UserFolders) {
        $i++
        $rel = $SharePath.TrimStart('\') + '\' + $u.Folder
        switch ($fmt) {
            'unc' { $p = '\\' + $HostIP + '\' + $rel }
            'split-backslash' { $p = $rel }
            'split-slash' { $p = '/' + $rel.Replace('\', '/') }
            default { $p = '\\' + $HostIP + '\' + $rel }
        }
        [void]$list.Add(@{
            index = $i; name = $u.Name; host = $HostIP; path = $p; share = $SharePath.Split('\')[0]
            folder = $u.Folder; user = $ScanUser; password = $Password; domain = $Domain; format = 'PDF'
            uncPath = ('\\' + $HostIP + '\' + $rel)
        })
    }
    return ,($list.ToArray())
}

function Invoke-PKMfpConfiguration {
    # Login (una sola prova con la password di fabbrica), backup rubrica, protocolli, voci, verifica.
    param([string]$IP, [string]$Model, [hashtable]$Match, [object[]]$Entries, [string]$OutDir,
          [scriptblock]$AskAdminPassword, [scriptblock]$Confirm, [switch]$WhatIf)
    $recipe = $Match.Recipe
    $changes = New-Object System.Collections.ArrayList
    $def = Get-PKRecipeValue $recipe 'defaultAdmin' @{}
    $vars = @{ ip = $IP; adminUser = (Get-PKRecipeValue $def 'user' 'admin'); adminPassword = (Get-PKRecipeValue $def 'password' '') }
    $ctx = New-PKRecipeContext -BaseUrl $Match.BaseUrl -Vars $vars -OutDir $OutDir
    $loginSteps = @(Get-PKRecipeValue $recipe 'login' @())
    $logged = $false
    try { [void](Invoke-PKRecipeSteps $loginSteps $ctx); $logged = $true; Write-PKLog 'Accesso alla multifunzione con la password di fabbrica' 'ok' }
    catch { Write-PKLog "Password di fabbrica non accettata (un solo tentativo, per non bloccare l'account)" 'avviso' }
    if (-not $logged) {
        $cred = & $AskAdminPassword $vars.adminUser
        if (-not $cred) { throw 'password amministratore della multifunzione non inserita' }
        $vars.adminUser = $cred.User; $vars.adminPassword = $cred.Password
        Register-PKSecret $cred.Password
        $ctx.Cookies = New-Object Net.CookieContainer
        [void](Invoke-PKRecipeSteps $loginSteps $ctx)
        Write-PKLog 'Accesso alla multifunzione riuscito' 'ok'
    }
    if (-not [bool](Get-PKRecipeValue $recipe 'validata' $false) -and -not $WhatIf) {
        $ok = & $Confirm ('La ricetta "{0}" non è ancora stata collaudata su una macchina reale. Il backup della rubrica viene fatto prima. Procedo con la scrittura delle voci?' -f (Get-PKRecipeValue $recipe 'id'))
        if (-not $ok) { throw 'scrittura annullata dal tecnico (ricetta non collaudata)' }
    }
    $backup = Get-PKRecipeValue $recipe 'backup'
    if ($backup) {
        try { [void](Invoke-PKRecipeSteps @($backup) $ctx); [void]$changes.Add('backup della rubrica salvato in ' + $OutDir) }
        catch { Write-PKLog ('Backup della rubrica non riuscito: ' + $_.Exception.Message) 'avviso' }
    }
    # Protocolli (§10.6): si legge lo stato e si attiva solo ciò che manca.
    $read = Get-PKRecipeValue $recipe 'readSettings'
    if ($read) {
        try { [void](Invoke-PKRecipeSteps @($read) $ctx) } catch { Write-PKLog ('Lettura impostazioni non riuscita: ' + $_.Exception.Message) 'avviso' }
    }
    foreach ($p in @(Get-PKRecipeValue $recipe 'protocols' @())) {
        $flag = Get-PKRecipeValue $p 'var'
        $wanted = Get-PKRecipeValue $p 'enabledValue' '1'
        if ($ctx.Vars.ContainsKey($flag) -and "$($ctx.Vars[$flag])" -ne "$wanted") {
            [void](Invoke-PKRecipeSteps @(Get-PKRecipeValue $p 'enable' @()) $ctx -DryRun:$WhatIf)
            [void]$changes.Add(('multifunzione: attivato {0}' -f (Get-PKRecipeValue $p 'name')))
        }
    }
    $addSteps = @(Get-PKRecipeValue $recipe 'addEntry' @())
    $verifySteps = @(Get-PKRecipeValue $recipe 'verify' @())
    foreach ($e in $Entries) {
        foreach ($k in $e.Keys) { $ctx.Vars[$k] = $e[$k] }
        [void](Invoke-PKRecipeSteps $addSteps $ctx -DryRun:$WhatIf)
        if (-not $WhatIf -and $verifySteps.Count -gt 0) { [void](Invoke-PKRecipeSteps $verifySteps $ctx) }
        [void]$changes.Add(('rubrica multifunzione: voce "{0}" -> {1}' -f $e.name, $e.uncPath))
        Write-PKLog ('Voce di rubrica "{0}" creata e verificata' -f $e.name) 'ok'
    }
    $logout = Get-PKRecipeValue $recipe 'logout'
    if ($logout) { try { [void](Invoke-PKRecipeSteps @($logout) $ctx) } catch { } }
    return $changes
}

function Save-PKRecipeRequest {
    # Modello senza ricetta: salva quanto serve per crearla (modello, firmware, struttura delle pagine web).
    param([string]$IP, [string]$Model, [string]$Description, [string]$OutDir)
    $pages = New-Object System.Collections.ArrayList
    foreach ($scheme in @('http', 'https')) {
        Register-PKTrustedHost $IP
        try {
            $r = Invoke-PKHttp -Url ('{0}://{1}/' -f $scheme, $IP) -TimeoutMs 8000
            $links = @([regex]::Matches($r.Body, '(?:href|src|action)\s*=\s*"([^"#]+)"', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique -First 200)
            $title = ''; if ($r.Body -match '<title>([^<]*)</title>') { $title = $matches[1] }
            [void]$pages.Add(@{ scheme = $scheme; status = $r.Status; finalUrl = $r.Url; title = $title; server = "$($r.Headers['Server'])"; links = $links })
        } catch { }
    }
    $data = @{ model = $Model; sysDescr = $Description; ip = $IP; date = (Get-Date -Format 's'); pages = $pages.ToArray() }
    $name = 'richiesta_ricetta_' + (ConvertTo-PKFolderName $Model).Replace(' ', '_') + '.json'
    $file = Join-Path $OutDir $name
    [IO.File]::WriteAllText($file, (ConvertTo-PKJson $data), [Text.Encoding]::UTF8)
    return $file
}

function Wait-PKScanFile {
    # Attende un file nuovo in una delle cartelle (scansione di prova).
    param([string[]]$Folders, [int]$Seconds = 120, [scriptblock]$Tick)
    $before = @{}
    foreach ($f in $Folders) { foreach ($x in @(Get-ChildItem -LiteralPath $f -ErrorAction SilentlyContinue)) { $before[$x.FullName] = $true } }
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        foreach ($f in $Folders) {
            foreach ($x in @(Get-ChildItem -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })) {
                if (-not $before.ContainsKey($x.FullName)) { return $x.FullName }
            }
        }
        if ($Tick) { & $Tick ([int]($end - (Get-Date)).TotalSeconds) }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Write-PKScannerCard {
    # Scheda di intervento: contiene la password di scanner in chiaro, perché servirà per l'assistenza.
    param([string]$Folder, [hashtable]$Info)
    $lines = @(
        '=== PrinterKit - scheda scanner ===',
        ('Data: {0}   PC: {1}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm'), $env:COMPUTERNAME),
        ('Multifunzione: {0} ({1})' -f $Info.Model, $Info.IP),
        ('Destinazione: {0}' -f $Info.Destination),
        ('Cartella condivisa: {0}' -f $Info.Unc),
        ('Utente per la multifunzione: {0}' -f $Info.User),
        ('Password: {0}' -f $Info.Password),
        ('Utenti/voci di rubrica: {0}' -f ([string]::Join(', ', [string[]]$Info.Users))),
        '',
        'Modifiche eseguite:'
    )
    foreach ($c in $Info.Changes) { $lines += ('  - ' + $c) }
    if ($Info.Notes) { $lines += ''; $lines += 'Note:'; foreach ($n in $Info.Notes) { $lines += ('  - ' + $n) } }
    $file = Join-Path $Folder 'scheda_scanner.txt'
    Add-Content -LiteralPath $file -Value $lines -Encoding UTF8
    return $file
}

Export-ModuleMember -Function *-PK*
