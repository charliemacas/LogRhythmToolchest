<#
.SYNOPSIS
    LogRhythm / Exabeam SIEM - Enhanced Audit (UDLA) Log Source Onboarding Wizard.

.DESCRIPTION
    Replaces the manual "export XML template -> import via UDLA Settings tab"
    workflow for enabling LogRhythm Enhanced Auditing with a single guided,
    API-driven tool.

    It talks to the LR Admin Service API (createLogSource and friends) to
    create the 12 UDLA log sources that make up a full Enhanced Audit
    deployment - one per SQL Server "_SHADOW" table - using the exact
    query / output-format definitions previously distributed as one-off XML
    templates (AIERuleConfig, AIERuleSets, AIERuleSetToWorkLoad,
    AIERuleStatus, AIERuleToEngine, Alarm, Entity, GLPR, Identity, Person,
    User, MsgSource).

    Because it is intended to be run FROM the Platform Manager against the
    System Monitor / Data Indexer that already sits on that box, the UDLA
    connection string uses SQL Server Integrated Security (Trusted
    connection) throughout - no SQL credentials are ever typed, stored, or
    sent in clear text.

.NOTES
    Author   : Charlie (Security Engineering / TAM)
    Version  : 1.0.0
    Requires : Windows PowerShell 5.1+ or PowerShell 7+
               Network access to the LogRhythm Admin API (default TCP/8501)
               An LR API token with rights to create log sources

    This script ONLY talks to the LogRhythm Admin API. It does not run any
    SQL itself - it assumes LogRhythm Enhanced Auditing (the *_SHADOW
    tables) and the least-privileged 'lrsqlaudit' SQL login have already
    been provisioned (see LR_sqlaudit_create_leastprivuser.sql).

    API token resolution order:
      1. -ApiToken parameter
      2. $env:apikey environment variable (offered automatically, either
         at the -BaseUrl/-ApiToken fast-connect path or inside the
         "Configure Connection" menu option)
      3. Interactive prompt (input hidden)

.LINK
    https://developers.exabeam.com/logrhythm-siem/reference/createlogsource
#>

[CmdletBinding()]
param(
    [string]$BaseUrl,
    [string]$ApiToken,      # falls back to $env:apikey if not supplied
    [switch]$SkipCertificateCheck,
    [switch]$NoBanner
)

# ============================================================================
#region  SCRIPT STATE
# ============================================================================
$script:ConfigDir     = Join-Path $env:LOCALAPPDATA 'LR-EnhancedAudit-Onboarder'
$script:ConfigFile    = Join-Path $script:ConfigDir 'connection.xml'
$script:LogDir        = Join-Path $script:ConfigDir 'logs'
$script:SessionLog    = [System.Collections.Generic.List[object]]::new()
$script:Connected     = $false
$script:ApiBaseUrl       = $null
$script:PlainToken    = $null
$script:SkipCert      = $false

$script:Env = [ordered]@{
    SystemMonitorId   = $null
    SystemMonitorName = $null
    HostId            = $null
    HostName          = $null
    EntityId          = $null
    EntityName        = $null
    LogSourceTypeId   = $null
    LogSourceTypeName = $null
    MpePolicyId       = $null
    MpePolicyName     = $null
}

# Preserved verbatim from the working UDLA export templates - do not "tidy"
# the SQL, the odd spacing/casing in a couple of these is harmless and
# matches the tested, exported originals.
$script:DefaultConnectionString = 'Driver={SQL Server};Server=localhost;Database=LogRhythmEMDB;Integrated Security=SSPI;'
$script:DefaultGetUtcStatement  = 'SELECT GetUTCDate()'
#endregion

# ============================================================================
#region  UI / COLOUR HELPERS  (neon-green, matrix-ish console theme)
# ============================================================================
function Write-Status {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)]
        [ValidateSet('Info', 'Success', 'Warn', 'Error', 'Prompt', 'Dim', 'Title')]
        [string]$Type = 'Info'
    )
    $colour = switch ($Type) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warn'    { 'Yellow' }
        'Error'   { 'Red' }
        'Prompt'  { 'White' }
        'Dim'     { 'DarkGray' }
        'Title'   { 'Green' }
    }
    $prefix = switch ($Type) {
        'Info'    { '[*]' }
        'Success' { '[+]' }
        'Warn'    { '[!]' }
        'Error'   { '[x]' }
        'Prompt'  { '[?]' }
        'Dim'     { '   ' }
        'Title'   { '###' }
    }
    Write-Host "$prefix " -ForegroundColor $colour -NoNewline
    Write-Host $Message -ForegroundColor $colour
}

function Write-Divider {
    param([int]$Length = 74, [string]$Char = '-')
    Write-Host ($Char * $Length) -ForegroundColor DarkGreen
}

function Show-Banner {
    if ($NoBanner) { return }
    $green  = 'Green'
    $dim    = 'DarkGreen'
    Write-Host ''
    Write-Host ' _    ___   ___ ___ _  ___   _______ _  _ __  __ '  -ForegroundColor $dim
    Write-Host '| |  / _ \ / __| _ \ || \ \ / /_   _| || |  \/  |' -ForegroundColor $green
    Write-Host '| |_| (_) | (_ |   / __ |\ V /  | | | __ | |\/| |' -ForegroundColor $green
    Write-Host '|____\___/ \___|_|_\_||_| |_|   |_| |_||_|_|  |_|' -ForegroundColor $dim
    Write-Host ''
    Write-Host ' ___ _  _ _  _   _   _  _  ___ ___ ___      _  _   _ ___ ___ _____ ' -ForegroundColor $dim
    Write-Host '| __| \| | || | /_\ | \| |/ __| __|   \    /_\| | | |   \_ _|_   _|' -ForegroundColor $green
    Write-Host '| _|| .`| | __ |/ _ \| .` | (__| _|| |) |  / _ \ |_| | |) | |  | |  ' -ForegroundColor $green
    Write-Host '|___|_|\_|_||_/_/ \_\_|\_|\___|___|___/  /_/ \_\___/|___/___| |_|  ' -ForegroundColor $dim
    Write-Host ''
    Write-Host '            >> UDLA Log Source Onboarding Wizard <<' -ForegroundColor $green
    Write-Host '            >> AIE / Alarm / GLPR / Identity / Entity / MsgSource audit tables' -ForegroundColor $dim
    Write-Divider
}

function Read-Line {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default,
        [switch]$AllowEmpty
    )
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        Write-Host "[?] $Prompt$suffix`: " -ForegroundColor White -NoNewline
        $val = Read-Host
        if ([string]::IsNullOrWhiteSpace($val)) {
            if ($Default) { return $Default }
            if ($AllowEmpty) { return '' }
            Write-Status 'A value is required.' Warn
            continue
        }
        return $val
    }
}

function Read-SecureLine {
    param([Parameter(Mandatory)][string]$Prompt)
    Write-Host "[?] $Prompt`: " -ForegroundColor White -NoNewline
    return Read-Host -AsSecureString
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$DefaultYes = $true)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        Write-Host "[?] $Prompt $suffix`: " -ForegroundColor White -NoNewline
        $val = (Read-Host).Trim().ToLower()
        if ([string]::IsNullOrWhiteSpace($val)) { return $DefaultYes }
        if ($val -in @('y', 'yes')) { return $true }
        if ($val -in @('n', 'no')) { return $false }
        Write-Status "Please answer 'y' or 'n'." Warn
    }
}

