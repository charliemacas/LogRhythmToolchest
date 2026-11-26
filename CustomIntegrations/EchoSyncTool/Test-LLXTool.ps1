<#
.SYNOPSIS
    Self-test for LLX-Tool.ps1. Run it on the machine where you'll use the tool.

.DESCRIPTION
    Builds synthetic log files in a temporary folder, runs every LLX-Tool mode
    against them and checks the results. Nothing outside the temp folder is touched,
    and the temp folder is removed afterwards unless -KeepFiles is given.

    Exit code 0 = all tests passed, 1 = at least one failure.

.EXAMPLE
    .\Tests\Test-LLXTool.ps1

.EXAMPLE
    .\Tests\Test-LLXTool.ps1 -KeepFiles      # leave the generated files for inspection
#>
[CmdletBinding()]
param(
    [string]$ToolPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'LLX-Tool.ps1'),
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not (Test-Path -LiteralPath $ToolPath)) { throw "LLX-Tool.ps1 not found at $ToolPath" }
$Tool = (Resolve-Path -LiteralPath $ToolPath).ProviderPath
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("llxtool-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$results = New-Object System.Collections.Generic.List[object]

function Write-TextFile([string]$Name, [string]$Content) {
    $p = Join-Path $Work $Name
    $d = Split-Path -Parent $p
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllText($p, $Content, $utf8)
    return $p
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
        $results.Add([pscustomobject]@{ Result = 'PASS'; Test = $Name; Ms = $sw.ElapsedMilliseconds; Detail = '' })
    }
    catch {
        $results.Add([pscustomobject]@{ Result = 'FAIL'; Test = $Name; Ms = $sw.ElapsedMilliseconds; Detail = $_.Exception.Message })
    }
}

function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

function Read-Txt([string]$Path) { ([System.IO.File]::ReadAllText($Path, $utf8)) -replace "`r`n", "`n" }

$syslog = @"
<38>Nov 17 09:15:01 host1.example.com sshd[2101]: Accepted publickey for alice from 192.0.2.10 port 51122 ssh2
<38>Nov 17 09:15:07 host1.example.com sshd[2107]: Failed password for invalid user admin from 198.51.100.23

<86>Nov 17 09:16:30 host1.example.com sudo: alice : COMMAND=/usr/bin/id
"@

$events = @"
<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'>
  <System><Provider Name='Test-Provider'/><EventID>4625</EventID><Channel>Security</Channel><Computer>DC01.example.com</Computer></System>
  <EventData><Data Name='TargetUserName'>jdoe</Data></EventData>
</Event>
<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><EventID>4624</EventID><Computer>DC02.example.com</Computer></System></Event>
"@

$multi = "first line`nstill first`n`nsecond message`n`n`nthird`nmessage"

$common = @{ LicenseID = 123456; MsgSourceID = 1; MsgSourceTypeID = 1000000 }

Write-Host "LLX-Tool self-test"
Write-Host "  Tool : $Tool"
Write-Host "  Temp : $Work"
Write-Host "  Host : PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Host ''

# ----------------------------------------------------------------------------
Test-Case 'Compile: one message per line, blank lines ignored' {
    $src = Write-TextFile 'syslog.txt' $syslog
    $r = & $Tool Compile $src @common -Force 6>$null
    Assert ($r.Messages -eq 3) "Expected 3 messages, got $($r.Messages)"
    Assert (Test-Path (Join-Path $Work 'syslog.llx')) 'syslog.llx not created'
}

