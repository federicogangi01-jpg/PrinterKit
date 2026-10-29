# Scansione rete, SNMP minimale (BER) e IPP (§7.1, §7.2). Compatibile con PowerShell 2.0
# (niente -shl/-shr, niente ::new, niente [pscustomobject]).

# ---------- Indirizzi IP ----------

function ConvertTo-PKIPNumber {
    param([string]$IP)
    $o = $IP.Trim().Split('.')
    if ($o.Count -ne 4) { throw "Indirizzo IP non valido: $IP" }
    $n = [int64]0
    foreach ($x in $o) {
        $v = 0
        if (-not [int]::TryParse($x, [ref]$v) -or $v -lt 0 -or $v -gt 255) { throw "Indirizzo IP non valido: $IP" }
        $n = $n * 256 + $v
    }
    return $n
}

function ConvertFrom-PKIPNumber {
    param([int64]$Number)
    $a = [math]::Floor($Number / 16777216) % 256
    $b = [math]::Floor($Number / 65536) % 256
    $c = [math]::Floor($Number / 256) % 256
    $d = $Number % 256
    return ('{0}.{1}.{2}.{3}' -f $a, $b, $c, $d)
}

function Expand-PKIPRange {
    # Formati: 192.168.1.1-254 | 192.168.1.10-192.168.1.20 | 192.168.1.0/24 | IP singoli separati da virgola.
    param([string]$Range, [int]$MaxHosts = 4096)
    $seen = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($part in ($Range -split '[,;\s]+')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        $start = $null; $end = $null
        if ($p -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
            $bits = [int]$matches[2]
            if ($bits -lt 16 -or $bits -gt 32) { throw "Maschera /$bits non ammessa (usa da /16 a /32)" }
            $size = [int64][math]::Pow(2, 32 - $bits)
            $base = (ConvertTo-PKIPNumber $matches[1])
            $base = $base - ($base % $size)
            if ($bits -le 30) { $start = $base + 1; $end = $base + $size - 2 } else { $start = $base; $end = $base + $size - 1 }
        } elseif ($p -match '^(\d{1,3}(?:\.\d{1,3}){3})-(\d{1,3}(?:\.\d{1,3}){3})$') {
            $start = ConvertTo-PKIPNumber $matches[1]; $end = ConvertTo-PKIPNumber $matches[2]
        } elseif ($p -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.(\d{1,3})-(\d{1,3})$') {
            $start = ConvertTo-PKIPNumber ($matches[1] + '.' + $matches[2])
            $end = ConvertTo-PKIPNumber ($matches[1] + '.' + $matches[3])
        } elseif ($p -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
            $start = ConvertTo-PKIPNumber $p; $end = $start
        } else {
            throw "Intervallo non riconosciuto: '$p'. Esempi: 192.168.1.1-254, 192.168.1.0/24, 192.168.1.50"
        }
        if ($end -lt $start) { throw "Intervallo al contrario: '$p'" }
        for ($n = $start; $n -le $end; $n++) {
            if ($list.Count -ge $MaxHosts) { throw "Troppi indirizzi (massimo $MaxHosts)" }
            $ip = ConvertFrom-PKIPNumber $n
            if (-not $seen.ContainsKey($ip)) { $seen[$ip] = $true; [void]$list.Add($ip) }
        }
    }
    return ,([string[]]$list.ToArray())
}

