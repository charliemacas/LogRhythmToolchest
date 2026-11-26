<#
.SYNOPSIS
    Lab step 6: create an Echo use case via the API from a lab run, titled with the alarm's rule name.

.DESCRIPTION
    Uses the output folder of the lab script (LabPoc_<date>_<time>):

      1. Reads the alarm ID from drilldown-raw.json and gets the alarm's rule name (LogRhythm Alarm API)
      2. Reads the logs back from alarm-logs.llx (exactly what Echo imported before)
      3. Checks Echo doesn't already have a use case with that title
      4. Creates the use case       POST /api/usecase  (JSON:API first, then plain JSON if Echo rejects the shape)
      5. Adds the logs              POST /api/addLogs
      6. Reads it back              GET  /api/usecasesByIds/<id>

    Every request/response is saved to <LabFolder>\echo-api\ so the real Echo formats are on record.
    If step 5 fails, the empty use case from step 4 is deleted again.

.PARAMETER LabFolder
    A LabPoc_<date>_<time> folder. Default: the newest one in the current folder.

.PARAMETER Title
    Use case title. Default: the alarm's rule name, e.g. 'AIE: <rule name>'.

.PARAMETER LrApiBaseUrl
    Used to look up the alarm's rule name. Default https://localhost:8501

.PARAMETER EchoBaseUrl
    Default https://localhost:33333

.PARAMETER EchoCredential
    Only if your Echo API needs a login.

.PARAMETER MsgSourceTypeName
    Name sent as msg_src_name. Default: looked up from Echo, else taken from the drilldown.

.PARAMETER AllowDuplicate
    Create even if a use case with this title exists.

.PARAMETER SkipCertificateCheck
    Accept self-signed certificates.

