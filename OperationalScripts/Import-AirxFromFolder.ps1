<#
.SYNOPSIS
  Import all .airx files from a local folder into LogRhythm AIE.

.EXAMPLE
  $env:LR_BEARER = "PASTE_TOKEN"
  .\Import-AirxFromFolder.ps1 `
    -SourceDir "C:\ProgramData\LogRhythm\AIE\Imports" `
    -LogRhythmBaseUrl "https://172.10.2.65:8501" `
    -BearerToken $env:LR_BEARER `
    -ListSyncSetting "DoNotImportListContents" `
    -IgnoreTlsErrors `
    -Recurse `
    -WriteCsvSummary
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$SourceDir,

  [Parameter(Mandatory)]
  [string]$LogRhythmBaseUrl,

  [Parameter(Mandatory)]
  [string]$BearerToken,

  [ValidateSet("DoNotImportListContents","ImportListContents","MergeListContents")]
  [string]$ListSyncSetting = "DoNotImportListContents",

  # Known-good in your environment
  [string]$AieImportPath = "/lr-aie-api/aie/rules/import",

  [switch]$Recurse,
  [switch]$IgnoreTlsErrors,
  [switch]$WriteCsvSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Save original TLS globals so we can always restore them
$script:OrigCallback  = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$script:OrigProtocols = [System.Net.ServicePointManager]::SecurityProtocol

function Set-Tls12Safely {
  try {
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::SecurityProtocol = ([System.Net.ServicePointManager]::SecurityProtocol -bor $tls12)
  } catch {}
}

function Get-UriParts {
  param([Parameter(Mandatory)][string]$BaseUrl)
  $u = [Uri]($BaseUrl.TrimEnd("/") + "/")
  $port = if ($u.IsDefaultPort) { if ($u.Scheme -eq "https") { 443 } else { 80 } } else { $u.Port }
  [pscustomobject]@{ Host=$u.Host; Port=$port }
}

function Test-ApiConnectivity {
  param([Parameter(Mandatory)][string]$BaseUrl)
  $p = Get-UriParts -BaseUrl $BaseUrl
  Write-Host "Preflight: testing TCP connectivity to $($p.Host):$($p.Port) ..."
  $t = Test-NetConnection -ComputerName $p.Host -Port $p.Port
  if (-not $t.TcpTestSucceeded) {
    throw "Cannot reach $($p.Host):$($p.Port) (TcpTestSucceeded=False). Check host/port/firewall."
  }
  Write-Host "OK: TCP connectivity to $($p.Host):$($p.Port)"
}

function Use-LogRhythmTls {
  param(
    [Parameter(Mandatory)][string]$LogRhythmHost,
    [switch]$Bypass
  )

  Set-Tls12Safely

  if (-not $Bypass) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    return
  }

  # Bypass only for the LogRhythm host
  $old = $script:OrigCallback
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $cert, $chain, $errors)

    try {
      if ($sender -and $sender.RequestUri -and $sender.RequestUri.Host -eq $LogRhythmHost) {
        return $true
      }
    } catch {}

    if ($old) { return $old.Invoke($sender, $cert, $chain, $errors) }
    return ($errors -eq [System.Net.Security.SslPolicyErrors]::None)
  }
}

function Import-AirxToLogRhythm {
  param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [Parameter(Mandatory)][string]$ImportPath,
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$AirxLocalPath,
    [Parameter(Mandatory)][string]$ListSyncSetting,
    [Parameter(Mandatory)][string]$LogRhythmHost,
    [switch]$IgnoreTlsErrors
  )

  Use-LogRhythmTls -LogRhythmHost $LogRhythmHost -Bypass:$IgnoreTlsErrors

  $endpoint = ($BaseUrl.TrimEnd("/")) + "/" + ($ImportPath.TrimStart("/"))

  $headers = @{
    "accept"        = "application/json"
    "content-type"  = "application/*+json"
    "authorization" = "Bearer $Token"
  }

  $body = @{
    file            = $AirxLocalPath
    listSyncSetting = $ListSyncSetting
  } | ConvertTo-Json -Depth 5

  Write-Host "IMPORTING: $AirxLocalPath"
  $r = Invoke-WebRequest -Method POST -Uri $endpoint -Headers $headers -Body $body -UseBasicParsing
  return $r
}

try {
  if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "SourceDir does not exist: $SourceDir"
  }

  if ($IgnoreTlsErrors) {
    Write-Warning "TLS bypass is enabled for LogRhythm host only (-IgnoreTlsErrors)."
  }

  Test-ApiConnectivity -BaseUrl $LogRhythmBaseUrl
  $lrParts = Get-UriParts -BaseUrl $LogRhythmBaseUrl

  $gciParams = @{
    Path   = $SourceDir
    Filter = "*.airx"
    File   = $true
  }
  if ($Recurse) { $gciParams.Recurse = $true }

  $files = Get-ChildItem @gciParams | Sort-Object FullName
  if (-not $files -or $files.Count -eq 0) {
    Write-Warning "No .airx files found in: $SourceDir"
    exit 1
  }

  Write-Host "Found $($files.Count) AIRX file(s) in: $SourceDir"
  Write-Host "LogRhythmBaseUrl: $LogRhythmBaseUrl"
  Write-Host "AIE Import Path: $AieImportPath"
  Write-Host "ListSyncSetting: $ListSyncSetting"

  $results = @()

  foreach ($f in $files) {
    try {
      $resp = Import-AirxToLogRhythm `
        -BaseUrl $LogRhythmBaseUrl `
        -ImportPath $AieImportPath `
        -Token $BearerToken `
        -AirxLocalPath $f.FullName `
        -ListSyncSetting $ListSyncSetting `
        -LogRhythmHost $lrParts.Host `
        -IgnoreTlsErrors:$IgnoreTlsErrors

      $results += [pscustomobject]@{
        File   = $f.Name
        Status = "Success"
        Http   = $resp.StatusCode
        Path   = $f.FullName
      }
    }
    catch {
      $status = $null
      try { if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
      Write-Warning "Failed: $($f.Name) -> $($_.Exception.Message)"
      $results += [pscustomobject]@{
        File   = $f.Name
        Status = "Failed"
        Http   = $status
        Path   = $f.FullName
      }
    }
  }

  Write-Host "`nSUMMARY:"
  $results | Format-Table -AutoSize

  if ($WriteCsvSummary) {
    $csvPath = Join-Path $SourceDir ("airx_import_results_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $results | Export-Csv -NoTypeInformation -Path $csvPath
    Write-Host "CSV summary written to: $csvPath"
  }
}
finally {
  # restore TLS globals
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $script:OrigCallback
  [System.Net.ServicePointManager]::SecurityProtocol = $script:OrigProtocols
}