function Test-PKUsableIPv4 {
    param([string]$IP)
    if ($IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    if ($IP -match '^(127\.|169\.254\.|0\.)') { return $false }
    return $true
}

function Get-PKLocalRanges {
    # La /24 di ogni scheda di rete attiva (escluse 127.x e 169.254.x).
    $ranges = New-Object System.Collections.ArrayList
    $adapters = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE'
    foreach ($a in $adapters) {
        foreach ($ip in @($a.IPAddress)) {
            if (Test-PKUsableIPv4 $ip) {
                $o = $ip.Split('.')
                $r = '{0}.{1}.{2}.1-254' -f $o[0], $o[1], $o[2]
                if (-not $ranges.Contains($r)) { [void]$ranges.Add($r) }
            }
        }
    }
    return ,([string[]]$ranges.ToArray())
}

function Get-PKLocalAddresses {
    # Indirizzi IPv4 del PC, con MAC e DHCP (serve al modulo scanner, §10.1.2).
    $out = New-Object System.Collections.ArrayList
    foreach ($a in (Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE')) {
        foreach ($ip in @($a.IPAddress)) {
            if (Test-PKUsableIPv4 $ip) {
                [void]$out.Add((New-Object PSObject -Property @{
                    IP = $ip; Mac = $a.MACAddress; Dhcp = [bool]$a.DHCPEnabled
                    Gateway = (@($a.DefaultIPGateway) | Select-Object -First 1); Description = $a.Description
                }))
            }
        }
    }
    return ,($out.ToArray())
}

# ---------- Porte TCP ----------

function Test-PKTcpPorts {
    # Connessioni TCP asincrone in parallelo, lotti da massimo 256 host.
    param([string[]]$Hosts, [int[]]$Ports = @(9100, 631, 515), [int]$TimeoutMs = 1000, [scriptblock]$Progress)
    $result = @{}
    $batchSize = 256
    for ($i = 0; $i -lt $Hosts.Count; $i += $batchSize) {
        $batch = $Hosts[$i..([math]::Min($i + $batchSize, $Hosts.Count) - 1)]
        $pending = New-Object System.Collections.ArrayList
        foreach ($h in $batch) {
            foreach ($port in $Ports) {
                $c = New-Object System.Net.Sockets.TcpClient
                try {
                    $ar = $c.BeginConnect($h, $port, $null, $null)
                    [void]$pending.Add(@{ Host = $h; Port = $port; Client = $c; Async = $ar })
                } catch { $c.Close() }
            }
        }
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ((Get-Date) -lt $deadline) {
            $allDone = $true
            foreach ($p in $pending) { if (-not $p.Async.IsCompleted) { $allDone = $false; break } }
            if ($allDone) { break }
            Start-Sleep -Milliseconds 50
            if ($Progress) { & $Progress $i $Hosts.Count }
        }
        foreach ($p in $pending) {
            $ok = $false
            if ($p.Async.IsCompleted) {
                try { $p.Client.EndConnect($p.Async); $ok = $p.Client.Connected } catch { $ok = $false }
            }
            try { $p.Client.Close() } catch { }
            if ($ok) {
                if (-not $result.ContainsKey($p.Host)) { $result[$p.Host] = New-Object System.Collections.ArrayList }
                [void]$result[$p.Host].Add($p.Port)
            }
        }
        if ($Progress) { & $Progress ([math]::Min($i + $batchSize, $Hosts.Count)) $Hosts.Count }
    }
    return $result
}

function Test-PKTcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 1500)
    $r = Test-PKTcpPorts -Hosts @($HostName) -Ports @($Port) -TimeoutMs $TimeoutMs
    return $r.ContainsKey($HostName)
}

# ---------- BER / SNMP ----------

function ConvertTo-PKBerLength {
    param([int]$Length)
    if ($Length -lt 128) { return ,([byte[]]@($Length)) }
    if ($Length -lt 256) { return ,([byte[]]@(0x81, $Length)) }
    return ,([byte[]]@(0x82, [math]::Floor($Length / 256), ($Length % 256)))
}

function New-PKBerTlv {
    param([int]$Tag, [byte[]]$Content)
    if ($null -eq $Content) { $Content = [byte[]]@() }
    $out = New-Object 'System.Collections.Generic.List[byte]'
    $out.Add([byte]$Tag)
    $out.AddRange([byte[]](ConvertTo-PKBerLength $Content.Length))
    $out.AddRange($Content)
    return ,($out.ToArray())
}

function ConvertTo-PKBerInteger {
    param([int64]$Value)
    if ($Value -lt 0) { throw 'Interi negativi non supportati' }
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    do { $bytes.Insert(0, [byte]($Value % 256)); $Value = [math]::Floor($Value / 256) } while ($Value -gt 0)
    if ($bytes[0] -ge 0x80) { $bytes.Insert(0, [byte]0) }
    return ,($bytes.ToArray())
}

