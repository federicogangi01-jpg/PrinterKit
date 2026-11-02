# Porta di rete, coda di stampa, pagina di prova (§7.5). Compatibile con PowerShell 2.0.
# Nessuna azione distruttiva: porte e stampanti esistenti non vengono mai modificate o rimosse.

function Get-PKExistingPrinterByIP {
    # Stampanti già installate che puntano a questo IP (porta TCP/IP o URL IPP/WSD con l'IP).
    param([string]$IP)
    $ports = @{}
    foreach ($p in @(Get-WmiObject Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue)) {
        if ("$($p.HostAddress)" -eq $IP) { $ports[$p.Name.ToLower()] = $true }
    }
    $found = New-Object System.Collections.ArrayList
    $rx = '(^|[^0-9])' + [regex]::Escape($IP) + '([^0-9]|$)'
    foreach ($pr in @(Get-WmiObject Win32_Printer -ErrorAction SilentlyContinue)) {
        $pn = "$($pr.PortName)"
        if ($ports.ContainsKey($pn.ToLower()) -or $pn -match $rx) { [void]$found.Add($pr.Name) }
    }
    return ,([string[]]$found.ToArray())
}

function Test-PKPortExists {
    param([string]$Name)
    return [bool](Get-WmiObject Win32_TCPIPPrinterPort -Filter ("Name = '{0}'" -f $Name.Replace("'", "\'")) -ErrorAction SilentlyContinue)
}

