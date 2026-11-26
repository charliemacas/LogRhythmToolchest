<#
.SYNOPSIS
    Builds one LogRhythm Echo use case per enabled AIE rule, from the logs that
    actually triggered that rule's alarms.

.DESCRIPTION
    Pipeline (each stage saves its results to the run folder, so a run can be resumed):

      1. Rules      List enabled AIE rules (EMDB SQL query, or a CSV you supply)
      2. Alarms     Page through recent alarms (LogRhythm Alarm API) and group them by rule name
      3. Drilldown  For each rule, fetch the triggering logs of its newest alarm
                    (AIE Drilldown Cache API), falling back to older alarms if needed
      4. LLX        Write one .llx per rule with LLX-Tool.ps1 (per-log log source types kept)
      5. Echo       Send the .llx through Echo's own LLX unpacker, create the use case and add the logs
      6. Report     coverage-report.csv / .html: every enabled rule and what happened to it

    Modes
      Discover  Read-only. Calls each API once and saves the raw responses so formats can be checked.
      Run       The full pipeline (use -StopAfter to stop early, -DryRun to send nothing to Echo).
      Report    Rebuild the report from an existing run folder.

    Several Echo endpoints are undocumented. Every HTTP request and response is saved to
    <run>\http\ (secrets redacted) so problems can be diagnosed. See HANDOVER.md.

.PARAMETER Mode
    Discover | Run | Report. Default Run.

.PARAMETER RunFolder
    Where results are written. Default: .\EchoCoverage_<date>_<time>. Use an existing folder with -Resume.

.PARAMETER Resume
    Continue a previous run in -RunFolder. Completed steps are skipped.

.PARAMETER RulesCsv
    CSV of AIE rules instead of SQL. Needs columns for ID and name (AIERuleID/RuleID/ID and Name/RuleName).

.PARAMETER SqlServer
    SQL Server holding the EMDB (e.g. the Platform Manager). Used when -RulesCsv isn't given.

.PARAMETER SqlDatabase
    Default LogRhythmEMDB.

.PARAMETER SqlCredential
    SQL login. Omit to use Windows authentication.

.PARAMETER SqlTrustServerCertificate
    Trust the SQL Server's certificate without validation.

.PARAMETER RulesQuery
    Your own SQL returning AIERuleID and Name for the enabled rules. Overrides the built-in query.

.PARAMETER RuleFilter
    Only process rules whose name or ID matches one of these (wildcards allowed). Good for testing.

.PARAMETER RenameMapCsv
    CSV with OldName,NewName columns for AIE rules that were renamed. Alarms raised under the old
    name are counted for the new name (the drilldown's AIERuleID check still guards against mismatches).

.PARAMETER LrApiBaseUrl
    LogRhythm API gateway, e.g. https://platformmanager:8501

.PARAMETER LrApiToken
    LogRhythm API token as a SecureString. If omitted, $env:LR_API_TOKEN is used, then you are prompted.

.PARAMETER LookbackDays
    How far back to look for alarms. Default 90.

.PARAMETER AlarmPageSize
    Alarms per Alarm API request. Default 500.

.PARAMETER MaxAlarmsTotal
    Stop paging after this many alarms. Default 50000.

.PARAMETER AlarmQueryExtra
    Extra query string for the alarm list call, e.g. '&alarmStatus=New'. Appended verbatim.

.PARAMETER MaxAlarmsPerRule
    Newest alarms to try per rule when looking for drilldown logs. Default 5.

.PARAMETER MaxLogsPerRule
    Cap on logs per use case. Default 500.

.PARAMETER LlxToolPath
    Path to LLX-Tool.ps1. Default: next to this script.

.PARAMETER LicenseID
    LicenseID written into the .llx files.

.PARAMETER TemplateLlx
    An .llx from this LogRhythm system; its LicenseID, SubmittedBy and version are reused.

.PARAMETER EchoBaseUrl
    Echo API base. Default https://localhost:33333

.PARAMETER EchoCredential
    Echo login. Omit if your Echo API doesn't require one.

.PARAMETER EchoImportMode
    Unpack (default): upload each .llx to Echo's /api/unpackLLXFile and use what Echo returns.
    Direct: send the logs straight to /api/addLogs (the .llx is still written to disk).

.PARAMETER EchoLlxUploadField
    Multipart field name for the LLX upload. Default 'file'.

.PARAMETER ExistingUseCase
    Skip (default): leave a use case alone if one with the same title exists.
    Duplicate: create another one anyway.

.PARAMETER TitlePrefix
    Optional prefix for use case titles. Titles are the alarm name (e.g. 'AIE: <rule name>'), so none by default.

.PARAMETER TimeDelaySeconds
    Echo use case time delay (backdating between logs). Default 0.

.PARAMETER DryRun
    Build everything but send nothing to Echo; payloads are saved under <run>\echo\.

.PARAMETER StopAfter
    Stop after this stage: Rules, Alarms, Drilldown, Llx, Echo.

.PARAMETER Anonymise
    Consistently replace IP addresses, e-mail addresses, Windows user/host/domain fields,
    hosts under -AnonymiseDomain and any terms in -AnonymiseTermsFile, before the .llx is written.

.PARAMETER AnonymiseDomain
    DNS suffixes whose host names should be anonymised, e.g. 'corp.local','example.com'.

.PARAMETER AnonymiseTermsFile
    Text file: one term per line (or 'original,replacement'). Replaced case-insensitively.

.PARAMETER AnonymiseSalt
    Secret that makes replacements unpredictable. Default: random per run.

.PARAMETER SkipCertificateCheck
    Accept self-signed certificates on the LogRhythm API and Echo (typical for both).

.PARAMETER RequestDelayMs
    Pause between API calls. Default 0.

.PARAMETER EchoProbeLlx
    Discover mode only: also upload this .llx to /api/unpackLLXFile to capture its response.

.EXAMPLE
    # 1. Capture real responses first (read-only)
    .\Build-EchoCoverage.ps1 -Mode Discover -SqlServer PM01 -LrApiBaseUrl https://PM01:8501 -SkipCertificateCheck

.EXAMPLE
    # 2. Try three rules without touching Echo
    .\Build-EchoCoverage.ps1 -SqlServer PM01 -LrApiBaseUrl https://PM01:8501 -RuleFilter 'Brute*','1000000123' -DryRun -SkipCertificateCheck

.EXAMPLE
    # 3. Full run
    .\Build-EchoCoverage.ps1 -SqlServer PM01 -LrApiBaseUrl https://PM01:8501 -TemplateLlx .\export.llx -EchoCredential (Get-Credential) -SkipCertificateCheck

.EXAMPLE
    # Resume after a failure
    .\Build-EchoCoverage.ps1 -Resume -RunFolder .\EchoCoverage_20261126_1400 -SqlServer PM01 -LrApiBaseUrl https://PM01:8501 -SkipCertificateCheck

.NOTES
    Name    : Build-EchoCoverage.ps1
    Version : 1.0.0 (formats confirmed in a live lab: LogRhythm 7.x drilldown API, Echo REST API)
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Discover', 'Run', 'Report')]
    [string]$Mode = 'Run',
    [string]$RunFolder,
    [switch]$Resume,

    # Rules
    [string]$RulesCsv,
    [string]$SqlServer,
    [string]$SqlDatabase = 'LogRhythmEMDB',
    [pscredential]$SqlCredential,
    [switch]$SqlTrustServerCertificate,
    [string]$RulesQuery,
    [string[]]$RuleFilter,
    [string]$RenameMapCsv,

    # LogRhythm API
    [string]$LrApiBaseUrl,
    [securestring]$LrApiToken,
    [ValidateRange(1, 3650)][int]$LookbackDays = 90,
    [ValidateRange(1, 5000)][int]$AlarmPageSize = 500,
    [ValidateRange(1, 10000000)][int]$MaxAlarmsTotal = 50000,
    [string]$AlarmQueryExtra = '',
    [ValidateRange(1, 100)][int]$MaxAlarmsPerRule = 5,
    [ValidateRange(1, 100000)][int]$MaxLogsPerRule = 500,

    # LLX
    [string]$LlxToolPath,
    [int]$LicenseID,
    [string]$TemplateLlx,

    # Echo
    [string]$EchoBaseUrl = 'https://localhost:33333',
    [pscredential]$EchoCredential,
    [ValidateSet('Unpack', 'Direct')][string]$EchoImportMode = 'Unpack',
    [string]$EchoLlxUploadField = 'file',
    [ValidateSet('Skip', 'Duplicate')][string]$ExistingUseCase = 'Skip',
    [string]$TitlePrefix = '',
    [ValidateRange(0, 86400)][int]$TimeDelaySeconds = 0,
    [switch]$DryRun,
    [ValidateSet('Rules', 'Alarms', 'Drilldown', 'Llx', 'Echo')][string]$StopAfter,

    # Anonymiser
    [switch]$Anonymise,
    [string[]]$AnonymiseDomain,
    [string]$AnonymiseTermsFile,
    [string]$AnonymiseSalt,

    # Transport
    [switch]$SkipCertificateCheck,
    [ValidateRange(0, 60000)][int]$RequestDelayMs = 0,

    [string]$EchoProbeLlx
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'
$StageOrder = @('Rules', 'Alarms', 'Drilldown', 'Llx', 'Echo')

# =====================================================================================
# Run folder, logging, state
# =====================================================================================

if (-not $RunFolder) {
    if ($Resume -or $Mode -eq 'Report') { throw '-RunFolder is required with -Resume or -Mode Report.' }
    $RunFolder = Join-Path (Get-Location).Path ('EchoCoverage_{0:yyyyMMdd_HHmmss}' -f (Get-Date))
}
$RunFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunFolder)
foreach ($d in '', 'http', 'drilldown', 'llx', 'echo', 'discover') {
    $p = Join-Path $RunFolder $d
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
$LogFile = Join-Path $RunFolder 'run.log'
$StateFile = Join-Path $RunFolder 'state.json'
$script:HttpSeq = 0
$script:LrTokenPlain = $null
$script:State = $null
$script:AnonLookup = @{}
$script:TypesLoaded = $false
$script:EchoConnected = $false
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO') {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $Utf8)
    $colour = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } 'STEP' { 'Cyan' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $colour
}

function Save-Json($Object, [string]$Path, [int]$Depth = 12) {
    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth $Depth), $Utf8)
}

function ConvertFrom-JsonSafe([string]$Text) {
    # Keep JSON arrays as arrays (PowerShell 7 unrolls one-element arrays unless -NoEnumerate)
    if ($PSVersionTable.PSVersion.Major -ge 7) { return , (ConvertFrom-Json -InputObject $Text -NoEnumerate) }
    return , (ConvertFrom-Json -InputObject $Text)
}

function Read-Json([string]$Path) {
    return , (ConvertFrom-JsonSafe ([System.IO.File]::ReadAllText($Path, $Utf8)))
}

