# Contributing

Thanks for helping. A few rules keep this tool safe to share publicly.

## Never include real data
- No real logs, hostnames, usernames, IP addresses, alarm/rule IDs, licence IDs or `.llx` exports from real systems, in code, tests, docs, issues or pull requests.
- Use synthetic data: `example.com` / `example.local` hosts, documentation IP ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and invented names and values.
- When reporting a format difference, share **field names and structure**. The tool's `-Mode Discover` output and `http\` captures are useful, but redact them first.

## Code conventions
- PowerShell must run on **Windows PowerShell 5.1** and **PowerShell 7+**: no ternaries, `??`, `&&` or `-Parallel`.
- Embedded C# (`Add-Type`) must be **C# 5**, and must not pass `-ReferencedAssemblies`.
- Save `.ps1` files as UTF-8 **with BOM** (5.1 reads BOM-less files as ANSI) and CRLF line endings. `.gitattributes` handles the line endings.
- Read `HANDOVER.md` §9 for the PowerShell pitfalls already hit (one-element arrays unrolling, StrictMode, UTF-8 decoding on 5.1, the `Content-Type` header on PowerShell 7).

## Changing an API format
1. Update the mock in `Tests/MockServers/mock_lr_echo.py` to emit or accept the real format.
2. Change the parser or payload function (see `HANDOVER.md` §5 for the code map).
3. Run both test suites (below) and record the change in `HANDOVER.md` §4 and `CHANGELOG.md`.

## Tests
```powershell
.\Tests\Test-LLXTool.ps1
# with the mocks running (see Tests/MockServers/README.md):
.\Tests\Test-EchoCoverage.ps1 -LrApiBaseUrl https://127.0.0.1:18501 -EchoBaseUrl https://127.0.0.1:13333
```