.EXAMPLE
    .\New-EchoUseCaseFromLab.ps1 -SkipCertificateCheck
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$LabFolder,
    [string]$Title,
    [string]$LrApiBaseUrl = 'https://localhost:8501',
    [string]$EchoBaseUrl = 'https://localhost:33333',
    [pscredential]$EchoCredential,
    [string]$MsgSourceTypeName,
    [string]$LlxToolPath,
    [switch]$AllowDuplicate,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$IsPS7 = $PSVersionTable.PSVersion.Major -ge 7
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Stage([string]$t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Write-Ok([string]$t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Info([string]$t) { Write-Host "  $t" }

if (-not $LlxToolPath) {
    $LlxToolPath = Join-Path $PSScriptRoot 'LLX-Tool.ps1'
    if (-not (Test-Path -LiteralPath $LlxToolPath)) { $LlxToolPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'LLX-Tool.ps1' }
}
if (-not (Test-Path -LiteralPath $LlxToolPath)) { throw "LLX-Tool.ps1 not found at $LlxToolPath" }
if (-not $LabFolder) {
    $LabFolder = Get-ChildItem -Directory -Filter 'LabPoc_*' | Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName
    if (-not $LabFolder) { throw 'No LabPoc_* folder here. Run the lab script first, or pass -LabFolder.' }
}
$llx = Join-Path $LabFolder 'alarm-logs.llx'
$ddFile = Join-Path $LabFolder 'drilldown-raw.json'
foreach ($f in $llx, $ddFile) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f" } }
$capDir = Join-Path $LabFolder 'echo-api'
New-Item -ItemType Directory -Path $capDir -Force | Out-Null
$script:seq = 0

# ---------------------------------------------------------------- HTTP
if (-not $IsPS7) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($SkipCertificateCheck) {
        if (-not ('LabPoc.TrustAll' -as [type])) {
            Add-Type -TypeDefinition @'
namespace LabPoc { public static class TrustAll {
  public static bool Accept(object s, System.Security.Cryptography.X509Certificates.X509Certificate c, System.Security.Cryptography.X509Certificates.X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; }
  public static void Enable() { System.Net.ServicePointManager.ServerCertificateValidationCallback = Accept; } } }
'@
        }
        [LabPoc.TrustAll]::Enable()
    }
}

function Invoke-Http([string]$Method, [string]$Url, [hashtable]$Headers = @{}, [string]$JsonBody, [string]$ContentType, $Session, [string]$Label) {
    $h = @{} + $Headers
    if ($IsPS7 -and $h.ContainsKey('Content-Type')) { if (-not $ContentType) { $ContentType = $h['Content-Type'] }; $h.Remove('Content-Type') }
    $p = @{ Method = $Method; Uri = $Url; Headers = $h; UseBasicParsing = $true; TimeoutSec = 120 }
    # Send UTF-8 bytes: Windows PowerShell 5.1 would otherwise encode a string body as ISO-8859-1
    if ($null -ne $JsonBody -and $JsonBody -ne '') { $p.Body = $Utf8.GetBytes($JsonBody) }
    if ($ContentType) { $p.ContentType = $ContentType }
    if ($Session) { $p.WebSession = $Session }
    if ($IsPS7) { $p.SkipHttpErrorCheck = $true; if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true } }
    $status = 0; $content = ''; $err = $null
    try {
        $r = Invoke-WebRequest @p
        $status = [int]$r.StatusCode
        $content = $Utf8.GetString($r.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
    }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream(), $Utf8); $content = $sr.ReadToEnd(); $sr.Dispose()
        }
        else { $err = $_.Exception.Message }
    }
    $json = $null
    if ($content) { try { $json = if ($IsPS7) { ConvertFrom-Json -InputObject $content -NoEnumerate } else { ConvertFrom-Json -InputObject $content } } catch { } }
    $script:seq++
    $safeBody = if ($JsonBody) { $JsonBody -replace '("password"\s*:\s*")[^"]*', '$1***' } else { $null }
    [ordered]@{ Label = $Label; Method = $Method; Url = $Url; ContentType = $ContentType; RequestBody = $safeBody; Status = $status; Error = $err; Response = $content } |
        ConvertTo-Json -Depth 3 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $capDir ('{0:D2}_{1}.json' -f $script:seq, ($Label -replace '[^\w]+', '_'))), $_, $Utf8) }
    [pscustomobject]@{ Status = $status; Content = $content; Json = $json; Error = $err }
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
function Show-Fail($r) { $c = ($r.Content -replace '\s+', ' '); if ($c.Length -gt 300) { $c = $c.Substring(0, 300) + '...' }; "HTTP $($r.Status) $($r.Error) $c" }

# ================================================================ 1. title
Write-Stage '1. Use case title from the alarm'
$dd = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ddFile, $Utf8))
$ddr = Get-Prop (Get-Prop $dd @('Data')) @('DrillDownResults')
$alarmId = [string](Get-Prop $ddr @('AlarmID', 'alarmId'))
$aieName = [string](Get-Prop $ddr @('AIERuleName'))
if (-not $Title) {
    $tok = $env:LR_API_TOKEN
    if ($tok -and $alarmId) {
        $ar = Invoke-Http GET "$($LrApiBaseUrl.TrimEnd('/'))/lr-alarm-api/alarms/$alarmId" @{ Authorization = "Bearer $tok"; Accept = 'application/json'; 'Content-Type' = 'application/json' } -Label 'lr alarm'
        $Title = [string](Get-Prop (Get-Prop $ar.Json @('alarmDetails')) @('alarmRuleName'))
    }
    if (-not $Title -and $aieName) { $Title = "AIE: $aieName" }
    if (-not $Title) { throw 'Could not work out the alarm rule name; pass -Title.' }
}
Write-Ok "Alarm $alarmId -> title '$Title'"

# ================================================================ 2. logs from the LLX
Write-Stage '2. Logs from the LLX'
$logs = @(& $LlxToolPath View $llx 6>$null)
if (-not $logs.Count) { throw "No messages in $llx" }
$typeId = [int]$logs[0].MsgSourceTypeID
Write-Ok "$($logs.Count) log(s), log source type $typeId"

