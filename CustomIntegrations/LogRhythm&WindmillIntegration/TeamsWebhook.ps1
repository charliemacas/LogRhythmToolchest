param(
    [Parameter(Mandatory = $true)]
    [string]$AlarmId,

    [Parameter(Mandatory = $true)]
    [string]$WebhookUrl,

    [Parameter(Mandatory = $false)]
    [string]$LrBaseUrl = "https://172.17.5.11:8501",

    [Parameter(Mandatory = $false)]
    [string]$BearerToken = ""
)

$ErrorActionPreference = "Stop"

$LogPath = "C:\ProgramData\LogRhythm\SmartResponse\Send-AIEAlarmWebhook.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    try {
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
        Write-Host $line
        Add-Content -Path $LogPath -Value $line
    }
    catch { Write-Host "Logging failure: $($_.Exception.Message)" }
}

function Enable-SecureTls {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "TLS 1.2 enforced."
}

function Get-FirstNonEmptyValue {
    param([AllowNull()][object[]]$Values)
    if ($null -eq $Values) { return $null }
    foreach ($value in $Values) {
        if ($null -ne $value) {
            $s = $value.ToString().Trim()
            if ($s.Length -gt 0) { return $s }
        }
    }
    return $null
}

function Get-AlarmData {
    param([string]$LrBaseUrl, [string]$AlarmId, [hashtable]$Headers)

    $alarmUri = "$LrBaseUrl/lr-alarm-api/alarms/$AlarmId"
    Write-Log "Querying Alarm API: $alarmUri"
    $alarmResponse = Invoke-RestMethod -Uri $alarmUri -Headers $Headers -Method GET -SkipCertificateCheck

    if (-not $alarmResponse) { throw "Alarm API returned empty response." }
    if (-not $alarmResponse.alarmDetails) {
        throw "Response missing 'alarmDetails': $($alarmResponse | ConvertTo-Json -Depth 4 -Compress)"
    }
    $alarmDetails = $alarmResponse.alarmDetails

    $alarmSummaryData  = $null
    $alarmEventSummary = $null

    try {
        $summaryUri = "$LrBaseUrl/lr-alarm-api/alarms/$AlarmId/summary"
        Write-Log "Querying Alarm Summary API: $summaryUri"
        $summaryResponse = Invoke-RestMethod -Uri $summaryUri -Headers $Headers -Method GET -SkipCertificateCheck
        if ($summaryResponse -and $summaryResponse.alarmSummaryDetails) {
            $alarmSummaryData  = $summaryResponse.alarmSummaryDetails
            $alarmEventSummary = $alarmSummaryData.alarmEventSummary
            Write-Log "Alarm summary retrieved."
        }
        else { Write-Log "Summary missing 'alarmSummaryDetails' - continuing without." "WARN" }
    }
    catch { Write-Log "Summary API call failed (non-fatal): $($_.Exception.Message)" "WARN" }

    $originHosts = @(); $impactedHosts = @(); $originUsers = @()
    $impactedUsers = @(); $originIPs = @(); $impactedIPs = @(); $commonEvents = @()

    if ($alarmEventSummary) {
        foreach ($ev in $alarmEventSummary) {
            if ($ev.originHost      -and $ev.originHost      -ne "") { $originHosts   += $ev.originHost }
            if ($ev.impactedHost    -and $ev.impactedHost    -ne "") { $impactedHosts += $ev.impactedHost }
            if ($ev.originUser      -and $ev.originUser      -ne "") { $originUsers   += $ev.originUser }
            if ($ev.impactedUser    -and $ev.impactedUser    -ne "") { $impactedUsers += $ev.impactedUser }
            if ($ev.originIp        -and $ev.originIp        -ne "") { $originIPs     += $ev.originIp }
            if ($ev.impactedIp      -and $ev.impactedIp      -ne "") { $impactedIPs   += $ev.impactedIp }
            if ($ev.commonEventName -and $ev.commonEventName -ne "") { $commonEvents  += $ev.commonEventName }
        }
        $originHosts   = @($originHosts   | Select-Object -Unique)
        $impactedHosts = @($impactedHosts | Select-Object -Unique)
        $originUsers   = @($originUsers   | Select-Object -Unique)
        $impactedUsers = @($impactedUsers | Select-Object -Unique)
        $originIPs     = @($originIPs     | Select-Object -Unique)
        $impactedIPs   = @($impactedIPs   | Select-Object -Unique)
        $commonEvents  = @($commonEvents  | Select-Object -Unique)
    }

    return @{
        alarmDetails   = $alarmDetails
        alarmSummary   = $alarmSummaryData
        originHosts    = $originHosts
        impactedHosts  = $impactedHosts
        originUsers    = $originUsers
        impactedUsers  = $impactedUsers
        originIPs      = $originIPs
        impactedIPs    = $impactedIPs
        commonEvents   = $commonEvents
    }
}

