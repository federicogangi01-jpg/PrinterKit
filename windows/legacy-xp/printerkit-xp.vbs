' ==========================================================================
' PrinterKit - versione leggera per Windows XP SP3 (VBScript/WSH)
' Usa SOLO la cache del kit: XP non supporta l'HTTPS moderno.
' I pacchetti in cache sono entrati solo dopo la verifica della firma digitale
' fatta dall'app principale (Windows 8.1/10/11); qui si ricontrolla lo SHA-256.
' Avvio: cscript //nologo printerkit-xp.vbs "<cartella del kit>"
' ==========================================================================
Option Explicit

Dim fso, sh, net, kit, sysVer, sysArch, sysLabel, pcName, userName, downloads, sessionLog
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
Set net = CreateObject("WScript.Network")

If WScript.Arguments.Count > 0 Then kit = WScript.Arguments(0) Else kit = fso.GetParentFolderName(fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName)))
If Right(kit, 1) = "\" Then kit = Left(kit, Len(kit) - 1)

' ---------- Elevazione ----------
If Not IsAdmin() Then
    If WScript.Arguments.Named.Exists("elevato") Then
        MsgBox "Servono i diritti di amministratore.", vbCritical, "PrinterKit"
        WScript.Quit 1
    End If
    ' Su XP non c'è UAC: si chiede di rilanciare con "Esegui come…".
    CreateObject("Shell.Application").ShellExecute "cscript.exe", "//nologo """ & WScript.ScriptFullName & """ """ & kit & """ /elevato", "", "runas", 1
    WScript.Quit 0
End If

pcName = net.ComputerName
userName = net.UserName
DetectSystem
downloads = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\Download"
If Not fso.FolderExists(downloads) Then
    If fso.FolderExists(sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\Downloads") Then downloads = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\Downloads" Else fso.CreateFolder downloads
End If
EnsureFolder downloads & "\PrinterKit"
sessionLog = downloads & "\PrinterKit\sessione_" & DateStamp(Now, True) & ".txt"
Logga "=== PrinterKit (versione XP) - sessione del " & FormatIt(Now) & " ==="
Logga "PC: " & pcName & "   Utente: " & userName & "   Sistema: " & sysLabel

Dim index : index = ReadIndex(kit & "\cache\indice-xp.txt")
If UBound(index) < 0 Then
    MsgBox "Indice della cache assente o vuoto (cache\indice-xp.txt)." & vbCrLf & _
           "Prepara la chiavetta da un PC Windows 10/11 aggiornato: l'app principale scarica e verifica i driver, il workflow GitHub genera l'indice.", vbExclamation, "PrinterKit"
    WScript.Quit 1
End If

Dim ipText, ips, ip, okCount, koCount
ipText = InputBox("Indirizzi IP delle stampanti, separati da virgola:" & vbCrLf & "(su XP la scansione automatica della rete non è disponibile)", "PrinterKit - " & sysLabel)
If Trim(ipText) = "" Then WScript.Quit 0
ips = Split(Replace(ipText, " ", ""), ",")
okCount = 0 : koCount = 0
For Each ip In ips
    If ip <> "" Then
        If InstallPrinter(ip) Then okCount = okCount + 1 Else koCount = koCount + 1
    End If
Next
Logga "Fine: " & okCount & " installate, " & koCount & " non installate"
If fso.FolderExists(kit) Then
    On Error Resume Next
    EnsureFolder kit & "\log"
    fso.CopyFile sessionLog, kit & "\log\", True
    On Error GoTo 0
End If
MsgBox "Fine: " & okCount & " installate, " & koCount & " non installate." & vbCrLf & "Log: " & sessionLog, vbInformation, "PrinterKit"

' ==========================================================================

Function InstallPrinter(ip)
    Dim model, man, pkg, reason, logLines, folder, result, ok
    InstallPrinter = False
    ok = False
    Set logLines = CreateObject("Scripting.Dictionary")
    model = GetWebTitle(ip)
    model = InputBox("Modello della stampante " & ip & ":" & vbCrLf & "(ricavato dalla pagina web, correggilo se serve)", "PrinterKit", model)
    If Trim(model) = "" Then Logga ip & ": modello non indicato, saltata" : Exit Function
    If PrinterExistsForIP(ip) Then Logga ip & ": Già installata, lasciata com'è" : Exit Function

    man = FindManufacturer(model)
    If man = "" Then
        reason = "Modello non presente nel catalogo"
    Else
        pkg = SelectPackage(man, model, reason)
    End If
    folder = downloads & "\" & CleanName("Driver " & BrandPrefix(man, model) & model)
    result = "ERRORE"
    Dim drvName, portName, queue, sha, src
    On Error Resume Next
    If IsArray(pkg) Then
        Logga ip & ": driver previsto " & pkg(4) & " " & pkg(5) & " (" & pkg(3) & ")"
        src = FindCachedPackage(pkg(0), pkg(3))
        If src = "" Then
            reason = "Driver " & pkg(4) & " non presente nella cache del kit (XP non può scaricarlo da internet)"
        Else
            sha = CheckSha(src, pkg(13), pkg(0), pkg(3), reason)
            If reason = "" Then
                drvName = InstallDriver(src, pkg, model, reason)
                If reason = "" Then
                    portName = "IP_" & ip
                    RunScript "prnport.vbs", "-a -r " & portName & " -h " & ip & " -o raw -n 9100 -me -y public -i 1"
                    queue = UniqueName(BrandPrefix(man, model) & model & " (" & ip & ")")
                    RunScript "prnmngr.vbs", "-a -p """ & queue & """ -m """ & drvName & """ -r " & portName
                    If PrinterExists(queue) Then
                        RunScript "prnqctl.vbs", "-e -p """ & queue & """"
                        result = "OK" : ok = True
                        EnsureFolder folder
                        fso.CopyFile src, folder & "\", True
                    Else
                        reason = "creazione della stampante non riuscita"
                    End If
                End If
            End If
        End If
    End If
    On Error GoTo 0
    If Not ok Then result = "NON INSTALLATA - " & reason : Logga ip & ": " & reason Else Logga ip & ": stampante """ & queue & """ creata"

    ' Log di intervento (§9)
    Dim t
    t = "=== PrinterKit - intervento del " & FormatIt(Now) & " ===" & vbCrLf & _
        "PC: " & pcName & "   Utente: " & userName & "   Sistema: " & sysLabel & vbCrLf & _
        "Stampante: " & model & "   IP: " & ip & "   Porte aperte: non rilevate (XP)" & vbCrLf
    If IsArray(pkg) Then
        t = t & "Driver: " & pkg(4) & " " & pkg(5) & " (" & pkg(3) & ")" & vbCrLf & _
            "  Fonte: cache del kit (" & src & ")   Firma: verificata all'ingresso in cache (" & ReadManifest(pkg(0), pkg(3), "firma") & ")" & vbCrLf & _
            "  SHA-256: " & sha & vbCrLf
    Else
        t = t & "Driver: nessuno" & vbCrLf
    End If
    If ok Then t = t & "Porta creata: " & portName & " (RAW 9100)" & vbCrLf & "Stampante creata: """ & queue & """ - predefinita: no" & vbCrLf & "Pagina di prova: inviata" & vbCrLf
    t = t & "Esito: " & result & vbCrLf
    EnsureFolder folder
    AppendText folder & "\log_" & DateStamp(Now, False) & "_" & pcName & ".txt", t
    InstallPrinter = ok
End Function

' ---------- Sistema ----------

Sub DetectSystem()
    Dim wmi, os, o, arch
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    For Each o In wmi.ExecQuery("SELECT Version, ServicePackMajorVersion FROM Win32_OperatingSystem")
        Set os = o
    Next
    sysVer = Left(os.Version, 3)
    arch = sh.ExpandEnvironmentStrings("%PROCESSOR_ARCHITEW6432%")
    If arch = "%PROCESSOR_ARCHITEW6432%" Then arch = sh.ExpandEnvironmentStrings("%PROCESSOR_ARCHITECTURE%")
    If UCase(arch) = "AMD64" Then sysArch = "x64" Else sysArch = "x86"
    sysLabel = "Windows XP"
    If sysVer = "5.2" Then sysLabel = "Windows XP x64 / 2003"
    If os.ServicePackMajorVersion > 0 Then sysLabel = sysLabel & " SP" & os.ServicePackMajorVersion
    If sysArch = "x64" Then sysLabel = sysLabel & " 64 bit" Else sysLabel = sysLabel & " 32 bit"
    sysLabel = sysLabel & " (" & os.Version & ")"
End Sub

Function IsAdmin()
    Dim r
    r = sh.Run("cmd /c net session >nul 2>&1", 0, True)
    IsAdmin = (r = 0)
End Function

' ---------- Catalogo (indice piatto generato da manutenzione/genera_indice_xp.py) ----------
' Campi separati da TAB: 0 marca-id, 1 marca, 2 regex match, 3 pacchetto-id, 4 famiglia, 5 versione,
' 6 osMin, 7 osMax, 8 arch (separate da virgola), 9 regex modelli, 10 tipo file, 11 infHint,
' 12 driverName, 13 sha256, 14 status

Function ReadIndex(path)
    Dim arr(), n, f, line
    n = -1
    ReDim arr(-1)
    If Not fso.FileExists(path) Then ReadIndex = arr : Exit Function
    Set f = fso.OpenTextFile(path, 1, False, -2)
    Do While Not f.AtEndOfStream
        line = f.ReadLine
        If Len(line) > 0 And Left(line, 1) <> "#" Then
            n = n + 1
            ReDim Preserve arr(n)
            arr(n) = Split(line, vbTab)
        End If
    Loop
    f.Close
    ReadIndex = arr
End Function

Function RegexTest(pattern, text)
    Dim re
    Set re = New RegExp
    re.Pattern = pattern : re.IgnoreCase = True
    On Error Resume Next
    RegexTest = re.Test(text)
    If Err.Number <> 0 Then RegexTest = False
    On Error GoTo 0
End Function

Function FindManufacturer(model)
    Dim row
    FindManufacturer = ""
    For Each row In index
        If RegexTest(row(2), model) Then FindManufacturer = row(0) : Exit Function
    Next
End Function

Function ManName(manId)
    Dim row
    ManName = ""
    For Each row In index
        If row(0) = manId Then ManName = row(1) : Exit Function
    Next
End Function

Function BrandPrefix(manId, model)
    Dim n
    n = ManName(manId)
    If InStr(n, " (") > 0 Then n = Left(n, InStr(n, " (") - 1)
    If n = "" Or UCase(Left(model, Len(n))) = UCase(n) Then BrandPrefix = "" Else BrandPrefix = n & " "
End Function

Function VerCmp(a, b)
    ' -1, 0, 1 su versioni "5.1"
    Dim pa, pb, i, x, y
    pa = Split(a & ".0.0", ".") : pb = Split(b & ".0.0", ".")
    VerCmp = 0
    For i = 0 To 2
        x = 0 : y = 0
        If IsNumeric(pa(i)) Then x = CLng(pa(i))
        If IsNumeric(pb(i)) Then y = CLng(pb(i))
        If x < y Then VerCmp = -1 : Exit Function
        If x > y Then VerCmp = 1 : Exit Function
    Next
End Function

Function SelectPackage(manId, model, ByRef reason)
    ' Specifico per modello > universale; a parità, la prima voce dell'indice (già ordinata per versione).
    Dim row, best, bestSpecific, isSpecific, noDriver
    best = Empty : bestSpecific = False : noDriver = False
    For Each row In index
        If row(0) = manId And UBound(row) >= 14 Then
            If VerCmp(sysVer, row(6)) >= 0 And (row(7) = "" Or VerCmp(sysVer, row(7)) <= 0) And InStr("," & row(8) & ",", "," & sysArch & ",") > 0 Then
                If row(9) = "*" Or RegexTest(row(9), model) Then
                    If row(14) = "nessun_driver" Then noDriver = True
                    If row(14) = "ok" Then
                        isSpecific = (row(9) <> "*")
                        If IsEmpty(best) Or (isSpecific And Not bestSpecific) Then best = row : bestSpecific = isSpecific
                    End If
                End If
            End If
        End If
    Next
    If IsEmpty(best) Then
        If noDriver Then reason = "Il produttore non offre un driver " & ManName(manId) & " ufficiale per Windows XP" Else reason = "Nessun driver " & ManName(manId) & " ufficiale per Windows XP " & Replace(sysArch, "x", "") & " bit"
        If sysArch = "x86" Then reason = Replace(reason, "86 bit", "32 bit")
        If sysArch = "x64" Then reason = Replace(reason, "64 bit", "64 bit")
        SelectPackage = Empty
    Else
        reason = ""
        SelectPackage = best
    End If
End Function

' ---------- Cache ----------

Function FindCachedPackage(manId, pkgId)
    Dim dir, f
    FindCachedPackage = ""
    dir = kit & "\cache\" & manId & "\" & pkgId
    If Not fso.FolderExists(dir) Then Exit Function
    For Each f In fso.GetFolder(dir).Files
        If LCase(f.Name) <> "verificato.txt" Then FindCachedPackage = f.Path : Exit Function
    Next
End Function

Function ReadManifest(manId, pkgId, key)
    Dim p, f, l
    ReadManifest = ""
    p = kit & "\cache\" & manId & "\" & pkgId & "\verificato.txt"
    If Not fso.FileExists(p) Then Exit Function
    Set f = fso.OpenTextFile(p, 1)
    Do While Not f.AtEndOfStream
        l = f.ReadLine
        If LCase(Left(l, Len(key) + 1)) = LCase(key) & "=" Then ReadManifest = Mid(l, Len(key) + 2)
    Loop
    f.Close
End Function

Function Sha256File(path)
    ' Usa .NET (COM) se installato: System.Security.Cryptography.SHA256Managed.
    Dim st, bytes, h, i, hx
    Sha256File = ""
    On Error Resume Next
    Set h = CreateObject("System.Security.Cryptography.SHA256Managed")
    If Err.Number <> 0 Then Err.Clear : Exit Function
    Set st = CreateObject("ADODB.Stream")
    st.Type = 1 : st.Open : st.LoadFromFile path
    bytes = st.Read : st.Close
    bytes = h.ComputeHash_2((bytes))
    If Err.Number <> 0 Then Err.Clear : Exit Function
    On Error GoTo 0
    hx = ""
    For i = 1 To LenB(bytes)
        hx = hx & Right("0" & LCase(Hex(AscB(MidB(bytes, i, 1)))), 2)
    Next
    Sha256File = hx
End Function

Function CheckSha(path, expected, manId, pkgId, ByRef reason)
    Dim h, manifest
    reason = ""
    manifest = LCase(ReadManifest(manId, pkgId, "sha256"))
    If expected = "" Then expected = manifest
    If expected = "" Then reason = "pacchetto in cache senza hash di verifica (verificato.txt mancante)" : Exit Function
    h = Sha256File(path)
    If h = "" Then
        ' Senza .NET non si può ricalcolare lo SHA-256 su XP: decide il tecnico.
        If MsgBox("Su questo PC manca .NET Framework: non posso ricalcolare lo SHA-256 del pacchetto." & vbCrLf & _
                  "Il pacchetto è stato verificato (firma " & ReadManifest(manId, pkgId, "firma") & ") il " & ReadManifest(manId, pkgId, "data") & "." & vbCrLf & _
                  "Procedere comunque?", vbYesNo + vbExclamation, "PrinterKit") = vbNo Then reason = "SHA-256 non verificabile, installazione annullata"
        CheckSha = expected & " (non ricalcolato)"
        Exit Function
    End If
    If LCase(h) <> LCase(expected) Then
        reason = "SHA-256 diverso da quello verificato: pacchetto in cache non affidabile"
        CheckSha = h
        Exit Function
    End If
    CheckSha = h
End Function

' ---------- Driver ----------

Function InstallDriver(src, pkg, model, ByRef reason)
    Dim tmp, infs, inf, names, n, ext, cand
    InstallDriver = "" : reason = ""
    tmp = sh.ExpandEnvironmentStrings("%TEMP%") & "\PrinterKit_" & pkg(3)
    If fso.FolderExists(tmp) Then fso.DeleteFolder tmp, True
    fso.CreateFolder tmp
    ext = LCase(fso.GetExtensionName(src))
    If ext = "zip" Then
        Dim app
        Set app = CreateObject("Shell.Application")
        app.NameSpace(tmp).CopyHere app.NameSpace(src).Items, 4 + 16 + 512 + 1024
        WScript.Sleep 1500
    ElseIf ext = "inf" Then
        fso.CopyFile src, tmp & "\"
    ElseIf ext = "exe" And pkg(11) <> "" Then
        reason = "pacchetto .exe: su XP usare un pacchetto .zip in cache"
        Exit Function
    Else
        reason = "tipo di pacchetto non gestito su XP: " & ext
        Exit Function
    End If
    Set infs = CreateObject("Scripting.Dictionary")
    CollectInfs fso.GetFolder(tmp), infs
    For Each inf In infs.Keys
        names = InfModelNames(inf)
        If pkg(12) <> "" Then cand = pkg(12) Else cand = BestName(names, model)
        If cand <> "" Then
            sh.Run "rundll32 printui.dll,PrintUIEntry /ia /m """ & cand & """ /f """ & inf & """ /q", 0, True
            WScript.Sleep 2000
            If DriverInstalled(cand) Then InstallDriver = cand : Logga "Driver installato: " & cand : Exit Function
        End If
    Next
    reason = "nessun INF di stampante installabile per XP " & sysArch & " nel pacchetto"
End Function

Sub CollectInfs(folder, dict)
    Dim f, sf, p
    p = LCase(folder.Path) & "\"
    If sysArch = "x86" And (InStr(p, "\x64\") > 0 Or InStr(p, "\amd64\") > 0 Or InStr(p, "64bit") > 0) Then Exit Sub
    If sysArch = "x64" And (InStr(p, "\x86\") > 0 Or InStr(p, "\i386\") > 0 Or InStr(p, "32bit") > 0) Then Exit Sub
    For Each f In folder.Files
        If LCase(fso.GetExtensionName(f.Name)) = "inf" Then
            If IsPrinterInf(f.Path) Then dict(f.Path) = True
        End If
    Next
    For Each sf In folder.SubFolders
        CollectInfs sf, dict
    Next
End Sub

Function ReadAllText(path)
    Dim f, fmt
    ' -2 = predefinito di sistema; gli INF Unicode hanno il BOM e vanno letti con -1.
    fmt = -2
    Set f = fso.OpenTextFile(path, 1, False, 0)
    Dim head : head = ""
    If Not f.AtEndOfStream Then head = f.Read(2)
    f.Close
    If Len(head) = 2 Then If AscB(Left(head, 1)) = &HFF And AscB(Mid(head, 2, 1)) = &HFE Then fmt = -1
    Set f = fso.OpenTextFile(path, 1, False, fmt)
    If f.AtEndOfStream Then ReadAllText = "" Else ReadAllText = f.ReadAll
    f.Close
End Function

Function IsPrinterInf(path)
    Dim re
    Set re = New RegExp
    re.Pattern = "^\s*Class\s*=\s*""?Printer""?\s*(;.*)?$" : re.IgnoreCase = True : re.Multiline = True
    IsPrinterInf = re.Test(ReadAllText(path))
End Function

Function InfModelNames(path)
    ' Righe modello delle sezioni indicate in [Manufacturer] (non decorate o NTx86 / NTamd64), con %token% risolti.
    Dim text, lines, l, sec, strings, sections, i, res, k, parts, j, base, deco, wanted, key, m, nm
    text = ReadAllText(path)
    lines = Split(Replace(text, vbCr, ""), vbLf)
    Set strings = CreateObject("Scripting.Dictionary") : strings.CompareMode = 1
    Set sections = CreateObject("Scripting.Dictionary") : sections.CompareMode = 1
    sec = ""
    For Each l In lines
        If InStr(l, ";") > 0 And InStr(l, """") = 0 Then l = Left(l, InStr(l, ";") - 1)
        l = Trim(l)
        If Left(l, 1) = "[" And Right(l, 1) = "]" Then
            sec = LCase(Mid(l, 2, Len(l) - 2))
            If Not sections.Exists(sec) Then sections.Add sec, ""
        ElseIf l <> "" And sec <> "" Then
            sections(sec) = sections(sec) & l & vbLf
            If sec = "strings" Or Left(sec, 8) = "strings." Then
                If InStr(l, "=") > 0 Then
                    k = LCase(Trim(Left(l, InStr(l, "=") - 1)))
                    If Not strings.Exists(k) Then strings.Add k, Replace(Trim(Mid(l, InStr(l, "=") + 1)), """", "")
                End If
            End If
        End If
    Next
    Set res = CreateObject("Scripting.Dictionary")
    If sections.Exists("manufacturer") Then
        For Each l In Split(sections("manufacturer"), vbLf)
            If InStr(l, "=") > 0 Then
                parts = Split(Mid(l, InStr(l, "=") + 1), ",")
                base = Trim(parts(0))
                If sysArch = "x64" Then wanted = "ntamd64" Else wanted = "ntx86"
                key = ""
                If UBound(parts) = 0 Then
                    If sysArch = "x86" Then key = base
                Else
                    For j = 1 To UBound(parts)
                        deco = LCase(Trim(parts(j)))
                        If deco = wanted Or Left(deco, Len(wanted) + 1) = wanted & "." Then key = base & "." & Trim(parts(j))
                    Next
                    If key = "" And sysArch = "x86" Then key = base
                End If
                If key <> "" And sections.Exists(LCase(key)) Then
                    For Each m In Split(sections(LCase(key)), vbLf)
                        If InStr(m, "=") > 0 Then
                            nm = Trim(Left(m, InStr(m, "=") - 1))
                            nm = ResolveTokens(nm, strings)
                            If nm <> "" And Not res.Exists(nm) Then res.Add nm, True
                        End If
                    Next
                End If
            End If
        Next
    End If
    InfModelNames = res.Keys
End Function

Function ResolveTokens(s, strings)
    Dim re, ms, mm, out
    out = s
    Set re = New RegExp : re.Pattern = "%([^%]+)%" : re.Global = True
    Set ms = re.Execute(s)
    For Each mm In ms
        If strings.Exists(LCase(mm.SubMatches(0))) Then out = Replace(out, mm.Value, strings(LCase(mm.SubMatches(0))))
    Next
    ResolveTokens = Trim(Replace(out, """", ""))
End Function

Function BestName(names, model)
    ' Nome identico al modello > contiene il codice modello > PCL6 > Universal.
    Dim n, code, re, ms, best, score, bestScore
    bestScore = 99 : best = ""
    Set re = New RegExp : re.Pattern = "([A-Za-z]{1,4})[- ]?(\d{3,5})" : re.Global = False
    code = ""
    Set ms = re.Execute(model)
    If ms.Count > 0 Then code = UCase(ms(0).SubMatches(0) & ms(0).SubMatches(1))
    For Each n In names
        score = 50
        If UCase(n) = UCase(model) Or Right(UCase(model), Len(n)) = UCase(n) Then
            score = 0
        ElseIf code <> "" And InStr(Replace(Replace(UCase(n), "-", ""), " ", ""), code) > 0 Then
            score = 10
        ElseIf RegexTest("PCL\s?6|PCL\s?XL", n) Then
            score = 20
        ElseIf RegexTest("UNIVERSAL|\bUPD\b|\bKX\b", n) Then
            score = 30
        End If
        If score < bestScore Then bestScore = score : best = n
    Next
    BestName = best
End Function

Function DriverInstalled(name)
    Dim wmi, d
    DriverInstalled = False
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    For Each d In wmi.ExecQuery("SELECT Name FROM Win32_PrinterDriver")
        If LCase(Split(d.Name, ",")(0)) = LCase(name) Then DriverInstalled = True : Exit Function
    Next
End Function

' ---------- Stampanti ----------

Function PrinterExistsForIP(ip)
    Dim wmi, p, pr, ports
    PrinterExistsForIP = False
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    Set ports = CreateObject("Scripting.Dictionary") : ports.CompareMode = 1
    For Each p In wmi.ExecQuery("SELECT Name, HostAddress FROM Win32_TCPIPPrinterPort")
        If p.HostAddress = ip Then ports(p.Name) = True
    Next
    For Each pr In wmi.ExecQuery("SELECT PortName FROM Win32_Printer")
        If ports.Exists(pr.PortName) Then PrinterExistsForIP = True : Exit Function
    Next
End Function

Function PrinterExists(name)
    Dim wmi, pr
    PrinterExists = False
    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    For Each pr In wmi.ExecQuery("SELECT Name FROM Win32_Printer")
        If LCase(pr.Name) = LCase(name) Then PrinterExists = True : Exit Function
    Next
End Function

Function UniqueName(name)
    Dim i
    UniqueName = name
    If Not PrinterExists(name) Then Exit Function
    For i = 2 To 50
        If Not PrinterExists(name & " (" & i & ")") Then UniqueName = name & " (" & i & ")" : Exit Function
    Next
End Function

Sub RunScript(script, args)
    Dim p
    p = sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\" & script
    If Not fso.FileExists(p) Then Logga "Script di sistema mancante: " & p : Exit Sub
    sh.Run "cscript //nologo """ & p & """ " & args, 0, True
End Sub

Function GetWebTitle(ip)
    ' Molte stampanti mostrano il modello nel titolo della pagina web.
    Dim x, body, re, ms
    GetWebTitle = ""
    On Error Resume Next
    Set x = CreateObject("MSXML2.ServerXMLHTTP")
    x.setTimeouts 3000, 3000, 3000, 5000
    x.Open "GET", "http://" & ip & "/", False
    x.Send
    If Err.Number = 0 Then
        body = x.responseText
        Set re = New RegExp : re.Pattern = "<title>([^<]+)</title>" : re.IgnoreCase = True
        Set ms = re.Execute(body)
        If ms.Count > 0 Then GetWebTitle = Trim(ms(0).SubMatches(0))
    End If
    Err.Clear
    On Error GoTo 0
End Function

' ---------- Utilità ----------

Function CleanName(s)
    Dim re
    Set re = New RegExp : re.Pattern = "[\\/:*?""<>|]" : re.Global = True
    CleanName = Trim(re.Replace(s, " "))
    Do While InStr(CleanName, "  ") > 0 : CleanName = Replace(CleanName, "  ", " ") : Loop
End Function

Sub EnsureFolder(p)
    If Not fso.FolderExists(p) Then
        If Not fso.FolderExists(fso.GetParentFolderName(p)) Then EnsureFolder fso.GetParentFolderName(p)
        fso.CreateFolder p
    End If
End Sub

Sub AppendText(path, text)
    Dim f
    Set f = fso.OpenTextFile(path, 8, True)
    f.Write text & vbCrLf
    f.Close
End Sub

Sub Logga(text)
    WScript.Echo text
    If sessionLog <> "" Then AppendText sessionLog, Right("0" & Hour(Now), 2) & ":" & Right("0" & Minute(Now), 2) & ":" & Right("0" & Second(Now), 2) & " " & text
End Sub

Function Pad2(n)
    Pad2 = Right("0" & n, 2)
End Function

Function DateStamp(d, withTime)
    DateStamp = Year(d) & "-" & Pad2(Month(d)) & "-" & Pad2(Day(d))
    If withTime Then DateStamp = DateStamp & "_" & Pad2(Hour(d)) & "-" & Pad2(Minute(d)) & "-" & Pad2(Second(d))
End Function

Function FormatIt(d)
    FormatIt = Pad2(Day(d)) & "/" & Pad2(Month(d)) & "/" & Year(d) & " " & Pad2(Hour(d)) & ":" & Pad2(Minute(d))
End Function
