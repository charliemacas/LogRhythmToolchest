# LR-Echo-Coverage

**Turn the alarms your LogRhythm SIEM actually raised into replayable LogRhythm Echo use cases, and report on it.**

> *"I have X enabled AIE rules. How many fired in the last 90 days? Turn those into Echo use cases, and give me a report."*

For every enabled AIE rule that raised an alarm in the lookback period, the toolkit:
1. fetches the logs that triggered it (through the AIE drilldown)
2. packages them as a LogRhythm `.llx` log export
3. creates an Echo use case named after the alarm

It produces a self-contained HTML report covering every enabled rule. The same toolkit also includes a standalone `.llx` reader/writer.

> **Community tool. Not an official LogRhythm or Exabeam product, and not supported by them.** LogRhythm, Echo and related names are trademarks of their respective owners. It uses undocumented behaviour of the Echo API: test in a lab first and use at your own risk.

```
Enabled AIE rules ─► Which fired? ─► Drilldown logs ─► .llx per rule ─► Echo use case ─► coverage-report.html
 (EMDB or CSV)       (Alarm API)     (Drilldown API)   (LLX-Tool)       (Echo REST API,
                                                                         titled with the alarm name)
```

---

## What's inside

| Tool | What it does | Guide |
|---|---|---|
| **`Build-EchoCoverage.ps1`** | The full pipeline at scale. It lists enabled AIE rules, finds which fired, and builds one Echo use case per rule from its drilldown logs. It writes an HTML/CSV coverage report and supports resume, dry run, a read-only "how many fired" pass and an optional anonymiser. | [docs/Build-EchoCoverage.md](docs/Build-EchoCoverage.md) |
| **`LLX-Tool.ps1`** | View, export and create LogRhythm `.llx` files: TXT ↔ LLX, JSON → LLX with per-log log source types, and bulk conversion. Safe on untrusted files (no .NET deserialisation). | [docs/LLX-Tool.md](docs/LLX-Tool.md) |
| **`Lab/`** | Two small scripts that prove the chain on a single alarm, one stage at a time | [docs/Build-EchoCoverage.md#quick-start-one-alarm-by-hand-lab-scripts](docs/Build-EchoCoverage.md#quick-start-one-alarm-by-hand-lab-scripts) |

```
LR-Echo-Coverage/
├── Build-EchoCoverage.ps1        Pipeline
├── LLX-Tool.ps1                  LLX reader/writer
├── Lab/                          Single-alarm proof-of-concept scripts
├── docs/                         User guides, LLX format handover, API capture checklist
├── Examples/                     Synthetic sample logs, example CSVs (no real data)
├── Tests/                        Self-tests + mock LogRhythm/Echo servers
├── HANDOVER.md                   Technical handover for engineers and AI assistants
├── CHANGELOG.md · SECURITY.md · CONTRIBUTING.md
```

---

## Requirements

- Windows PowerShell **5.1** or PowerShell **7+**. No modules to install.
- Network access to the **LogRhythm API gateway** (usually `https://<platform-manager>:8501`) and **LogRhythm Echo** (default `https://<echo-host>:33333`).
- A **LogRhythm API token**, issued by a Global Administrator from a third-party application in the Client Console.
- Read access to the **EMDB** to list the enabled AIE rules, or a CSV export of them.
- **Auto Drilldown** enabled on the AIE rules you want covered. Only alarms from those rules keep their triggering logs.

---

## Quick start

```powershell
# One-off: unblock the files and set your API token for this window
Get-ChildItem -Recurse | Unblock-File
$env:LR_API_TOKEN = Read-Host 'LogRhythm API token'

# 1. How many enabled rules fired in the last 90 days? (read-only)
.\Build-EchoCoverage.ps1 -SqlServer localhost -LrApiBaseUrl https://localhost:8501 `
    -LookbackDays 90 -StopAfter Alarms -SkipCertificateCheck

# 2. Dry run on a couple of rules (builds everything, sends nothing to Echo)
.\Build-EchoCoverage.ps1 -SqlServer localhost -LrApiBaseUrl https://localhost:8501 `
    -EchoBaseUrl https://localhost:33333 -RuleFilter '*Brute*' -DryRun -SkipCertificateCheck

# 3. Create the use cases and the report
.\Build-EchoCoverage.ps1 -SqlServer localhost -LrApiBaseUrl https://localhost:8501 `
    -EchoBaseUrl https://localhost:33333 -LookbackDays 90 -SkipCertificateCheck
```

The results go to `EchoCoverage_<date>_<time>\`. Open `coverage-report.html`.

Working with `.llx` files on their own:

```powershell
.\LLX-Tool.ps1 View   .\export.llx -ExpandEventXml
.\LLX-Tool.ps1 Export .\export.llx                       # -> export.txt
.\LLX-Tool.ps1 Compile .\logs.txt -TemplateLlx .\export.llx
.\LLX-Tool.ps1 BulkCompile .\folder-of-txt -OutputPath .\llx
```

---

## Status

| Area | State |
|---|---|
| LLX format | Byte-identical to a genuine LogRhythm 7.25 export; accepted by Echo's LLX browser and API |
| Drilldown, Alarm and Echo API formats | Confirmed against a live LogRhythm 7.x + Echo 2.x system (see [HANDOVER.md](HANDOVER.md) §4) |
| End-to-end (single alarm) | Proven live: drilldown → LLX → Echo use case created via API → replay → logs landed and parsed the same as the originals |
| Multi-rule pipeline | Tested end to end against mock servers that reproduce the confirmed formats (11 tests). First real-estate runs should start with `-StopAfter Alarms` and `-DryRun`. |
| PowerShell | 5.1 used in the live lab; 7.4 used for the automated tests |

Known limits and why a replayed use case may not re-trigger its alarm: see [docs/Build-EchoCoverage.md](docs/Build-EchoCoverage.md#why-a-use-case-might-not-re-trigger-its-alarm).

---

## Tests

```powershell
.\Tests\Test-LLXTool.ps1          # 19 tests, no dependencies
```

The pipeline tests need Python 3 (standard library only) to run the mock LogRhythm/Echo servers. See [Tests/MockServers/README.md](Tests/MockServers/README.md).

---

## Data handling: please read before contributing

Real SIEM logs contain usernames, hostnames, IP addresses and more.
- **Never commit run folders** (`EchoCoverage_*`, `LabPoc_*`), `.llx` files from real systems, HTTP captures or `anonymisation-map.csv`. `.gitignore` excludes them by default.
- **Never paste real logs into issues.** Share field names and structure, or redacted samples.
- Everything in `Examples/` and `Tests/` is synthetic: `example.com` hosts, documentation-only IP ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and invented values.

See [SECURITY.md](SECURITY.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Licence

No licence file is included yet. Choose one before publishing (MIT and Apache-2.0 are common for tools like this), and check any obligations to your employer for work produced in a professional capacity.
