# Rilevamento sistema operativo, architettura e capacità (§6). Compatibile con PowerShell 2.0.

function Get-PKArchitecture {
    # PROCESSOR_ARCHITEW6432 è valorizzata quando un processo a 32 bit gira su Windows a 64 bit.
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    return (ConvertTo-PKArch $a)
}

function ConvertTo-PKArch {
    param([string]$Raw)
    switch -regex ("$Raw".ToUpper()) {
        '^(AMD64|X64|X86_64|EM64T)$' { return 'x64' }
        '^ARM64$' { return 'arm64' }
        '^(X86|I386|I686)$' { return 'x86' }
        default { return "$Raw".ToLower() }
    }
}

function Get-PKWindowsName {
    param([string]$Version, [int]$Build)
    $v = [version]$Version
    if ($v.Major -eq 10) { if ($Build -ge 22000) { return 'Windows 11' } else { return 'Windows 10' } }
    switch ('{0}.{1}' -f $v.Major, $v.Minor) {
        '6.3' { return 'Windows 8.1' }
        '6.2' { return 'Windows 8' }
        '6.1' { return 'Windows 7' }
        '6.0' { return 'Windows Vista' }
        '5.2' { return 'Windows XP x64' }
        '5.1' { return 'Windows XP' }
    }
    return ('Windows ' + $Version)
}

function Test-PKTls12 {
    # Tentativo reale di connessione TLS 1.2 (non basta che l'enum esista).
    param([string]$TestUrl = 'https://raw.githubusercontent.com/')
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { return $false }
    try {
        $req = [Net.HttpWebRequest]::Create($TestUrl)
        $req.Method = 'HEAD'
        $req.Timeout = 8000
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        # Una risposta HTTP (anche 4xx) significa che l'handshake TLS è riuscito.
        # Le eccezioni .NET arrivano avvolte in MethodInvocationException.
        $ex = $_.Exception
        while ($ex) {
            if ($ex -is [Net.WebException] -and $ex.Response) { return $true }
            $ex = $ex.InnerException
        }
        return $false
    }
}

function Get-PKSystemInfo {
    param([switch]$SkipNetworkTest)
    $os = Get-WmiObject Win32_OperatingSystem
    $version = $os.Version            # es. 6.1.7601
    $parts = $version.Split('.')
    $short = '{0}.{1}' -f $parts[0], $parts[1]
    $build = [int]$os.BuildNumber
    $arch = Get-PKArchitecture
    $name = Get-PKWindowsName -Version $short -Build $build
    $sp = [int]$os.ServicePackMajorVersion
    $label = $name
    if ($sp -gt 0) { $label += (' SP' + $sp) }
    $bits = @{ x64 = '64 bit'; x86 = '32 bit'; arm64 = 'ARM64' }[$arch]
    if (-not $bits) { $bits = $arch }
    $label += (' - ' + $bits)
    $hasPrintMgmt = [bool](Get-Command Add-Printer -ErrorAction SilentlyContinue)
    $pnputil = Join-Path $env:WINDIR 'System32\pnputil.exe'
    $pnp = 'none'
    if (Test-Path -LiteralPath $pnputil) {
        if ([version]$short -ge [version]'10.0' -and $build -ge 14393) { $pnp = 'new' } else { $pnp = 'old' }
    }
    $tls = $null
    if (-not $SkipNetworkTest) { $tls = Test-PKTls12 }
    $mode = 'main'
    if ($PSVersionTable.PSVersion.Major -lt 5 -or [version]$short -lt [version]'6.3' -or -not $hasPrintMgmt) { $mode = 'compat' }
    return New-Object PSObject -Property @{
        Family        = 'windows'
        Name          = $name
        Caption       = $os.Caption
        Version       = $short
        FullVersion   = $version
        Build         = $build
        ServicePack   = $sp
        Arch          = $arch
        Label         = $label
        LogLabel      = ('{0} ({1})' -f $label.Replace(' - ', ' '), $version)
        PSVersion     = $PSVersionTable.PSVersion.ToString()
        HasPrintMgmt  = $hasPrintMgmt
        PnpUtil       = $pnp
        Tls12         = $tls
        Mode          = $mode
        ComputerName  = $env:COMPUTERNAME
        OsTag         = (ConvertTo-PKOsTag -Version $short -Build $build)
    }
}

function ConvertTo-PKOsTag {
    # Etichetta usata in pagine_ufficiali.json (windows-11, windows-7, …).
    param([string]$Version, [int]$Build)
    $v = [version]$Version
    if ($v.Major -eq 10) { if ($Build -ge 22000) { return 'windows-11' } else { return 'windows-10' } }
    if ($v -ge [version]'6.3') { return 'windows-8.1' }
    if ($v -ge [version]'6.1') { return 'windows-7' }
    return 'windows-xp'
}

function Test-PKAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function *-PK*