function Read-MenuChoice {
    <#
        Renders a numbered menu of $Items (using $DisplayScript to render
        each line) and returns the *index* (0-based) the user picked.
        Supports a single choice only - see Read-MultiChoice for checklists.
    #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][scriptblock]$DisplayScript,
        [string]$Prompt = 'Choose an option',
        [switch]$AllowCancel
    )
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $line = & $DisplayScript $Items[$i] $i
        Write-Host ('  {0,2}) {1}' -f ($i + 1), $line) -ForegroundColor White
    }
    if ($AllowCancel) { Write-Host '   0) Cancel' -ForegroundColor DarkGray }
    while ($true) {
        Write-Host "[?] $Prompt`: " -ForegroundColor White -NoNewline
        $raw = (Read-Host).Trim()
        if ($AllowCancel -and $raw -eq '0') { return -1 }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
            return $n - 1
        }
        Write-Status "Enter a number between $(if($AllowCancel){0}else{1}) and $($Items.Count)." Warn
    }
}

function Read-MultiChoice {
    <#
        Checklist-style picker. Accepts comma separated numbers ("1,3,5"),
        a range ("1-4"), "*"/"a"/"all", or a blank Enter - the last three
        (and Enter) all select everything, since that's the common case
        for a wizard whose whole point is creating all of these. "0" is
        the explicit "select nothing" / bail-out option.
        Returns an array of 0-based indexes.
    #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][scriptblock]$DisplayScript,
        [string]$Prompt = 'Select item(s)'
    )
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $line = & $DisplayScript $Items[$i] $i
        Write-Host ('  {0,2}) {1}' -f ($i + 1), $line) -ForegroundColor White
    }
    Write-Host '      (comma-separated numbers, a range like 1-4, or "*" for all - just press Enter to select all; "0" selects none)' -ForegroundColor DarkGray
    while ($true) {
        Write-Host "[?] $Prompt`: " -ForegroundColor White -NoNewline
        $raw = (Read-Host).Trim()
        if ($raw -eq '' -or $raw -eq '*' -or $raw -match '^(a|all)$') { return 0..($Items.Count - 1) }
        if ($raw -eq '0') { return @() }

        $picked = [System.Collections.Generic.List[int]]::new()
        $valid = $true
        foreach ($part in ($raw -split ',')) {
            $p = $part.Trim()
            if ($p -match '^(\d+)-(\d+)$') {
                $lo = [int]$matches[1]; $hi = [int]$matches[2]
                if ($lo -lt 1 -or $hi -gt $Items.Count -or $lo -gt $hi) { $valid = $false; break }
                ($lo..$hi) | ForEach-Object { $picked.Add($_ - 1) }
            }
            elseif ($p -match '^\d+$') {
                $n = [int]$p
                if ($n -lt 1 -or $n -gt $Items.Count) { $valid = $false; break }
                $picked.Add($n - 1)
            }
            else { $valid = $false; break }
        }
        if ($valid -and $picked.Count -gt 0) { return ($picked | Sort-Object -Unique) }
        Write-Status 'Could not parse that selection - try e.g. "1,3,5" or "1-4" or "*".' Warn
    }
}
#endregion

# ============================================================================
#region  TLS / CONNECTION PLUMBING
# ============================================================================
function Initialize-TlsSettings {
    param([switch]$SkipCertificateCheck)

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    # PowerShell 7+ handles cert bypass per-request via -SkipCertificateCheck
    # on Invoke-RestMethod, so nothing global to do there. Windows PowerShell
    # 5.1 has no such switch, so fall back to a process-wide policy override
    # using the (deprecated but still functional in .NET Framework)
    # ICertificatePolicy hook. This has to be full C# source via
    # -TypeDefinition - the -MemberDefinition/-ImplementedInterface shorthand
    # does not exist on Add-Type.
    if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -lt 6) {
        try {
            if (-not ('LREATrustAllCertsPolicy' -as [type])) {
                $src = @'
using System.Net;
using System.Security.Cryptography.X509Certificates;

public class LREATrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
'@
                Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
            }
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object LREATrustAllCertsPolicy
        }
        catch {
            Write-Status "Could not set up the TLS certificate bypass ($($_.Exception.Message)) - connections to a self-signed PM certificate may fail. As a workaround, import the PM's certificate into the local machine's Trusted Root store instead of skipping validation." Warn
        }
    }
}

function Save-LREAConnection {
    param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][securestring]$Token, [bool]$SkipCert)
    if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
    [pscustomobject]@{
        BaseUrl  = $BaseUrl
        Token    = ($Token | ConvertFrom-SecureString)
        SkipCert = $SkipCert
        SavedUtc = (Get-Date).ToUniversalTime().ToString('o')
    } | Export-Clixml -Path $script:ConfigFile -Force
}

function Import-LREAConnection {
    if (-not (Test-Path $script:ConfigFile)) { return $null }
    try {
        $raw = Import-Clixml -Path $script:ConfigFile
        $secure = $raw.Token | ConvertTo-SecureString
        [pscustomobject]@{ BaseUrl = $raw.BaseUrl; Token = $secure; SkipCert = [bool]$raw.SkipCert }
    }
    catch {
        # Token was almost certainly encrypted under a different Windows
        # user/machine (DPAPI is not portable) - just treat as "no saved config".
        return $null
    }
}

function ConvertFrom-SecureToPlain {
    param([Parameter(Mandatory)][securestring]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-LRApi {
    <#
        Thin wrapper around Invoke-WebRequest for the LR Admin Service API.
        - Adds the Authorization: Bearer header
        - Builds query strings from a hashtable
        - Decodes the response body as UTF-8 explicitly and parses the JSON
          ourselves, instead of trusting Invoke-RestMethod's own encoding
          auto-detection. Windows PowerShell 5.1 has a long-standing bug
          where it silently mis-decodes UTF-8 response bodies as
          Windows-1252 whenever the server's Content-Type header doesn't
          spell out "charset=utf-8" - which mangles anything with an
          en-dash, accented character, etc. (LogRhythm log source type
          names are a common victim: "Syslog - Temporary LST" comes back
          as "Syslog Ã¢ Temporary LST" or similar).
        - Normalises errors (status code + server-supplied detail message)
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [hashtable]$Query,
        $Body
    )
    if (-not $script:Connected) { throw 'Not connected - use "Configure Connection" first.' }

    $uri = "$($script:ApiBaseUrl.TrimEnd('/'))$Path"
    if ($Query -and $Query.Count -gt 0) {
        $pairs = foreach ($k in $Query.Keys) {
            $v = $Query[$k]
            if ($null -ne $v -and "$v" -ne '') {
                "$([uri]::EscapeDataString($k))=$([uri]::EscapeDataString([string]$v))"
            }
        }
        if ($pairs) { $uri += '?' + ($pairs -join '&') }
    }

    $headers = @{
        Authorization = "Bearer $($script:PlainToken)"
        Accept        = 'application/json'
    }

    $webParams = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $headers
        ErrorAction     = 'Stop'
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        # Deliberately a plain string, not a byte[] - Windows PowerShell
        # 5.1's Invoke-WebRequest has a well-documented quirk where
        # -ContentType can be silently overridden/ignored when -Body is a
        # byte array, which is exactly the kind of thing that gets a
        # request bounced with 415 Unsupported Media Type. A string body
        # with -ContentType 'application/json' is the traditional,
        # well-tested pattern that works the same way on every PowerShell
        # version - there's no encoding risk here since this is what *we*
        # send, not what the server sends back (the earlier UTF-8 fix was
        # about decoding the response correctly, which is a different,
        # already-solved problem).
        $webParams.Body        = ($Body | ConvertTo-Json -Depth 15 -Compress)
        $webParams.ContentType = 'application/json'
    }
    if ($script:SkipCert -and $PSVersionTable.PSVersion.Major -ge 6) {
        $webParams.SkipCertificateCheck = $true
    }

    try {
        $resp = Invoke-WebRequest @webParams
        return ConvertFrom-LRResponseBytes -Response $resp
    }
    catch {
        $status = $null
        $detail = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        try {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                # PS6+: Invoke-WebRequest throws HttpResponseException; the
                # body is already captured (as text) on ErrorDetails.
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $detail = $_.ErrorDetails.Message
                }
            }
            elseif ($_.Exception.Response) {
                # Windows PowerShell 5.1: classic WebException with a
                # readable stream - decode it as UTF-8 ourselves too.
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $ms = New-Object IO.MemoryStream
                    $stream.CopyTo($ms)
                    $detail = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
                }
            }
        }
        catch {}

        $friendlyDetail = $detail
        if ($detail) {
            try {
                $parsed = $detail | ConvertFrom-Json -ErrorAction Stop
                if ($parsed.message) { $friendlyDetail = $parsed.message }
                elseif ($parsed.Message) { $friendlyDetail = $parsed.Message }
            }
            catch {}
        }

        $apiErr = [pscustomobject]@{
            StatusCode = $status
            Message    = $_.Exception.Message
            Detail     = $friendlyDetail
        }
        throw $apiErr
    }
}

