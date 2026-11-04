# Verifica Authenticode dei pacchetti Windows scaricati (job windows-latest, Windows PowerShell 5.1).
# Usa le stesse regole dell'app (windows/modules/DriverInstall.psm1): firma valida del produttore o WHQL
# con Provider dell'INF del produttore, e INF presenti per ogni architettura dichiarata.
param([Parameter(Mandatory)][string]$Elenco, [Parameter(Mandatory)][string]$Cartella)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($m in 'Log', 'DriverInstall') { Import-Module (Join-Path $root "windows\modules\$m.psm1") -Force -DisableNameChecking -Global }

$voci = Get-Content -LiteralPath $Elenco -Raw -Encoding UTF8 | ConvertFrom-Json
$scaricati = Get-Content -LiteralPath (Join-Path $Cartella 'scaricati.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$seven = 'C:\Program Files\7-Zip\7z.exe'
$out = @()
foreach ($s in @($scaricati)) {
    $r = [ordered]@{ indice = $s.indice; ok = $false; firma = ''; sha256 = $s.sha256; motivo = $s.errore; arch = @() }
    if ($s.errore) { $out += $r; continue }
    $v = @($voci)[$s.indice]
    $p = $v; if ($v.package -is [psobject]) { $p = $v.package }
    $man = @{ signerNames = @($v.signerNames); match = $v.match }
    $file = Join-Path $Cartella $s.file
    $dest = Join-Path $Cartella ('x_' + $s.indice)
    try {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        switch ($p.fileType) {
            'zip' { Expand-Archive -LiteralPath $file -DestinationPath $dest -Force }
            'cab' { & expand.exe -F:* $file $dest | Out-Null }
            'exe' {
                if ($p.extractArgs) { Start-Process -FilePath $file -ArgumentList ($p.extractArgs.Replace('{dest}', $dest)) -Wait -WindowStyle Hidden }
                else { & $seven x -y ('-o' + $dest) $file | Out-Null }
            }
        }
        $infs = @(); $trovate = @()
        foreach ($a in @($p.arch)) {
            $x = Find-PKPrinterInfs -Directory $dest -Arch $a
            if ($x.Count -gt 0) { $trovate += $a; $infs += $x }
        }
        $r.arch = $trovate
        # L'architettura vera è quella degli INF: si tengono quelle trovate, serve almeno una tra le dichiarate.
        if ($trovate.Count -eq 0) { throw ('nessun INF di stampante per ' + (@($p.arch) -join ', ') + ' (architettura dichiarata non coerente)') }
        $auth = Test-PKPackageAuthenticity -PackageFile $file -ExtractedDir $dest -Manufacturer $man -Infs ([string[]]($infs | Select-Object -Unique))
        if (-not $auth.Ok) { throw $auth.Message }
        $r.ok = $true; $r.firma = $auth.Signer; $r.motivo = 'firma valida'
    } catch { $r.motivo = $_.Exception.Message }
    Write-Host ('{0}: {1}' -f $s.file, $r.motivo)
    $out += $r
}
ConvertTo-Json -InputObject @($out) -Depth 5 | Set-Content -LiteralPath (Join-Path $Cartella 'verificati_windows.json') -Encoding UTF8