Test-Case 'File structure: GZip with inner filename, .NET stream, LogRhythm type names' {
    $b = [System.IO.File]::ReadAllBytes((Join-Path $Work 'syslog.llx'))
    Assert ($b[0] -eq 0x1F -and $b[1] -eq 0x8B -and $b[2] -eq 8) 'Not a GZip/deflate file'
    Assert (($b[3] -band 0x08) -ne 0) 'GZip FNAME flag not set'
    $i = 10; while ($b[$i] -ne 0) { $i++ }
    $inner = [System.Text.Encoding]::ASCII.GetString($b, 10, $i - 10)
    Assert ($inner -match '^SubmittedLogs_123456_\d{8}_\d{8}\.llx\.txt$') "Unexpected inner name '$inner'"
    $ms = New-Object System.IO.MemoryStream(, $b)
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $out = New-Object System.IO.MemoryStream; $gz.CopyTo($out); $p = $out.ToArray()
    Assert ($p[0] -eq 0 -and $p[5] -eq 0xFF -and $p[8] -eq 0xFF) 'Missing .NET serialisation header'
    $ascii = [System.Text.Encoding]::ASCII.GetString($p)
    foreach ($t in 'scvbcomn, Version=', 'SC.Message.Export.LogMessageCollection', 'SC.Message.Export.LogMessage', 'System.Collections.Hashtable') {
        Assert ($ascii.Contains($t)) "Missing '$t' in payload"
    }
}

Test-Case 'View: header and message fields' {
    $v = @(& $Tool View (Join-Path $Work 'syslog.llx') 6>$null)
    Assert ($v.Count -eq 3) "Expected 3 messages, got $($v.Count)"
    Assert ($v[0].LicenseID -eq 123456) 'LicenseID wrong'
    Assert ($v[0].MsgSourceID -eq 1 -and $v[0].MsgSourceTypeID -eq 1000000) 'Source IDs wrong'
    Assert ($v[0].MPERuleID -eq -1) 'MPERuleID should default to -1'
    Assert ($v[0].SubmittedBy -eq 'LogRhythm Administrator') 'SubmittedBy default wrong'
    Assert ($v[1].Message -like '*Failed password*') 'Message order or content wrong'
}

Test-Case 'View -Summary' {
    $s = & $Tool View (Join-Path $Work 'syslog.llx') -Summary
    Assert ($s.Messages -eq 3 -and $s.MsgSourceTypeIDs -eq '1000000') 'Summary values wrong'
}

Test-Case 'Export: TXT matches original (lossless round trip)' {
    $r = & $Tool Export (Join-Path $Work 'syslog.llx') -Force
    $expected = (($syslog -split '\r?\n') | Where-Object { $_.Trim() }) -join "`n"
    $actual = (Read-Txt $r.Output).TrimEnd("`n")
    Assert ($actual -ceq $expected) 'Exported text differs from source'
}

Test-Case 'Windows event XML: auto-detected, flattened, -ExpandEventXml' {
    $src = Write-TextFile 'events.txt' $events
    $r = & $Tool Compile $src @common -Force 6>$null
    Assert ($r.Messages -eq 2) "Expected 2 events, got $($r.Messages)"
    $v = @(& $Tool View (Join-Path $Work 'events.llx') -ExpandEventXml 6>$null)
    Assert ($v[0].EventID -eq '4625' -and $v[0].Computer -eq 'DC01.example.com') 'Event fields not extracted'
    Assert ($v[0].EventData -eq 'TargetUserName=jdoe') 'EventData not extracted'
    Assert ($v[0].Message -notmatch '\n') 'Event XML was not flattened to one line'
}

Test-Case 'Auto mode leaves logs with embedded <Event> elements intact (e.g. McAfee ePO)' {
    $epo = '01 15 2026 09:00:00 192.0.2.60 <SYSD:NOTE> EPOEvents <EPOEvent><MachineInfo><MachineName>a</MachineName></MachineInfo><Event><EventID>1</EventID></Event></EPOEvent>'
    $src = Write-TextFile 'epo.txt' ($epo + "`n" + $epo.Replace('<EventID>1', '<EventID>2'))
    $r = & $Tool Compile $src @common -Force 6>$null
    Assert ($r.Messages -eq 2) "Expected 2, got $($r.Messages)"
    $v = @(& $Tool View (Join-Path $Work 'epo.llx') 6>$null)
    Assert ($v[0].Message -ceq $epo) 'ePO log was altered'
}

