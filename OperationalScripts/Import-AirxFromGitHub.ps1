<#
.SYNOPSIS
  Downloads .airx files from a public GitHub folder (via GitHub Contents API URL)
  and imports them into LogRhythm AIE via the correct endpoint:
    /lr-aie-api/aie/rules/import

.NOTES
  - GitHub URL you pass MUST be the "contents" API URL, e.g.:
      https://api.github.com/repos/<owner>/<repo>/contents/<path>?ref=<branch>

  - LogRhythm import endpoint expects a FILE PATH (it does NOT upload file bytes).
    Therefore, -DownloadDir MUST be a path the AIE service can read.
    Best: run this on/near the AIE server and use a service-readable folder.

  - If LogRhythm uses a self-signed/untrusted cert, use -IgnoreTlsErrors.
    This script ONLY bypasses TLS validation for the LogRhythm host (not GitHub).

.EXAMPLE
  $env:LR_BEARER = "eyJhbGciOi..."
  .\Import-AirxFromGitHub.ps1 `
    -GitHubContentsApiUrl "https://api.github.com/repos/charliemacas/LogRhythmToolchest/contents/AIERules/REST-Test?ref=main" `
    -LogRhythmBaseUrl "https://172.17.5.11:8501" `
    -BearerToken $env:LR_BEARER `
    -DownloadDir "C:\ProgramData\LogRhythm\AIE\Imports" `
    -ListSyncSetting "DoNotImportListContents" `
    -IgnoreTlsErrors `
    -WriteCsvSummary
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$GitHubContentsApiUrl,

  [Parameter(Mandatory)]
  [string]$LogRhythmBaseUrl,

  [Parameter(Mandatory)]
  [string]$BearerToken,

  [Parameter(Mandatory)]
  [string]$DownloadDir,

  [ValidateSet("DoNotImportListContents","ImportListContents","MergeListContents")]
  [string]$ListSyncSetting = "DoNotImportListContents",

  # Override if needed in future (you discovered this is the right one for your env)
  [string]$AieImportPath = "/lr-aie-api/aie/rules/import",

  [switch]$SkipExisting,
  [switch]$WhatIf,

  # LAB/TRUSTED ONLY: bypass SSL cert validation for LogRhythm host
  [switch]$IgnoreTlsErrors,

  [switch]$WriteCsvSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Save original TLS globals so we can always restore ---
$script:OrigCallback  = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$script:OrigProtocols = [System.Net.ServicePointManager]::SecurityProtocol

function Set-Tls12Safely {
  try {
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::SecurityProtocol = ([System.Net.ServicePointManager]::SecurityProtocol -bor $tls12)
  } catch {}
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
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

function Use-GitHubTlsDefaults {
  # GitHub: always use system defaults for cert validation
  Set-Tls12Safely
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
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

  # Bypass only for the LogRhythm host; allow normal behaviour for everything else.
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

function Get-GitHubFolderContentsFromApiUrl {
  param([Parameter(Mandatory)][string]$ApiUrl)

  Use-GitHubTlsDefaults

  $headers = @{
    "User-Agent" = "airx-import-script"
    "Accept"     = "application/vnd.github+json"
  }

  Write-Host "GitHub contents API -> $ApiUrl"
  $resp = Invoke-RestMethod -Method GET -Uri $ApiUrl -Headers $headers

  if ($null -eq $resp) { return @() }
  if ($resp -is [System.Collections.IDictionary]) { return @($resp) }
  return @($resp)
}

function Download-File {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutFile,
    [switch]$SkipExisting
  )

  if ($SkipExisting -and (Test-Path -LiteralPath $OutFile)) {
    Write-Host "SKIP (exists): $OutFile"
    return
  }

  Ensure-Directory -Path (Split-Path -Parent $OutFile)

  Use-GitHubTlsDefaults

  Write-Host "DOWNLOADING: $OutFile"
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing | Out-Null
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
  # Invoke-RestMethod is fine; if LogRhythm returns no JSON, it may throw. Using Invoke-WebRequest gives status.
  $r = Invoke-WebRequest -Method POST -Uri $endpoint -Headers $headers -Body $body -UseBasicParsing
  return $r
}

# ---------------- MAIN ----------------
try {
  if ($IgnoreTlsErrors) {
    Write-Warning "TLS bypass is enabled for LogRhythm host only (-IgnoreTlsErrors)."
  }

  Ensure-Directory -Path $DownloadDir
  Test-ApiConnectivity -BaseUrl $LogRhythmBaseUrl

  $lrParts = Get-UriParts -BaseUrl $LogRhythmBaseUrl

  $items = Get-GitHubFolderContentsFromApiUrl -ApiUrl $GitHubContentsApiUrl
  $airx = $items | Where-Object { $_.type -eq "file" -and $_.name -match '\.airx$' -and $_.download_url }

  if (-not $airx -or $airx.Count -eq 0) {
    Write-Warning "No .airx files found at the provided GitHub contents API URL."
    exit 1
  }

  Write-Host "Found $($airx.Count) AIRX file(s)."
  Write-Host "DownloadDir: $DownloadDir"
  Write-Host "LogRhythmBaseUrl: $LogRhythmBaseUrl"
  Write-Host "AIE Import Path: $AieImportPath"
  Write-Host "ListSyncSetting: $ListSyncSetting"
  if ($WhatIf) { Write-Warning "WhatIf is ON: will NOT call LogRhythm import endpoint." }

  $results = @()

  foreach ($f in $airx) {
    $localPath = Join-Path $DownloadDir $f.name

    try {
      Download-File -Url $f.download_url -OutFile $localPath -SkipExisting:$SkipExisting

      if ($WhatIf) {
        Write-Host "WHATIF: Would import '$localPath'"
        $results += [pscustomobject]@{ File=$f.name; Status="WhatIf"; Path=$localPath; Http=$null; Detail="" }
        continue
      }

      $resp = Import-AirxToLogRhythm `
        -BaseUrl $LogRhythmBaseUrl `
        -ImportPath $AieImportPath `
        -Token $BearerToken `
        -AirxLocalPath $localPath `
        -ListSyncSetting $ListSyncSetting `
        -LogRhythmHost $lrParts.Host `
        -IgnoreTlsErrors:$IgnoreTlsErrors

      $results += [pscustomobject]@{
        File   = $f.name
        Status = "Success"
        Path   = $localPath
        Http   = $resp.StatusCode
        Detail = $resp.StatusDescription
      }
    }
    catch {
      $status = $null
      try { if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
      $results += [pscustomobject]@{
        File   = $f.name
        Status = "Failed"
        Path   = $localPath
        Http   = $status
        Detail = $_.Exception.Message
      }
      Write-Warning "Failed: $($f.name) -> $($_.Exception.Message)"
    }
  }

  Write-Host "`nSUMMARY:"
  $results | Select-Object File, Status, Http, Path | Format-Table -AutoSize

  if ($WriteCsvSummary) {
    $csvPath = Join-Path $DownloadDir ("airx_import_results_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $results | Export-Csv -NoTypeInformation -Path $csvPath
    Write-Host "CSV summary written to: $csvPath"
  }
}
finally {
  # ALWAYS restore original TLS settings
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $script:OrigCallback
  [System.Net.ServicePointManager]::SecurityProtocol = $script:OrigProtocols
}