function ConvertTo-PKBerOid {
    param([string]$Oid)
    $n = $Oid.Trim('.').Split('.') | ForEach-Object { [int64]$_ }
    if ($n.Count -lt 2) { throw "OID non valido: $Oid" }
    $out = New-Object 'System.Collections.Generic.List[byte]'
    $out.Add([byte](40 * $n[0] + $n[1]))
    for ($i = 2; $i -lt $n.Count; $i++) {
        $v = $n[$i]
        $chunk = New-Object 'System.Collections.Generic.List[byte]'
        $chunk.Add([byte]($v % 128))
        $v = [math]::Floor($v / 128)
        while ($v -gt 0) { $chunk.Insert(0, [byte](($v % 128) + 128)); $v = [math]::Floor($v / 128) }
        $out.AddRange($chunk)
    }
    return ,($out.ToArray())
}

function ConvertFrom-PKBerOid {
    param([byte[]]$Bytes)
    if ($Bytes.Length -eq 0) { return '' }
    $first = $Bytes[0]
    $a = [math]::Min([math]::Floor($first / 40), 2)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add($a); [void]$parts.Add($first - 40 * $a)
    $v = [int64]0
    for ($i = 1; $i -lt $Bytes.Length; $i++) {
        $b = $Bytes[$i]
        $v = $v * 128 + ($b % 128)
        if ($b -lt 128) { [void]$parts.Add($v); $v = 0 }
    }
    return [string]::Join('.', [string[]]($parts | ForEach-Object { "$_" }))
}

function New-PKSnmpRequest {
    # GetRequest (0xA0) o GetNextRequest (0xA1). Version: 0 = v1, 1 = v2c.
    param([string]$Community = 'public', [string[]]$Oids, [int]$RequestId = 1, [int]$PduType = 0xA0, [int]$Version = 1)
    $vbs = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($o in $Oids) {
        $vb = New-Object 'System.Collections.Generic.List[byte]'
        $vb.AddRange([byte[]](New-PKBerTlv 0x06 (ConvertTo-PKBerOid $o)))
        $vb.AddRange([byte[]](New-PKBerTlv 0x05 $null))
        $vbs.AddRange([byte[]](New-PKBerTlv 0x30 $vb.ToArray()))
    }
    $pdu = New-Object 'System.Collections.Generic.List[byte]'
    $pdu.AddRange([byte[]](New-PKBerTlv 0x02 (ConvertTo-PKBerInteger $RequestId)))
    $pdu.AddRange([byte[]](New-PKBerTlv 0x02 (ConvertTo-PKBerInteger 0)))
    $pdu.AddRange([byte[]](New-PKBerTlv 0x02 (ConvertTo-PKBerInteger 0)))
    $pdu.AddRange([byte[]](New-PKBerTlv 0x30 $vbs.ToArray()))
    $msg = New-Object 'System.Collections.Generic.List[byte]'
    $msg.AddRange([byte[]](New-PKBerTlv 0x02 (ConvertTo-PKBerInteger $Version)))
    $msg.AddRange([byte[]](New-PKBerTlv 0x04 ([Text.Encoding]::ASCII.GetBytes($Community))))
    $msg.AddRange([byte[]](New-PKBerTlv $PduType $pdu.ToArray()))
    return ,([byte[]](New-PKBerTlv 0x30 $msg.ToArray()))
}

function Read-PKBerNodes {
    # Decodifica TLV in un albero: ogni nodo ha Tag, Value (byte) e Children (per i tipi costruiti).
    param([byte[]]$Data, [int]$Offset = 0, [int]$End = -1)
    if ($End -lt 0) { $End = $Data.Length }
    $nodes = New-Object System.Collections.ArrayList
    $i = $Offset
    while ($i -lt $End) {
        $tag = $Data[$i]; $i++
        if ($i -ge $End) { throw 'BER troncato' }
        $len = [int]$Data[$i]; $i++
        if ($len -ge 0x80) {
            $nb = $len - 0x80; $len = 0
            for ($k = 0; $k -lt $nb; $k++) { $len = $len * 256 + $Data[$i]; $i++ }
        }
        if ($i + $len -gt $End) { throw 'BER: lunghezza oltre la fine del messaggio' }
        $value = New-Object byte[] $len
        if ($len -gt 0) { [Array]::Copy($Data, $i, $value, 0, $len) }
        $children = $null
        # Tipi costruiti: SEQUENCE (0x30) e PDU SNMP (0xA0-0xA8).
        if ($tag -eq 0x30 -or ($tag -ge 0xA0 -and $tag -le 0xA8)) { $children = Read-PKBerNodes -Data $Data -Offset $i -End ($i + $len) }
        [void]$nodes.Add((New-Object PSObject -Property @{ Tag = [int]$tag; Value = $value; Children = $children }))
        $i += $len
    }
    return ,($nodes.ToArray())
}