Test-Case 'Multi-line logs: -SplitMode BlankLine, export, recompile' {
    $src = Write-TextFile 'multi.txt' $multi
    $r = & $Tool Compile $src @common -SplitMode BlankLine -Force 6>$null
    Assert ($r.Messages -eq 3) "Expected 3 blocks, got $($r.Messages)"
    $e = & $Tool Export (Join-Path $Work 'multi.llx') -OutputPath (Join-Path $Work 'multi-out.txt') -Force -WarningVariable wv -WarningAction SilentlyContinue
    Assert ($wv.Count -ge 1) 'Expected a multi-line warning on export'
    $r2 = & $Tool Compile $e.Output @common -SplitMode BlankLine -OutputPath (Join-Path $Work 'multi2.llx') -Force 6>$null
    $a = @(& $Tool View (Join-Path $Work 'multi.llx') 6>$null).Message -join '|'
    $b = @(& $Tool View (Join-Path $Work 'multi2.llx') 6>$null).Message -join '|'
    Assert ($a -ceq $b) 'Messages changed after export/recompile'
}

Test-Case 'Regex split' {
    $src = Write-TextFile 'regex.txt' 'id=1 a; id=2 b; id=3 c;'
    $r = & $Tool Compile $src @common -SplitMode Regex -SplitPattern 'id=\d+[^;]*' -Force 6>$null
    Assert ($r.Messages -eq 3) "Expected 3 matches, got $($r.Messages)"
}

Test-Case 'JSON input: per-message log source IDs, defaults for missing ones' {
    $json = '[{"Message":"a1","MsgSourceTypeID":1000030,"MsgSourceID":12},{"message":"b2","msgSourceTypeId":1000301,"mpeRuleId":5},{"Message":"c3"}]'
    $src = Write-TextFile 'records.json' $json
    $r = & $Tool Compile $src @common -Force 6>$null
    Assert ($r.Messages -eq 3) "Expected 3, got $($r.Messages)"
    $v = @(& $Tool View (Join-Path $Work 'records.llx') 6>$null)
    Assert ($v[0].MsgSourceTypeID -eq 1000030 -and $v[0].MsgSourceID -eq 12) 'record 1 IDs wrong'
    Assert ($v[1].MsgSourceTypeID -eq 1000301 -and $v[1].MPERuleID -eq 5) 'record 2 IDs wrong'
    Assert ($v[2].MsgSourceTypeID -eq 1000000 -and $v[2].MPERuleID -eq -1) 'record 3 should use defaults'
}

Test-Case 'Unicode survives a round trip' {
    $text = "naïve café ü ß € 日本語 ✓"
    $src = Write-TextFile 'unicode.txt' $text
    & $Tool Compile $src @common -Force 6>$null | Out-Null
    $v = & $Tool View (Join-Path $Work 'unicode.llx') 6>$null
    Assert ($v.Message -ceq $text) "Got '$($v.Message)'"
}

Test-Case '-TemplateLlx copies settings; explicit parameters override' {
    $src = Write-TextFile 'tmpl.txt' 'x'
    & $Tool Compile $src -TemplateLlx (Join-Path $Work 'syslog.llx') -MsgSourceID 7 -Force 6>$null | Out-Null
    $v = & $Tool View (Join-Path $Work 'tmpl.llx') 6>$null
    Assert ($v.LicenseID -eq 123456 -and $v.MsgSourceTypeID -eq 1000000) 'Template values not copied'
    Assert ($v.MsgSourceID -eq 7) 'Explicit -MsgSourceID did not override template'
}

Test-Case 'Missing IDs produce warnings' {
    $src = Write-TextFile 'noid.txt' 'x'
    & $Tool Compile $src -Force -WarningVariable wv -WarningAction SilentlyContinue 6>$null | Out-Null
    Assert ($wv.Count -ge 2) "Expected 2 warnings, got $($wv.Count)"
}