function Get-SafeName([string]$Text, [int]$Max = 60) {
    $s = ($Text -replace '[^\w\-\. ]', '_' -replace '\s+', '_').Trim('_')
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max) }
    return $s
}

# Case-insensitive property lookup across several candidate names (StrictMode-safe)
function Get-Prop($Object, [string[]]$Names) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($n in $Names) { foreach ($k in $Object.Keys) { if ([string]::Equals([string]$k, $n, 'OrdinalIgnoreCase')) { return , $Object[$k] } } }
        return $null
    }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        # comma: keep one-element arrays as arrays
        if ($p) { return , $p.Value }
    }
    return $null
}

function Get-PropName($Object, [string[]]$Names) {
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) { $p = $Object.PSObject.Properties[$n]; if ($p) { return $p.Name } }
    return $null
}

function Find-Array($Object, [string[]]$Names) {
    # Returns the first array found at the root or under one of the given property names
    if ($null -eq $Object) { return , @() }
    if ($Object -is [System.Array]) { return , $Object }
    foreach ($n in $Names) {
        $v = Get-Prop $Object @($n)
        if ($v -is [System.Array]) { return , $v }
        if ($null -ne $v -and $v -isnot [string] -and $v -isnot [ValueType]) {
            $inner = Find-Array $v $Names
            if ($inner.Count) { return , $inner }
        }
    }
    return , @()
}

function Test-StageAllowed([string]$Stage) {
    if (-not $StopAfter) { return $true }
    return ([array]::IndexOf($StageOrder, $Stage) -le [array]::IndexOf($StageOrder, $StopAfter))
}

# State: one record per rule, saved after every change so -Resume can pick up
function Save-State { Save-Json $script:State $StateFile }

function New-RuleRecord($Id, $Name) {
    [pscustomobject]@{
        RuleID = [string]$Id; Name = [string]$Name
        Status = 'Pending'; Detail = ''
        AlarmCount = 0; AlarmName = $null; AlarmIDs = @(); AlarmCandidates = @(); AlarmUsed = $null; AlarmDate = $null
        RuleBlocks = 0; Logs = 0; LogSourceTypes = ''; AieCount = $null; DxCount = $null
        LlxFile = $null; EchoUseCaseID = $null; EchoTitle = $null; EchoLogs = 0
        Done = [pscustomobject]@{ Alarms = $false; Drilldown = $false; Llx = $false; Echo = $false }
        Notes = @()
    }
}

function Add-Note($Rule, [string]$Note) { $Rule.Notes = @($Rule.Notes) + $Note }

# =====================================================================================
# HTTP
# =====================================================================================

$IsPS7 = $PSVersionTable.PSVersion.Major -ge 7
if (-not $IsPS7) {
    # Windows PowerShell 5.1 defaults can exclude TLS 1.2
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    if ($SkipCertificateCheck) {
        if (-not ('EchoCoverage.TrustAll' -as [type])) {
            Add-Type -TypeDefinition @'
namespace EchoCoverage {
    public static class TrustAll {
        public static bool Accept(object s, System.Security.Cryptography.X509Certificates.X509Certificate c,
            System.Security.Cryptography.X509Certificates.X509Chain ch, System.Net.Security.SslPolicyErrors e) { return true; }
        public static void Enable() {
            System.Net.ServicePointManager.ServerCertificateValidationCallback = Accept;
        }
    }
}
'@
        }
        [EchoCoverage.TrustAll]::Enable()
    }
}

function Get-PlainToken([securestring]$Secure) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Protect-Text([string]$Text) {
    # Redact secrets before anything is written to disk
    if (-not $Text) { return $Text }
    $t = $Text -replace '(?i)("?(password|passwd|pwd|token|access_token|secret|authorization)"?\s*[:=]\s*")[^"]*(")', '$1***$3'
    $t = $t -replace '(?i)(Bearer\s+)[A-Za-z0-9\-\._~\+/]+=*', '$1***'
    return $t
}

function Invoke-Api {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [hashtable]$Headers = @{},
        $Body,
        [string]$ContentType,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$Label = 'call',
        [int]$TimeoutSec = 120
    )
    if ($RequestDelayMs) { Start-Sleep -Milliseconds $RequestDelayMs }
    $script:HttpSeq++
    $seq = $script:HttpSeq
    $h = @{} + $Headers
    # PowerShell 7 only sends Content-Type via -ContentType; 5.1 sends it from -Headers (verified on 5.1 against the drilldown API)
    if ($IsPS7 -and $h.ContainsKey('Content-Type')) { if (-not $ContentType) { $ContentType = $h['Content-Type'] }; $h.Remove('Content-Type') }
    $args2 = @{ Method = $Method; Uri = $Url; Headers = $h; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
    if ($null -ne $Body) { $args2.Body = $Body }
    if ($ContentType) { $args2.ContentType = $ContentType }
    if ($Session) { $args2.WebSession = $Session }
    if ($IsPS7) { $args2.SkipHttpErrorCheck = $true; if ($SkipCertificateCheck) { $args2.SkipCertificateCheck = $true } }

    $status = 0; $content = ''; $err = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest @args2
        $status = [int]$resp.StatusCode
        # Decode as UTF-8 ourselves (Windows PowerShell 5.1 assumes ISO-8859-1 without a charset: NBSP becomes 'Â ')
        $content = $Utf8.GetString($resp.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
    }
    catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($r) {
            $status = [int]$r.StatusCode
            $sr = New-Object System.IO.StreamReader($r.GetResponseStream(), $Utf8)
            $content = $sr.ReadToEnd(); $sr.Dispose()
        }
        else { $err = $_.Exception.Message }
    }
    catch { $err = $_.Exception.Message }
    $ms = $sw.ElapsedMilliseconds

    $json = $null
    if ($content) { try { $json = ConvertFrom-JsonSafe $content } catch { } }

    # Capture (secrets redacted, large bodies truncated)
    $bodyText = $null
    if ($null -ne $Body) {
        $bodyText = if ($Body -is [byte[]]) { "<$($Body.Length) bytes binary>" } else { [string]$Body }
        if ($bodyText.Length -gt 200000) { $bodyText = $bodyText.Substring(0, 200000) + '...<truncated>' }
    }
    $capContent = if ($content -and $content.Length -gt 2000000) { $content.Substring(0, 2000000) + '...<truncated>' } else { $content }
    $slug = Get-SafeName (([uri]$Url).AbsolutePath) 50
    $cap = [ordered]@{
        Seq = $seq; Label = $Label; Time = (Get-Date).ToString('o'); Method = $Method
        Url = $Url; ContentType = $ContentType
        RequestHeaders = @($Headers.Keys | ForEach-Object { if ($_ -match '(?i)auth|token|cookie') { "${_}: ***" } else { "${_}: $($Headers[$_])" } })
        RequestBody = (Protect-Text $bodyText); Status = $status; Ms = $ms; Error = $err
        ResponseBody = (Protect-Text $capContent)
    }
    Save-Json $cap (Join-Path (Join-Path $RunFolder 'http') ('{0:D5}_{1}_{2}.json' -f $seq, $Method, $slug)) 4

    [pscustomobject]@{ Status = $status; Content = $content; Json = $json; Error = $err; Seq = $seq }
}

function Get-LrHeaders {
    if (-not $script:LrTokenPlain) {
        $tok = $LrApiToken
        if (-not $tok -and $env:LR_API_TOKEN) { $tok = ConvertTo-SecureString $env:LR_API_TOKEN -AsPlainText -Force }
        if (-not $tok) { $tok = Read-Host 'LogRhythm API token' -AsSecureString }
        $script:LrTokenPlain = Get-PlainToken $tok
    }
    # Content-Type is required: the drilldown API returns 400 'Invalid request at route' without it, even on GET
    return @{ Authorization = "Bearer $($script:LrTokenPlain)"; Accept = 'application/json'; 'Content-Type' = 'application/json' }
}

function Get-NameKey([string]$Name) {
    # Alarm names and AIE rule names are matched case-insensitively, ignoring an 'AIE:' prefix on either side
    return (($Name -replace '^\s*AIE\s*:\s*', '').Trim()).ToLowerInvariant()
}

function Join-Url([string]$Base, [string]$Path) { return $Base.TrimEnd('/') + '/' + $Path.TrimStart('/') }

# =====================================================================================
# Stage 1: rules
# =====================================================================================

function Invoke-Sql([string]$Query) {
    $cs = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $cs['Data Source'] = $SqlServer
    $cs['Initial Catalog'] = $SqlDatabase
    $cs['Application Name'] = 'Build-EchoCoverage'
    if ($SqlTrustServerCertificate) { $cs['TrustServerCertificate'] = $true }
    if ($SqlCredential) {
        $cs['User ID'] = $SqlCredential.UserName
        $cs['Password'] = $SqlCredential.GetNetworkCredential().Password
    }
    else { $cs['Integrated Security'] = $true }
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs.ConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = 120
        $da = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        return , $dt
    }
    finally { $conn.Dispose() }
}

function Get-EmdbColumns([string]$Table) {
    $dt = Invoke-Sql "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='dbo' AND TABLE_NAME='$Table'"
    return @($dt.Rows | ForEach-Object { [string]$_.COLUMN_NAME })
}

function Get-DefaultRulesQuery {
    # The EMDB schema is undocumented: build the query from the columns that exist.
    $ruleCols = Get-EmdbColumns 'AIERule'
    if (-not $ruleCols) { throw "Table dbo.AIERule not found in $SqlDatabase." }
    $where = New-Object System.Collections.Generic.List[string]
    if ($ruleCols -contains 'RecordStatus') { $where.Add('r.RecordStatus = 1') }
    if ($ruleCols -contains 'Enabled') { $where.Add('r.Enabled = 1') }
    $engCols = Get-EmdbColumns 'AIERuleToEngine'
    if ($engCols -contains 'AIERuleID') {
        $e = 'EXISTS (SELECT 1 FROM dbo.AIERuleToEngine e WHERE e.AIERuleID = r.AIERuleID'
        if ($engCols -contains 'Enabled') { $e += ' AND e.Enabled = 1' }
        if ($engCols -contains 'RecordStatus') { $e += ' AND e.RecordStatus = 1' }
        $where.Add($e + ')')
    }
    $q = 'SELECT r.AIERuleID, r.Name FROM dbo.AIERule r'
    if ($where.Count) { $q += ' WHERE ' + ($where -join ' AND ') }
    return $q + ' ORDER BY r.Name'
}