function ConvertFrom-LRResponseBytes {
    param($Response)
    $bytes = $null
    if ($Response.PSObject.Properties.Name -contains 'RawContentStream' -and $Response.RawContentStream) {
        $bytes = $Response.RawContentStream.ToArray()
    }
    elseif ($Response.Content -is [byte[]]) {
        $bytes = $Response.Content
    }
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    # ConvertFrom-Json's -Depth parameter doesn't exist in Windows
    # PowerShell 5.1 (it was added in 6.2) - passing it there fails with
    # "A parameter cannot be found that matches parameter name 'Depth'"
    # before the response is even parsed. WinPS 5.1's fixed built-in depth
    # (100) is already far more than this API's JSON needs, so only add
    # -Depth where the parameter actually exists.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $text | ConvertFrom-Json -Depth 20
    }
    return $text | ConvertFrom-Json
}

function Test-LRApiConnection {
    <#
        Returns an object rather than a bare boolean so callers can show
        *why* it failed - connection refused, TLS handshake failure, 401
        Unauthorized, a genuine PowerShell exception, etc. Swallowing that
        detail (as an earlier version of this function did) makes an auth
        failure and a network failure look identical, which is exactly the
        kind of thing that's impossible to debug from the outside.
    #>
    try {
        # Cheapest possible authenticated call - list a single agent record.
        Invoke-LRApi -Path '/lr-admin-api/agents' -Query @{ count = 1 } | Out-Null
        return [pscustomobject]@{ Success = $true; Detail = $null }
    }
    catch {
        $e = $_.TargetObject
        $detail = if ($e) {
            $parts = @()
            if ($e.StatusCode) { $parts += "HTTP $($e.StatusCode)" }
            if ($e.Detail) { $parts += $e.Detail }
            elseif ($e.Message) { $parts += $e.Message }
            if ($parts.Count -gt 0) { $parts -join ' - ' } else { 'Unknown error (no status code or message captured).' }
        }
        else {
            # Invoke-LRApi threw something that wasn't its own normalised
            # error object - e.g. a raw PowerShell/.NET exception before
            # the request even went out. Show it raw rather than hiding it.
            "$($_.Exception.GetType().Name): $($_.Exception.Message)"
        }
        return [pscustomobject]@{ Success = $false; Detail = $detail }
    }
}

