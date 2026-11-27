<#
.SYNOPSIS
    End-to-end test of Build-EchoCoverage.ps1 against the mock LogRhythm + Echo servers.

.DESCRIPTION
    Start the mocks first (fresh state each time), for example:

        python3 Tests/MockServers/mock_lr_echo.py --cert cert.pem --key key.pem --lr-port 18501 --echo-port 13333

    then run:

        .\Tests\Test-EchoCoverage.ps1 -LrApiBaseUrl https://127.0.0.1:18501 -EchoBaseUrl https://127.0.0.1:13333

    Exit code 0 = all passed. Nothing outside a temp folder is written.
#>
[CmdletBinding()]
param(
    [string]$LrApiBaseUrl = 'https://127.0.0.1:18501',
    [string]$EchoBaseUrl = 'https://127.0.0.1:13333',
    [switch]$KeepFiles
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$S = Join-Path $root 'Build-EchoCoverage.ps1'
$Llx = Join-Path $root 'LLX-Tool.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('echocov-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $work | Out-Null
$results = New-Object System.Collections.Generic.List[object]
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add([pscustomobject]@{ Result = 'PASS'; Test = $Name; Detail = '' }) }
    catch { $results.Add([pscustomobject]@{ Result = 'FAIL'; Test = $Name; Detail = $_.Exception.Message }) }
}
function Assert($c, [string]$m) { if (-not $c) { throw $m } }
function Get-Report($f) { $h = @{}; Import-Csv (Join-Path $f 'coverage-report.csv') | ForEach-Object { $h[$_.RuleID] = $_ }; $h }
function Get-MockState {
    if ($PSVersionTable.PSVersion.Major -ge 7) { return Invoke-RestMethod -Uri "$EchoBaseUrl/mock/state" -SkipCertificateCheck }
    # Windows PowerShell 5.1 has no -SkipCertificateCheck; the mock uses a throwaway self-signed certificate
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $prev = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    try { return Invoke-RestMethod -Uri "$EchoBaseUrl/mock/state" }
    finally { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prev }
}

$env:LR_API_TOKEN = 'testtoken'
$cred = New-Object pscredential('admin', (ConvertTo-SecureString 'password' -AsPlainText -Force))
@'
AIERuleID,Name
1001,AIE: Brute Force Login
1002,AIE: Malware Then Outbound
1003,AIE: Partial Logs Rule
1004,AIE: No Drilldown Rule
1005,AIE: Echo Reject Rule
1006,AIE: Noisy Rule
1007,AIE: Old Rule
1008,AIE: Never Fired Rule
1009,Brute Force Login
1010,AIE: Name Only Type Rule
1011,AIE: ePO Style Rule
'@ | Set-Content (Join-Path $work 'rules.csv')
$common = @{ RulesCsv = (Join-Path $work 'rules.csv'); LrApiBaseUrl = $LrApiBaseUrl; EchoBaseUrl = $EchoBaseUrl; SkipCertificateCheck = $true; LlxToolPath = $Llx }

Test-Case 'Discover captures alarms, a drilldown with logs and Echo endpoints' {
    $f = Join-Path $work 'discover'
    & $S -Mode Discover -RunFolder $f @common -EchoCredential $cred 6>$null | Out-Null
    $sum = Get-Content (Join-Path $f 'discover/DISCOVER-SUMMARY.txt') -Raw
    Assert ($sum -match 'log\(s\) with raw text') 'no drilldown parse result'
    Assert (Test-Path (Join-Path $f 'discover/echo-usecases.json')) 'echo usecases not captured'
    Assert (-not (Select-String -Path (Join-Path $f 'http/*.json') -Pattern 'testtoken|"password": "password"' -Quiet)) 'secret written to disk'
}

Test-Case 'Dry run builds LLX + payloads and sends nothing' {
    $f = Join-Path $work 'dry'
    $before = @((Get-MockState).usecases).Count
    & $S -RunFolder $f @common -EchoCredential $cred -DryRun 6>$null | Out-Null
    $r = Get-Report $f
    Assert ($r['1001'].Status -eq 'DryRun') "1001 is $($r['1001'].Status)"
    Assert (@((Get-MockState).usecases).Count -eq $before) 'dry run created use cases'
    Assert (@(Get-ChildItem (Join-Path $f 'echo') -Filter *.payload.json).Count -ge 5) 'payloads missing'
}

Test-Case 'Full run: statuses per rule' {
    $f = Join-Path $work 'real'
    & $S -RunFolder $f @common -EchoCredential $cred 6>$null | Out-Null
    $r = Get-Report $f
    $expect = @{ '1001' = 'Created'; '1002' = 'Created'; '1003' = 'Created'; '1004' = 'NoDrilldown'; '1005' = 'Failed'; '1006' = 'Created'; '1007' = 'NoAlarms'; '1008' = 'NoAlarms'; '1009' = 'NoAlarms'; '1010' = 'Created'; '1011' = 'Created' }
    foreach ($k in $expect.Keys) { Assert ($r[$k].Status -eq $expect[$k]) "$k expected $($expect[$k]) got $($r[$k].Status): $($r[$k].Detail)" }
    Assert ($r['1003'].Notes -match 'only 3 of 10') 'partial-logs warning missing'
    Assert ($r['1006'].Logs -eq '500') 'MaxLogsPerRule not applied'
    Assert ($r['1001'].Notes -match 'Echo unpacked the LLX') 'LLX did not go through Echo unpacker'
    Assert (Test-Path (Join-Path $f 'coverage-report.html')) 'html report missing'
}

