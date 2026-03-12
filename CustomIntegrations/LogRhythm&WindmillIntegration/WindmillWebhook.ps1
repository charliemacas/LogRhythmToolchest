param(
    [Parameter(Mandatory = $true)]
    [string]$AlarmId,

    [Parameter(Mandatory = $true)]
    [string]$WebhookUrl,

    [Parameter(Mandatory = $false)]
    [string]$LrBaseUrl = "https://172.17.5.11:8501",

    [Parameter(Mandatory = $false)]
    [string]$BearerToken = "",

    [Parameter(Mandatory = $false)]
    [string]$WindmillBearerToken = ""
)

$ErrorActionPreference = "Stop"

# =========================
# Logging
# =========================
$LogPath = "C:\ProgramData\LogRhythm\SmartResponse\Send-AIEAlarmWebhook.log"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    try {
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "[$timestamp] [$Level] $Message"
        Write-Host $line
        Add-Content -Path $LogPath -Value $line
    }
    catch { Write-Host "Logging failure: $($_.Exception.Message)" }
}

# =========================
# TLS
# =========================
function Enable-SecureTls {
    # TLS 1.2 enforced. LogRhythm API calls use -SkipCertificateCheck per call
    # to handle the self-signed cert (matches LR's own Case Management SRP approach).
    # Outbound calls to Windmill retain full certificate validation.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "TLS 1.2 enforced."
}

# =========================
# Helpers
# =========================
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
    param(
        [string]$LrBaseUrl,
        [string]$AlarmId,
        [hashtable]$Headers
    )

    # --- Call 1: Alarm details ---
    $alarmUri = "$LrBaseUrl/lr-alarm-api/alarms/$AlarmId"
    Write-Log "Querying Alarm API: $alarmUri"
    $alarmResponse = Invoke-RestMethod -Uri $alarmUri -Headers $Headers -Method GET -SkipCertificateCheck

    if (-not $alarmResponse) { throw "Alarm API returned empty response." }
    if (-not $alarmResponse.alarmDetails) {
        throw "Response missing 'alarmDetails': $($alarmResponse | ConvertTo-Json -Depth 4 -Compress)"
    }
    $alarmDetails = $alarmResponse.alarmDetails

    Write-Host "=== ALARMDETAILS ==="
    Write-Host ($alarmDetails | ConvertTo-Json -Depth 10)

    # --- Call 2: Alarm summary (group-by fields: IPs, hosts, users) ---
    $summaryUri = "$LrBaseUrl/lr-alarm-api/alarms/$AlarmId/summary"
    Write-Log "Querying Alarm Summary API: $summaryUri"

    $alarmSummaryData  = $null
    $alarmEventSummary = $null

    try {
        $summaryResponse = Invoke-RestMethod -Uri $summaryUri -Headers $Headers -Method GET -SkipCertificateCheck
        if ($summaryResponse -and $summaryResponse.alarmSummaryDetails) {
            $alarmSummaryData  = $summaryResponse.alarmSummaryDetails
            $alarmEventSummary = $alarmSummaryData.alarmEventSummary
            Write-Host "=== ALARM SUMMARY ==="
            Write-Host ($alarmSummaryData | ConvertTo-Json -Depth 10)
            Write-Log "Alarm summary retrieved."
        }
        else {
            Write-Log "Summary response missing 'alarmSummaryDetails' - continuing without." "WARN"
        }
    }
    catch {
        Write-Log "Summary API call failed (non-fatal): $($_.Exception.Message)" "WARN"
    }

    # --- Extract and deduplicate group-by fields ---
    $originHosts   = @()
    $impactedHosts = @()
    $originUsers   = @()
    $impactedUsers = @()
    $originIPs     = @()
    $impactedIPs   = @()
    $commonEvents  = @()

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