function Test-PKPrinterExists {
    param([string]$Name)
    return [bool](Get-WmiObject Win32_Printer -Filter ("Name = '{0}'" -f $Name.Replace('\', '\\').Replace("'", "\'")) -ErrorAction SilentlyContinue)
}

function Get-PKFreePrinterName {
    # Se il nome è già usato, aggiunge " (2)", " (3)", … senza toccare la stampante esistente.
    param([string]$Name)
    if (-not (Test-PKPrinterExists $Name)) { return $Name }
    for ($i = 2; $i -lt 50; $i++) { $n = '{0} ({1})' -f $Name, $i; if (-not (Test-PKPrinterExists $n)) { return $n } }
    return ($Name + ' ' + (Get-Date -Format 'HHmmss'))
}

function Select-PKPortProtocol {
    # RAW 9100 se aperta, altrimenti LPR (coda lp), altrimenti IPP.
    param([int[]]$OpenPorts)
    if ($OpenPorts -contains 9100) { return 'RAW' }
    if ($OpenPorts -contains 515) { return 'LPR' }
    if ($OpenPorts -contains 631) { return 'IPP' }
    return 'RAW'
}

function New-PKPrinterPort {
    param([string]$IP, [string]$Protocol, [string]$Community = 'public', [object]$System, [switch]$WhatIf)
    $name = 'IP_' + $IP
    if ($Protocol -eq 'IPP') {
        # Porta Internet (client di stampa Internet di Windows): il nome della porta è l'URL.
        $url = 'http://{0}:631/ipp/print' -f $IP
        return New-Object PSObject -Property @{ Name = $url; Description = $url + ' (IPP)'; Created = $false; Protocol = 'IPP' }
    }
    $desc = @{ RAW = 'RAW 9100'; LPR = 'LPR coda lp' }[$Protocol]
    if (Test-PKPortExists $name) {
        Write-PKLog ("Porta $name già presente: la riuso senza modificarla")
        return New-Object PSObject -Property @{ Name = $name; Description = "$name ($desc, già esistente)"; Created = $false; Protocol = $Protocol }
    }
    if ($WhatIf) { Write-PKLog "[prova] creerei la porta $name ($desc)"; return New-Object PSObject -Property @{ Name = $name; Description = "$name ($desc)"; Created = $false; Protocol = $Protocol } }
    if ($System.HasPrintMgmt -and $System.Mode -eq 'main') {
        if ($Protocol -eq 'LPR') { Add-PrinterPort -Name $name -LprHostAddress $IP -LprQueueName 'lp' -LprByteCounting -SNMP 1 -SNMPCommunity $Community -ErrorAction Stop }
        else { Add-PrinterPort -Name $name -PrinterHostAddress $IP -PortNumber 9100 -SNMP 1 -SNMPCommunity $Community -ErrorAction Stop }
    } else {
        # Windows 7 / Vista: WMI (equivalente a prnport.vbs).
        $port = ([wmiclass]'Win32_TCPIPPrinterPort').CreateInstance()
        $port.Name = $name; $port.HostAddress = $IP
        $port.SNMPEnabled = $true; $port.SNMPCommunity = $Community; $port.SNMPDevIndex = 1
        if ($Protocol -eq 'LPR') { $port.Protocol = 2; $port.Queue = 'lp'; $port.ByteCount = $true; $port.PortNumber = 515 }
        else { $port.Protocol = 1; $port.PortNumber = 9100 }
        [void]$port.Put()
    }
    return New-Object PSObject -Property @{ Name = $name; Description = "$name ($desc)"; Created = $true; Protocol = $Protocol }
}

function New-PKPrinterQueue {
    param([string]$Name, [string]$DriverName, [object]$Port, [object]$System, [switch]$WhatIf)
    $Name = Get-PKFreePrinterName $Name
    if ($WhatIf) { Write-PKLog ('[prova] creerei la stampante "{0}" su {1} con "{2}"' -f $Name, $Port.Name, $DriverName); return $Name }
    if ($Port.Protocol -eq 'IPP') {
        $rundll = Join-Path $env:WINDIR 'System32\rundll32.exe'
        $a = ('printui.dll,PrintUIEntry /if /b "{0}" /r "{1}" /m "{2}" /u /q' -f $Name, $Port.Name, $DriverName)
        [void](Start-Process -FilePath $rundll -ArgumentList $a -Wait -PassThru)
        Start-Sleep -Seconds 2
        if (-not (Test-PKPrinterExists $Name)) { throw 'creazione con porta IPP non riuscita (serve la funzionalità "Client di stampa Internet" di Windows)' }
        return $Name
    }
    if ($System.HasPrintMgmt -and $System.Mode -eq 'main') {
        Add-Printer -Name $Name -DriverName $DriverName -PortName $Port.Name -ErrorAction Stop
    } else {
        $p = ([wmiclass]'Win32_Printer').CreateInstance()
        $p.Name = $Name; $p.DeviceID = $Name; $p.DriverName = $DriverName; $p.PortName = $Port.Name
        $p.Network = $true; $p.Shared = $false
        [void]$p.Put()
    }
    if (-not (Test-PKPrinterExists $Name)) { throw 'la stampante non risulta creata' }
    return $Name
}

function Send-PKTestPage {
    param([string]$Name, [switch]$WhatIf)
    if ($WhatIf) { Write-PKLog "[prova] invierei la pagina di prova a $Name"; return 'non inviata (prova)' }
    $pr = Get-WmiObject Win32_Printer -Filter ("Name = '{0}'" -f $Name.Replace('\', '\\').Replace("'", "\'"))
    if (-not $pr) { return 'non inviata (stampante non trovata)' }
    $r = $pr.PrintTestPage()
    if ($r.ReturnValue -eq 0) { return 'inviata' }
    # Ripiego: pagina di prova tramite printui.
    $rundll = Join-Path $env:WINDIR 'System32\rundll32.exe'
    [void](Start-Process -FilePath $rundll -ArgumentList ('printui.dll,PrintUIEntry /k /n "{0}"' -f $Name) -Wait -PassThru)
    return 'inviata (printui)'
}

function Set-PKDefaultPrinter {
    param([string]$Name, [switch]$WhatIf)
    if ($WhatIf) { return $false }
    $pr = Get-WmiObject Win32_Printer -Filter ("Name = '{0}'" -f $Name.Replace('\', '\\').Replace("'", "\'"))
    if (-not $pr) { return $false }
    # Windows 10/11 gestisce da solo la predefinita: va disattivato solo per l'utente corrente.
    try { Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name 'LegacyDefaultPrinterMode' -Value 1 -Type DWord -ErrorAction SilentlyContinue } catch { }
    return ($pr.SetDefaultPrinter().ReturnValue -eq 0)
}

Export-ModuleMember -Function *-PK*