function ConvertTo-LRRecordArray {
    <#
        Defensively coerces whatever Invoke-LRApi handed back into a flat
        array of one-record-per-item objects, regardless of which shape
        that particular endpoint happens to use:
          - a bare JSON array                                -> passthrough
          - a common pagination envelope ({ items: [...] },
            { results: [...] }, { records: [...] }, { value: [...] },
            { data: [...] })                                  -> unwrapped
          - a single object whose properties are themselves
            parallel arrays (id: [1,2,3], name: ["a","b","c"])
            instead of one object per row                     -> zipped
            back into proper row objects
        This exists because a couple of LR Admin API list endpoints have
        been observed collapsing into that last shape for larger result
        sets, which silently breaks any code assuming one scalar-valued
        object per row (e.g. -match against a "name" that's actually an
        array matches/doesn't-match every element at once).
    #>
    param($Raw)

    if ($null -eq $Raw) { return @() }
    $arr = @($Raw)
    if ($arr.Count -ne 1) { return $arr }

    $only = $arr[0]
    if ($null -eq $only) { return @() }

    foreach ($wrapperProp in @('items', 'results', 'records', 'value', 'data')) {
        $prop = $only.PSObject.Properties[$wrapperProp]
        if ($prop -and $prop.Value -is [array]) { return @($prop.Value) }
    }

    $arrayProps = @($only.PSObject.Properties | Where-Object { $_.Value -is [array] })
    if ($arrayProps.Count -ge 1) {
        $lengths = $arrayProps | ForEach-Object { $_.Value.Count } | Sort-Object -Unique
        if ($lengths.Count -eq 1 -and $lengths[0] -gt 1) {
            $rowCount = $lengths[0]
            return @(
                for ($i = 0; $i -lt $rowCount; $i++) {
                    $row = [ordered]@{}
                    foreach ($p in $only.PSObject.Properties) {
                        $row[$p.Name] = if ($p.Value -is [array] -and $p.Value.Count -eq $rowCount) { $p.Value[$i] } else { $p.Value }
                    }
                    [pscustomobject]$row
                }
            )
        }
    }

    return $arr
}
#endregion

# ============================================================================
#region  ENHANCED AUDIT UDLA TEMPLATES
#
#   Transcribed verbatim (query text, output format, field names) from the
#   twelve UDLA XML export templates that make up a full LogRhythm Enhanced
#   Audit deployment. Source file noted against each for traceability back
#   to the originals if LogRhythm ever revises the shadow-table schema.
# ============================================================================
function Get-AuditTemplates {
    @(
        [pscustomobject]@{
            Key           = 'AIERuleConfig'
            Label         = 'AIE Rule Config'
            Description   = 'AI Engine rule create / edit / retire audit trail'
            SourceFile    = 'AIERuleConfig.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.AIERule_SHADOW.TransDate, dbo.AIERule_SHADOW.AuditID, dbo.AIERule_SHADOW.OriginalUser, dbo.AIERule_SHADOW.RecordStatus, dbo.AIERule_SHADOW.TransType, dbo.aierule_SHADOW.AIERuleID, dbo.aierule.name FROM dbo.AIERule_SHADOW INNER JOIN AIERule on dbo.AIERule_SHADOW.AIERuleID = dbo.AIERule.AIERuleID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,aieRuleID=<aieruleid>,name=<name>,retired=<recordstatus>,originalUser=<OriginalUser>,transType=<transtype>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'AIERuleSets'
            Label         = 'AIE Rule Sets'
            Description   = 'AI Engine rule-set create / edit audit trail'
            SourceFile    = 'AIERuleSets.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.AIERuleSet_SHADOW.TransDate, dbo.AIERuleSet_SHADOW.AuditID, dbo.AIERuleSet_SHADOW.OriginalUser, dbo.AIERuleSet_SHADOW.TransType, dbo.AIERuleSet_SHADOW.AIERuleSetID, dbo.AIERuleSet.Name FROM dbo.AIERuleSet_SHADOW INNER JOIN AIERuleSet on dbo.AIERuleSet_SHADOW.AIERuleSetID = dbo.AIERuleSet.AIERuleSetID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,aieRuleSetID=<aierulesetid>,name=<name>,originalUser=<OriginalUser>,transType=<transtype>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'AIERuleSetToWorkLoad'
            Label         = 'AIE Rule Set To Workload'
            Description   = 'AI Engine rule-set <-> workload (engine) assignment audit trail'
            SourceFile    = 'AIERuleSetToWorkLoad.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.AIERuleSetToWorkLoad_SHADOW.TransDate, dbo.AIERuleSetToWorkLoad_SHADOW.AuditID, dbo.AIERuleSetToWorkLoad_SHADOW.OriginalUser, dbo.AIERuleSetToWorkLoad_SHADOW.TransType, dbo.AIERuleSetToWorkLoad_SHADOW.AIERuleSetID, dbo.AIERuleSetToWorkLoad_SHADOW.AIEWorkloadID, dbo.AIERuleSet.Name as AIERuleSetName, dbo.AIEWorkLoad.Name as AIEWorkloadName FROM dbo.AIERuleSetToWorkLoad_SHADOW INNER JOIN AIERuleSet on dbo.AIERuleSetToWorkload_SHADOW.AIERuleSetID = dbo.AIERuleSet.AIERuleSetID INNER JOIN AIEWorkload on dbo.AIERuleSetToWorkload_SHADOW.AIEWorkloadID = dbo.AIEWorkLoad.AIEWorkLoadID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,aieWorkloadID=<aieworkloadid>,name=<aieworkloadname>,originalUser=<originaluser>,transType=<transtype>,aieRuleSetID=<aierulesetid>,aieRuleSetName=<aierulesetname>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'AIERuleStatus'
            Label         = 'AIE Rule Status'
            Description   = 'AI Engine rule enable/disable-per-engine audit trail'
            SourceFile    = 'AIERuleStatus.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.AIERuleToEngine_SHADOW.TransDate, dbo.AIERuleToEngine_SHADOW.AuditID, dbo.AIERuleToEngine_SHADOW.OriginalUser, dbo.AIERuleToEngine_SHADOW.Enabled, dbo.AIERuleToEngine_SHADOW.TransType, dbo.AIERule.AIERuleID, dbo.AIERule.Name FROM dbo.AIERuleToEngine_SHADOW INNER JOIN AIERule on dbo.AIERuleToEngine_SHADOW.AIERuleID = dbo.AIERule.AIERuleID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,aieRuleID=<aieruleid>,name=<name>,enabled=<enabled>,originalUser=<OriginalUser>,transType=<transtype>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'AIERuleToEngine'
            Label         = 'AIE Rule To Engine'
            Description   = 'AI Engine rule <-> engine assignment audit trail'
            SourceFile    = 'AIERuleToEngine.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.AIERuleToEngine_SHADOW.TransDate, dbo.AIERuleToEngine_SHADOW.AuditID, dbo.AIERuleToEngine_SHADOW.OriginalUser, dbo.AIERuleToEngine_SHADOW.TransType, dbo.AIERuleToEngine_SHADOW.AIERuleID, dbo.AIERuleToEngine_SHADOW.Enabled, dbo.AIERule.Name as AIERuleName, dbo.AIERuleToEngine_Shadow.AIEEngineID, dbo.AIEServer.Name as AIEEngineName  FROM dbo.AIERuleToEngine_SHADOW  INNER JOIN AIERule on dbo.AIERuleToEngine_SHADOW.AIERuleID = dbo.AIERule.AIERuleID INNER JOIN AIEServer on dbo.AIERuleToEngine_SHADOW.AIEEngineID = dbo.AIEServer.AIEServerID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,aieEngineID=<aieengineid>,name=<aieenginename>,enabled=<enabled>,originalUser=<OriginalUser>,transType=<transtype>,aieRuleID=<aieruleid>,aieRuleName=<aierulename>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'Alarm'
            Label         = 'Alarm Rule'
            Description   = 'Alarm rule create / edit / enable-disable audit trail (excludes the "sa" system account)'
            SourceFile    = 'Alarm.xml'
            Query         = "SELECT TOP <Max_Message_Count> AlarmRule_SHADOW.TransDate, AlarmRule_SHADOW.SystemUser, AlarmRule_SHADOW.RecordStatus, AlarmRule_SHADOW.Enabled, AlarmRule_SHADOW.TransType, dbo.AlarmRule.AlarmRuleID, dbo.alarmRule.name FROM dbo.AlarmRule_SHADOW INNER JOIN AlarmRule on dbo.AlarmRule_SHADOW.AlarmRuleID = dbo.AlarmRule.AlarmRuleID WHERE dbo.AlarmRule_SHADOW.systemuser not like 'sa'"
            OutputFormat  = 'transDate=<transdate> UTC,alarmRuleID=<alarmruleid>,name=<name>,systemUser=<systemuser>,transType=<transtype>,recordStatus=<RecordStatus>,enabled=<Enabled>'
            UniqueId      = 'TransDate'
            MsgDateField  = 'TransDate'
            StateType     = 'Timestamp'
            StateField    = 'TransDate'
        }
        [pscustomobject]@{
            Key           = 'Entity'
            Label         = 'Entity'
            Description   = 'Entity (log source grouping) create / edit audit trail'
            SourceFile    = 'Entity.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.Entity_SHADOW.TransDate, dbo.Entity_SHADOW.AuditID, dbo.Entity_SHADOW.OriginalUser, dbo.Entity_SHADOW.TransType, dbo.Entity_SHADOW.EntityID, dbo.Entity_SHADOW.ParentEntityID, dbo.Entity_SHADOW.RecordStatus, dbo.Entity_SHADOW.Name, dbo.Entity_SHADOW.FullName as newFullName, dbo.Entity_SHADOW.Abbreviation, dbo.Entity_SHADOW.ShortDesc, dbo.Entity_SHADOW.LongDesc, dbo.Entity.FullName FROM dbo.Entity_SHADOW INNER JOIN Entity on dbo.Entity_SHADOW.EntityID = dbo.Entity.EntityID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,entityID=<EntityID>,fullName=<fullname>,recordStatus=<recordstatus>,originalUser=<OriginalUser>,transType=<transtype>,newName=<name>,newFullName=<newfullname>,newAbbreviation=<abbreviation>,newParentEntityID<parententityid>,newShortDesc<shortdesc>,newLongDesc=<longdesc>'
            UniqueId      = 'TransDate'
            MsgDateField  = 'TransDate'
            StateType     = 'Timestamp'
            StateField    = 'TransDate'
        }
        [pscustomobject]@{
            Key           = 'GLPR'
            Label         = 'Global Log Processing Rule'
            Description   = 'Global Log Processing Rule (GLPR) create / edit / status audit trail'
            SourceFile    = 'GLPR.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.GlobalLogProcessingRule_SHADOW.TransDate, dbo.GlobalLogProcessingRule_SHADOW.AuditID, dbo.GlobalLogProcessingRule_SHADOW.OriginalUser, dbo.GlobalLogProcessingRule_SHADOW.Status, dbo.GlobalLogProcessingRule_SHADOW.TransType, dbo.GlobalLogProcessingRule.GlobalLogProcessingRuleID, dbo.GlobalLogProcessingRule.Name FROM dbo.GlobalLogProcessingRule_SHADOW INNER JOIN GlobalLogProcessingRule on dbo.GlobalLogProcessingRule_SHADOW.GlobalLogProcessingRuleID = dbo.GlobalLogProcessingRule.GlobalLogProcessingRuleID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,globalLogProcessingRuleID=<GlobalLogProcessingRuleID>,name=<name>,status=<status>,originalUser=<OriginalUser>,transType=<transtype>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'Identity'
            Label         = 'Identity (legacy Person)'
            Description   = 'Lightweight person/identity record change audit trail (id, status, full name only)'
            SourceFile    = 'Identity.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.Person_Shadow.TransDate, dbo.Person_SHADOW. AuditID, dbo.Person_SHADOW.OriginalUser, dbo.Person_SHADOW.TransType, dbo.Person_SHADOW.PersonID, dbo.Person_SHADOW.RecordStatus, dbo.Person.FullName FROM dbo.Person_SHADOW INNER JOIN person on dbo.Person_SHADOW.PersonID = dbo.Person.PersonID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,personID=<personID>,fullName=<fullname>,recordStatus=<recordstatus>,originalUser=<OriginalUser>,transType=<transtype>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'Person'
            Label         = 'Person (full)'
            Description   = 'Full person record change audit trail - name, AD group/domain, UPN, description fields'
            SourceFile    = 'Person.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.Person_SHADOW.TransDate, dbo.Person_SHADOW.AuditID, dbo.Person_SHADOW.OriginalUser, dbo.Person_SHADOW.TransType, dbo.Person_SHADOW.PersonID, dbo.Person_SHADOW.RecordStatus, dbo.Person_SHADOW.FirstName,dbo.Person_SHADOW.MiddleName, dbo.Person_SHADOW.LastName, dbo.Person_SHADOW.FullName as newFullName, dbo.Person_SHADOW.Abbreviation, dbo.Person_SHADOW.PersonType, dbo.Person_SHADOW.ShortDesc, dbo.Person_SHADOW.LongDesc, dbo.Person_SHADOW.ADGroup, dbo.Person_SHADOW.IsAPIPerson, dbo.Person_SHADOW.ADDomain, dbo.Person_SHADOW.UserPrincipalName, dbo.Person.FullName FROM dbo.Person_SHADOW INNER JOIN Person on dbo.Person_SHADOW.PersonID = dbo.Person.PersonID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,PersonID=<PersonID>,fullName=<fullname>,recordStatus=<recordstatus>,originalUser=<OriginalUser>,transType=<transtype>,newFirstName=<firstname>,newMiddleName=<middlename>,newLastName=<lastname>,newFullName=<newfullname>,abbreviation=<abbreviation>,newPersonType=<persontype>,newShortDesc=<shortdesc>,newLongDesc=<longdesc>,newADGroup=<adgroup>,newIsAPerson=<isapiperson>,newADDomain=<addomain>,newUserPrincipalName=<userprincipalname>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'User'
            Label         = 'User (SCUser)'
            Description   = 'Console user account create/edit/status + profile & default-entity assignment audit trail'
            SourceFile    = 'User.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.SCUser_SHADOW.TransDate, dbo.SCUser_SHADOW.AuditID, dbo.SCUser_SHADOW.OriginalUser, dbo.SCUser_SHADOW.TransType, dbo.SCUser_SHADOW.UserID, dbo.SCUser_SHADOW.RecordStatus, dbo.SCUser_SHADOW.UserProfileID, dbo.SCUser_SHADOW.DefaultEntityID, dbo.SCUser.Login, dbo.person.fullname FROM dbo.SCUser_SHADOW INNER JOIN scuser on dbo.SCUser_SHADOW.UserID = dbo.SCUser.UserID Inner join person on dbo.SCUser.personID = dbo.person.personid'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,userID=<userID>,fullName=<fullname>,recordStatus=<recordstatus>,originalUser=<OriginalUser>,transType=<transtype>,login=<login>,newUserProfileID=<userprofileid>,newDefaultEntityID=<defaultentityid>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'TransDate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
        [pscustomobject]@{
            Key           = 'MsgSource'
            Label         = 'Log Message Source'
            Description   = 'Log source create / edit / status audit trail'
            SourceFile    = 'MsgSource.xml'
            Query         = 'SELECT TOP <Max_Message_Count> dbo.MsgSource_SHADOW.TransDate, dbo.MsgSource_SHADOW.AuditID,dbo.MsgSource_SHADOW.OriginalUser, dbo.MsgSource_SHADOW.RecordStatus, dbo.MsgSource_SHADOW.TransType, dbo.MsgSource.MsgSourceID, dbo.MsgSource.Name FROM dbo.MsgSource_SHADOW INNER JOIN MsgSource on dbo. MsgSource_SHADOW.MsgSourceID = dbo.MsgSource.MsgSourceID'
            OutputFormat  = 'transDate=<transdate> UTC,auditID=<AuditID>,msgSourceID=<MsgSourceID>,name=<name>,recordStatus=<recordstatus>,originalUser=<OriginalUser>,transType=<transtype>'
            UniqueId      = 'AuditID'
            MsgDateField  = 'transdate'
            StateType     = 'Increment'
            StateField    = 'AuditID'
        }
    )
}
#endregion

# ============================================================================
#region  ENVIRONMENT DISCOVERY  (system monitor, host, entity, log source
#         type, mpe policy - everything Create Log Source needs by reference)
# ============================================================================
function Get-LRAgents {
    param([string]$NameFilter)
    $q = @{ count = 1000; recordStatus = 'active' }
    if ($NameFilter) { $q.name = $NameFilter }
    ConvertTo-LRRecordArray (Invoke-LRApi -Path '/lr-admin-api/agents' -Query $q)
}

function Get-LRAgentHostName {
    <#
        An agent's LogRhythm display Name (e.g. "LabXM") and the underlying
        Windows host it runs on (e.g. "XM") are two different things in
        LogRhythm's data model - the API's "name" query filter only ever
        searches the former. This tries every plausible property name the
        Admin API has been observed using for the latter, falling back to
        the display name only if none are present.
    #>
    param($Agent)
    foreach ($prop in @('agentHostName', 'hostName', 'hostname', 'agentHost', 'HostName')) {
        if ($Agent.PSObject.Properties.Name -contains $prop -and $Agent.$prop) {
            return [string]$Agent.$prop
        }
    }
    return [string]$Agent.name
}

function Get-LRHosts {
    param([string]$NameFilter)
    $q = @{ count = 1000 }
    if ($NameFilter) { $q.name = $NameFilter }
    ConvertTo-LRRecordArray (Invoke-LRApi -Path '/lr-admin-api/hosts' -Query $q)
}

function Get-LREntities {
    param([string]$NameFilter)
    $q = @{ count = 1000 }
    if ($NameFilter) { $q.name = $NameFilter }
    ConvertTo-LRRecordArray (Invoke-LRApi -Path '/lr-admin-api/entities' -Query $q)
}

function Get-LRMessageSourceTypes {
    param([string]$NameFilter, [string]$Format)
    $q = @{ count = 1000 }
    if ($NameFilter) { $q.name = $NameFilter }
    if ($Format) { $q.messageSourceFormat = $Format }
    ConvertTo-LRRecordArray (Invoke-LRApi -Path '/lr-admin-api/messagesourcetypes' -Query $q)
}

function Get-LRMpePolicies {
    param([string]$NameFilter, [int]$MessageSourceTypeId)
    $q = @{ count = 1000 }
    if ($NameFilter) { $q.name = $NameFilter }
    if ($MessageSourceTypeId) { $q.messageSourceTypeId = $MessageSourceTypeId }
    ConvertTo-LRRecordArray (Invoke-LRApi -Path '/lr-admin-api/mpepolicies' -Query $q)
}

function Get-LRExistingLogSourceNames {
    # Pulls current log source names so we can flag "this name already exists"
    # before we bother POSTing (a 409 is not fatal but a pre-flight check
    # saves a round trip and lets us suggest an alternate name up front).
    param([int]$SystemMonitorId)
    $q = @{ count = 1000 }
    if ($SystemMonitorId) { $q.systemMonitorId = $SystemMonitorId }
    try {
        $result = ConvertTo-LRRecordArray (Invoke-LRApi -Path '/lr-admin-api/logsources' -Query $q)
        return @($result | ForEach-Object { $_.name })
    }
    catch { return @() }
}

function Select-DiscoveredItem {
    <#
        Runs a discovery call, shows a numbered pick-list of id/name pairs,
        and returns the chosen object. Handles the "exactly one match -
        just use it" fast path so the wizard doesn't nag when there's
        nothing to choose between.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][scriptblock]$FetchScript,
        [string]$SuggestedFilter
    )
    Write-Status "Looking up $What..." Info
    $items = @(& $FetchScript $SuggestedFilter)
    if ($items.Count -eq 0 -and $SuggestedFilter) {
        Write-Status "No $What matched '$SuggestedFilter' - showing full list instead." Warn
        $items = @(& $FetchScript $null)
    }
    if ($items.Count -eq 0) {
        Write-Status "No $What found via the API. Check the account has read access, then try again." Error
        return $null
    }
    $suspect = $items | Where-Object { "$($_.name)".Length -gt 150 }
    if ($suspect) {
        Write-Status "The $What list came back looking malformed (an item's name is unusually long - the API response for this endpoint may not be shaped the way this wizard expects). Proceed carefully and double-check the id you pick against the LR console." Warn
    }
    if ($items.Count -eq 1) {
        Write-Status "Using the only $What found: $($items[0].name) (id $($items[0].id))" Success
        return $items[0]
    }
    $idx = Read-MenuChoice -Items $items -Prompt "Select the $What to use" -DisplayScript {
        param($it, $i) "$($it.name)  (id $($it.id))"
    }
    return $items[$idx]
}
#endregion