function Get-EnabledRules {
    $rows = @()
    if ($RulesCsv) {
        Write-Log "Reading rules from $RulesCsv"
        foreach ($r in @(Import-Csv -LiteralPath $RulesCsv)) {
            $id = Get-Prop $r @('AIERuleID', 'RuleID', 'ID', 'Id')
            $name = Get-Prop $r @('Name', 'RuleName', 'AIERuleName')
            if ($name) { $rows += [pscustomobject]@{ RuleID = [string]$id; Name = ([string]$name).Trim() } }
        }
    }
    elseif ($SqlServer) {
        $q = if ($RulesQuery) { $RulesQuery } else { Get-DefaultRulesQuery }
        Write-Log "Querying $SqlServer/$SqlDatabase for enabled AIE rules"
        Write-Log "SQL: $q"
        $dt = Invoke-Sql $q
        foreach ($r in $dt.Rows) {
            $id = if ($dt.Columns.Contains('AIERuleID')) { $r['AIERuleID'] } else { $r[0] }
            $name = if ($dt.Columns.Contains('Name')) { $r['Name'] } else { $r[1] }
            $rows += [pscustomobject]@{ RuleID = [string]$id; Name = ([string]$name).Trim() }
        }
    }
    else { throw 'Give -SqlServer (EMDB) or -RulesCsv to list the AIE rules.' }

    if ($RuleFilter) {
        $rows = @($rows | Where-Object {
                $r = $_
                @($RuleFilter | Where-Object { $r.Name -like $_ -or $r.RuleID -like $_ }).Count -gt 0
            })
    }
    return , $rows
}

# =====================================================================================
# Stage 2: alarms
# =====================================================================================

function ConvertTo-DateSafe($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    $d = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal', [ref]$d)) { return $d }
    return $null
}

function Get-RecentAlarms {
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$LookbackDays)
    $all = New-Object System.Collections.Generic.List[object]
    $offset = 0
    $base = Join-Url $LrApiBaseUrl 'lr-alarm-api/alarms'
    while ($true) {
        $url = '{0}?count={1}&offset={2}&orderby=dateInserted&dir=descending{3}' -f $base, $AlarmPageSize, $offset, $AlarmQueryExtra
        $r = Invoke-Api -Method GET -Url $url -Headers (Get-LrHeaders) -Label 'alarms'
        if ($r.Status -eq 401 -or $r.Status -eq 403) { throw "Alarm API refused the token (HTTP $($r.Status))." }
        if ($r.Status -lt 200 -or $r.Status -ge 300) { throw "Alarm API failed: HTTP $($r.Status) $($r.Error)" }
        $page = Find-Array $r.Json @('alarmsSearchDetails', 'alarms', 'data', 'items', 'results')
        if ($page.Count -eq 0) { break }
        $oldestOnPage = $null
        foreach ($a in $page) {
            $rec = [pscustomobject]@{
                AlarmID  = [string](Get-Prop $a @('alarmId', 'alarmID', 'AlarmId', 'id'))
                RuleName = ([string](Get-Prop $a @('alarmRuleName', 'AlarmRuleName', 'alarmName', 'ruleName'))).Trim()
                Date     = ConvertTo-DateSafe (Get-Prop $a @('dateInserted', 'DateInserted', 'alarmDate', 'date'))
                Entity   = [string](Get-Prop $a @('entityName', 'EntityName'))
                Cached   = [string](Get-Prop $a @('alarmDataCached'))
            }
            if ($rec.Date -and (-not $oldestOnPage -or $rec.Date -lt $oldestOnPage)) { $oldestOnPage = $rec.Date }
            if (-not $rec.Date -or $rec.Date -ge $cutoff) { $all.Add($rec) }
        }
        Write-Log ("  alarms page offset {0}: {1} returned, {2} kept so far" -f $offset, $page.Count, $all.Count)
        if ($page.Count -lt $AlarmPageSize) { break }
        if ($oldestOnPage -and $oldestOnPage -lt $cutoff) { break }
        $offset += $page.Count
        if ($offset -ge $MaxAlarmsTotal) { Write-Log "Stopped paging at -MaxAlarmsTotal $MaxAlarmsTotal" 'WARN'; break }
    }
    return , $all.ToArray()
}

# =====================================================================================
# Stage 3: drilldown
# =====================================================================================

$MsgKeys = @('logMessage', 'LogMessage', 'rawLog', 'RawLog', 'message', 'Message', 'log', 'msg')
# Lab-confirmed (LogRhythm 7.x drilldown): logMessage, logSourceType (type ID), logSourceTypeName, logSourceId,
# logSourceName, ruleBlockNumber, sequenceNumber, normalDate. Other names kept as fallbacks.
$TypeIdKeys = @('logSourceType', 'msgSourceTypeId', 'MsgSourceTypeID', 'logSourceTypeId', 'LogSourceTypeID')
$TypeNameKeys = @('msgSourceTypeName', 'MsgSourceTypeName', 'logSourceTypeName', 'LogSourceTypeName', 'msgSourceType')
$SourceIdKeys = @('logSourceId', 'msgSourceId', 'MsgSourceID', 'LogSourceID')
$SourceNameKeys = @('msgSourceName', 'MsgSourceName', 'logSourceName', 'LogSourceName')
$DateKeys = @('normalDate', 'NormalDate', 'normalMsgDate', 'NormalMsgDate', 'logDate', 'LogDate', 'dateInserted', 'insertedDate')
$MpeKeys = @('mpeRuleId', 'MPERuleID', 'mpeRuleID', 'commonEventId')

function ConvertFrom-Drilldown($Json) {
    # Returns @{ Blocks; Logs; AieRuleID; Status }. Tolerant of field-name and nesting variations.
    $res = Get-Prop $Json @('Data', 'data')
    if ($null -eq $res) { $res = $Json }
    $dd = Get-Prop $res @('DrillDownResults', 'drillDownResults', 'drilldownResults')
    if ($null -eq $dd) { $dd = $res }
    $aieRuleId = Get-Prop $dd @('AIERuleID', 'aieRuleId', 'AieRuleID', 'ruleId')
    $blocks = Find-Array $dd @('RuleBlocks', 'ruleBlocks', 'ruleBlockDetails')
    $logs = New-Object System.Collections.Generic.List[object]
    $aie = 0; $dx = 0; $haveCounts = $false
    $bi = 0
    foreach ($b in $blocks) {
        $bi++
        $bid = Get-Prop $b @('RuleBlockID', 'ruleBlockId', 'RuleBlockId', 'blockId')
        if ($null -eq $bid) { $bid = $bi }
        $ac = Get-Prop $b @('AIECount', 'aieCount', 'AIEMsgCount', 'aieMsgCount')
        $dc = Get-Prop $b @('DXCount', 'dxCount', 'DXMsgCount', 'dxMsgCount')
        if ($null -ne $ac) { $aie += [int]$ac; $haveCounts = $true }
        if ($null -ne $dc) { $dx += [int]$dc }
        $raw = Get-Prop $b @('DrillDownLogs', 'drillDownLogs', 'drilldownLogs', 'logs')
        if ($raw -is [string]) { if ($raw.Trim()) { try { $raw = ConvertFrom-JsonSafe $raw } catch { $raw = $null } } else { $raw = $null } }
        $li = 0
        foreach ($l in @($raw)) {
            if ($null -eq $l) { continue }
            $li++
            $msg = if ($l -is [string]) { $l } else { Get-Prop $l $MsgKeys }
            if (-not $msg) { continue }
            $tid = Get-Prop $l $TypeIdKeys
            if ($null -ne $tid -and "$tid" -notmatch '^-?\d+$') { $tid = $null }   # only accept a numeric type ID
            $rbn = Get-Prop $l @('ruleBlockNumber', 'RuleBlockNumber')
            $seqn = Get-Prop $l @('sequenceNumber', 'SequenceNumber')
            $logs.Add([pscustomobject]@{
                    Block          = $(if ($null -ne $rbn -and "$rbn" -match '^\d+$') { [int]$rbn } else { [int]$bid })
                    Index          = $(if ($null -ne $seqn -and "$seqn" -match '^\d+$') { [int]$seqn } else { $li })
                    Message        = [string]$msg
                    MsgSourceTypeID = $tid
                    MsgSourceTypeName = [string](Get-Prop $l $TypeNameKeys)
                    MsgSourceID    = (Get-Prop $l $SourceIdKeys)
                    MsgSourceName  = [string](Get-Prop $l $SourceNameKeys)
                    MPERuleID      = (Get-Prop $l $MpeKeys)
                    Date           = ConvertTo-DateSafe (Get-Prop $l $DateKeys)
                })
        }
    }
    [pscustomobject]@{
        Blocks = $blocks.Count; Logs = $logs.ToArray(); AieRuleID = $aieRuleId
        AieCount = $(if ($haveCounts) { $aie } else { $null }); DxCount = $(if ($haveCounts) { $dx } else { $null })
    }
}

function Get-RuleDrilldown($Rule) {
    foreach ($alarmId in @($Rule.AlarmIDs)) {
        $url = Join-Url $LrApiBaseUrl "lr-drilldown-cache-api/drilldown/$alarmId"
        $r = Invoke-Api -Method GET -Url $url -Headers (Get-LrHeaders) -Label "drilldown $alarmId"
        if ($r.Status -eq 204 -or (-not $r.Content)) { Add-Note $Rule "alarm ${alarmId}: no drilldown data (HTTP $($r.Status))"; continue }
        if ($r.Status -lt 200 -or $r.Status -ge 300) { Add-Note $Rule "alarm ${alarmId}: drilldown HTTP $($r.Status)"; continue }
        if (-not $r.Json) { Add-Note $Rule "alarm ${alarmId}: drilldown response was not JSON"; continue }
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $RunFolder 'drilldown') ("{0}_{1}.json" -f $Rule.RuleID, $alarmId)), $r.Content, $Utf8)
        $dd = ConvertFrom-Drilldown $r.Json
        if ($dd.Logs.Count -eq 0) { Add-Note $Rule "alarm ${alarmId}: drilldown had $($dd.Blocks) rule block(s) but no raw logs"; continue }
        if ($dd.AieRuleID -and $Rule.RuleID -and ([string]$dd.AieRuleID -ne $Rule.RuleID)) {
            Add-Note $Rule "alarm ${alarmId} skipped: it belongs to AIERuleID $($dd.AieRuleID), not $($Rule.RuleID)"
            continue
        }
        return [pscustomobject]@{ AlarmID = $alarmId; Result = $dd }
    }
    return $null
}

# =====================================================================================
# Anonymiser
# =====================================================================================

$script:AnonMap = [ordered]@{}
$script:AnonSalt = if ($AnonymiseSalt) { $AnonymiseSalt } else { [guid]::NewGuid().ToString('N') }
$script:Sha = [System.Security.Cryptography.SHA256]::Create()

function Get-Hash([string]$Value) {
    $b = $script:Sha.ComputeHash($Utf8.GetBytes($script:AnonSalt + '|' + $Value.ToLowerInvariant()))
    return $b
}

