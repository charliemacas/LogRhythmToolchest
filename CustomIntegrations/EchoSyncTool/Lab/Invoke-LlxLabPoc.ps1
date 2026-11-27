<#
.SYNOPSIS
    Lab proof of concept: drilldown logs (REST) -> .llx -> Echo use case.

.DESCRIPTION
    Runs the chain one stage at a time and pauses after each so you can check the result:

      1. Find an alarm and fetch its drilldown logs  (LogRhythm Alarm + AIE Drilldown Cache APIs)
      2. Show the logs and pick one log source type   (LLX-Tool v1.0.0 = one type per file)
      3. Write them to a .txt and compile a .llx      (LLX-Tool.ps1 Compile, then View to verify)
      4. (optional) Ask Echo to decode the .llx       (Echo /api/unpackLLXFile, no use case created)
      5. Print the steps to import and run it in Echo, and how to see the logs land

    Read-only against LogRhythm. It changes nothing in Echo unless you choose to import manually.

.PARAMETER LrApiBaseUrl
    e.g. https://PM01:8501

.PARAMETER AlarmId
    Use this alarm. If omitted, the newest alarms are searched for one with drilldown logs.

.PARAMETER AlarmRuleName
    Only consider alarms whose rule name matches (wildcards allowed), e.g. '*Brute*'.

.PARAMETER MsgSourceTypeID
    Log source type to keep if the alarm's logs span several types. Default: the most common one.

.PARAMETER LlxToolPath
    Path to LLX-Tool.ps1 (v1.0.0 or later). Default: next to this script.

.PARAMETER TemplateLlx
    An .llx exported from this LogRhythm (sets LicenseID/version). Recommended.

.PARAMETER LicenseID
    Used when there's no template.

.PARAMETER OutputFolder
    Default .\LabPoc_<date>_<time>

.PARAMETER EchoBaseUrl
    Set this (and -EchoCredential if needed) to have Echo decode the .llx in step 4.

.PARAMETER EchoCredential
    Echo login, if your Echo API needs one.

.PARAMETER EchoUploadField
    Multipart field name for the LLX upload. Default 'file'.

.PARAMETER SkipCertificateCheck
    Accept self-signed certificates (normal in a lab).

.PARAMETER NoPause
    Don't stop between stages.

.EXAMPLE
    $env:LR_API_TOKEN = Read-Host 'LR API token'
    .\Invoke-LlxLabPoc.ps1 -LrApiBaseUrl https://PM01:8501 -TemplateLlx .\export.llx -SkipCertificateCheck

.EXAMPLE
    .\Invoke-LlxLabPoc.ps1 -LrApiBaseUrl https://PM01:8501 -AlarmRuleName '*Brute*' -LicenseID 1 `
        -EchoBaseUrl https://ECHO01:33333 -EchoCredential (Get-Credential) -SkipCertificateCheck
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LrApiBaseUrl,
    [string]$AlarmId,
    [string]$AlarmRuleName = '*',
    [int]$MsgSourceTypeID,
    [string]$LlxToolPath,
    [string]$TemplateLlx,
    [int]$LicenseID = 0,
    [string]$OutputFolder,
    [string]$EchoBaseUrl,
    [pscredential]$EchoCredential,
    [string]$EchoUploadField = 'file',
    [switch]$SkipCertificateCheck,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$IsPS7 = $PSVersionTable.PSVersion.Major -ge 7
$Utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not $LlxToolPath) {
    $LlxToolPath = Join-Path $PSScriptRoot 'LLX-Tool.ps1'
    if (-not (Test-Path -LiteralPath $LlxToolPath)) { $LlxToolPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'LLX-Tool.ps1' }
}
if (-not (Test-Path -LiteralPath $LlxToolPath)) { throw "LLX-Tool.ps1 not found at $LlxToolPath (use -LlxToolPath)" }
if (-not $OutputFolder) { $OutputFolder = Join-Path (Get-Location).Path ('LabPoc_{0:yyyyMMdd_HHmmss}' -f (Get-Date)) }
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