function ConvertFrom-PKBerValue {
    param([object]$Node)
    switch ($Node.Tag) {
        0x04 {
            $b = $Node.Value
            # Alcune stampanti terminano la stringa con zeri.
            $s = [Text.Encoding]::UTF8.GetString($b).TrimEnd([char]0)
            return $s.Trim()
        }
        0x06 { return ConvertFrom-PKBerOid $Node.Value }
        { $_ -eq 0x02 -or $_ -eq 0x41 -or $_ -eq 0x42 -or $_ -eq 0x43 } {
            $v = [int64]0; foreach ($x in $Node.Value) { $v = $v * 256 + $x }; return $v
        }
        0x40 { return [string]::Join('.', [string[]]($Node.Value | ForEach-Object { "$_" })) }
        default { return $null }   # NULL, noSuchObject (0x80), noSuchInstance (0x81), endOfMibView (0x82)
    }
}

function Get-PKSnmpVarbinds {
    param([byte[]]$Response)
    $root = Read-PKBerNodes $Response
    $msg = $root[0].Children
    $pdu = $msg[2]
    $errorStatus = ConvertFrom-PKBerValue $pdu.Children[1]
    $list = New-Object System.Collections.ArrayList
    foreach ($vb in $pdu.Children[3].Children) {
        $oid = ConvertFrom-PKBerValue $vb.Children[0]
        $valNode = $vb.Children[1]
        [void]$list.Add((New-Object PSObject -Property @{
            Oid = $oid; Tag = $valNode.Tag; Value = (ConvertFrom-PKBerValue $valNode); ErrorStatus = $errorStatus
        }))
    }
    return ,($list.ToArray())
}

function Invoke-PKSnmpRaw {
    param([string]$IP, [byte[]]$Packet, [int]$TimeoutMs = 1500)
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        [void]$udp.Send($Packet, $Packet.Length, $IP, 161)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        return ,($udp.Receive([ref]$ep))
    } catch { return $null } finally { $udp.Close() }
}

function Invoke-PKSnmpGet {
    param([string]$IP, [string[]]$Oids, [string]$Community = 'public', [int]$TimeoutMs = 1500)
    # Prima v2c, poi v1 (alcune stampanti vecchie rispondono solo a v1).
    foreach ($ver in @(1, 0)) {
        $resp = Invoke-PKSnmpRaw -IP $IP -Packet (New-PKSnmpRequest -Community $Community -Oids $Oids -Version $ver -RequestId (Get-Random -Minimum 1 -Maximum 2000000)) -TimeoutMs $TimeoutMs
        if ($resp) {
            try {
                $h = @{}
                foreach ($vb in (Get-PKSnmpVarbinds $resp)) { if ($null -ne $vb.Value -and "$($vb.Value)" -ne '') { $h[$vb.Oid] = $vb.Value } }
                return $h
            } catch { }
        }
    }
    return $null
}

function Invoke-PKSnmpWalk {
    param([string]$IP, [string]$BaseOid, [string]$Community = 'public', [int]$Max = 32, [int]$TimeoutMs = 1500)
    $values = New-Object System.Collections.ArrayList
    $current = $BaseOid
    for ($k = 0; $k -lt $Max; $k++) {
        $resp = Invoke-PKSnmpRaw -IP $IP -Packet (New-PKSnmpRequest -Community $Community -Oids @($current) -PduType 0xA1 -RequestId ($k + 1)) -TimeoutMs $TimeoutMs
        if (-not $resp) { break }
        $vb = (Get-PKSnmpVarbinds $resp)[0]
        if (-not $vb -or -not $vb.Oid.StartsWith($BaseOid + '.') -or $vb.Tag -ge 0x80) { break }
        [void]$values.Add($vb.Value)
        $current = $vb.Oid
    }
    return ,($values.ToArray())
}