Test-Case 'Echo received correct logs, types and play order; failed one rolled back' {
    $st = Get-MockState
    $uc = @($st.usecases | Where-Object { $_.title -eq 'AIE: Malware Then Outbound' })
    Assert ($uc.Count -eq 1) 'malware use case missing'
    $logs = @($st.logs | Where-Object { $_.owner_id -eq $uc[0].id } | Sort-Object play_order)
    Assert ($logs.Count -eq 2 -and $logs[0].msg_src_id -eq 1000111 -and $logs[1].msg_src_id -eq 1000222) 'types/order wrong'
    Assert ($logs[0].msg_src_name -eq 'Syslog - Generic AV') 'type name not resolved from Echo'
    Assert (@($st.deleted).Count -ge 1) 'rollback not performed'
    Assert (-not @($st.usecases | Where-Object { $_.title -eq 'AIE: Echo Reject Rule' }).Count) 'orphan use case left behind'
}

Test-Case 'Titles are alarm names; type IDs looked up from names; ePO-style log intact' {
    $st = Get-MockState
    foreach ($t in 'AIE: Name Only Type Rule', 'AIE: ePO Style Rule') {
        $uc = @($st.usecases | Where-Object { $_.title -eq $t })
        Assert ($uc.Count -eq 1) "use case '$t' missing"
        $logs = @($st.logs | Where-Object { $_.owner_id -eq $uc[0].id })
        Assert (@($logs | Where-Object { $_.msg_src_id -ne 1000901 }).Count -eq 0) "type ID not resolved for '$t'"
    }
    $epo = @($st.logs | Where-Object { $_.log -match 'EPOEvent' })[0].log
    Assert ($epo -match '^01 15 2026 .*<SYSD:NOTE>.*</EPOEvent>  $') 'ePO log was cut or altered (trailing spaces must be kept)'
    Assert ($epo.Contains([string][char]0xA0)) 'non-breaking space lost'
}

Test-Case 'HTML report: headline numbers and use case sections' {
    $h = Get-Content (Join-Path (Join-Path $work 'real') 'coverage-report.html') -Raw
    Assert ($h -match '<div class="n">11</div><div class="l">Enabled AIE rules') 'enabled count missing'
    Assert ($h -match '<div class="n">8</div><div class="l">Fired in the last 90 days') 'fired count wrong'
    Assert ($h -match '<div class="n">6</div><div class="l">Echo use cases created') 'created count wrong'
    Assert ($h -match 'Fired, but no use case \(2\)') 'gap section wrong'
    Assert ($h -match '<details><summary>Show \d+ of \d+ log') 'sample logs missing'
}

Test-Case 'Re-run skips existing use cases' {
    $f = Join-Path $work 'again'
    & $S -RunFolder $f @common -EchoCredential $cred -RuleFilter '1001' 6>$null | Out-Null
    Assert ((Get-Report $f)['1001'].Status -eq 'Exists') 'expected Exists'
}

Test-Case 'Resume after Echo outage' {
    $f = Join-Path $work 'resume'
    $down = $common.Clone(); $down.EchoBaseUrl = 'https://127.0.0.1:1'
    & $S -RunFolder $f @down -EchoCredential $cred -RuleFilter '1003' -ExistingUseCase Duplicate 6>$null | Out-Null
    Assert ((Get-Report $f)['1003'].Status -eq 'Failed') 'expected Failed while Echo down'
    & $S -RunFolder $f -Resume @common -EchoCredential $cred -RuleFilter '1003' -ExistingUseCase Duplicate 6>$null | Out-Null
    Assert ((Get-Report $f)['1003'].Status -eq 'Created') 'resume did not create'
}

Test-Case 'Anonymiser: no originals left, consistent replacements' {
    $f = Join-Path $work 'anon'
    & $S -RunFolder $f @common -RuleFilter '1001', '1002' -StopAfter Llx -Anonymise -AnonymiseDomain 'corp.example' 6>$null | Out-Null
    $text = (Get-ChildItem (Join-Path $f 'llx') -Filter *.llx | ForEach-Object { (& $Llx View $_.FullName 6>$null).Message }) -join "`n"
    foreach ($w in 'jdoe', '203.0.113.', 'corp.example', 'asmith', '192.0.2.10', '198.51.100.7') { Assert ($text -notmatch [regex]::Escape($w)) "leaked $w" }
    $map = Import-Csv (Join-Path $f 'anonymisation-map.csv')
    $ip = ($map | Where-Object Original -eq '192.0.2.10').Replacement
    Assert (([regex]::Matches($text, [regex]::Escape($ip))).Count -eq 2) 'same IP not mapped consistently'
}

Test-Case 'Rename map links alarms under an old name' {
    $f = Join-Path $work 'rename'
    "OldName,NewName`nSome Non-AIE Alarm,AIE: Never Fired Rule" | Set-Content (Join-Path $work 'renames.csv')
    & $S -RunFolder $f @common -RuleFilter '1008' -RenameMapCsv (Join-Path $work 'renames.csv') -StopAfter Alarms 6>$null | Out-Null
    $st = Get-Content (Join-Path $f 'state.json') -Raw | ConvertFrom-Json
    Assert (@($st.Rules)[0].AlarmCount -eq 1) 'old-name alarm not counted'
}

Test-Case 'Report mode rebuilds the report' {
    $f = Join-Path $work 'real'
    Remove-Item (Join-Path $f 'coverage-report.html')
    & $S -Mode Report -RunFolder $f 6>$null | Out-Null
    Assert (Test-Path (Join-Path $f 'coverage-report.html')) 'report not rebuilt'
}

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
if ($failed) { Write-Host "$failed of $($results.Count) FAILED" -ForegroundColor Red } else { Write-Host "All $($results.Count) tests passed" -ForegroundColor Green }
if ($KeepFiles) { Write-Host "Files kept in $work" } else { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
exit ([int]($failed -gt 0))