# ============================================================================
#region  LOG SOURCE CREATION
# ============================================================================
function New-AuditLogSourceBody {
    <#
        Builds the JSON body for POST /lr-admin-api/logsources/ for one
        Enhanced Audit UDLA template, using whatever the wizard discovered
        for System Monitor / Host / Entity / LogSourceType / MpePolicy.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Template,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ConnectionString,
        [int]$MaxMessageCount = 1000,
        [string]$MpeProcessingMode = 'EventForwardingEnabled'
    )
    [ordered]@{
        id                      = -1
        systemMonitorId         = $script:Env.SystemMonitorId
        name                    = $Name
        host                    = @{ id = $script:Env.HostId }
        entity                  = @{ id = $script:Env.EntityId }
        logSourceType           = @{ id = $script:Env.LogSourceTypeId }
        mpePolicy               = @{ id = $script:Env.MpePolicyId }
        shortDescription        = "LogRhythm Enhanced Audit - $($Template.Label)"
        longDescription         = "Auto-created by the LR Enhanced Audit Onboarder ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) from $($Template.SourceFile). $($Template.Description)"
        recordStatus            = 'Active'
        status                  = 'Enabled'
        isVirtual               = $false
        mpeProcessingMode       = $MpeProcessingMode
        isArchivingEnabled      = $true
        maxMsgCount             = $MaxMessageCount
        msgPerCycle             = 100
        collectionThreadTimeout = 120
        udlaConnectionType      = 0                 # 0 = ODBC (matches the exported templates)
        udlaConnectionString    = $ConnectionString
        udlaQueryStatement      = $Template.Query
        udlaOutputFormat        = $Template.OutputFormat
        udlaUniqueIdentifier    = $Template.UniqueId
        udlaMsgDateField        = $Template.MsgDateField
        udlaStateFieldType      = $Template.StateType
        udlaStateField          = $Template.StateField
        udlaStateFieldConversion = '<NONE>'
        udlaGetUTCDateStatement = $script:DefaultGetUtcStatement
    }
}