function Get-Alias([string]$Kind, [string]$Value) {
    $key = "$Kind|$($Value.ToLowerInvariant())"
    if ($script:AnonMap.Contains($key)) { return $script:AnonMap[$key].Replacement }
    $h = Get-Hash "$Kind|$Value"
    $tag = ('{0:x2}{1:x2}{2:x2}' -f $h[0], $h[1], $h[2]).ToUpperInvariant()
    $rep = switch ($Kind) {
        'ip' { '10.{0}.{1}.{2}' -f $h[0], $h[1], [Math]::Max(1, [int]$h[2] % 254) }
        'email' { "user-$tag@example.com".ToLowerInvariant() }
        'user' { "USER-$tag" }
        'host' { if ($Value.EndsWith('$')) { "HOST-$tag`$" } else { "HOST-$tag" } }
        'fqdn' { "host-$tag.example.local".ToLowerInvariant() }
        'domain' { "DOMAIN-$tag" }
        default { "TERM-$tag" }
    }
    $script:AnonMap[$key] = [pscustomobject]@{ Kind = $Kind; Original = $Value; Replacement = $rep }
    return $rep
}

$WinUserFields = 'TargetUserName', 'SubjectUserName', 'AccountName', 'TargetOutboundUserName', 'MemberName', 'SamAccountName', 'UserPrincipalName'
$WinHostFields = 'WorkstationName', 'TargetServerName', 'ClientName', 'SourceWorkstation', 'Workstation'
$WinDomainFields = 'TargetDomainName', 'SubjectDomainName', 'TargetOutboundDomainName', 'AccountDomain'
$NeverAnon = @('-', '', 'SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'ANONYMOUS LOGON', 'NT AUTHORITY', 'NT SERVICE', 'Window Manager', 'Font Driver Host', 'BUILTIN', 'N/A', '%%1833')

function Register-AnonTerms([string]$Message) {
    # Pass 1: learn values worth replacing
    foreach ($m in [regex]::Matches($Message, "<Data Name=['""]([A-Za-z]+)['""]>([^<]+)</Data>")) {
        $f = $m.Groups[1].Value; $v = $m.Groups[2].Value.Trim()
        if ($NeverAnon -contains $v) { continue }
        if ($WinUserFields -contains $f) { [void](Get-Alias 'user' $v) }
        elseif ($WinHostFields -contains $f) { [void](Get-Alias 'host' $v) }
        elseif ($WinDomainFields -contains $f) { [void](Get-Alias 'domain' $v) }
    }
    foreach ($m in [regex]::Matches($Message, '<Computer>([^<]+)</Computer>')) { [void](Get-Alias 'fqdn' $m.Groups[1].Value.Trim()) }
    foreach ($m in [regex]::Matches($Message, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')) { [void](Get-Alias 'email' $m.Value) }
    foreach ($m in [regex]::Matches($Message, '(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])')) {
        if ($m.Value -notmatch '^(0\.0\.0\.0|127\.|255\.|224\.)') { [void](Get-Alias 'ip' $m.Value) }
    }
    foreach ($sfx in @($AnonymiseDomain)) {
        if (-not $sfx) { continue }
        foreach ($m in [regex]::Matches($Message, '\b[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.' + [regex]::Escape($sfx.TrimStart('.')) + '\b', 'IgnoreCase')) {
            [void](Get-Alias 'fqdn' $m.Value)
        }
    }
}

function Initialize-AnonTerms {
    if (-not $AnonymiseTermsFile) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($AnonymiseTermsFile)) {
        $l = $line.Trim(); if (-not $l -or $l.StartsWith('#')) { continue }
        $parts = $l -split ',', 2
        $orig = $parts[0].Trim()
        $key = "term|$($orig.ToLowerInvariant())"
        $rep = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { $null }
        if ($rep) { $script:AnonMap[$key] = [pscustomobject]@{ Kind = 'term'; Original = $orig; Replacement = $rep } }
        else { [void](Get-Alias 'term' $orig) }
    }
}

function Get-AnonRegex {
    # Longest originals first so "jdoe.admin" is replaced before "jdoe"
    $entries = @($script:AnonMap.Values | Sort-Object { $_.Original.Length } -Descending)
    if (-not $entries.Count) { return $null }
    $script:AnonLookup = @{}
    foreach ($e in $entries) { $script:AnonLookup[$e.Original.ToLowerInvariant()] = $e.Replacement }
    $alts = ($entries | ForEach-Object { [regex]::Escape($_.Original) }) -join '|'
    return New-Object System.Text.RegularExpressions.Regex("(?<![A-Za-z0-9])(?:$alts)(?![A-Za-z0-9])", 'IgnoreCase', [TimeSpan]::FromSeconds(30))
}

function Protect-Logs($Logs) {
    foreach ($l in $Logs) { Register-AnonTerms $l.Message }
    $rx = Get-AnonRegex
    if (-not $rx) { return }
    $eval = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $script:AnonLookup[$m.Value.ToLowerInvariant()] }
    foreach ($l in $Logs) {
        $l.Message = $rx.Replace($l.Message, $eval)
        if ($l.MsgSourceName) { $l.MsgSourceName = $rx.Replace($l.MsgSourceName, $eval) }
    }
}

# =====================================================================================
# Stage 4: LLX
# =====================================================================================

function New-RuleLlx($Rule, $Logs) {
    $base = '{0}_{1}' -f (Get-SafeName $Rule.RuleID 20), (Get-SafeName $Rule.Name 60)
    $jsonPath = Join-Path (Join-Path $RunFolder 'llx') "$base.json"
    $llxPath = Join-Path (Join-Path $RunFolder 'llx') "$base.llx"
    $records = foreach ($l in $Logs) {
        $o = [ordered]@{ Message = $l.Message }
        if ($null -ne $l.MsgSourceTypeID -and "$($l.MsgSourceTypeID)" -ne '') { $o.MsgSourceTypeID = [int]$l.MsgSourceTypeID }
        if ($null -ne $l.MsgSourceID -and "$($l.MsgSourceID)" -ne '') { $o.MsgSourceID = [int]$l.MsgSourceID }
        $o.MPERuleID = -1
        [pscustomobject]$o
    }
    Save-Json @($records) $jsonPath 4
    $llxArgs = @{ Mode = 'Compile'; Path = $jsonPath; OutputPath = $llxPath; Force = $true; Comments = ("AIE rule {0}: {1}" -f $Rule.RuleID, $Rule.Name) }
    if ($TemplateLlx) { $llxArgs.TemplateLlx = $TemplateLlx }
    if ($PSBoundParameters_LicenseID) { $llxArgs.LicenseID = $LicenseID }
    $out = & $LlxToolPath @llxArgs 6>$null 3>$null
    if (-not $out -or -not (Test-Path -LiteralPath $llxPath)) { throw "LLX-Tool did not produce $llxPath" }
    return $llxPath
}

# =====================================================================================
# Stage 5: Echo
# =====================================================================================

$script:EchoSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$script:EchoHeaders = @{ Accept = 'application/json, application/vnd.api+json' }
$script:EchoCreateFormat = $null   # learned on first success: JsonApi | Plain
$script:EchoTypeNames = @{}
$script:EchoTypeIds = @{}     # lower-case name -> id

function Connect-Echo {
    if ($script:EchoConnected) { return }
    $script:EchoConnected = $true
    if (-not $EchoCredential) { Write-Log 'No -EchoCredential: calling the Echo API without logging in'; return }
    $body = @{ username = $EchoCredential.UserName; password = $EchoCredential.GetNetworkCredential().Password } | ConvertTo-Json
    $r = Invoke-Api -Method POST -Url (Join-Url $EchoBaseUrl 'api/login') -Body $body -ContentType 'application/json' -Session $script:EchoSession -Headers $script:EchoHeaders -Label 'echo login'
    if ($r.Status -lt 200 -or $r.Status -ge 300) { throw "Echo login failed: HTTP $($r.Status) $($r.Error)" }
    $tok = Get-Prop $r.Json @('token', 'access_token', 'accessToken', 'jwt')
    if ($tok) { $script:EchoHeaders.Authorization = "Bearer $tok" }
    Write-Log 'Logged in to Echo' 'OK'
}

function Invoke-Echo([string]$Method, [string]$Path, $Body, [string]$ContentType, [string]$Label) {
    $p = @{ Method = $Method; Url = (Join-Url $EchoBaseUrl $Path); Headers = $script:EchoHeaders; Session = $script:EchoSession; Label = $Label }
    if ($null -ne $Body) { $p.Body = $Body }
    if ($ContentType) { $p.ContentType = $ContentType }
    return Invoke-Api @p
}

function Get-EchoUseCaseIndex {
    $r = Invoke-Echo GET 'api/usecases' $null $null 'echo usecases'
    if ($r.Status -lt 200 -or $r.Status -ge 300) { throw "Echo GET /api/usecases failed: HTTP $($r.Status) $($r.Error)" }
    $list = Find-Array $r.Json @('usecases', 'useCases', 'data', 'objects', 'items')
    $idx = @{}
    foreach ($u in $list) {
        $attrs = Get-Prop $u @('attributes'); if ($null -eq $attrs) { $attrs = $u }
        $t = [string](Get-Prop $attrs @('title', 'Title', 'name'))
        $id = Get-Prop $u @('id', 'ID', 'usecase_id')
        if ($t) { $idx[$t.ToLowerInvariant()] = $id }
    }
    return $idx
}

function Initialize-EchoTypes {
    $r = Invoke-Echo GET 'api/msgsourcetypes' $null $null 'echo msgsourcetypes'
    if ($r.Status -lt 200 -or $r.Status -ge 300) { Write-Log "Echo /api/msgsourcetypes HTTP $($r.Status): log source names will come from LogRhythm" 'WARN'; return }
    foreach ($t in (Find-Array $r.Json @('msgsourcetypes', 'data', 'items', 'objects'))) {
        $id = Get-Prop $t @('MsgSourceTypeID', 'msgSourceTypeId', 'msg_src_id', 'id', 'ID')
        $nm = Get-Prop $t @('FullName', 'Name', 'name', 'msg_src_name', 'fullName')
        if ($null -ne $id -and $nm) { $script:EchoTypeNames[[string]$id] = [string]$nm; $script:EchoTypeIds[([string]$nm).ToLowerInvariant()] = [int]$id }
    }
    Write-Log "Echo knows $($script:EchoTypeNames.Count) log source types"
}

function Resolve-TypeIds($Rule, $Logs) {
    # Fill in missing log source type IDs from the type name (Echo's list first, then the EMDB)
    $missing = @($Logs | Where-Object { ($null -eq $_.MsgSourceTypeID -or "$($_.MsgSourceTypeID)" -eq '') -and $_.MsgSourceTypeName })
    if (-not $missing.Count) { return }
    foreach ($l in $missing) {
        $k = $l.MsgSourceTypeName.ToLowerInvariant()
        if (-not $script:EchoTypeIds.ContainsKey($k) -and $SqlServer) {
            try {
                $dt = Invoke-Sql ("SELECT TOP 1 MsgSourceTypeID FROM dbo.MsgSourceType WHERE Name = N'{0}'" -f ($l.MsgSourceTypeName -replace "'", "''"))
                if ($dt.Rows.Count) { $script:EchoTypeIds[$k] = [int]$dt.Rows[0][0] }
            }
            catch { }
        }
        if ($script:EchoTypeIds.ContainsKey($k)) { $l.MsgSourceTypeID = $script:EchoTypeIds[$k] }
    }
    $still = @($Logs | Where-Object { $null -eq $_.MsgSourceTypeID -or "$($_.MsgSourceTypeID)" -eq '' }).Count
    if ($still) { Add-Note $Rule "$still log(s) have no log source type ID and none could be found from the name" }
    else { Add-Note $Rule "log source type ID looked up from the type name for $($missing.Count) log(s)" }
}

function Invoke-EchoUnpack([string]$LlxPath) {
    $bytes = [System.IO.File]::ReadAllBytes($LlxPath)
    $boundary = '----EchoCoverage' + [guid]::NewGuid().ToString('N')
    $name = [System.IO.Path]::GetFileName($LlxPath) -replace '"', ''
    $head = $Utf8.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"$EchoLlxUploadField`"; filename=`"$name`"`r`nContent-Type: application/octet-stream`r`n`r`n")
    $tail = $Utf8.GetBytes("`r`n--$boundary--`r`n")
    $body = New-Object byte[] ($head.Length + $bytes.Length + $tail.Length)
    [Array]::Copy($head, 0, $body, 0, $head.Length)
    [Array]::Copy($bytes, 0, $body, $head.Length, $bytes.Length)
    [Array]::Copy($tail, 0, $body, $head.Length + $bytes.Length, $tail.Length)
    $r = Invoke-Echo POST 'api/unpackLLXFile' $body "multipart/form-data; boundary=$boundary" 'echo unpackLLX'
    if ($r.Status -lt 200 -or $r.Status -ge 300) { return [pscustomobject]@{ Ok = $false; Detail = "HTTP $($r.Status) $($r.Error)"; Logs = @() } }
    $items = Find-Array $r.Json @('logs', 'messages', 'data', 'items', 'results', 'LogMessages')
    $logs = foreach ($i in $items) {
        $msg = if ($i -is [string]) { $i } else { Get-Prop $i @('Message', 'message', 'log', 'Log', 'raw', 'logMessage') }
        if ($msg) {
            [pscustomobject]@{
                Message = [string]$msg
                MsgSourceTypeID = Get-Prop $i @('MsgSourceTypeID', 'msgSourceTypeId', 'msg_src_id', 'msgSourceTypeID')
                MsgSourceTypeName = [string](Get-Prop $i @('MsgSourceTypeName', 'msg_src_name', 'msgSourceTypeName'))
            }
        }
    }
    [pscustomobject]@{ Ok = $true; Detail = "$(@($logs).Count) log(s) returned"; Logs = @($logs) }
}