$script:OID_SysDescr = '1.3.6.1.2.1.1.1.0'
$script:OID_HrDeviceDescr = '1.3.6.1.2.1.25.3.2.1.3.1'
$script:OID_LangFamily = '1.3.6.1.2.1.43.15.1.1.3'

function ConvertTo-PKLanguages {
    # prtInterpreterLangFamily: 3 = PCL, 47 = PCL XL (PCL6), 6 = PostScript, 54 = PDF.
    param([object[]]$Codes)
    $l = New-Object System.Collections.ArrayList
    foreach ($c in $Codes) {
        switch ([int]$c) {
            3 { if (-not $l.Contains('pcl5')) { [void]$l.Add('pcl5') } }
            47 { if (-not $l.Contains('pcl6')) { [void]$l.Add('pcl6') } }
            6 { if (-not $l.Contains('ps')) { [void]$l.Add('ps') } }
            54 { if (-not $l.Contains('pdf')) { [void]$l.Add('pdf') } }
        }
    }
    return ,([string[]]$l.ToArray())
}

function ConvertTo-PKLanguagesFromMime {
    param([string[]]$Formats)
    $l = New-Object System.Collections.ArrayList
    foreach ($f in $Formats) {
        $f = "$f".ToLower()
        if ($f -match 'pclxl|pcl-xl|pcl6') { if (-not $l.Contains('pcl6')) { [void]$l.Add('pcl6') } }
        elseif ($f -match 'vnd\.hp-pcl') { if (-not $l.Contains('pcl5')) { [void]$l.Add('pcl5') } }
        elseif ($f -match 'postscript') { if (-not $l.Contains('ps')) { [void]$l.Add('ps') } }
        elseif ($f -match 'application/pdf') { if (-not $l.Contains('pdf')) { [void]$l.Add('pdf') } }
    }
    return ,([string[]]$l.ToArray())
}

# ---------- IPP ----------

function New-PKIppGetAttributes {
    param([string]$PrinterUri)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $writeShortBE = { param($v) $w.Write([byte]([math]::Floor($v / 256))); $w.Write([byte]($v % 256)) }
    $writeAttr = {
        param($tag, $name, $value)
        $nb = [Text.Encoding]::UTF8.GetBytes($name); $vb = [Text.Encoding]::UTF8.GetBytes($value)
        $w.Write([byte]$tag); & $writeShortBE $nb.Length; $w.Write($nb); & $writeShortBE $vb.Length; $w.Write($vb)
    }
    $w.Write([byte]1); $w.Write([byte]1)          # versione 1.1
    & $writeShortBE 0x000B                          # Get-Printer-Attributes
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]1)   # request-id
    $w.Write([byte]0x01)                            # operation-attributes-tag
    & $writeAttr 0x47 'attributes-charset' 'utf-8'
    & $writeAttr 0x48 'attributes-natural-language' 'en'
    & $writeAttr 0x45 'printer-uri' $PrinterUri
    & $writeAttr 0x44 'requested-attributes' 'printer-make-and-model'
    & $writeAttr 0x44 '' 'document-format-supported'
    & $writeAttr 0x44 '' 'printer-device-id'
    $w.Write([byte]0x03)                            # end-of-attributes
    $w.Flush()
    return ,($ms.ToArray())
}

function Read-PKIppAttributes {
    param([byte[]]$Data)
    $attrs = @{}
    if ($Data.Length -lt 9) { return $attrs }
    $i = 8; $last = $null
    while ($i -lt $Data.Length) {
        $tag = $Data[$i]; $i++
        if ($tag -eq 0x03) { break }
        if ($tag -lt 0x10) { continue }    # delimitatori di gruppo
        if ($i + 2 -gt $Data.Length) { break }
        $nl = $Data[$i] * 256 + $Data[$i + 1]; $i += 2
        $name = [Text.Encoding]::UTF8.GetString($Data, $i, $nl); $i += $nl
        $vl = $Data[$i] * 256 + $Data[$i + 1]; $i += 2
        if ($i + $vl -gt $Data.Length) { break }
        $value = [Text.Encoding]::UTF8.GetString($Data, $i, $vl); $i += $vl
        if ($nl -gt 0) { $last = $name }
        if (-not $last) { continue }
        if (-not $attrs.ContainsKey($last)) { $attrs[$last] = New-Object System.Collections.ArrayList }
        [void]$attrs[$last].Add($value)
    }
    return $attrs
}