Test-Case 'Existing output is not overwritten without -Force' {
    $src = Join-Path $Work 'syslog.txt'
    $null = & $Tool Compile $src @common -ErrorVariable ev -ErrorAction SilentlyContinue 6>$null
    Assert (($ev | Out-String) -match 'already exists') 'Expected an "already exists" error'
}

Test-Case 'BulkCompile: recursion, subfolders kept, empty files skipped' {
    $bulk = Join-Path $Work 'bulk'
    Write-TextFile 'bulk\a.txt' "a1`na2" | Out-Null
    Write-TextFile 'bulk\sub\b.txt' "b1" | Out-Null
    Write-TextFile 'bulk\empty.txt' '' | Out-Null
    $out = Join-Path $Work 'bulk-out'
    $r = @(& $Tool BulkCompile $bulk -Recurse -OutputPath $out @common -WarningVariable wv -WarningAction SilentlyContinue 6>$null)
    Assert ($r.Count -eq 2) "Expected 2 files, got $($r.Count)"
    Assert (Test-Path (Join-Path $out 'a.llx')) 'a.llx missing'
    Assert (Test-Path (Join-Path (Join-Path $out 'sub') 'b.llx')) 'sub\b.llx missing'
    Assert (($wv | Out-String) -match 'empty.txt') 'Empty file was not reported'
}

Test-Case 'Export a whole folder' {
    $r = @(& $Tool Export (Join-Path $Work 'bulk-out') -Recurse -OutputPath (Join-Path $Work 'bulk-txt') -Force)
    Assert ($r.Count -eq 2) "Expected 2 exports, got $($r.Count)"
    Assert ((Read-Txt (Join-Path (Join-Path (Join-Path $Work 'bulk-txt') 'sub') 'b.txt')).Trim() -eq 'b1') 'Content wrong'
}

Test-Case 'Non-LLX input is rejected cleanly' {
    $bad = Write-TextFile 'bad.llx' 'not an llx'
    $null = & $Tool View $bad -ErrorVariable ev -ErrorAction SilentlyContinue 6>$null
    Assert (($ev | Out-String) -match 'Not an LLX') 'Expected "Not an LLX" error'
}

Test-Case 'Truncated LLX produces a warning' {
    $b = [System.IO.File]::ReadAllBytes((Join-Path $Work 'syslog.llx'))
    $ms = New-Object System.IO.MemoryStream(, $b)
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $out = New-Object System.IO.MemoryStream; $gz.CopyTo($out); $p = $out.ToArray()
    $cut = New-Object byte[] ([int]($p.Length * 0.7)); [Array]::Copy($p, $cut, $cut.Length)
    $t = Join-Path $Work 'truncated.llx'; [System.IO.File]::WriteAllBytes($t, $cut)
    $null = & $Tool View $t -WarningVariable wv -WarningAction SilentlyContinue -ErrorAction SilentlyContinue 6>$null
    Assert (($wv | Out-String) -match 'truncated') 'Expected a truncation warning'
}

Test-Case 'Performance: 20,000 lines compile and export' {
    $lines = 1..20000 | ForEach-Object { "Jan 01 00:00:00 host$($_ % 10) app[$_]: synthetic event $_" }
    $src = Write-TextFile 'perf.txt' ($lines -join "`n")
    $r = & $Tool Compile $src @common -Force 6>$null
    Assert ($r.Messages -eq 20000) "Expected 20000, got $($r.Messages)"
    $e = & $Tool Export (Join-Path $Work 'perf.llx') -OutputPath (Join-Path $Work 'perf-out.txt') -Force
    Assert ((Read-Txt $e.Output).TrimEnd("`n") -ceq ($lines -join "`n")) 'Round trip mismatch'
}

# ----------------------------------------------------------------------------
$results | Format-Table Result, Test, Ms, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
if ($failed) { Write-Host "$failed of $($results.Count) test(s) FAILED" -ForegroundColor Red }
else { Write-Host "All $($results.Count) tests passed" -ForegroundColor Green }

if ($KeepFiles) { Write-Host "Test files kept in $Work" }
else { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }

exit ([int]($failed -gt 0))