try {
    Write-Host "=== SCRIPT MARKER: TeamsWebhook.ps1 ==="
    Write-Log "Starting SmartResponse for AlarmId=$AlarmId"
    Write-Log "WebhookUrl=$WebhookUrl"
    Write-Log "LrBaseUrl=$LrBaseUrl"

    Enable-SecureTls

    if ([string]::IsNullOrWhiteSpace($BearerToken)) { $BearerToken = $env:LR_BEARER }
    if ([string]::IsNullOrWhiteSpace($BearerToken)) { throw "No bearer token supplied and LR_BEARER is empty." }
    Write-Log "LR Bearer token present: True"

    $headers = @{ Authorization = "Bearer $BearerToken"; Accept = "application/json" }

    $data = Get-AlarmData -LrBaseUrl $LrBaseUrl -AlarmId $AlarmId -Headers $headers

    $alarmDetails  = $data.alarmDetails
    $alarmRuleName = Get-FirstNonEmptyValue @($alarmDetails.alarmRuleName, $alarmDetails.ruleName, $alarmDetails.name)
    if (-not $alarmRuleName) { $alarmRuleName = "Unknown Rule" }

    $alarmDate   = Get-FirstNonEmptyValue @($alarmDetails.alarmDate, $alarmDetails.dateInserted); if (-not $alarmDate)   { $alarmDate   = (Get-Date).ToString("o") }
    $alarmStatus = Get-FirstNonEmptyValue @($alarmDetails.alarmStatusName, $alarmDetails.alarmStatus); if (-not $alarmStatus) { $alarmStatus = "Unknown" }
    $eventCount  = Get-FirstNonEmptyValue @($alarmDetails.eventCount); if (-not $eventCount) { $eventCount = "0" }
    $severity    = Get-FirstNonEmptyValue @($alarmDetails.priority, $alarmDetails.severity, $alarmDetails.alarmSeverity, $alarmDetails.rbpMax)
    if (-not $severity) { $severity = "Unknown" }

    # Build FactSet rows — only include fields that have values
    $facts = @(
        @{ title = "Alarm ID";      value = "$AlarmId" },
        @{ title = "Severity (RBP)"; value = "$severity" },
        @{ title = "Status";        value = "$alarmStatus" },
        @{ title = "Event Count";   value = "$eventCount" },
        @{ title = "Alarm Time";    value = "$alarmDate" }
    )

    if ($data.originIPs     -and $data.originIPs.Count -gt 0)     { $facts += @{ title = "Origin IPs";      value = ($data.originIPs     -join ', ') } }
    if ($data.impactedIPs   -and $data.impactedIPs.Count -gt 0)   { $facts += @{ title = "Impacted IPs";    value = ($data.impactedIPs   -join ', ') } }
    if ($data.originHosts   -and $data.originHosts.Count -gt 0)   { $facts += @{ title = "Origin Hosts";    value = ($data.originHosts   -join ', ') } }
    if ($data.impactedHosts -and $data.impactedHosts.Count -gt 0) { $facts += @{ title = "Impacted Hosts";  value = ($data.impactedHosts -join ', ') } }
    if ($data.originUsers   -and $data.originUsers.Count -gt 0)   { $facts += @{ title = "Origin Users";    value = ($data.originUsers   -join ', ') } }
    if ($data.impactedUsers -and $data.impactedUsers.Count -gt 0) { $facts += @{ title = "Impacted Users";  value = ($data.impactedUsers -join ', ') } }

    # Teams Adaptive Card via Workflow webhook
    $payloadObject = @{
        type        = "message"
        attachments = @(
            @{
                contentType = "application/vnd.microsoft.card.adaptive"
                contentUrl  = $null
                content     = @{
                    '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                    type      = "AdaptiveCard"
                    version   = "1.4"
                    body      = @(
                        @{
                            type   = "TextBlock"
                            size   = "Medium"
                            weight = "Bolder"
                            text   = "LogRhythm AIE Alarm Triggered"
                            wrap   = $true
                        },
                        @{
                            type   = "TextBlock"
                            text   = "$alarmRuleName"
                            wrap   = $true
                            color  = "Warning"
                        },
                        @{
                            type  = "FactSet"
                            facts = $facts
                        }
                    )
                }
            }
        )
    }

    $payloadJson = $payloadObject | ConvertTo-Json -Depth 15 -Compress

    Write-Log "Preparing Teams payload for alarm '$alarmRuleName'"
    Write-Host ""
    Write-Host "=== TEAMS PAYLOAD ==="
    Write-Host $payloadJson
    Write-Host ""

    Write-Log "Posting Teams webhook for alarm '$alarmRuleName'"
    $webhookResponse = Invoke-RestMethod -Uri $WebhookUrl -Method POST -Body $payloadJson -ContentType "application/json"

    Write-Host "=== WEBHOOK RESPONSE ==="
    if ($null -ne $webhookResponse) {
        Write-Host $webhookResponse.ToString()
        Write-Log "Teams webhook POST successful."
    }
    else {
        Write-Host "No response body."
        Write-Log "Teams webhook POST successful. No response body."
    }

    Write-Host ""
    Write-Host "=== SMARTRESPONSE COMPLETED SUCCESSFULLY ==="
    exit 0
}
catch {
    Write-Host ""
    Write-Host "=== SMARTRESPONSE FAILED ==="
    Write-Host $_.Exception.Message
    Write-Log "SmartResponse failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