function New-AuditLogSource {
    param(
        [Parameter(Mandatory)][pscustomobject]$Template,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ConnectionString,
        [int]$MaxMessageCount = 1000
    )
    $body = New-AuditLogSourceBody -Template $Template -Name $Name -ConnectionString $ConnectionString -MaxMessageCount $MaxMessageCount
    $result = [pscustomobject]@{
        Template  = $Template.Label
        Name      = $Name
        Success   = $false
        LogSourceId = $null
        Message   = ''
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    try {
        $resp = Invoke-LRApi -Path '/lr-admin-api/logsources/' -Method POST -Body $body
        $result.Success     = $true
        $result.LogSourceId = $resp.id
        $result.Message     = 'Created'
    }
    catch {
        $apiErr = $_.TargetObject
        $code   = if ($apiErr) { $apiErr.StatusCode } else { $null }
        $detail = if ($apiErr) { $apiErr.Detail } else { $null }
        $msg    = if ($apiErr) { $apiErr.Message } else { $_.Exception.Message }

        $result.Success = $false
        $result.Message = switch ($code) {
            403 { 'Permission denied - the API token does not have rights to create log sources.' }
            409 { "A log source named '$Name' already exists." }
            default {
                if ($detail) { "HTTP $code - $detail" } else { "HTTP $code - $msg" }
            }
        }
    }
    $script:SessionLog.Add($result)
    return $result
}
#endregion

# ============================================================================
#region  WIZARD STEPS
# ============================================================================
function Invoke-ConfigureConnection {
    Write-Divider
    Write-Status 'Configure Connection' Title
    Write-Divider

    $saved = Import-LREAConnection
    if ($saved) {
        Write-Status "A saved connection was found for $($saved.BaseUrl)." Info
        if (Read-YesNo -Prompt 'Use the saved connection?' -DefaultYes $true) {
            $script:ApiBaseUrl = $saved.BaseUrl
            $script:PlainToken = ConvertFrom-SecureToPlain -Secure $saved.Token
            $script:SkipCert   = $saved.SkipCert
            Initialize-TlsSettings -SkipCertificateCheck:$script:SkipCert
            $script:Connected  = $true
            $test = Test-LRApiConnection
            if ($test.Success) {
                Write-Status 'Connected successfully using the saved token.' Success
                return
            }
            Write-Status "Saved connection did not work: $($test.Detail)" Warn
            $script:Connected = $false
        }
    }

    Write-Status 'This wizard is normally run FROM the Platform Manager, so the default' Dim
    Write-Status 'below points at the local Admin API on this box.' Dim
    $base = Read-Line -Prompt 'LR Admin API base URL' -Default 'https://localhost:8501'

    if ($env:apikey) {
        Write-Status 'Found an API token in the $env:apikey environment variable.' Info
        if (Read-YesNo -Prompt 'Use it?' -DefaultYes $true) {
            $secureToken = ConvertTo-SecureString -String $env:apikey -AsPlainText -Force
        }
        else {
            $secureToken = Read-SecureLine -Prompt 'API token (input hidden)'
        }
    }
    else {
        $secureToken = Read-SecureLine -Prompt 'API token (input hidden)'
    }

    $skip = Read-YesNo -Prompt 'Skip TLS certificate validation? (yes for a self-signed PM cert)' -DefaultYes $true

    $script:ApiBaseUrl    = $base
    $script:PlainToken = ConvertFrom-SecureToPlain -Secure $secureToken
    $script:SkipCert   = $skip
    Initialize-TlsSettings -SkipCertificateCheck:$skip
    $script:Connected  = $true

    Write-Status 'Testing connection...' Info
    $test = Test-LRApiConnection
    if ($test.Success) {
        Write-Status 'Connected successfully.' Success
        if (Read-YesNo -Prompt 'Save this connection for next time? (token is encrypted to your Windows user account)' -DefaultYes $true) {
            Save-LREAConnection -BaseUrl $base -Token $secureToken -SkipCert $skip
            Write-Status "Saved to $script:ConfigFile" Success
        }
    }
    else {
        Write-Status "Could not authenticate against that URL/token: $($test.Detail)" Error
        Write-Status 'Double-check the base URL, that the token is valid, and that this box can reach the Admin API port (8501 by default).' Dim
        $script:Connected = $false
    }
}

function Invoke-DiscoverEnvironment {
    Write-Divider
    Write-Status 'Discover Environment' Title
    Write-Divider
    if (-not $script:Connected) {
        Write-Status 'Configure the connection first (main menu option 1).' Warn
        return
    }

    # --- System Monitor (agent) -------------------------------------------------
    # Deliberately NOT filtering this server-side: the API's "name" query
    # param only searches the agent's LogRhythm display name (e.g. "LabXM"),
    # not the underlying host it runs on (e.g. "XM") - those are commonly
    # different, and a hostname-based guess would silently miss a match if
    # we relied on the server-side filter here.
    Write-Status 'Every Enhanced Audit log source has to be assigned to a System Monitor - that''s the agent that will actually run the SQL queries and poll for new audit records.' Info
    Write-Status 'Because the connection string uses "localhost", this has to be the System Monitor running ON this Platform Manager box - not a remote agent elsewhere in the deployment.' Info
    $localName = $env:COMPUTERNAME
    Write-Status 'Looking up System Monitor agent...' Info
    $agents = @(Get-LRAgents)
    if ($agents.Count -eq 0) {
        Write-Status 'No System Monitor agents found via the API. Check the account has read access, then try again.' Error
        return
    }
    $suspect = $agents | Where-Object { "$($_.name)".Length -gt 150 }
    if ($suspect) {
        Write-Status "The agent list came back looking malformed (an item's name is unusually long). Proceed carefully and double-check the id against the LR console." Warn
    }

    $agentMatches = @($agents | Where-Object { $_.name -eq $localName -or (Get-LRAgentHostName $_) -eq $localName })
    if ($agentMatches.Count -eq 0 -and $localName) {
        $agentMatches = @($agents | Where-Object { $_.name -like "*$localName*" -or (Get-LRAgentHostName $_) -like "*$localName*" })
    }
    $candidates = if ($agentMatches.Count -gt 0) { $agentMatches } else { $agents }
    if ($candidates.Count -lt $agents.Count) {
        Write-Status "Matched '$localName' against $($candidates.Count) of $($agents.Count) agent(s) (checked both agent name and host name)." Dim
    }

    if ($candidates.Count -eq 1) {
        $agent = $candidates[0]
        Write-Status "Using the only System Monitor agent found: $($agent.name) [host: $(Get-LRAgentHostName $agent)] (id $($agent.id))" Success
    }
    else {
        $idx = Read-MenuChoice -Items $candidates -Prompt "Select the System Monitor running on THIS box ($env:COMPUTERNAME) - it will own all the log sources created below" -DisplayScript {
            param($it, $i) "$($it.name)  [host: $(Get-LRAgentHostName $it)]  (id $($it.id))"
        }
        $agent = $candidates[$idx]
    }
    $script:Env.SystemMonitorId   = $agent.id
    $script:Env.SystemMonitorName = $agent.name

    # --- Host --------------------------------------------------------------------
    $hostGuess = Get-LRAgentHostName $agent
    $hostRec = Select-DiscoveredItem -What 'Host record' -SuggestedFilter $hostGuess -FetchScript {
        param($filter) (Get-LRHosts -NameFilter $filter)
    }
    if (-not $hostRec) { return }
    $script:Env.HostId   = $hostRec.id
    $script:Env.HostName = $hostRec.name

    # --- Entity --------------------------------------------------------------------
    $entityGuess = if ($agent.entityName) { $agent.entityName } else { 'Global Entity' }
    $entity = Select-DiscoveredItem -What 'Entity' -SuggestedFilter $entityGuess -FetchScript {
        param($filter) (Get-LREntities -NameFilter $filter)
    }
    if (-not $entity) { return }
    $script:Env.EntityId   = $entity.id
    $script:Env.EntityName = $entity.name

    # --- Log Source Type (UDLA - LREnhancedAudit) ---------------------------------
    Write-Status 'Looking up the UDLA log source type...' Info
    $types = @(Get-LRMessageSourceTypes -Format 'UniversalDatabaseLogAdapter')
    if ($types.Count -eq 0) {
        Write-Status 'No UDLA log source types found on this deployment - is the LogRhythm Enhanced Audit knowledge base module installed?' Error
        return
    }
    $suspect = $types | Where-Object { "$($_.name)".Length -gt 150 }
    if ($suspect) {
        Write-Status "The log source type list came back looking malformed (an item's name is unusually long). Proceed carefully and double-check the id against the LR console." Warn
    }

    # Actually filter (not just reorder) down to likely Enhanced Audit
    # matches, falling back to progressively broader nets so we still show
    # something sensible even on an LR version that names this type
    # differently.
    $candidates = @($types | Where-Object { [string]$_.name -match 'Enhanced' })
    if ($candidates.Count -eq 0) { $candidates = @($types | Where-Object { [string]$_.name -match 'Audit' }) }
    if ($candidates.Count -eq 0) { $candidates = $types }
    if ($candidates.Count -lt $types.Count) {
        Write-Status "Narrowed $($types.Count) UDLA log source types down to $($candidates.Count) likely match(es)." Dim
    }

    if ($candidates.Count -eq 1) {
        $lst = $candidates[0]
        Write-Status "Using log source type: $($lst.name) (id $($lst.id))" Success
    }
    else {
        $idx = Read-MenuChoice -Items $candidates -Prompt 'Select the UDLA log source type (look for "LREnhancedAudit")' -DisplayScript {
            param($it, $i) "$($it.name)  (id $($it.id))"
        }
        $lst = $candidates[$idx]
    }
    $script:Env.LogSourceTypeId   = $lst.id
    $script:Env.LogSourceTypeName = $lst.name

    # --- MPE Policy ------------------------------------------------------------
    $policy = Select-DiscoveredItem -What 'MPE Policy' -SuggestedFilter 'LogRhythm Default' -FetchScript {
        param($filter) (Get-LRMpePolicies -NameFilter $filter -MessageSourceTypeId $script:Env.LogSourceTypeId)
    }
    if (-not $policy) { return }
    $script:Env.MpePolicyId   = $policy.id
    $script:Env.MpePolicyName = $policy.name

    Write-Divider
    Write-Status 'Environment discovered:' Success
    Write-Host "    System Monitor : $($script:Env.SystemMonitorName)  (id $($script:Env.SystemMonitorId))" -ForegroundColor White
    Write-Host "    Host           : $($script:Env.HostName)  (id $($script:Env.HostId))" -ForegroundColor White
    Write-Host "    Entity         : $($script:Env.EntityName)  (id $($script:Env.EntityId))" -ForegroundColor White
    Write-Host "    Log Source Type: $($script:Env.LogSourceTypeName)  (id $($script:Env.LogSourceTypeId))" -ForegroundColor White
    Write-Host "    MPE Policy     : $($script:Env.MpePolicyName)  (id $($script:Env.MpePolicyId))" -ForegroundColor White
}

function Test-EnvironmentReady {
    foreach ($k in @('SystemMonitorId', 'HostId', 'EntityId', 'LogSourceTypeId', 'MpePolicyId')) {
        if (-not $script:Env[$k]) { return $false }
    }
    return $true
}

function Invoke-CreateAuditSources {
    Write-Divider
    Write-Status 'Create Enhanced Audit Log Source(s)' Title
    Write-Divider

    if (-not $script:Connected) {
        Write-Status 'Configure the connection first (main menu option 1).' Warn
        return
    }
    if (-not (Test-EnvironmentReady)) {
        Write-Status 'Run "Discover Environment" first (main menu option 2) so the wizard knows which System Monitor / Host / Entity / MPE Policy to use.' Warn
        return
    }

    $templates = Get-AuditTemplates
    Write-Status 'Checking for log sources that already exist on this System Monitor...' Info
    $existingNames = Get-LRExistingLogSourceNames -SystemMonitorId $script:Env.SystemMonitorId

    # Fixed naming convention - "LR Enhanced Audit - <template key>", where
    # the key matches the source XML template's file name (e.g. Alarm.xml
    # -> "LR Enhanced Audit - Alarm") for easy traceability back to it.
    $rows = foreach ($t in $templates) {
        $name = "LR Enhanced Audit - $($t.Key)"
        [pscustomobject]@{
            Template = $t
            Name     = $name
            Exists   = ($existingNames -contains $name)
        }
    }

    Write-Host ''
    Write-Status 'Select which Enhanced Audit sources to create:' Info
    $indexes = Read-MultiChoice -Items $rows -DisplayScript {
        param($r, $i)
        $flag = if ($r.Exists) { '  [already exists - will conflict]' } else { '' }
        "$($r.Template.Label.PadRight(28)) -> $($r.Name)$flag"
    }
    if ($indexes.Count -eq 0) {
        Write-Status 'Nothing selected.' Warn
        return
    }
    $selected = $indexes | ForEach-Object { $rows[$_] }

    $maxMsgCount = [int](Read-Line -Prompt 'Max message count per collection cycle' -Default '1000')

    Write-Host ''
    Write-Status 'About to create the following log source(s):' Info
    foreach ($r in $selected) {
        $tag = if ($r.Exists) { ' (WILL LIKELY CONFLICT - name already in use)' } else { '' }
        Write-Host "    - $($r.Name)$tag" -ForegroundColor $(if ($r.Exists) { 'Yellow' } else { 'White' })
    }
    Write-Host ''
    Write-Host "    Connection string : $script:DefaultConnectionString" -ForegroundColor DarkGray
    Write-Host "    System Monitor    : $($script:Env.SystemMonitorName)" -ForegroundColor DarkGray
    Write-Host "    Host / Entity     : $($script:Env.HostName) / $($script:Env.EntityName)" -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'Proceed?' -DefaultYes $true)) {
        Write-Status 'Cancelled.' Warn
        return
    }

    $results = @()
    foreach ($r in $selected) {
        Write-Host "[*] Creating '$($r.Name)'..." -ForegroundColor Cyan -NoNewline
        $res = New-AuditLogSource -Template $r.Template -Name $r.Name -ConnectionString $script:DefaultConnectionString -MaxMessageCount $maxMsgCount
        if ($res.Success) {
            Write-Host "  OK (id $($res.LogSourceId))" -ForegroundColor Green
        }
        else {
            Write-Host "  FAILED - $($res.Message)" -ForegroundColor Red
        }
        $results += $res
    }

    Write-Divider
    $ok = @($results | Where-Object Success).Count
    $bad = @($results | Where-Object { -not $_.Success }).Count
    Write-Status "Done: $ok created, $bad failed." $(if ($bad -eq 0) { 'Success' } else { 'Warn' })

    Export-SessionLog -Results $results
}