function Write-Stage([string]$Text) { Write-Host ''; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  $Text" }
function Wait-Next { if (-not $NoPause) { [void](Read-Host '  Press Enter to continue (Ctrl+C to stop)') } }

# ---------------------------------------------------------------- HTTP
if (-not $IsPS7) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($SkipCertificateCheck -and -not ('LabPoc.TrustAll' -as [type])) {
        Add-Type -TypeDefinition @'
namespace LabPoc { public static class TrustAll {
  public static bool Accept(object s, System.Security.Cryptography.X509Certificates.X509Certificate c, System.Security.Cryptography.X509Certificates.X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; }
  public static void Enable() { System.Net.ServicePointManager.ServerCertificateValidationCallback = Accept; } } }
'@
    }
    if ($SkipCertificateCheck) { [LabPoc.TrustAll]::Enable() }
}

function Invoke-Http([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body, [string]$ContentType, $Session) {
    $h = @{} + $Headers
    # The LogRhythm drilldown API answers 400 unless Content-Type: application/json is sent, even on a GET.
    # Windows PowerShell 5.1 sends it from -Headers; PowerShell 7 needs it via -ContentType.
    if ($IsPS7 -and $h.ContainsKey('Content-Type')) { if (-not $ContentType) { $ContentType = $h['Content-Type'] }; $h.Remove('Content-Type') }
    $p = @{ Method = $Method; Uri = $Url; Headers = $h; UseBasicParsing = $true; TimeoutSec = 120 }
    if ($null -ne $Body) { $p.Body = $Body }
    if ($ContentType) { $p.ContentType = $ContentType }
    if ($Session) { $p.WebSession = $Session }
    if ($IsPS7) { $p.SkipHttpErrorCheck = $true; if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true } }
    $status = 0; $content = ''
    try {
        $r = Invoke-WebRequest @p
        $status = [int]$r.StatusCode
        # Decode the raw bytes as UTF-8 ourselves: Windows PowerShell 5.1 assumes ISO-8859-1 when the server
        # sends no charset, which turns characters such as non-breaking spaces into 'Â '.
        $raw = $r.RawContentStream.ToArray()
        $content = $Utf8.GetString($raw).TrimStart([char]0xFEFF)
    }
    catch [System.Net.WebException] {
        if (-not $_.Exception.Response) { throw }
        $status = [int]$_.Exception.Response.StatusCode
        $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream(), $Utf8); $content = $sr.ReadToEnd(); $sr.Dispose()
    }
    $json = $null
    if ($content) { try { $json = if ($IsPS7) { ConvertFrom-Json -InputObject $content -NoEnumerate } else { ConvertFrom-Json -InputObject $content } } catch { } }
    [pscustomobject]@{ Status = $status; Content = $content; Json = $json }
}

function Get-Prop($o, [string[]]$Names) {
    if ($null -eq $o -or $o -is [string] -or $o -is [ValueType]) { return $null }
    foreach ($n in $Names) { $p = $o.PSObject.Properties[$n]; if ($p) { return , $p.Value } }
    return $null
}
function Get-Array($o, [string[]]$Names) {
    if ($null -eq $o) { return , @() }
    if ($o -is [Array]) { return , $o }
    foreach ($n in $Names) { $v = Get-Prop $o @($n); if ($v -is [Array]) { return , $v } }
    return , @()
}