function New-EchoUseCase([string]$Title, [string]$Description) {
    $attrs = [ordered]@{ title = $Title; description = $Description; timedelay = $TimeDelaySeconds }
    # Plain JSON first: a live Echo rejected JSON:API and accepted plain JSON (lab-confirmed)
    $formats = if ($script:EchoCreateFormat) { @($script:EchoCreateFormat) } else { @('Plain', 'JsonApi') }
    $last = $null
    foreach ($fmt in $formats) {
        if ($fmt -eq 'JsonApi') {
            $body = @{ data = @{ type = 'usecase'; attributes = $attrs } } | ConvertTo-Json -Depth 5
            $r = Invoke-Echo POST 'api/usecase' $body 'application/vnd.api+json' 'echo create usecase (JSON:API)'
        }
        else {
            $body = $attrs | ConvertTo-Json
            $r = Invoke-Echo POST 'api/usecase' $body 'application/json; charset=utf-8' 'echo create usecase (plain)'
        }
        $last = $r
        if ($r.Status -ge 200 -and $r.Status -lt 300) {
            $data = Get-Prop $r.Json @('data'); if ($null -eq $data) { $data = $r.Json }
            $id = Get-Prop $data @('id', 'ID', 'usecase_id')
            if ($null -ne $id) { $script:EchoCreateFormat = $fmt; return [string]$id }
        }
        # Only fall back to the next format when Echo rejected the request shape
        if ($r.Status -notin 400, 406, 415, 422) { break }
    }
    throw "Echo use case create failed: HTTP $($last.Status) $($last.Error) $((Protect-Text $last.Content) -replace '\s+', ' ')"
}

function Remove-EchoUseCase([string]$Id) {
    $r = Invoke-Echo POST 'api/deleteUseCases' (ConvertTo-Json @([int]$Id) -Compress) 'application/json' 'echo rollback'
    if ($r.Status -lt 200 -or $r.Status -ge 300) {
        $r = Invoke-Echo POST 'api/deleteUseCases' (@{ ids = @([int]$Id) } | ConvertTo-Json -Compress) 'application/json' 'echo rollback (ids)'
    }
    return ($r.Status -ge 200 -and $r.Status -lt 300)
}

function Get-EchoLogPayload($Rule, $Logs, [string]$UseCaseId) {
    $order = 0
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
    foreach ($l in $Logs) {
        $order++
        $typeId = if ($null -ne $l.MsgSourceTypeID -and "$($l.MsgSourceTypeID)" -ne '') { [int]$l.MsgSourceTypeID } else { $null }
        $typeName = ''
        if ($null -ne $typeId -and $script:EchoTypeNames.ContainsKey([string]$typeId)) { $typeName = $script:EchoTypeNames[[string]$typeId] }
        elseif ($l.MsgSourceTypeName) { $typeName = $l.MsgSourceTypeName }
        $blk = if ($l.PSObject.Properties['Block']) { $l.Block } else { 1 }
        [ordered]@{
            owner_id     = $(if ($UseCaseId -match '^\d+$') { [int]$UseCaseId } else { $UseCaseId })
            description  = ('Rule block {0}, log {1}' -f $blk, $order)
            message      = ('{0} ({1}/{2})' -f $Rule.Name, $order, @($Logs).Count)
            log          = $l.Message
            msg_src_id   = $typeId
            msg_src_name = $typeName
            timestamp    = $now
            customtime   = $false
            play_order   = $order
        }
    }
}

function Publish-RuleToEcho($Rule, $Logs, [hashtable]$Existing) {
    # Title = the alarm's name as LogRhythm shows it (e.g. 'AIE: <rule name>'), optionally prefixed
    $baseName = if ($Rule.PSObject.Properties['AlarmName'] -and $Rule.AlarmName) { $Rule.AlarmName } else { $Rule.Name }
    $title = $TitlePrefix + $baseName
    if ($title.Length -gt 250) { $title = $title.Substring(0, 250) }
    $Rule.EchoTitle = $title
    if ($ExistingUseCase -eq 'Skip' -and $Existing.ContainsKey($title.ToLowerInvariant())) {
        $Rule.EchoUseCaseID = [string]$Existing[$title.ToLowerInvariant()]
        return 'Exists'
    }

    $sendLogs = $Logs
    if ($EchoImportMode -eq 'Unpack' -and -not $DryRun) {
        $u = Invoke-EchoUnpack $Rule.LlxFile
        if ($u.Ok -and $u.Logs.Count -eq @($Logs).Count) {
            # Echo decoded our LLX: use its view of the logs, keeping block numbers from ours
            for ($i = 0; $i -lt $u.Logs.Count; $i++) {
                $ul = $u.Logs[$i]; $ol = @($Logs)[$i]
                if ($null -eq $ul.MsgSourceTypeID) { $ul | Add-Member -NotePropertyName MsgSourceTypeID -NotePropertyValue $ol.MsgSourceTypeID -Force }
                $ul | Add-Member -NotePropertyName Block -NotePropertyValue $ol.Block -Force
            }
            $sendLogs = $u.Logs
            Add-Note $Rule "Echo unpacked the LLX ($($u.Detail))"
        }
        elseif ($u.Ok) { Add-Note $Rule "Echo unpacked $($u.Logs.Count) of $(@($Logs).Count) logs; sent the original logs instead" }
        else { Add-Note $Rule "Echo LLX unpack failed ($($u.Detail)); sent the logs directly" }
    }

    $desc = @(
        "Generated from alarm '$($Rule.AlarmName)' (AIE rule '$($Rule.Name)', AIERuleID $($Rule.RuleID))."
        "Source alarm $($Rule.AlarmUsed) at $($Rule.AlarmDate) UTC: $(@($Logs).Count) log(s) from $($Rule.RuleBlocks) rule block(s)."
        "Built $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC by Build-EchoCoverage $ScriptVersion$(if ($Anonymise) { ' (anonymised)' })."
    ) -join "`n"

    $safe = '{0}_{1}' -f (Get-SafeName $Rule.RuleID 20), (Get-SafeName $Rule.Name 60)
    if ($DryRun) {
        $payload = [ordered]@{ usecase = [ordered]@{ title = $title; description = $desc; timedelay = $TimeDelaySeconds }; logs = @(Get-EchoLogPayload $Rule $sendLogs '<new id>') }
        Save-Json $payload (Join-Path (Join-Path $RunFolder 'echo') "$safe.payload.json") 6
        return 'DryRun'
    }

    $id = New-EchoUseCase $title $desc
    $Rule.EchoUseCaseID = $id
    $logPayload = @(Get-EchoLogPayload $Rule $sendLogs $id)
    $r = Invoke-Echo POST 'api/addLogs' (ConvertTo-Json -InputObject $logPayload -Depth 4) 'application/json' "echo addLogs ($($logPayload.Count))"
    if ($r.Status -lt 200 -or $r.Status -ge 300) {
        $rolled = Remove-EchoUseCase $id
        $Rule.EchoUseCaseID = $null
        throw "Echo addLogs failed: HTTP $($r.Status) $((Protect-Text $r.Content) -replace '\s+', ' '). Empty use case $id $(if ($rolled) { 'was removed' } else { 'could NOT be removed - delete it in Echo' })."
    }
    $Rule.EchoLogs = $logPayload.Count
    $Existing[$title.ToLowerInvariant()] = $id

    # Best-effort verification
    $v = Invoke-Echo GET "api/usecasesByIds/$id" $null $null 'echo verify'
    if ($v.Status -ge 200 -and $v.Status -lt 300) {
        $vl = Find-Array $v.Json @('logs', 'log', 'data', 'usecases')
        if ($vl.Count -eq 1 -and $vl[0].PSObject.Properties['logs']) { $vl = @($vl[0].logs) }
        Add-Note $Rule "verified in Echo (GET usecasesByIds returned $($vl.Count) item(s))"
    }
    else { Add-Note $Rule "could not verify in Echo (HTTP $($v.Status))" }
    return 'Created'
}

# =====================================================================================
# Report
# =====================================================================================