# =========================
# Main
# =========================
try {
    Write-Host "=== SCRIPT MARKER: WindmillWebhook.ps1 ==="
    Write-Log "Starting SmartResponse for AlarmId=$AlarmId"
    Write-Log "WebhookUrl=$WebhookUrl"
    Write-Log "LrBaseUrl=$LrBaseUrl"

    Enable-SecureTls

    if ([string]::IsNullOrWhiteSpace($BearerToken)) { $BearerToken = $env:LR_BEARER }
    if ([string]::IsNullOrWhiteSpace($BearerToken)) { throw "No bearer token supplied and LR_BEARER is empty." }
    Write-Log "LR Bearer token present: True"

    if ([string]::IsNullOrWhiteSpace($WindmillBearerToken)) { throw "No Windmill bearer token supplied." }
    Write-Log "Windmill bearer token present: True"

    $headers = @{ Authorization = "Bearer $BearerToken"; Accept = "application/json" }

    $data = Get-AlarmData -LrBaseUrl $LrBaseUrl -AlarmId $AlarmId -Headers $headers

    $alarmDetails = $data.alarmDetails
    $alarmRuleName = Get-FirstNonEmptyValue @($alarmDetails.alarmRuleName, $alarmDetails.ruleName, $alarmDetails.name)
    if (-not $alarmRuleName) { $alarmRuleName = "Unknown Rule" }

    $entityName   = Get-FirstNonEmptyValue @($alarmDetails.entityName);   if (-not $entityName)   { $entityName   = "Unknown Entity" }
    $alarmDate    = Get-FirstNonEmptyValue @($alarmDetails.alarmDate, $alarmDetails.dateInserted); if (-not $alarmDate)    { $alarmDate    = (Get-Date).ToString("o") }
    $alarmStatus  = Get-FirstNonEmptyValue @($alarmDetails.alarmStatusName, $alarmDetails.alarmStatus); if (-not $alarmStatus)  { $alarmStatus  = "Unknown" }
    $eventCount   = Get-FirstNonEmptyValue @($alarmDetails.eventCount);   if (-not $eventCount)   { $eventCount   = "0" }
    $rbpMax       = Get-FirstNonEmptyValue @($alarmDetails.rbpMax);       if (-not $rbpMax)       { $rbpMax       = "Unknown" }
    $severity     = Get-FirstNonEmptyValue @($alarmDetails.priority, $alarmDetails.severity, $alarmDetails.alarmSeverity, $alarmDetails.rbpMax)
    if (-not $severity) { $severity = "Unknown" }

    $message = "AIE rule '$alarmRuleName' fired on entity '$entityName' (AlarmID=$AlarmId, EventCount=$eventCount, Status=$alarmStatus)"

    $payloadObject = @{
        vendor         = "LogRhythm"
        product        = "AIE"
        event_type     = "alarm"
        alarm_id       = $AlarmId
        alarm_name     = $alarmRuleName
        entity_name    = $entityName
        alarm_time     = $alarmDate
        alarm_status   = $alarmStatus
        event_count    = $eventCount
        severity       = $severity
        rbp_max        = $rbpMax
        message        = $message
        # Promoted group-by fields — directly addressable by Windmill subflow steps
        origin_hosts   = $data.originHosts
        impacted_hosts = $data.impactedHosts
        origin_users   = $data.originUsers
        impacted_users = $data.impactedUsers
        origin_ips     = $data.originIPs
        impacted_ips   = $data.impactedIPs
        common_events  = $data.commonEvents
        smartresponse  = @{
            script_name = "WindmillWebhook.ps1"
            version     = "1.2"
            host        = $env:COMPUTERNAME
            executed_at = (Get-Date).ToString("o")
        }
        raw_alarm      = $alarmDetails
        alarm_summary  = $data.alarmSummary
    }

    $payloadJson = $payloadObject | ConvertTo-Json -Depth 15

    Write-Host ""
    Write-Host "=== AIE ALARM WEBHOOK SUMMARY ==="
    Write-Host "Rule:            $alarmRuleName"
    Write-Host "Entity:          $entityName"
    Write-Host "AlarmID:         $AlarmId"
    Write-Host "Alarm Time:      $alarmDate"
    Write-Host "Status:          $alarmStatus"
    Write-Host "Event Count:     $eventCount"
    Write-Host "Severity:        $severity"
    Write-Host "Origin Hosts:    $($data.originHosts   -join ', ')"
    Write-Host "Impacted Hosts:  $($data.impactedHosts -join ', ')"
    Write-Host "Origin Users:    $($data.originUsers   -join ', ')"
    Write-Host "Impacted Users:  $($data.impactedUsers -join ', ')"
    Write-Host "Origin IPs:      $($data.originIPs     -join ', ')"
    Write-Host "Impacted IPs:    $($data.impactedIPs   -join ', ')"
    Write-Host "Webhook URL:     $WebhookUrl"
    Write-Host "================================="
    Write-Host ""
    Write-Host "=== WEBHOOK PAYLOAD ==="
    Write-Host $payloadJson
    Write-Host ""

    $webhookHeaders = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $WindmillBearerToken"
    }

    Write-Log "Posting webhook for alarm '$alarmRuleName'"
    $webhookResponse = Invoke-RestMethod -Uri $WebhookUrl -Method POST -Body $payloadJson -Headers $webhookHeaders

    Write-Host "=== WEBHOOK RESPONSE ==="
    if ($null -ne $webhookResponse) {
        try {
            Write-Host ($webhookResponse | ConvertTo-Json -Depth 10)
            Write-Log "Webhook POST successful. Response=$($webhookResponse | ConvertTo-Json -Depth 6 -Compress)"
        }
        catch {
            Write-Host $webhookResponse.ToString()
            Write-Log "Webhook POST successful. Response=$($webhookResponse.ToString())"
        }
    }
    else {
        Write-Host "Webhook returned no content."
        Write-Log "Webhook POST successful. No response body."
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