$token = $env:LR_API_TOKEN
if (-not $token) {
    $sec = Read-Host 'LogRhythm API token' -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
$lrHeaders = @{ Authorization = "Bearer $token"; Accept = 'application/json'; 'Content-Type' = 'application/json' }
$base = $LrApiBaseUrl.TrimEnd('/')

function Get-DrilldownLogs([string]$Id) {
    $r = Invoke-Http GET "$base/lr-drilldown-cache-api/drilldown/$Id" $lrHeaders
    if ($r.Status -eq 401 -or $r.Status -eq 403) { throw "Drilldown API refused the token (HTTP $($r.Status))" }
    if (-not $r.Json) { return [pscustomobject]@{ Status = $r.Status; Raw = $r.Content; Logs = @(); Blocks = 0 } }
    $data = Get-Prop $r.Json @('Data', 'data'); if ($null -eq $data) { $data = $r.Json }
    $dd = Get-Prop $data @('DrillDownResults', 'drillDownResults'); if ($null -eq $dd) { $dd = $data }
    $blocks = Get-Array $dd @('RuleBlocks', 'ruleBlocks')
    $logs = New-Object System.Collections.Generic.List[object]
    $bi = 0
    foreach ($b in $blocks) {
        $bi++
        $raw = Get-Prop $b @('DrillDownLogs', 'drillDownLogs', 'logs')
        if ($raw -is [string] -and $raw.Trim()) { $raw = if ($IsPS7) { ConvertFrom-Json -InputObject $raw -NoEnumerate } else { ConvertFrom-Json -InputObject $raw } }
        foreach ($l in @($raw)) {
            if ($null -eq $l) { continue }
            $msg = if ($l -is [string]) { $l } else { Get-Prop $l @('logMessage', 'LogMessage', 'rawLog', 'message', 'Message') }
            if (-not $msg) { continue }
            # Real drilldowns put the type ID in 'logSourceType' (only accept a number)
            $tRaw = Get-Prop $l @('logSourceType', 'msgSourceTypeId', 'MsgSourceTypeID', 'logSourceTypeId')
            $logs.Add([pscustomobject]@{
                    Block    = $bi
                    TypeID   = $(if ("$($tRaw)" -match '^\d+$') { $tRaw } else { $null })
                    TypeName = [string](Get-Prop $l @('msgSourceTypeName', 'MsgSourceTypeName', 'logSourceTypeName'))
                    Message  = [string]$msg
                })
        }
    }
    [pscustomobject]@{ Status = $r.Status; Raw = $r.Content; Logs = $logs.ToArray(); Blocks = $blocks.Count }
}

# ================================================================ 1. alarm + drilldown
Write-Stage '1. Find an alarm and fetch its drilldown logs (REST)'
$chosen = $null; $dd = $null
if ($AlarmId) {
    $ar = Invoke-Http GET "$base/lr-alarm-api/alarms/$AlarmId" $lrHeaders
    $det = Get-Prop $ar.Json @('alarmDetails')
    $ruleName = if ($det) { [string](Get-Prop $det @('alarmRuleName')) } else { '(unknown rule)' }
    $dd = Get-DrilldownLogs $AlarmId
    Write-Info ("alarm {0}  {1}  drilldown HTTP {2}, {3} log(s) in {4} rule block(s)" -f $AlarmId, $ruleName, $dd.Status, $dd.Logs.Count, $dd.Blocks)
    if ($dd.Status -ge 400 -and $dd.Raw) { Write-Host "  API said: $($dd.Raw)" -ForegroundColor Yellow }
    $chosen = [pscustomobject]@{ Id = $AlarmId; Rule = $ruleName; Date = '' }
}
else {
    $r = Invoke-Http GET "$base/lr-alarm-api/alarms?count=50&offset=0&orderby=dateInserted&dir=descending" $lrHeaders
    if ($r.Status -ne 200) { throw "Alarm API returned HTTP $($r.Status): $($r.Content)" }
    $alarms = Get-Array $r.Json @('alarmsSearchDetails', 'alarms', 'data')
    $alarms = @($alarms | Where-Object { [string](Get-Prop $_ @('alarmRuleName')) -like $AlarmRuleName })
    Write-Info "$($alarms.Count) recent alarm(s) match '$AlarmRuleName'. Looking for one with drilldown logs..."
    foreach ($a in ($alarms | Select-Object -First 20)) {
        $id = [string](Get-Prop $a @('alarmId', 'alarmID', 'id'))
        $res = Get-DrilldownLogs $id
        Write-Info ("  alarm {0,-8} {1,-50} HTTP {2}, {3} log(s)" -f $id, [string](Get-Prop $a @('alarmRuleName')), $res.Status, $res.Logs.Count)
        if ($res.Logs.Count) { $dd = $res; $chosen = [pscustomobject]@{ Id = $id; Rule = [string](Get-Prop $a @('alarmRuleName')); Date = [string](Get-Prop $a @('dateInserted')) }; break }
    }
}
if ($dd -and $dd.Raw -and -not $dd.Logs.Count -and $dd.Status -lt 300) {
    Write-Host '  Got a response but found no raw logs in it. Top-level structure:' -ForegroundColor Yellow
    try {
        $j = ConvertFrom-Json -InputObject $dd.Raw
        $d = Get-Prop $j @('Data'); $r2 = Get-Prop $d @('DrillDownResults')
        foreach ($o in @($j, $d, $r2)) { if ($o -and $o -isnot [string]) { Write-Info ('    ' + (($o.PSObject.Properties | ForEach-Object { $_.Name + ':' + $(if ($null -eq $_.Value) { 'null' } else { $_.Value.GetType().Name }) }) -join ', ')) } }
    } catch { }
}
if (-not $dd -or -not $dd.Logs.Count) {
    if ($dd -and $dd.Raw) { [IO.File]::WriteAllText((Join-Path $OutputFolder 'drilldown-raw.json'), $dd.Raw, $Utf8) }
    throw 'No drilldown logs found. Check Auto Drilldown is enabled on the rule, or pass -AlarmId of an alarm whose drilldown shows logs in the Web Console. Any raw response was saved as drilldown-raw.json.'
}
[IO.File]::WriteAllText((Join-Path $OutputFolder 'drilldown-raw.json'), $dd.Raw, $Utf8)
Write-Ok "Alarm $($chosen.Id) '$($chosen.Rule)': $($dd.Logs.Count) log(s) in $($dd.Blocks) rule block(s). Raw response saved: drilldown-raw.json"
Wait-Next

# ================================================================ 2. show + pick type
Write-Stage '2. The logs'
$i = 0
foreach ($l in $dd.Logs) {
    $i++
    $preview = ($l.Message -replace '\s+', ' '); if ($preview.Length -gt 90) { $preview = $preview.Substring(0, 90) + '...' }
    Write-Info ("{0,3}. block {1}  type {2,-8} {3}" -f $i, $l.Block, $l.TypeID, $preview)
}
# Group by type ID where present, otherwise by type name (some LogRhythm versions only return the name)
foreach ($l in $dd.Logs) { $l | Add-Member -NotePropertyName TypeKey -NotePropertyValue $(if ("$($l.TypeID)" -ne '') { "id:$($l.TypeID)" } else { "name:$($l.TypeName)" }) -Force }
$groups = @($dd.Logs | Group-Object TypeKey | Sort-Object Count -Descending)
foreach ($g in $groups) { Write-Info ("  {0}: {1} log(s)" -f ($g.Name -replace '^(id|name):', ''), $g.Count) }
$haveIds = @($dd.Logs | Where-Object { "$($_.TypeID)" -ne '' }).Count -gt 0
if ($PSBoundParameters.ContainsKey('MsgSourceTypeID')) {
    $typeId = $MsgSourceTypeID
    $match = @($dd.Logs | Where-Object { "$($_.TypeID)" -eq "$typeId" })
    # Logs that carry the ID: keep the matching ones. Logs without IDs: use the largest group and stamp this ID on it.
    $keep = if ($match.Count) { $match } else { @($groups[0].Group) }
    if (-not $match.Count -and $haveIds) { Write-Host "  No logs carry type ID $typeId; using the largest group ($($groups[0].Name -replace '^(id|name):', '')) with that ID." -ForegroundColor Yellow }
}
else {
    if (-not $haveIds) { throw "The drilldown logs carry only the log source type name ('$($groups[0].Name -replace '^name:', '')'), not its ID. Look it up (SELECT MsgSourceTypeID, Name FROM LogRhythmEMDB.dbo.MsgSourceType WHERE Name = '...') and pass -MsgSourceTypeID." }
    $keep = @($groups[0].Group)
    $typeId = @($keep)[0].TypeID
}
if ($groups.Count -gt 1) { Write-Host "  Logs span $($groups.Count) log source types; LLX-Tool v1.0.0 writes one type per file, so keeping $($keep.Count) log(s) of one type." -ForegroundColor Yellow }
if (-not $keep.Count) { throw "No logs to use." }
Write-Ok "Using $($keep.Count) log(s) of log source type $typeId"
Wait-Next

# ================================================================ 3. txt -> llx
Write-Stage '3. Write the logs to .txt and compile the .llx (LLX-Tool)'
$multiLine = @($keep | Where-Object { $_.Message -match '[\r\n]' }).Count -gt 0
$sep = if ($multiLine) { "`r`n`r`n" } else { "`r`n" }
$txt = Join-Path $OutputFolder 'alarm-logs.txt'
[IO.File]::WriteAllText($txt, (($keep | ForEach-Object { $_.Message }) -join $sep) + "`r`n", $Utf8)
$llx = Join-Path $OutputFolder 'alarm-logs.llx'
$compile = @{ Mode = 'Compile'; Path = $txt; OutputPath = $llx; Force = $true; MsgSourceTypeID = [int]$typeId; Comments = "Lab PoC from alarm $($chosen.Id)" }
# Always state how to split: the 'Auto' mode would treat any log containing <Event>...</Event> (e.g. ePO XML) as Windows event XML
$compile.SplitMode = if ($multiLine) { 'BlankLine' } else { 'Line' }
if ($TemplateLlx) { $compile.TemplateLlx = $TemplateLlx } else { $compile.LicenseID = $LicenseID }
& $LlxToolPath @compile 3>$null | Out-Null
$check = @(& $LlxToolPath View $llx 6>$null)
if ($check.Count -ne $keep.Count) { throw "LLX has $($check.Count) message(s), expected $($keep.Count)" }
$trimmed = 0
for ($k = 0; $k -lt $keep.Count; $k++) {
    $orig = $keep[$k].Message; $got = [string]$check[$k].Message
    if ($got -ceq $orig) { continue }
    if ($got -ceq $orig.TrimEnd()) { $trimmed++; continue }   # LLX-Tool's line mode drops trailing whitespace: harmless
    # Show exactly where they differ
    $n = [Math]::Min($orig.Length, $got.Length); $pos = 0
    while ($pos -lt $n -and $orig[$pos] -ceq $got[$pos]) { $pos++ }
    $ctx = { param($t) $a = [Math]::Max(0, $pos - 30); $len = [Math]::Min(60, $t.Length - $a); if ($len -gt 0) { $t.Substring($a, $len) -replace '\s', '·' } else { '' } }
    $code = { param($t) if ($pos -lt $t.Length) { 'U+{0:X4}' -f [int]$t[$pos] } else { 'end of text' } }
    Write-Host "  LLX message $($k + 1) differs from the drilldown log at character $pos (original length $($orig.Length), LLX length $($got.Length))" -ForegroundColor Red
    Write-Host "    original: ...$(& $ctx $orig)...   char there: $(& $code $orig)" -ForegroundColor Red
    Write-Host "    in LLX:   ...$(& $ctx $got)...   char there: $(& $code $got)" -ForegroundColor Red
    throw "LLX content differs from the drilldown log (details above)"
}
if ($trimmed) { Write-Info "$trimmed log(s) had trailing spaces removed (harmless; MPE rules ignore trailing whitespace)" }
Write-Ok "$llx"
Write-Ok "Read back: $($check.Count) message(s) matching the drilldown logs, type $($check[0].MsgSourceTypeID), LicenseID $($check[0].LicenseID)"
Wait-Next

# ================================================================ 4. Echo decode (optional)
Write-Stage '4. Ask Echo to decode the .llx (optional, creates nothing)'
if ($EchoBaseUrl) {
    $eb = $EchoBaseUrl.TrimEnd('/')
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $eh = @{}
    if ($EchoCredential) {
        $lb = @{ username = $EchoCredential.UserName; password = $EchoCredential.GetNetworkCredential().Password } | ConvertTo-Json
        $lr = Invoke-Http POST "$eb/api/login" @{} $lb 'application/json' $session
        Write-Info "Echo login: HTTP $($lr.Status)"
        $tok = Get-Prop $lr.Json @('token', 'access_token'); if ($tok) { $eh.Authorization = "Bearer $tok" }
    }
    $bytes = [IO.File]::ReadAllBytes($llx)
    $boundary = '----LabPoc' + [guid]::NewGuid().ToString('N')
    $head = $Utf8.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"$EchoUploadField`"; filename=`"alarm-logs.llx`"`r`nContent-Type: application/octet-stream`r`n`r`n")
    $tail = $Utf8.GetBytes("`r`n--$boundary--`r`n")
    $body = New-Object byte[] ($head.Length + $bytes.Length + $tail.Length)
    [Array]::Copy($head, 0, $body, 0, $head.Length); [Array]::Copy($bytes, 0, $body, $head.Length, $bytes.Length); [Array]::Copy($tail, 0, $body, $head.Length + $bytes.Length, $tail.Length)
    $u = Invoke-Http POST "$eb/api/unpackLLXFile" $eh $body "multipart/form-data; boundary=$boundary" $session
    [IO.File]::WriteAllText((Join-Path $OutputFolder 'echo-unpack-response.json'), [string]$u.Content, $Utf8)
    if ($u.Status -ge 200 -and $u.Status -lt 300) { Write-Ok "Echo accepted the .llx (HTTP $($u.Status)). Response saved: echo-unpack-response.json" }
    else { Write-Host "  Echo returned HTTP $($u.Status). Saved echo-unpack-response.json. Try the UI route in stage 5; it shows the real request in browser dev tools." -ForegroundColor Yellow }
}
else { Write-Info 'Skipped (no -EchoBaseUrl). Stage 5 uses the Echo UI instead.' }
Wait-Next

# ================================================================ 5. manual import + run
Write-Stage '5. Import and run in Echo, then see the logs land'
$typeName = @($keep)[0].TypeName
Write-Host @"
  In the Echo web UI (tip: press F12 > Network first, to capture the API calls for later):
    a. Use Cases > New Use Case: title 'LAB PoC - $($chosen.Rule)', Log Message Dates = No Delay > Save
    b. LLX File Browser > Choose LLX File > $llx
    c. Select all $($keep.Count) log(s) > Add to Use Case > pick the use case above
    d. Open the use case: check the log source type shows as $typeId $(if ($typeName) { "($typeName)" })
    e. Run the use case

  In LogRhythm (Web Console > Search, last 15 minutes):
    - Filter on Log Source Type = $(if ($typeName) { $typeName } else { $typeId }), or search for a distinctive
      string from the logs above (e.g. a username or event ID)
    - The logs should appear from Echo's simulated log source within a minute or two
    - Bonus: if the logs meet the rule's conditions, a new '$($chosen.Rule)' alarm will fire

  Everything from this run is in: $OutputFolder
"@
Write-Ok 'Proof of concept prepared'
