# Motore delle "ricette" HTTP per multifunzione (§10.2) e NAS (§10.1.4). Compatibile con PowerShell 2.0.
# Una ricetta è una sequenza di richieste HTTP con segnaposto {{nome}}, estrazione di token (CSRF)
# con regex e controlli sull'esito. Le password non finiscono mai nel log.

$script:TrustLoaded = $false

function Initialize-PKTrust {
    # Accetta certificati autofirmati SOLO per gli host registrati (l'IP della macchina) e solo in questa sessione.
    if ($script:TrustLoaded) { return }
    $code = @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class PKTrust {
    private static Dictionary<string, bool> hosts = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
    private static bool installed = false;
    public static void Allow(string host) {
        lock (hosts) { hosts[host] = true; }
        if (!installed) {
            ServicePointManager.ServerCertificateValidationCallback += Check;
            installed = true;
        }
    }
    public static void Clear() { lock (hosts) { hosts.Clear(); } }
    private static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        if (errors == SslPolicyErrors.None) return true;
        HttpWebRequest req = sender as HttpWebRequest;
        if (req == null) return false;
        lock (hosts) { return hosts.ContainsKey(req.RequestUri.Host); }
    }
}
'@
    Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
    $script:TrustLoaded = $true
}

function Register-PKTrustedHost { param([string]$HostName) Initialize-PKTrust; [PKTrust]::Allow($HostName) }
function Clear-PKTrustedHosts { if ($script:TrustLoaded) { [PKTrust]::Clear() } }

function Expand-PKTemplate {
    # Sostituisce {{nome}}; escape: none | url | xml | json
    param([string]$Text, [hashtable]$Vars, [string]$Escape = 'none')
    if ($null -eq $Text) { return $null }
    $out = $Text
    foreach ($m in [regex]::Matches($Text, '\{\{\s*([A-Za-z0-9_.]+)\s*\}\}')) {
        $k = $m.Groups[1].Value
        $v = ''
        if ($Vars.ContainsKey($k)) { $v = "$($Vars[$k])" }
        switch ($Escape) {
            'url' { $v = [Uri]::EscapeDataString($v) }
            'xml' { $v = [Security.SecurityElement]::Escape($v) }
            'json' { $v = $v.Replace('\', '\\').Replace('"', '\"') }
        }
        $out = $out.Replace($m.Value, $v)
    }
    return $out
}

function Invoke-PKHttp {
    param([string]$Method = 'GET', [string]$Url, [string]$Body, [string]$ContentType, [hashtable]$Headers,
          [Net.CookieContainer]$Cookies, [int]$TimeoutMs = 20000, [switch]$NoRedirect, [byte[]]$BodyBytes)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 768 -bor 192 } catch { }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method; $req.Timeout = $TimeoutMs; $req.KeepAlive = $true
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PrinterKit'
    $req.AllowAutoRedirect = -not $NoRedirect
    if ($Cookies) { $req.CookieContainer = $Cookies }
    if ($Headers) {
        foreach ($k in $Headers.Keys) {
            switch ($k.ToLower()) {
                'referer' { $req.Referer = $Headers[$k] }
                'accept' { $req.Accept = $Headers[$k] }
                'content-type' { $req.ContentType = $Headers[$k] }
                default { $req.Headers[$k] = $Headers[$k] }
            }
        }
    }
    if ($null -ne $Body -or $BodyBytes) {
        if (-not $BodyBytes) { $BodyBytes = [Text.Encoding]::UTF8.GetBytes($Body) }
        if ($ContentType) { $req.ContentType = $ContentType }
        $req.ContentLength = $BodyBytes.Length
        $s = $req.GetRequestStream(); $s.Write($BodyBytes, 0, $BodyBytes.Length); $s.Close()
    }
    $resp = $null
    try { $resp = $req.GetResponse() }
    catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $resp = $ex.Response } else { throw }
    }
    try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd(); $sr.Close()
        $h = @{}
        foreach ($k in $resp.Headers.AllKeys) { $h[$k] = $resp.Headers[$k] }
        return New-Object PSObject -Property @{ Status = [int]$resp.StatusCode; Body = $text; Headers = $h; Url = $resp.ResponseUri.AbsoluteUri }
    } finally { $resp.Close() }
}

function Get-PKRecipeValue {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($Object -is [Collections.IDictionary]) { if ($Object.ContainsKey($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] } }
    return $Default
}

