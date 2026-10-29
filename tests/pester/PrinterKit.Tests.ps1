# Test unitari Pester 5 (eseguiti dal workflow "valida" su windows-latest).
BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    foreach ($m in 'Log', 'SystemInfo', 'Discovery', 'Catalog', 'DriverInstall', 'RecipeEngine') {
        Import-Module (Join-Path $root "windows\modules\$m.psm1") -Force -DisableNameChecking
    }
    $fixtures = Join-Path $root 'tests\fixtures'
    $catalog = Read-PKJsonFile (Join-Path $fixtures 'drivers-esempio.json')
    function Sys($ver, $build, $arch) { New-Object PSObject -Property @{ Family = 'windows'; Name = 'Windows'; Version = $ver; Build = $build; Arch = $arch } }
}

Describe 'Intervalli IP' {
    It 'espande 192.168.1.1-5' { (Expand-PKIPRange '192.168.1.1-5') | Should -Be @('192.168.1.1', '192.168.1.2', '192.168.1.3', '192.168.1.4', '192.168.1.5') }
    It 'espande una /24 escludendo rete e broadcast' {
        $r = Expand-PKIPRange '10.0.0.0/24'
        $r.Count | Should -Be 254; $r[0] | Should -Be '10.0.0.1'; $r[-1] | Should -Be '10.0.0.254'
    }
    It 'accetta IP singoli separati da virgola senza duplicati' { (Expand-PKIPRange '192.168.1.50, 192.168.1.51,192.168.1.50').Count | Should -Be 2 }
    It 'accetta intervalli completi' { (Expand-PKIPRange '192.168.1.250-192.168.2.3').Count | Should -Be 10 }
    It 'rifiuta input non valido' { { Expand-PKIPRange '192.168.1' } | Should -Throw; { Expand-PKIPRange '192.168.1.300' } | Should -Throw }
}

Describe 'SNMP (BER)' {
    It 'codifica e decodifica un OID' {
        $b = ConvertTo-PKBerOid '1.3.6.1.2.1.25.3.2.1.3.1'
        ConvertFrom-PKBerOid $b | Should -Be '1.3.6.1.2.1.25.3.2.1.3.1'
        ConvertFrom-PKBerOid (ConvertTo-PKBerOid '1.3.6.1.4.1.1347.43.5.1.1.1') | Should -Be '1.3.6.1.4.1.1347.43.5.1.1.1'
    }
    It 'costruisce una GetRequest v2c corretta' {
        $p = New-PKSnmpRequest -Community 'public' -Oids @('1.3.6.1.2.1.1.1.0') -RequestId 1
        ([BitConverter]::ToString($p)) | Should -Be '30-26-02-01-01-04-06-70-75-62-6C-69-63-A0-19-02-01-01-02-01-00-02-01-00-30-0E-30-0C-06-08-2B-06-01-02-01-01-01-00-05-00'
    }
    It 'legge una risposta con OCTET STRING' {
        $model = [Text.Encoding]::ASCII.GetBytes('ECOSYS M2540dn')
        $vb = New-PKBerTlv 0x30 ([byte[]]((New-PKBerTlv 0x06 (ConvertTo-PKBerOid '1.3.6.1.2.1.25.3.2.1.3.1')) + (New-PKBerTlv 0x04 $model)))
        $pdu = New-PKBerTlv 0xA2 ([byte[]]((New-PKBerTlv 0x02 ([byte[]]@(7))) + (New-PKBerTlv 0x02 ([byte[]]@(0))) + (New-PKBerTlv 0x02 ([byte[]]@(0))) + (New-PKBerTlv 0x30 $vb)))
        $msg = New-PKBerTlv 0x30 ([byte[]]((New-PKBerTlv 0x02 ([byte[]]@(1))) + (New-PKBerTlv 0x04 ([Text.Encoding]::ASCII.GetBytes('public'))) + $pdu))
        $v = Get-PKSnmpVarbinds $msg
        $v[0].Oid | Should -Be '1.3.6.1.2.1.25.3.2.1.3.1'
        $v[0].Value | Should -Be 'ECOSYS M2540dn'
    }
    It 'gestisce lunghezze lunghe (0x81)' { (ConvertTo-PKBerLength 200) | Should -Be @(0x81, 200) }
    It 'traduce i linguaggi della stampante' { ConvertTo-PKLanguages @(47, 6, 3) | Should -Be @('pcl6', 'ps', 'pcl5') }
}

Describe 'Parser INF' {
    It 'legge i modelli NTamd64 risolvendo [Strings]' {
        $n = Get-PKInfModelNames (Join-Path $fixtures 'inf\64bit\OEMSETUP.INF') 'x64'
        $n | Should -Contain 'Kyocera ECOSYS M2540dn KX'
        $n | Should -Contain 'Kyocera Classic Universaldriver PCL6'
        $n | Should -Contain 'Kyocera TASKalfa 2553ci KX'
    }
    It 'legge i modelli non decorati per x86' { Get-PKInfModelNames (Join-Path $fixtures 'inf\32bit\OEMSETUP.INF') 'x86' | Should -Be @('Kyocera ECOSYS M2540dn KX (32)') }
    It 'scarta gli INF non di stampante e le cartelle dell''altra architettura' {
        $f = Find-PKPrinterInfs (Join-Path $fixtures 'inf') 'x64'
        $f.Count | Should -Be 1
        $f[0] | Should -Match '64bit\\OEMSETUP.INF$'
    }
    It 'ordina i candidati: codice modello prima di PCL6 e Universal' {
        $c = Get-PKDriverNameCandidates -Names @('Kyocera Classic Universaldriver PCL6', 'Kyocera ECOSYS M2540dn KPDL', 'Kyocera ECOSYS M2540dn KX') -Model 'ECOSYS M2540dn'
        $c[0] | Should -Match 'M2540dn'
        $c[-1] | Should -Be 'Kyocera Classic Universaldriver PCL6'
    }
}