function Export-SessionLog {
    param([array]$Results)
    if (-not $Results -or $Results.Count -eq 0) { return }
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $file = Join-Path $script:LogDir "audit-onboard-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    try {
        $Results | Select-Object Template, Name, Success, LogSourceId, Message, TimestampUtc |
            Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
        Write-Status "Run log written to $file" Info
    }
    catch {
        Write-Status "Could not write run log to $file - $($_.Exception.Message)" Warn
    }
}

function Show-SessionLog {
    Write-Divider
    Write-Status 'This Session' Title
    Write-Divider
    if ($script:SessionLog.Count -eq 0) {
        Write-Status 'Nothing created yet this session.' Info
        return
    }
    foreach ($r in $script:SessionLog) {
        $mark   = if ($r.Success) { '[+]' } else { '[x]' }
        $colour = if ($r.Success) { 'Green' } else { 'Red' }
        $idPart = if ($r.LogSourceId) { "id $($r.LogSourceId)" } else { '-' }
        Write-Host ('  {0} {1,-26} {2,-6} {3,-45}' -f $mark, $r.Template, $idPart, $r.Name) -ForegroundColor $colour
        if (-not $r.Success) {
            Write-Host "        -> $($r.Message)" -ForegroundColor DarkRed
        }
    }
    Write-Host ''
    $ok  = @($script:SessionLog | Where-Object Success).Count
    $bad = @($script:SessionLog | Where-Object { -not $_.Success }).Count
    Write-Status "Total this session: $ok created, $bad failed." $(if ($bad -eq 0) { 'Success' } else { 'Warn' })
}
#endregion