function Invoke-PKRecipeSteps {
    # Esegue i passi; aggiorna $Context.Vars con i valori estratti. Restituisce l'ultima risposta.
    param([object[]]$Steps, [hashtable]$Context, [switch]$DryRun)
    $last = $null
    foreach ($step in $Steps) {
        $writes = [bool](Get-PKRecipeValue $step 'writes' $false)
        $label = Get-PKRecipeValue $step 'label' (Get-PKRecipeValue $step 'path' '')
        if ($DryRun -and $writes) { Write-PKLog ('[prova] salto il passo di scrittura: ' + $label); continue }
        $method = Get-PKRecipeValue $step 'method' 'GET'
        $path = Expand-PKTemplate (Get-PKRecipeValue $step 'path' '/') $Context.Vars 'none'
        $url = $path
        if ($path -notmatch '^https?://') { $url = $Context.BaseUrl.TrimEnd('/') + $path }
        $body = $null; $ctype = $null
        $form = Get-PKRecipeValue $step 'form'
        if ($form) {
            $pairs = New-Object System.Collections.ArrayList
            foreach ($k in $form.Keys) { [void]$pairs.Add(([Uri]::EscapeDataString($k) + '=' + (Expand-PKTemplate ([string]$form[$k]) $Context.Vars 'url'))) }
            $body = [string]::Join('&', [string[]]$pairs.ToArray()); $ctype = 'application/x-www-form-urlencoded'
        }
        $tpl = Get-PKRecipeValue $step 'body'
        if ($tpl) {
            $esc = Get-PKRecipeValue $step 'escape' 'none'
            $body = Expand-PKTemplate ([string]$tpl) $Context.Vars $esc
            $ctype = Get-PKRecipeValue $step 'contentType' 'text/plain'
        }
        $headers = @{}
        $hh = Get-PKRecipeValue $step 'headers'
        if ($hh) { foreach ($k in $hh.Keys) { $headers[$k] = Expand-PKTemplate ([string]$hh[$k]) $Context.Vars 'none' } }
        $resp = Invoke-PKHttp -Method $method -Url $url -Body $body -ContentType $ctype -Headers $headers -Cookies $Context.Cookies -NoRedirect:([bool](Get-PKRecipeValue $step 'noRedirect' $false))
        $last = $resp
        $okStatus = @(Get-PKRecipeValue $step 'expectStatus' @(200, 301, 302, 303))
        if ($okStatus -notcontains $resp.Status) { throw ('passo "{0}": risposta HTTP {1}' -f $label, $resp.Status) }
        $fail = Get-PKRecipeValue $step 'failRegex'
        if ($fail -and $resp.Body -match (Expand-PKTemplate $fail $Context.Vars 'none')) { throw ('passo "{0}": la macchina ha risposto con un errore' -f $label) }
        $expect = Get-PKRecipeValue $step 'expectRegex'
        if ($expect) {
            $rx = Expand-PKTemplate $expect $Context.Vars 'none'
            if ($resp.Body -notmatch $rx) { throw ('passo "{0}": risposta inattesa' -f $label) }
        }
        $ex = Get-PKRecipeValue $step 'extract'
        if ($ex) {
            foreach ($k in $ex.Keys) {
                $src = $resp.Body
                $spec = [string]$ex[$k]
                if ($spec.StartsWith('header:')) {
                    $parts = $spec.Substring(7).Split(@(':'), 2)
                    $src = "$($resp.Headers[$parts[0]])"; $spec = $parts[1]
                }
                $m = [regex]::Match($src, $spec, 'IgnoreCase')
                if ($m.Success) { $Context.Vars[$k] = $m.Groups[1].Value }
                elseif (-not [bool](Get-PKRecipeValue $step 'extractOptional' $false)) { throw ('passo "{0}": valore "{1}" non trovato nella risposta' -f $label, $k) }
            }
        }
        $save = Get-PKRecipeValue $step 'saveBodyAs'
        if ($save -and $Context.OutDir) { [IO.File]::WriteAllText((Join-Path $Context.OutDir (Expand-PKTemplate $save $Context.Vars)), $resp.Body, [Text.Encoding]::UTF8) }
    }
    return $last
}

function New-PKRecipeContext {
    param([string]$BaseUrl, [hashtable]$Vars, [string]$OutDir)
    return @{ BaseUrl = $BaseUrl; Vars = $Vars; Cookies = (New-Object Net.CookieContainer); OutDir = $OutDir }
}

function Read-PKRecipes {
    # Ricette dalla copia del kit; se configurato, prima prova a scaricarle aggiornate da GitHub.
    param([string]$Folder, [string]$RemoteBase, [string]$Brand)
    $list = New-Object System.Collections.ArrayList
    $dir = Join-Path $Folder $Brand
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json')) {
            try { $r = Read-PKJsonFile $f.FullName; $r['_file'] = $f.FullName; [void]$list.Add($r) } catch { Write-PKLog ('Ricetta non leggibile: ' + $f.Name) 'avviso' }
        }
    }
    return ,($list.ToArray())
}

function Find-PKRecipe {
    # Famiglia: regex sul modello SNMP + impronta della pagina web (se indicata).
    param([object[]]$Recipes, [string]$Model, [string]$IP)
    foreach ($r in $Recipes) {
        $mm = Get-PKRecipeValue $r 'modelMatch' '.'
        if ($Model -notmatch $mm) { continue }
        $fp = Get-PKRecipeValue $r 'fingerprint'
        $base = $null
        foreach ($scheme in @(Get-PKRecipeValue $r 'schemes' @('https', 'http'))) {
            $u = '{0}://{1}' -f $scheme, $IP
            if ($scheme -eq 'https') { Register-PKTrustedHost $IP }
            try {
                $resp = Invoke-PKHttp -Url ($u + (Get-PKRecipeValue $fp 'path' '/')) -TimeoutMs 8000
                if (-not $fp -or $resp.Body -match (Get-PKRecipeValue $fp 'regex' '.')) { $base = $u; break }
            } catch { }
        }
        if ($base) { return @{ Recipe = $r; BaseUrl = $base } }
    }
    return $null
}

Export-ModuleMember -Function *-PK*