# ================================================================ 3. Echo: login, types, existing titles
Write-Stage '3. Echo: check what is there'
$eb = $EchoBaseUrl.TrimEnd('/')
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$eh = @{ Accept = 'application/json' }
if ($EchoCredential) {
    $lr = Invoke-Http POST "$eb/api/login" $eh (@{ username = $EchoCredential.UserName; password = $EchoCredential.GetNetworkCredential().Password } | ConvertTo-Json) 'application/json; charset=utf-8' $session 'echo login'
    if ($lr.Status -lt 200 -or $lr.Status -ge 300) { throw "Echo login failed: $(Show-Fail $lr)" }
    $tk = Get-Prop $lr.Json @('token', 'access_token'); if ($tk) { $eh.Authorization = "Bearer $tk" }
    Write-Ok 'Logged in'
}
$u = Invoke-Http GET "$eb/api/usecases" $eh -Session $session -Label 'echo usecases'
if ($u.Status -ne 200) { throw "GET /api/usecases failed: $(Show-Fail $u)" }
$existing = Get-Array $u.Json @('usecases', 'data', 'objects', 'items')
$dupe = @($existing | Where-Object { $a = Get-Prop $_ @('attributes'); if (-not $a) { $a = $_ }; [string](Get-Prop $a @('title', 'name')) -eq $Title })
Write-Info "Echo has $($existing.Count) use case(s)"
if ($dupe.Count -and -not $AllowDuplicate) { throw "Echo already has a use case titled '$Title' (ID $(Get-Prop $dupe[0] @('id'))). Delete it in Echo, or use -AllowDuplicate / -Title." }

if (-not $MsgSourceTypeName) {
    $t = Invoke-Http GET "$eb/api/msgsourcetypes" $eh -Session $session -Label 'echo msgsourcetypes'
    foreach ($x in (Get-Array $t.Json @('msgsourcetypes', 'data', 'items'))) {
        $xid = Get-Prop $x @('MsgSourceTypeID', 'msgSourceTypeId', 'msg_src_id', 'id')
        if ("$xid" -eq "$typeId") { $MsgSourceTypeName = [string](Get-Prop $x @('FullName', 'Name', 'name', 'msg_src_name')); break }
    }
    if (-not $MsgSourceTypeName) {
        foreach ($b in (Get-Array $ddr @('RuleBlocks'))) {
            $dl = Get-Prop $b @('DrillDownLogs'); if ($dl -is [string]) { $dl = ConvertFrom-Json -InputObject $dl }
            foreach ($l in @($dl)) { $n = [string](Get-Prop $l @('msgSourceTypeName', 'MsgSourceTypeName', 'logSourceTypeName')); if ($n) { $MsgSourceTypeName = $n; break } }
            if ($MsgSourceTypeName) { break }
        }
    }
}
Write-Ok "Log source type name: '$MsgSourceTypeName'"