function Get-PKIppInfo {
    param([string]$IP, [int]$TimeoutMs = 3000)
    foreach ($path in @('/ipp/print', '/ipp', '/printers/lp', '/')) {
        $uri = 'ipp://{0}:631{1}' -f $IP, $path
        try {
            $body = New-PKIppGetAttributes $uri
            $req = [Net.HttpWebRequest]::Create(('http://{0}:631{1}' -f $IP, $path))
            $req.Method = 'POST'; $req.ContentType = 'application/ipp'; $req.Timeout = $TimeoutMs
            $req.ContentLength = $body.Length
            $s = $req.GetRequestStream(); $s.Write($body, 0, $body.Length); $s.Close()
            $resp = $req.GetResponse()
            $rs = $resp.GetResponseStream(); $ms = New-Object System.IO.MemoryStream
            $buf = New-Object byte[] 8192
            while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
            $resp.Close()
            $attrs = Read-PKIppAttributes $ms.ToArray()
            if ($attrs.ContainsKey('printer-make-and-model')) {
                return New-Object PSObject -Property @{
                    MakeModel = [string]$attrs['printer-make-and-model'][0]
                    Formats   = [string[]]@($attrs['document-format-supported'])
                    DeviceId  = [string](@($attrs['printer-device-id']) | Select-Object -First 1)
                    Path      = $path
                }
            }
        } catch { }
    }
    return $null
}

# ---------- Identificazione completa ----------

function Get-PKPrinterIdentity {
    param([string]$IP, [string]$Community = 'public', [int]$TimeoutMs = 1500, [int[]]$OpenPorts = @())
    $model = ''; $descr = ''; $langs = @(); $source = ''
    $snmp = Invoke-PKSnmpGet -IP $IP -Oids @($script:OID_HrDeviceDescr, $script:OID_SysDescr) -Community $Community -TimeoutMs $TimeoutMs
    if ($snmp) {
        if ($snmp.ContainsKey($script:OID_HrDeviceDescr)) { $model = [string]$snmp[$script:OID_HrDeviceDescr] }
        if ($snmp.ContainsKey($script:OID_SysDescr)) { $descr = [string]$snmp[$script:OID_SysDescr] }
        $source = 'SNMP'
        try { $langs = ConvertTo-PKLanguages (Invoke-PKSnmpWalk -IP $IP -BaseOid $script:OID_LangFamily -Community $Community -TimeoutMs $TimeoutMs) } catch { }
    }
    if (-not $model -and ($OpenPorts -contains 631 -or $OpenPorts.Count -eq 0)) {
        $ipp = Get-PKIppInfo -IP $IP
        if ($ipp) {
            $model = $ipp.MakeModel; $source = 'IPP'
            if (-not $langs -or $langs.Count -eq 0) { $langs = ConvertTo-PKLanguagesFromMime $ipp.Formats }
        }
    }
    return New-Object PSObject -Property @{ IP = $IP; Model = $model.Trim(); Description = $descr; Languages = [string[]]$langs; Source = $source }
}

function Find-PKPrinters {
    param([string]$Range, [string]$Community = 'public', [int]$TimeoutMs = 1000, [scriptblock]$Progress)
    $hosts = Expand-PKIPRange $Range
    $open = Test-PKTcpPorts -Hosts $hosts -TimeoutMs $TimeoutMs -Progress $Progress
    $found = New-Object System.Collections.ArrayList
    foreach ($ip in ($open.Keys | Sort-Object { ConvertTo-PKIPNumber $_ })) {
        $ports = [int[]]($open[$ip] | Sort-Object)
        $id = Get-PKPrinterIdentity -IP $ip -Community $Community -OpenPorts $ports
        $id | Add-Member -MemberType NoteProperty -Name Ports -Value $ports
        [void]$found.Add($id)
    }
    return ,($found.ToArray())
}

Export-ModuleMember -Function *-PK*