Describe 'Scelta del pacchetto' {
    BeforeAll { $kyo = Find-PKManufacturer $catalog 'KYOCERA ECOSYS M2540dn' '' }
    It 'riconosce la marca dalla regex' { Get-PKField $kyo 'id' | Should -Be 'kyocera' }
    It 'preferisce il pacchetto specifico per modello' {
        (Get-PKField (Select-PKDriverPackage $kyo (Sys '10.0' 22631 'x64') 'ECOSYS M2540dn').Package 'id') | Should -Be 'kyocera-m2540-win'
    }
    It 'tra gli universali sceglie la versione più recente' {
        (Get-PKField (Select-PKDriverPackage $kyo (Sys '10.0' 19045 'x64') 'ECOSYS P2235dn').Package 'id') | Should -Be 'kyocera-kx-win-x64'
    }
    It 'Windows 7 usa il pacchetto con osMax 6.3' {
        (Get-PKField (Select-PKDriverPackage $kyo (Sys '6.1' 7601 'x86') 'ECOSYS P2235dn').Package 'id') | Should -Be 'kyocera-kx-win7'
    }
    It 'nessun ripiego: XP 64 bit senza driver ufficiale' {
        $r = Select-PKDriverPackage $kyo (Sys '5.2' 3790 'x64') 'ECOSYS P2235dn'
        $r.Package | Should -BeNullOrEmpty
        $r.Reason | Should -Match 'non offre un driver Kyocera ufficiale'
    }
    It 'nessun driver per ARM64 se il catalogo non lo prevede' {
        $r = Select-PKDriverPackage $kyo (Sys '10.0' 22631 'arm64') 'ECOSYS P2235dn'
        $r.Package | Should -BeNullOrEmpty
        $r.Reason | Should -Be 'Nessun driver Kyocera ufficiale per Windows ARM64'
    }
    It 'scarta i linguaggi che la stampante non ha' {
        $ricoh = Find-PKManufacturer $catalog 'RICOH IM C3000' ''
        (Get-PKField (Select-PKDriverPackage $ricoh (Sys '10.0' 22631 'x64') 'IM C3000' @('ps')).Package 'id') | Should -Be 'ricoh-ps-up'
        (Get-PKField (Select-PKDriverPackage $ricoh (Sys '10.0' 22631 'x64') 'IM C3000' @('pcl6', 'ps')).Package 'id') | Should -Be 'ricoh-pcl6-up'
    }
    It 'confronta le versioni' { Compare-PKVersion '8.4.1716' '8.10' | Should -Be -1; Compare-PKVersion '10.0' '6.3' | Should -Be 1 }
    It 'riconosce i domini ufficiali' {
        Test-PKOfficialDomain 'https://cdn.kyostatics.net/a.zip' @('kyostatics.net') | Should -BeTrue
        Test-PKOfficialDomain 'https://kyostatics.net.evil.io/a.zip' @('kyostatics.net') | Should -BeFalse
        Test-PKOfficialDomain 'http://kyostatics.net/a.zip' @('kyostatics.net') | Should -BeFalse
    }
    It 'valida il catalogo di esempio e quello reale' {
        (Test-PKCatalog $catalog).Count | Should -Be 0
        (Test-PKCatalog (Read-PKJsonFile (Join-Path $root 'catalogo\drivers.json'))).Count | Should -Be 0
    }
}

Describe 'Nome cartella del log' {
    It 'Driver <Marca> <Modello> senza ripetere la marca' { Get-PKInterventionFolderName 'Kyocera' 'KYOCERA ECOSYS M2540dn' '1.2.3.4' | Should -Be 'Driver KYOCERA ECOSYS M2540dn' }
    It 'aggiunge la marca se manca' { Get-PKInterventionFolderName 'Kyocera' 'ECOSYS M2540dn' '1.2.3.4' | Should -Be 'Driver Kyocera ECOSYS M2540dn' }
    It 'usa l''IP se il modello è sconosciuto' { Get-PKInterventionFolderName '' '' '192.168.1.50' | Should -Be 'Driver 192.168.1.50' }
    It 'ripulisce i caratteri non validi' { ConvertTo-PKFolderName 'HP LaserJet M404/M405 "Pro": *' | Should -Be 'HP LaserJet M404 M405 Pro' }
    It 'maschera i segreti nel log' { Register-PKSecret 'Segreta123'; Protect-PKText 'pw=Segreta123' | Should -Be 'pw=********' }
}

Describe 'Ricette' {
    It 'sostituisce i segnaposto con escape' {
        Expand-PKTemplate 'a={{x}}&b={{y}}' @{ x = 'Mario Rossi'; y = '1' } 'url' | Should -Be 'a=Mario%20Rossi&b=1'
        Expand-PKTemplate '<n>{{x}}</n>' @{ x = 'A&B' } 'xml' | Should -Be '<n>A&amp;B</n>'
    }
    It 'le ricette di Sharp e Kyocera si leggono e riconoscono il modello' {
        $k = Read-PKRecipes -Folder (Join-Path $root 'scanner-ricette') -Brand 'kyocera'
        $k.Count | Should -BeGreaterThan 0
        'ECOSYS M2540dn' | Should -Match (Get-PKRecipeValue $k[0] 'modelMatch')
        $s = Read-PKRecipes -Folder (Join-Path $root 'scanner-ricette') -Brand 'sharp'
        'SHARP MX-3071' | Should -Match (Get-PKRecipeValue $s[0] 'modelMatch')
    }
}