function Write-Report {
    $rules = @($script:State.Rules)
    # Use the lookback the run was made with (matters in -Mode Report)
    $LookbackDays = if ($script:State.PSObject.Properties['LookbackDays'] -and $script:State.LookbackDays) { [int]$script:State.LookbackDays } else { $LookbackDays }
    $logsDir = Join-Path $RunFolder 'drilldown'
    $rows = foreach ($r in $rules) {
        [pscustomobject]@{
            RuleID = $r.RuleID; RuleName = $r.Name
            AlarmName = $(if ($r.PSObject.Properties['AlarmName']) { $r.AlarmName } else { $null })
            Status = $r.Status; Detail = $r.Detail
            AlarmsInLookback = $r.AlarmCount; AlarmUsed = $r.AlarmUsed; AlarmDate = $r.AlarmDate
            RuleBlocks = $r.RuleBlocks; Logs = $r.Logs; LogSourceTypes = $r.LogSourceTypes
            AieCount = $r.AieCount; DxCount = $r.DxCount
            LlxFile = $(if ($r.LlxFile) { Split-Path -Leaf $r.LlxFile }); EchoUseCaseID = $r.EchoUseCaseID; EchoTitle = $r.EchoTitle
            Notes = (@($r.Notes) -join ' | ')
        }
    }
    $csv = Join-Path $RunFolder 'coverage-report.csv'
    @($rows) | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

    # ---- numbers
    $total = $rules.Count
    $fired = @($rules | Where-Object { $_.AlarmCount -gt 0 })
    $created = @($rules | Where-Object { $_.Status -eq 'Created' })
    $exists = @($rules | Where-Object { $_.Status -eq 'Exists' })
    $ready = @($rules | Where-Object { $_.Status -in 'DryRun', 'LlxBuilt', 'LogsFound' })
    $noDd = @($rules | Where-Object { $_.Status -eq 'NoDrilldown' })
    $failed = @($rules | Where-Object { $_.Status -eq 'Failed' })
    $pending = @($fired | Where-Object { $_.Status -eq 'Pending' })
    $notFired = @($rules | Where-Object { $_.AlarmCount -eq 0 })

    $E = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    function Get-SampleLogs($r, [int]$Max = 3) {
        $f = Join-Path $logsDir ('{0}_{1}.logs.json' -f (Get-SafeName $r.RuleID 20), (Get-SafeName $r.Name 60))
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        try { $l = Read-Json $f } catch { return @() }
        return @(@($l) | Select-Object -First $Max)
    }

    $sb = New-Object System.Text.StringBuilder
    function Add([string]$t) { [void]$sb.Append($t) }
    $when = (Get-Date).ToString('dd MMM yyyy HH:mm')
    Add @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Echo use case coverage report</title>
<style>
:root{--ink:#1f2933;--muted:#5f6b7a;--line:#e3e8ee;--bg:#f6f8fa;--ok:#1a7f37;--info:#0b5cad;--warn:#9a6700;--bad:#b42318;--grey:#6e7781}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 "Segoe UI",system-ui,-apple-system,Arial,sans-serif;color:var(--ink);background:#fff}
.wrap{max-width:1100px;margin:0 auto;padding:32px 24px 48px}
h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:36px 0 12px;padding-bottom:6px;border-bottom:1px solid var(--line)}
.sub{color:var(--muted);margin:0 0 24px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
.card{border:1px solid var(--line);border-radius:8px;padding:14px 16px;background:var(--bg)}
.card .n{font-size:28px;font-weight:600;line-height:1.1}.card .l{color:var(--muted);font-size:13px}
.card.ok .n{color:var(--ok)}.card.info .n{color:var(--info)}.card.warn .n{color:var(--warn)}.card.bad .n{color:var(--bad)}.card.grey .n{color:var(--grey)}
.funnel{margin:16px 0 0;color:var(--muted)}
.uc{border:1px solid var(--line);border-radius:8px;margin:0 0 12px;overflow:hidden}
.uc header{display:flex;justify-content:space-between;gap:12px;align-items:baseline;padding:12px 16px;background:var(--bg);border-bottom:1px solid var(--line)}
.uc header .t{font-weight:600}.pill{display:inline-block;border-radius:999px;padding:1px 10px;font-size:12px;color:#fff;white-space:nowrap}
.p-ok{background:var(--ok)}.p-info{background:var(--info)}.p-warn{background:var(--warn)}.p-bad{background:var(--bad)}.p-grey{background:var(--grey)}
.meta{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:4px 16px;padding:12px 16px}
.meta div span{display:block;color:var(--muted);font-size:12px}
.notes{padding:0 16px 12px;color:var(--muted);font-size:13px}
details{padding:0 16px 12px}summary{cursor:pointer;color:var(--info)}
pre{white-space:pre-wrap;word-break:break-all;background:#0f172a;color:#e2e8f0;border-radius:6px;padding:10px 12px;font:12px/1.45 Consolas,Menlo,monospace;margin:8px 0 0}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-bottom:1px solid var(--line);padding:8px 10px;text-align:left;vertical-align:top}th{background:var(--bg);font-weight:600}
.small{color:var(--muted);font-size:12px}.cols{columns:2 320px;font-size:13px;margin:0;padding-left:18px}
footer{margin-top:40px;color:var(--muted);font-size:12px;border-top:1px solid var(--line);padding-top:12px}
@media print{details{display:block}details>summary{display:none}.uc{break-inside:avoid}}
</style></head><body><div class="wrap">
<h1>Echo use case coverage report</h1>
<p class="sub">Generated $when &middot; alarms from the last $LookbackDays days$(if ($script:State.PSObject.Properties['Anonymised'] -and $script:State.Anonymised) { ' &middot; logs anonymised' })</p>
<div class="cards">
<div class="card grey"><div class="n">$total</div><div class="l">Enabled AIE rules</div></div>
<div class="card info"><div class="n">$($fired.Count)</div><div class="l">Fired in the last $LookbackDays days</div></div>
<div class="card ok"><div class="n">$($created.Count)</div><div class="l">Echo use cases created</div></div>
$(if ($exists.Count) { "<div class='card info'><div class='n'>$($exists.Count)</div><div class='l'>Already in Echo</div></div>" })
$(if ($ready.Count) { "<div class='card info'><div class='n'>$($ready.Count)</div><div class='l'>Prepared, not sent to Echo</div></div>" })
<div class="card warn"><div class="n">$($noDd.Count)</div><div class="l">Fired, no drilldown data</div></div>
$(if ($failed.Count) { "<div class='card bad'><div class='n'>$($failed.Count)</div><div class='l'>Failed</div></div>" })
<div class="card grey"><div class="n">$($notFired.Count)</div><div class="l">Didn't fire</div></div>
</div>
<p class="funnel">Of <b>$total</b> enabled AIE rules, <b>$($fired.Count)</b> raised at least one alarm in the last $LookbackDays days. <b>$($created.Count + $exists.Count)</b> of those now have an Echo use case built from the real logs that triggered them.</p>
"@

    # ---- use cases
    $withUc = @($rules | Where-Object { $_.Status -in 'Created', 'Exists', 'DryRun', 'LlxBuilt', 'LogsFound' } | Sort-Object { if ($_.EchoTitle) { $_.EchoTitle } elseif ($_.AlarmName) { $_.AlarmName } else { $_.Name } })
    if ($withUc.Count) {
        Add "<h2>Echo use cases ($($withUc.Count))</h2>"
        foreach ($r in $withUc) {
            $title = if ($r.EchoTitle) { $r.EchoTitle } elseif ($r.AlarmName) { $r.AlarmName } else { $r.Name }
            $pill = switch ($r.Status) { 'Created' { "<span class='pill p-ok'>Created</span>" } 'Exists' { "<span class='pill p-info'>Already in Echo</span>" } 'DryRun' { "<span class='pill p-info'>Dry run: not sent</span>" } default { "<span class='pill p-info'>Prepared</span>" } }
            Add "<section class='uc'><header><span class='t'>$(& $E $title)</span>$pill</header><div class='meta'>"
            Add "<div><span>Echo use case ID</span>$(if ($r.EchoUseCaseID) { & $E $r.EchoUseCaseID } else { '&ndash;' })</div>"
            Add "<div><span>Logs</span>$($r.Logs) from $($r.RuleBlocks) rule block(s)</div>"
            Add "<div><span>Source alarm</span>$(& $E $r.AlarmUsed)$(if ($r.AlarmDate) { "<br><span class='small'>$(& $E $r.AlarmDate) UTC</span>" })</div>"
            Add "<div><span>Alarms in last $LookbackDays days</span>$($r.AlarmCount)</div>"
            Add "<div><span>Log source types</span>$(& $E $r.LogSourceTypes)</div>"
            Add "<div><span>AIE rule</span>$(& $E $r.Name)<br><span class='small'>ID $(& $E $r.RuleID)</span></div></div>"
            $notes = @($r.Notes | Where-Object { $_ -and $_ -notmatch '^(verified in Echo|Echo unpacked the LLX|alarm \d+: no drilldown data|log source type ID looked up)' })
            if ($notes.Count) { Add "<div class='notes'>&#9888; $(& $E ($notes -join ' &middot; '))</div>" -replace '&amp;middot;', '&middot;' }
            $samples = @(Get-SampleLogs $r 3)
            if ($samples.Count) {
                Add "<details><summary>Show $($samples.Count) of $($r.Logs) log(s)</summary>"
                foreach ($l in $samples) {
                    $m = [string]$l.Message; if ($m.Length -gt 2000) { $m = $m.Substring(0, 2000) + ' ...' }
                    $t = if ($l.MsgSourceTypeName) { $l.MsgSourceTypeName } else { "type $($l.MsgSourceTypeID)" }
                    Add "<pre><span class='small' style='color:#94a3b8'>Rule block $($l.Block) &middot; $(& $E $t)</span>`n$(& $E $m)</pre>"
                }
                Add '</details>'
            }
            Add '</section>'
        }
    }

    # ---- fired but no use case
    $gaps = @($noDd + $failed + $pending)
    if ($gaps.Count) {
        Add "<h2>Fired, but no use case ($($gaps.Count))</h2><table><tr><th>Alarm / AIE rule</th><th>Alarms</th><th>Reason</th><th>What to do</th></tr>"
        foreach ($r in @($gaps | Sort-Object Name)) {
            $todo = switch ($r.Status) {
                'NoDrilldown' { 'Enable Auto Drilldown on the rule (AIE rule &gt; Alarm settings), wait for it to fire again, then re-run with -Resume or a new run.' }
                'Failed' { 'See the reason; fix and re-run with -Resume -RunFolder &lt;this folder&gt;.' }
                default { 'Not processed yet (stopped early). Re-run without -StopAfter.' }
            }
            $name = if ($r.AlarmName) { $r.AlarmName } else { $r.Name }
            Add "<tr><td>$(& $E $name)<br><span class='small'>AIE rule ID $(& $E $r.RuleID)</span></td><td>$($r.AlarmCount)</td><td>$(& $E $r.Detail)</td><td>$todo</td></tr>"
        }
        Add '</table>'
    }

    # ---- didn't fire
    if ($notFired.Count) {
        Add "<h2>Didn't fire in the last $LookbackDays days ($($notFired.Count))</h2><details><summary>Show the list</summary><ul class='cols'>"
        foreach ($r in @($notFired | Sort-Object Name)) { Add "<li>$(& $E $r.Name)</li>" }
        Add "</ul><p class='small'>If a rule here is known to have fired, check whether it was renamed during the period (see -RenameMapCsv) or increase -LookbackDays.</p></details>"
    }

    Add @"
<h2>Using these use cases</h2>
<p>In the Echo web UI, open <b>Use Cases</b>, find the use case by its alarm name and click <b>Run</b>. The logs are replayed into LogRhythm through Echo's simulated log sources within a minute or two.</p>
<p class="small">A replay may not re-trigger its alarm when the AIE rule filters on a specific log source, entity or host (Echo uses its own), relies on thresholds or unique values that the retrieved logs don't reach, uses lists, or uses an MPE policy other than LogRhythm Default.</p>
<footer>Build-EchoCoverage $ScriptVersion &middot; $(& $E (Split-Path -Leaf $RunFolder)) &middot; full detail in coverage-report.csv</footer>
</div></body></html>
"@
    [System.IO.File]::WriteAllText((Join-Path $RunFolder 'coverage-report.html'), $sb.ToString(), $Utf8)

    Write-Log ("Summary: {0} enabled AIE rule(s) | {1} fired in the last {2} days | {3} use case(s) created | {4} already in Echo | {5} prepared | {6} no drilldown data | {7} failed | {8} didn't fire" -f `
            $total, $fired.Count, $LookbackDays, $created.Count, $exists.Count, $ready.Count, $noDd.Count, $failed.Count, $notFired.Count) 'OK'
    Write-Log "Report: $(Join-Path $RunFolder 'coverage-report.html')" 'OK'
}

# =====================================================================================
# Discover mode
# =====================================================================================

function Get-KeyInventory($Object, [string]$Prefix = '', [int]$Depth = 0) {
    # Lists every property path in a JSON object (first array element only) for format checks
    if ($Depth -gt 8 -or $null -eq $Object) { return }
    if ($Object -is [System.Array]) { if ($Object.Count) { Get-KeyInventory $Object[0] "$Prefix[]" ($Depth + 1) }; return }
    if ($Object -is [string] -or $Object -is [ValueType]) { return }
    foreach ($p in $Object.PSObject.Properties) {
        $path = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        $t = if ($null -eq $p.Value) { 'null' } elseif ($p.Value -is [System.Array]) { "array[$($p.Value.Count)]" } else { $p.Value.GetType().Name }
        "$path : $t"
        Get-KeyInventory $p.Value $path ($Depth + 1)
    }
}

function Invoke-Discover {
    $out = Join-Path $RunFolder 'discover'
    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add("Build-EchoCoverage $ScriptVersion discover run $((Get-Date).ToString('o'))")
    $summary.Add("PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)")
    $summary.Add('')

    function Save-Probe([string]$Name, $Resp) {
        if ($Resp.Content) { [System.IO.File]::WriteAllText((Join-Path $out "$Name.json"), (Protect-Text $Resp.Content), $Utf8) }
        $summary.Add("== $Name : HTTP $($Resp.Status) $($Resp.Error)")
        if ($Resp.Json) { foreach ($k in @(Get-KeyInventory $Resp.Json | Select-Object -First 80)) { $summary.Add("   $k") } }
        $summary.Add('')
    }

    # Rules
    try {
        if ($SqlServer) {
            foreach ($t in 'AIERule', 'AIERuleToEngine', 'AIEEngine') { $summary.Add("== EMDB dbo.$t columns: " + ((Get-EmdbColumns $t) -join ', ')) }
            $q = if ($RulesQuery) { $RulesQuery } else { Get-DefaultRulesQuery }
            $summary.Add("Rules query: $q")
        }
        $rules = Get-EnabledRules
        $summary.Add("Enabled rules found: $($rules.Count). First 10:")
        foreach ($r in @($rules | Select-Object -First 10)) { $summary.Add("   $($r.RuleID)  $($r.Name)") }
        Save-Json $rules (Join-Path $out 'rules.json') 3
    }
    catch { $summary.Add("Rules: FAILED - $($_.Exception.Message)") }
    $summary.Add('')

    # LogRhythm API
    if ($LrApiBaseUrl) {
        try {
            $r = Invoke-Api -Method GET -Url ((Join-Url $LrApiBaseUrl 'lr-alarm-api/alarms') + "?count=25&offset=0&orderby=dateInserted&dir=descending$AlarmQueryExtra") -Headers (Get-LrHeaders) -Label 'discover alarms'
            Save-Probe 'lr-alarms' $r
            $alarms = Find-Array $r.Json @('alarmsSearchDetails', 'alarms', 'data', 'items', 'results')
            # Try up to 10 recent alarms until one has drilldown logs, so a useful sample is captured
            $tried = 0; $found = $false
            foreach ($a in $alarms) {
                $id = Get-Prop $a @('alarmId', 'alarmID', 'AlarmId', 'id'); if (-not $id) { continue }
                $tried++
                $d = Invoke-Api -Method GET -Url (Join-Url $LrApiBaseUrl "lr-drilldown-cache-api/drilldown/$id") -Headers (Get-LrHeaders) -Label 'discover drilldown'
                if ($d.Json) {
                    Save-Probe "lr-drilldown-$id" $d
                    $dd = ConvertFrom-Drilldown $d.Json
                    $summary.Add("   Parser result for alarm ${id} ($(Get-Prop $a @('alarmRuleName'))): $($dd.Blocks) rule block(s), $($dd.Logs.Count) log(s) with raw text, AIERuleID=$($dd.AieRuleID)")
                    if ($dd.Logs.Count) {
                        $f = $dd.Logs[0]
                        $summary.Add("   First log: typeId=$($f.MsgSourceTypeID) typeName='$($f.MsgSourceTypeName)' sourceId=$($f.MsgSourceID) date=$($f.Date)")
                        $found = $true
                    }
                    $summary.Add('')
                }
                else { $summary.Add("   alarm ${id}: drilldown HTTP $($d.Status) (no data)") }
                if ($found -or $tried -ge 10) {
                    $e = Invoke-Api -Method GET -Url (Join-Url $LrApiBaseUrl "lr-alarm-api/alarms/$id/events") -Headers (Get-LrHeaders) -Label 'discover alarm events'
                    Save-Probe "lr-alarm-events-$id" $e
                    break
                }
            }
            if (-not $found) { $summary.Add("   No drilldown logs in the $tried newest alarm(s). Check Auto Drilldown is enabled on at least one AIE rule.") }
        }
        catch { $summary.Add("LogRhythm API: FAILED - $($_.Exception.Message)") }
    }
    else { $summary.Add('LogRhythm API: skipped (no -LrApiBaseUrl)') }

    # Echo (read-only GETs; login only if a credential was given)
    try {
        Connect-Echo
        foreach ($p in @('api/getechoversion', 'api/usecases', 'api/usecase', 'api/log?page[size]=3', 'api/msgsourcetypes', 'api/host', 'api/getLLXFileSettings')) {
            $r = Invoke-Echo GET $p $null $null "discover $p"
            Save-Probe ('echo-' + (Get-SafeName ($p -replace '^api/', '') 40)) $r
        }
        if ($EchoProbeLlx) {
            $u = Invoke-EchoUnpack $EchoProbeLlx
            $summary.Add("== echo unpackLLXFile with $EchoProbeLlx : $($u.Detail)")
            $cap = Get-ChildItem (Join-Path $RunFolder 'http') -Filter '*unpackLLXFile*' | Sort-Object Name | Select-Object -Last 1
            if ($cap) { Copy-Item $cap.FullName (Join-Path $out 'echo-unpackLLXFile.json') }
        }
    }
    catch { $summary.Add("Echo: FAILED - $($_.Exception.Message)") }

    $sumFile = Join-Path $out 'DISCOVER-SUMMARY.txt'
    [System.IO.File]::WriteAllLines($sumFile, $summary.ToArray(), $Utf8)
    Write-Log "Discover finished: $sumFile" 'OK'
    Write-Log 'These files contain real alarm and log data. Redact them before sharing.' 'WARN'
}

# =====================================================================================
# Main
# =====================================================================================

if (-not $LlxToolPath) { $LlxToolPath = Join-Path $PSScriptRoot 'LLX-Tool.ps1' }
$PSBoundParameters_LicenseID = $PSBoundParameters.ContainsKey('LicenseID')

Write-Log "Build-EchoCoverage $ScriptVersion | mode $Mode | run folder $RunFolder" 'STEP'

if ($Mode -eq 'Discover') { Invoke-Discover; return }

if ($Resume -or $Mode -eq 'Report') {
    if (-not (Test-Path -LiteralPath $StateFile)) { throw "No state.json in $RunFolder." }
    $script:State = Read-Json $StateFile
    $script:State.Rules = @($script:State.Rules)
    Write-Log "Loaded state: $($script:State.Rules.Count) rules"
}
if ($Mode -eq 'Report') { Write-Report; return }

if ($Mode -eq 'Run') {
    if (-not (Test-Path -LiteralPath $LlxToolPath)) { throw "LLX-Tool.ps1 not found at $LlxToolPath (use -LlxToolPath)." }
    if (-not $LrApiBaseUrl -and (Test-StageAllowed 'Alarms')) { throw '-LrApiBaseUrl is required (e.g. https://platformmanager:8501).' }
    if ($TemplateLlx -and -not (Test-Path -LiteralPath $TemplateLlx)) { throw "Template not found: $TemplateLlx" }
}

# ---- 1. Rules
if (-not $script:State) {
    Write-Log 'Stage 1/5: enabled AIE rules' 'STEP'
    $rules = Get-EnabledRules
    if (-not $rules.Count) { throw 'No enabled AIE rules found (check the query / -RuleFilter).' }
    $script:State = [pscustomobject]@{
        Version = $ScriptVersion; Created = (Get-Date).ToString('o'); LookbackDays = $LookbackDays
        Anonymised = [bool]$Anonymise; Rules = @($rules | ForEach-Object { New-RuleRecord $_.RuleID $_.Name })
    }
    Save-State
    Write-Log "$($rules.Count) enabled rule(s)" 'OK'
}
if (-not (Test-StageAllowed 'Alarms')) { Write-Report; return }

# ---- 2. Alarms
$needAlarms = @($script:State.Rules | Where-Object { -not $_.Done.Alarms })
if ($needAlarms.Count) {
    Write-Log "Stage 2/5: alarms from the last $LookbackDays day(s)" 'STEP'
    $alarms = Get-RecentAlarms
    Save-Json $alarms (Join-Path $RunFolder 'alarms.json') 3
    $byExact = @{}; $byName = @{}
    foreach ($a in $alarms) {
        if (-not $a.RuleName) { continue }
        foreach ($pair in @(@($byExact, $a.RuleName.Trim().ToLowerInvariant()), @($byName, (Get-NameKey $a.RuleName)))) {
            $d = $pair[0]; $k = $pair[1]
            if (-not $d.ContainsKey($k)) { $d[$k] = New-Object System.Collections.Generic.List[object] }
            $d[$k].Add($a)
        }
    }
    # Renamed rules: alarms under an old name count for the new name
    $oldNamesFor = @{}
    if ($RenameMapCsv) {
        foreach ($m in @(Import-Csv -LiteralPath $RenameMapCsv)) {
            $o = [string](Get-Prop $m @('OldName', 'Old', 'From')); $n = [string](Get-Prop $m @('NewName', 'New', 'To'))
            if ($o -and $n) {
                $nk = $n.Trim().ToLowerInvariant()
                if (-not $oldNamesFor.ContainsKey($nk)) { $oldNamesFor[$nk] = @() }
                $oldNamesFor[$nk] = @($oldNamesFor[$nk]) + $o.Trim().ToLowerInvariant()
            }
        }
        Write-Log "Rename map: $($oldNamesFor.Count) renamed rule(s)"
    }
    $exactNames = @{}
    foreach ($r in $script:State.Rules) { $exactNames[$r.Name.Trim().ToLowerInvariant()] = $true }
    foreach ($rule in $needAlarms) {
        $ek = $rule.Name.Trim().ToLowerInvariant()
        $acc = New-Object System.Collections.Generic.List[object]
        if ($byExact.ContainsKey($ek)) { foreach ($x in $byExact[$ek]) { $acc.Add($x) } }
        if ($oldNamesFor.ContainsKey($ek)) {
            foreach ($old in @($oldNamesFor[$ek])) {
                if ($old -ne $ek -and $byExact.ContainsKey($old)) {
                    foreach ($x in $byExact[$old]) { $acc.Add($x) }
                    Add-Note $rule "includes $($byExact[$old].Count) alarm(s) raised under the old name '$old'"
                }
            }
        }
        $group = if ($acc.Count) { $acc.ToArray() } else { $null }
        if (-not $group) {
            # Fuzzy ('AIE:' prefix) match only when no enabled rule has that exact alarm name
            $nk = Get-NameKey $rule.Name
            if ($byName.ContainsKey($nk)) {
                $cand = @($byName[$nk] | Where-Object { -not $exactNames.ContainsKey($_.RuleName.Trim().ToLowerInvariant()) })
                if ($cand.Count) { $group = $cand; Add-Note $rule "matched alarms named '$($cand[0].RuleName)' (ignoring an 'AIE:' prefix)" }
            }
        }
        if ($group) {
            # Alarms flagged alarmDataCached=Y first (they carry drilldown data), then newest first
            $list = @($group | Sort-Object @{ Expression = { if ($_.Cached -eq 'N') { 1 } else { 0 } } }, @{ Expression = { if ($_.Date) { $_.Date } else { [DateTime]::MinValue } }; Descending = $true })
            $rule.AlarmName = $list[0].RuleName
            $rule.AlarmCount = $list.Count
            $top = @($list | Select-Object -First $MaxAlarmsPerRule)
            $rule.AlarmIDs = @($top | ForEach-Object { $_.AlarmID })
            $rule.AlarmCandidates = @($top | ForEach-Object { [pscustomobject]@{ AlarmID = $_.AlarmID; Date = $(if ($_.Date) { $_.Date.ToString('o') }) } })
        }
        else {
            $rule.AlarmCount = 0
            $rule.Status = 'NoAlarms'; $rule.Detail = "No alarms in the last $LookbackDays day(s)"
        }
        $rule.Done.Alarms = $true
    }
    Save-State
    $with = @($script:State.Rules | Where-Object { $_.AlarmCount -gt 0 }).Count
    Write-Log "$($alarms.Count) alarm(s) fetched; $with of $($script:State.Rules.Count) rule(s) have alarms" 'OK'
    $allOld = @($oldNamesFor.Values | ForEach-Object { $_ } | ForEach-Object { Get-NameKey $_ })
    $unmatched = @($byName.Keys | Where-Object { $k = $_; ($allOld -notcontains $k) -and -not @($script:State.Rules | Where-Object { (Get-NameKey $_.Name) -eq $k }).Count })
    if ($unmatched.Count) { Write-Log "$($unmatched.Count) alarm name(s) don't match an enabled AIE rule (other alarm rules, or renamed AIE rules); see alarms.json" }
}

# ---- 3-5. Per rule
if ($Anonymise) { Initialize-AnonTerms; Write-Log 'Anonymiser on' }
$echoReady = $false
$existing = @{}
$todo = @($script:State.Rules | Where-Object { $_.AlarmCount -gt 0 -and -not $_.Done.Echo -and ($_.Status -ne 'Failed' -or $Resume) })
$i = 0
foreach ($rule in $todo) {
    $i++
    Write-Log ("[{0}/{1}] {2} (ID {3})" -f $i, $todo.Count, $rule.Name, $rule.RuleID) 'STEP'
    try {
        $safe = '{0}_{1}' -f (Get-SafeName $rule.RuleID 20), (Get-SafeName $rule.Name 60)
        $logsFile = Join-Path (Join-Path $RunFolder 'drilldown') "$safe.logs.json"

        # 3. Drilldown
        if (-not $rule.Done.Drilldown) {
            if (-not (Test-StageAllowed 'Drilldown')) { break }
            $dd = Get-RuleDrilldown $rule
            if (-not $dd) {
                $rule.Status = 'NoDrilldown'
                $rule.Detail = "None of the newest $(@($rule.AlarmIDs).Count) alarm(s) had drilldown logs. Is Auto Drilldown enabled for this rule?"
                $rule.Done.Drilldown = $true; Save-State
                Write-Log "  $($rule.Detail)" 'WARN'
                continue
            }
            $logs = @($dd.Result.Logs | Sort-Object Block, @{ Expression = { if ($_.Date) { $_.Date } else { [DateTime]::MinValue } } }, Index)
            if ($logs.Count -gt $MaxLogsPerRule) {
                Add-Note $rule "kept the first $MaxLogsPerRule of $($logs.Count) logs (-MaxLogsPerRule)"
                $logs = @($logs | Select-Object -First $MaxLogsPerRule)
            }
            if ($Anonymise) { Protect-Logs $logs }
            if (-not $script:TypesLoaded -and (Test-StageAllowed 'Llx')) {
                try { Connect-Echo; Initialize-EchoTypes } catch { Write-Log "Couldn't read Echo's log source types ($($_.Exception.Message)); EMDB lookup only" 'WARN' }
                $script:TypesLoaded = $true
            }
            Resolve-TypeIds $rule $logs
            $rule.AlarmUsed = $dd.AlarmID
            $cand = @($rule.AlarmCandidates | Where-Object { [string]$_.AlarmID -eq [string]$dd.AlarmID } | Select-Object -First 1)
            if ($cand.Count -and $cand[0].Date) { $rule.AlarmDate = ([DateTime]$cand[0].Date).ToString('yyyy-MM-dd HH:mm:ss') }
            $rule.RuleBlocks = $dd.Result.Blocks
            $rule.Logs = $logs.Count
            $rule.AieCount = $dd.Result.AieCount; $rule.DxCount = $dd.Result.DxCount
            $rule.LogSourceTypes = (@($logs | ForEach-Object { if ($_.MsgSourceTypeName) { $_.MsgSourceTypeName } elseif ($null -ne $_.MsgSourceTypeID) { [string]$_.MsgSourceTypeID } else { '?' } } | Sort-Object -Unique) -join '; ')
            if ($null -ne $rule.AieCount -and $null -ne $rule.DxCount -and $rule.DxCount -lt $rule.AieCount) {
                Add-Note $rule "only $($rule.DxCount) of $($rule.AieCount) triggering logs were retrievable; replay may not reach the rule's threshold"
            }
            if (@($logs | Where-Object { $null -eq $_.MsgSourceTypeID -or "$($_.MsgSourceTypeID)" -eq '' }).Count) {
                Add-Note $rule 'some logs have no log source type ID in the drilldown data'
            }
            Save-Json $logs $logsFile 4
            $rule.Status = 'LogsFound'; $rule.Detail = "$($logs.Count) log(s) from alarm $($dd.AlarmID)"
            $rule.Done.Drilldown = $true; Save-State
            Write-Log "  $($rule.Detail), $($rule.RuleBlocks) rule block(s), types: $($rule.LogSourceTypes)" 'OK'
        }
        if (-not (Test-StageAllowed 'Llx')) { continue }
        if ($rule.Status -eq 'NoDrilldown') { continue }

        $logs = Read-Json $logsFile

        # 4. LLX
        if (-not $rule.Done.Llx) {
            $rule.LlxFile = New-RuleLlx $rule $logs
            $rule.Status = 'LlxBuilt'; $rule.Detail = "$($logs.Count) log(s) -> $(Split-Path -Leaf $rule.LlxFile)"
            $rule.Done.Llx = $true; Save-State
            Write-Log "  LLX written: $($rule.LlxFile)" 'OK'
        }
        if (-not (Test-StageAllowed 'Echo')) { continue }

        # 5. Echo
        if (-not $echoReady) {
            # Read-only calls also run in -DryRun so the payloads show real log source names
            Connect-Echo
            $existing = Get-EchoUseCaseIndex; Write-Log "Echo has $($existing.Count) existing use case(s)"
            if (-not $script:EchoTypeNames.Count) { Initialize-EchoTypes }
            $echoReady = $true
        }
        $result = Publish-RuleToEcho $rule $logs $existing
        switch ($result) {
            'Created' { $rule.Status = 'Created'; $rule.Detail = "Echo use case $($rule.EchoUseCaseID) with $($rule.EchoLogs) log(s)"; $rule.Done.Echo = $true }
            'Exists' { $rule.Status = 'Exists'; $rule.Detail = "Echo already has '$($rule.EchoTitle)' (ID $($rule.EchoUseCaseID)); skipped"; $rule.Done.Echo = $true }
            'DryRun' { $rule.Status = 'DryRun'; $rule.Detail = 'Payload saved to echo\ (dry run, nothing sent)' }
        }
        Save-State
        Write-Log "  $($rule.Detail)" $(if ($result -eq 'Created') { 'OK' } else { 'INFO' })
    }
    catch {
        $rule.Status = 'Failed'; $rule.Detail = $_.Exception.Message
        Save-State
        Write-Log "  FAILED: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" 'ERROR'
        Write-Log ("  " + ($_.ScriptStackTrace -replace '\r?\n', ' <- '))
    }
}

if ($Anonymise -and $script:AnonMap.Count) {
    $mapFile = Join-Path $RunFolder 'anonymisation-map.csv'
    @($script:AnonMap.Values) | Export-Csv -LiteralPath $mapFile -NoTypeInformation -Encoding UTF8
    Write-Log "Anonymisation map (keep private - it reverses the anonymisation): $mapFile" 'WARN'
}

Write-Report