# ================================================================ 4. create use case
Write-Stage '4. Create the use case (POST /api/usecase)'
$desc = "Created via API from alarm $alarmId ($($logs.Count) log(s) from its AIE drilldown) on $((Get-Date).ToString('yyyy-MM-dd HH:mm'))."
$attrs = [ordered]@{ title = $Title; description = $desc; timedelay = 0 }
$ucId = $null
# Plain JSON is what a live Echo accepted (lab-confirmed); JSON:API kept as a fallback for other Echo versions
$attempts = @(
    @{ Label = 'create usecase plain JSON'; Ct = 'application/json; charset=utf-8'; Body = ($attrs | ConvertTo-Json) },
    @{ Label = 'create usecase JSON-API'; Ct = 'application/vnd.api+json'; Body = (@{ data = @{ type = 'usecase'; attributes = $attrs } } | ConvertTo-Json -Depth 5) }
)
foreach ($a in $attempts) {
    $ch = @{} + $eh; $ch['Accept'] = 'application/vnd.api+json, application/json'
    $r = Invoke-Http POST "$eb/api/usecase" $ch $a.Body $a.Ct $session $a.Label
    Write-Info ("{0,-28} HTTP {1}" -f $a.Label, $r.Status)
    if ($r.Status -ge 200 -and $r.Status -lt 300) {
        $d = Get-Prop $r.Json @('data'); if ($null -eq $d) { $d = $r.Json }
        $ucId = [string](Get-Prop $d @('id', 'ID', 'usecase_id'))
        if ($ucId) { Write-Ok "Created use case ID $ucId via $($a.Label)"; break }
        Write-Host "  Created, but couldn't find the new ID in the response. Saved in echo-api\." -ForegroundColor Yellow
        break
    }
    Write-Info "  $(Show-Fail $r)"
    if ($r.Status -notin 400, 406, 415, 422) { break }
}
if (-not $ucId) { throw "Could not create the use case. The requests and Echo's answers are in $capDir. Send me those files." }

# ================================================================ 5. add logs
Write-Stage '5. Add the logs (POST /api/addLogs)'
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
$i = 0
$payload = @(foreach ($l in $logs) {
        $i++
        [ordered]@{
            owner_id     = $(if ($ucId -match '^\d+$') { [int]$ucId } else { $ucId })
            description  = "Drilldown log $i of $($logs.Count) from alarm $alarmId"
            message      = "$Title ($i/$($logs.Count))"
            log          = [string]$l.Message
            msg_src_id   = $typeId
            msg_src_name = $MsgSourceTypeName
            timestamp    = $now
            customtime   = $false
            play_order   = $i
        }
    })
$r = Invoke-Http POST "$eb/api/addLogs" $eh (ConvertTo-Json -InputObject $payload -Depth 4) 'application/json; charset=utf-8' $session 'add logs'
Write-Info "addLogs HTTP $($r.Status)"
if ($r.Status -lt 200 -or $r.Status -ge 300) {
    Write-Host "  $(Show-Fail $r)" -ForegroundColor Red
    $del = Invoke-Http POST "$eb/api/deleteUseCases" $eh (ConvertTo-Json -InputObject @([int]$ucId) -Compress) 'application/json; charset=utf-8' $session 'rollback delete'
    Write-Host "  Rolled back the empty use case $ucId (delete HTTP $($del.Status)). If that isn't 2xx, delete it in the Echo UI." -ForegroundColor Yellow
    throw "addLogs failed. The requests and Echo's answers are in $capDir. Send me those files."
}
Write-Ok "$($payload.Count) log(s) added"

# ================================================================ 6. verify
Write-Stage '6. Read it back (GET /api/usecasesByIds)'
$v = Invoke-Http GET "$eb/api/usecasesByIds/$ucId" $eh -Session $session -Label 'verify'
if ($v.Status -eq 200) {
    $uc = Get-Array $v.Json @('usecases', 'data')
    $one = if ($uc.Count) { $uc[0] } else { $v.Json }
    $vl = Get-Array $one @('logs', 'log')
    $first = if ($vl.Count) { [string](Get-Prop $vl[0] @('log', 'Log', 'message')) } else { '' }
    $same = $vl.Count -and ($first -ceq [string]$logs[0].Message -or $first -ceq ([string]$logs[0].Message).TrimEnd())
    Write-Ok ("Echo returns '{0}' with {1} log(s); first log text {2}" -f [string](Get-Prop $one @('title')), $vl.Count, $(if ($same) { 'matches' } elseif ($vl.Count) { 'DIFFERS - check echo-api\' } else { 'not shown in this response' }))
}
else { Write-Info "Verify call returned HTTP $($v.Status); check the use case in the Echo UI." }

Write-Host @"

  Done. In the Echo UI: open '$Title', check its $($logs.Count) log(s) show as $MsgSourceTypeName, then run it.
  Every API request/response is in: $capDir
"@