# ============================================================================
#region  MAIN MENU
# ============================================================================
function Show-ConnectionStatusLine {
    if ($script:Connected) {
        Write-Host "Connected: " -ForegroundColor DarkGray -NoNewline
        Write-Host "$script:ApiBaseUrl" -ForegroundColor Green -NoNewline
        if (Test-EnvironmentReady) {
            Write-Host "   |   Environment: " -ForegroundColor DarkGray -NoNewline
            Write-Host "$($script:Env.HostName) / $($script:Env.EntityName)" -ForegroundColor Green
        }
        else {
            Write-Host "   |   Environment: " -ForegroundColor DarkGray -NoNewline
            Write-Host "not discovered yet" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Connected: " -ForegroundColor DarkGray -NoNewline
        Write-Host "no" -ForegroundColor Red
    }
    Write-Host ''
}

function Show-MainMenu {
    Show-ConnectionStatusLine
    $options = @(
        '1) Configure Connection'
        '2) Discover Environment (System Monitor / Host / Entity / MPE Policy)'
        '3) Create Enhanced Audit Log Source(s)'
        '4) View This Session''s Results'
        '5) Exit'
    )
    $options | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    Write-Host ''
    Write-Host '[?] Choose an option: ' -ForegroundColor White -NoNewline
    (Read-Host).Trim()
}

function Start-Wizard {
    Show-Banner

    if ($BaseUrl) {
        if (-not $ApiToken -and $env:apikey) {
            $ApiToken = $env:apikey
            Write-Status 'Using API token from the $env:apikey environment variable.' Info
        }

        if ($ApiToken) {
            $script:ApiBaseUrl = $BaseUrl
            $script:PlainToken = $ApiToken
            $script:SkipCert   = [bool]$SkipCertificateCheck
            Initialize-TlsSettings -SkipCertificateCheck:$script:SkipCert
            $script:Connected  = $true
            $test = Test-LRApiConnection
            if ($test.Success) {
                Write-Status "Connected to $BaseUrl using supplied credentials." Success
            }
            else {
                Write-Status "Supplied -BaseUrl/token did not authenticate: $($test.Detail)" Warn
                Write-Status 'Use option 1 to reconfigure.' Dim
                $script:Connected = $false
            }
        }
    }

    while ($true) {
        Write-Host ''
        Write-Divider
        switch (Show-MainMenu) {
            '1' { Invoke-ConfigureConnection }
            '2' { Invoke-DiscoverEnvironment }
            '3' { Invoke-CreateAuditSources }
            '4' { Show-SessionLog }
            '5' { Write-Status 'Goodbye.' Success; return }
            default { Write-Status 'Choose 1-5.' Warn }
        }
    }
}
#endregion

# ============================================================================
#region  ENTRY POINT
# ============================================================================
try {
    Start-Wizard
}
catch {
    Write-Host ''
    Write-Status "Unexpected error: $($_.Exception.Message)" Error
    Write-Status 'Re-run with -Verbose for more detail, or check the run log directory for partial results.' Dim
    exit 1
}
#endregion
