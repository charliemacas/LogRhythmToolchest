# Build-EchoCoverage: user guide

**"I have X enabled AIE rules. How many fired in the last 90 days? Turn those into Echo use cases."**

For every enabled AIE rule that raised an alarm in the lookback period, this tool takes the real logs that triggered it (from the AIE drilldown) and creates a LogRhythm Echo use case named after the alarm. You get a customer-friendly HTML report of exactly what was created and why the remaining rules weren't.

```
Enabled AIE rules ─► Which fired? ─► Drilldown logs ─► .llx per rule ─► Echo use case ─► coverage-report.html
 (EMDB or CSV)       (Alarm API)     (Drilldown API)   (LLX-Tool)       (Echo API,
                                                                         titled with the alarm name)
```

> **Version 1.0.0.** Every step has been proven against a live LogRhythm 7.x + Echo lab: drilldown retrieval, LLX creation, Echo accepting the LLX, use case creation via the API, replay, and the logs landing and parsing the same as the originals. It is also covered by an automated test suite against simulated servers that copy the real formats.

---

## Contents

1. [Where the files are](#where-the-files-are)
2. [Before you start](#before-you-start)
3. [Setup](#setup)
4. [Step 1: How many rules fired? (read-only)](#step-1-how-many-rules-fired-read-only)
5. [Step 2: Dry run on a few rules](#step-2-dry-run-on-a-few-rules)
6. [Step 3: Create the use cases](#step-3-create-the-use-cases)
7. [The HTML report](#the-html-report)
8. [What each status means](#what-each-status-means)
9. [Quick-start: one alarm by hand (Lab scripts)](#quick-start-one-alarm-by-hand-lab-scripts)
10. [Options](#options)
11. [FAQ](#faq)
12. [Why a use case might not re-trigger its alarm](#why-a-use-case-might-not-re-trigger-its-alarm)
13. [Troubleshooting](#troubleshooting)
14. [Security and data handling](#security-and-data-handling)

---

## Where the files are

See the repository [README](../README.md) for the layout. Commands below are run from the repository root.

---

## Before you start

| Requirement | Why | How to check |
|---|---|---|
| A Windows machine with **PowerShell 5.1+** that can reach the **LogRhythm API gateway** (usually `https://<platform-manager>:8501`) and **Echo** (default `https://<echo-host>:33333`) | The tool calls both. Running it on the Platform Manager/Echo host itself works well: use `localhost`. | `Test-NetConnection <host> -Port 8501` / `-Port 33333` |
| A **LogRhythm API token** | Alarm and Drilldown APIs | A Global Administrator creates a third-party application in the Client Console and issues the token |
| **Read access to the EMDB** (`LogRhythmEMDB`) *or* a CSV of rule IDs and names | To list the enabled AIE rules | `SELECT TOP 1 * FROM LogRhythmEMDB.dbo.AIERule` |
| **Auto Drilldown enabled** on the AIE rules (AIE rule > *Automatically drill down and cache results*) | Only alarms from those rules keep their triggering logs | Rules without it are reported as *Fired, no drilldown data* |
| **Echo installed and connected** to the Data Processor | Use cases are created over Echo's API | You can open the Echo web UI |
| *(Recommended)* Any `.llx` exported from **this** LogRhythm | Writes the deployment's real licence ID into the files (see [FAQ](#faq)) | Any log export from the console |

---

## Setup

1. Clone the repository (or download and extract it), e.g. to `C:\Tools\LR-Echo-Coverage`, and open PowerShell there.
2. Unblock the files:

   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```

   With the usual `RemoteSigned` policy (`Get-ExecutionPolicy -List`), that's all you need. If the policy is stricter, use `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` for this window only.
3. Run the LLX self-test (a few seconds; expect *All tests passed*):

   ```powershell
   .\Tests\Test-LLXTool.ps1
   ```

4. Give the tool your LogRhythm API token for this window only, so it never appears on the command line:

   ```powershell
   $env:LR_API_TOKEN = Read-Host 'LogRhythm API token'
   ```

The examples below use `localhost`. Replace it with your hosts if you run elsewhere.

---

## Step 1: How many rules fired? (read-only)

This reads the enabled rules and the alarms only, and changes nothing anywhere:

```powershell
.\Build-EchoCoverage.ps1 -SqlServer localhost -LrApiBaseUrl https://localhost:8501 `
    -LookbackDays 90 -StopAfter Alarms -SkipCertificateCheck
```

The last line on screen gives the answer, for example:

```
Summary: 150 enabled AIE rule(s) | 72 fired in the last 90 days | ... | 78 didn't fire
```

`EchoCoverage_<date>_<time>\coverage-report.html` shows the same numbers and lists which rules fired. It's a good first thing to show a customer.

> No SQL access? Export the rule list (AIERuleID, Name) to CSV and use `-RulesCsv .\rules.csv` instead of `-SqlServer`.

---

## Step 2: Dry run on a few rules

This builds everything (logs, `.llx` files, Echo payloads) for two or three rules, but **sends nothing to Echo**:

```powershell
.\Build-EchoCoverage.ps1 -SqlServer localhost -LrApiBaseUrl https://localhost:8501 `
    -EchoBaseUrl https://localhost:33333 -TemplateLlx .\export-from-this-lr.llx `
    -RuleFilter '*Brute*', '*ePO*' -DryRun -SkipCertificateCheck
```

Open the report and a payload in `echo\*.payload.json` to see exactly what would be created.

---

## Step 3: Create the use cases

The same command without `-StopAfter`, `-DryRun` and `-RuleFilter`:

```powershell
.\Build-EchoCoverage.ps1 -SqlServer localhost -LrApiBaseUrl https://localhost:8501 `
    -EchoBaseUrl https://localhost:33333 -TemplateLlx .\export-from-this-lr.llx `
    -LookbackDays 90 -SkipCertificateCheck
```

For every rule that fired, the tool:

1. picks the newest alarm that has cached drilldown data (`alarmDataCached = Y`), trying up to 5 alarms
2. fetches its triggering logs
3. writes `llx\<rule>.llx` and has Echo decode it, which proves Echo accepts it
4. creates a use case **titled with the alarm name** (e.g. `AIE: <rule name>`)
5. adds the logs with their log source types
6. reads the use case back to confirm

Progress shows on screen and in `run.log`.

- **Stopped part-way?** Add `-Resume -RunFolder .\EchoCoverage_<date>_<time>` to carry on from where it stopped.
- **Running again later** is safe. Use cases that already exist in Echo (same title) are skipped, so only new ones are added.
- **Renamed rules:** if rules were renamed during the lookback period (e.g. MITRE tagging), add `-RenameMapCsv .\renames.csv` (columns `OldName,NewName`). Alarms raised under the old names then count for the new names.

---

## The HTML report

`coverage-report.html` is a single self-contained file. You can email it or attach it to a ticket, and it prints cleanly. It contains:

- **Headline numbers:** enabled AIE rules, fired in the period, use cases created, already in Echo, fired but no drilldown data, failed, didn't fire.
- **One card per Echo use case:**
  - the title (the alarm name) and Echo use case ID
  - the source alarm ID and date, and how many times it fired
  - the number of logs and rule blocks, and the log source types
  - any warnings
  - an expandable sample of the actual logs
- **Fired, but no use case:** each rule with the reason and what to do.
- **Didn't fire:** a collapsible list.

`coverage-report.csv` has the same data in one row per rule, for Excel. `Build-EchoCoverage.ps1 -Mode Report -RunFolder <folder>` rebuilds the report from an existing run.

---

## What each status means

| Status (CSV) | In the report | Meaning | What to do |
|---|---|---|---|
| **Created** | Echo use cases | Use case created with the alarm's logs | Run it in Echo |
| **Exists** | Echo use cases | Echo already has a use case with that title | Nothing; or `-ExistingUseCase Duplicate` |
| **DryRun / LlxBuilt / LogsFound** | Echo use cases (*not sent*) | Prepared but not sent (`-DryRun` / `-StopAfter`) | Re-run without those switches |
| **NoDrilldown** | Fired, but no use case | Alarms exist, but none had drilldown logs | Enable Auto Drilldown on the rule. Older alarms may have left the cache. |
| **Failed** | Fired, but no use case | Something went wrong for that rule (reason shown) | Fix, then `-Resume` |
| **NoAlarms** | Didn't fire | No alarm in the lookback period | Nothing; or increase `-LookbackDays` / check renames |

---

## Quick-start: one alarm by hand (Lab scripts)

To prove the chain on a single alarm first, or to troubleshoot one, use the two scripts in `Lab\`:

```powershell
cd .\Lab
# Stages 1-4: drilldown logs -> .llx -> Echo decodes it (pauses after each stage)
.\Invoke-LlxLabPoc.ps1 -LrApiBaseUrl https://localhost:8501 -AlarmId <alarm ID> -LicenseID 1 `
    -EchoBaseUrl https://localhost:33333 -SkipCertificateCheck
# Stage 6: create the Echo use case via the API, titled with the alarm name
.\New-EchoUseCaseFromLab.ps1 -SkipCertificateCheck
```

Then run the use case in Echo and search the Web Console for its log source type over the last 15 minutes.

The lab script uses one log source type per `.llx`. If an alarm's logs span several types, it keeps the most common one and tells you. The main pipeline has no such limit.

---

## Options

| Option | Default | Purpose |
|---|---|---|
| `-Mode` | `Run` | `Run`, `Discover` (read-only format capture) or `Report` (rebuild the report) |
| `-LookbackDays` | 90 | Alarm window |
| `-StopAfter` | | `Rules`, `Alarms`, `Drilldown`, `Llx` or `Echo` (`Alarms` = the read-only "how many fired" pass) |
| `-DryRun` | | Build everything, send nothing to Echo |
| `-RunFolder`, `-Resume` | new folder | Where results go; continue a previous run |
| `-SqlServer`, `-SqlDatabase`, `-SqlCredential`, `-SqlTrustServerCertificate` | `LogRhythmEMDB`, Windows auth | Where to read the enabled AIE rules |
| `-RulesQuery` | built in | Your own SQL returning `AIERuleID, Name` |
| `-RulesCsv` | | CSV (`AIERuleID,Name`) instead of SQL. See `Examples\rules-example.csv`. |
| `-RuleFilter` | all | Only these rule names/IDs (wildcards) |
| `-RenameMapCsv` | | `OldName,NewName` for renamed rules |
| `-LrApiBaseUrl`, `-LrApiToken` | token from `$env:LR_API_TOKEN` or a prompt | LogRhythm API gateway and token |
| `-MaxAlarmsPerRule` | 5 | Alarms to try per rule for drilldown data |
| `-MaxLogsPerRule` | 500 | Cap on logs per use case |
| `-TemplateLlx` / `-LicenseID` | | Licence ID and version written into the `.llx` files |
| `-EchoBaseUrl`, `-EchoCredential` | `https://localhost:33333`, none | Echo API (login only if your Echo requires one) |
| `-EchoImportMode` | `Unpack` | `Unpack` = Echo decodes each `.llx` first (proves acceptance); `Direct` = skip that |
| `-ExistingUseCase` | `Skip` | `Skip` or `Duplicate` |
| `-TitlePrefix` | none | Optional prefix before the alarm name |
| `-TimeDelaySeconds` | 0 | Echo's per-log backdating |
| `-Anonymise`, `-AnonymiseDomain`, `-AnonymiseTermsFile`, `-AnonymiseSalt` | off | Consistently replace users, hosts, IPs, e-mails and listed terms (for use cases shared outside the customer) |
| `-SkipCertificateCheck` | off | Accept the self-signed certificates LogRhythm and Echo normally use |

Full help: `Get-Help .\Build-EchoCoverage.ps1 -Full`

---

## FAQ

**Which licence ID ends up in the `.llx` files?**
Whatever you give it: copied from `-TemplateLlx`, or `-LicenseID`. Echo doesn't check it: a lab test with licence ID `1` imported and replayed fine, and the API route doesn't read the LLX header at all. The field exists because LLX files are also used to submit logs to LogRhythm. Use `-TemplateLlx` with an export from the customer's own deployment so the files carry their real licence ID.

**Do I need to know log source type IDs?**
No. Each drilldown log carries its log source type (`logSourceType` / `logSourceTypeName`). If only the name is present, the tool looks the ID up in Echo's list of log source types, falling back to the EMDB. Every log keeps its own type, so one use case can mix several log source types.

**Do different log formats matter?**
The pipeline passes each log through unchanged: syslog headers, XML, multi-line, trailing spaces and non-ASCII characters are all kept. It never splits text, so formats like McAfee ePO (XML with embedded `<Event>` elements) stay intact. What can differ is **parsing on replay**, because Echo uses the LogRhythm Default MPE policy (see below).

**Is anything changed in LogRhythm?**
No. It only reads (Alarm API, Drilldown API, EMDB `SELECT`). Echo is the only place anything is created.

---

## Why a use case might not re-trigger its alarm

Replaying the triggering logs reproduces the **logs**: in the lab, replayed logs parsed with the same MPE rule and metadata as the originals. Whether the **AIE rule fires again** depends on the rule:

- **Log source / entity / host filters.** Echo sends logs from its own simulated log sources (e.g. `Echo_<n>_<typeId>`, entity `EchoTestEntity`). A rule scoped to the production log source or entity won't match them.
- **MPE policy.** Echo processes logs under the LogRhythm Default policy. Log types parsed only by a custom policy (e.g. an `… Default v2` copy) may classify differently.
- **Thresholds and unique values.** If the report notes that only some triggering logs were retrievable, the replay may fall short.
- **"Log not observed" blocks and time windows** can't be reproduced by replay.
- **Lists** (users, hosts, IPs) must still contain the replayed values. `-Anonymise` breaks this.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Drilldown returns HTTP 400 *Invalid request at route /drilldown/…* | The `Content-Type: application/json` header is missing | Already handled by these scripts. If you call the API yourself (Postman, scripts), send both `Accept` and `Content-Type: application/json`, even on GET. |
| Drilldown returns 204 / rule shows *Fired, no drilldown data* | Auto Drilldown off, or the alarm has left the cache | Enable Auto Drilldown; newer alarms will carry data |
| `Enabled rules found` doesn't match the console | The built-in query is a best effort on an undocumented schema | Use `-RulesQuery` with your known-good query, or `-RulesCsv` |
| `Alarm API refused the token (HTTP 401/403)` | Token wrong, expired or under-privileged | Re-issue the token |
| Many *Didn't fire* for rules you know fired | Alarm name ≠ rule name (renamed rules) | Check `alarms.json`; use `-RenameMapCsv` |
| `Echo use case create failed` | Different Echo version or login required | Send `http\*_POST_api_usecase.json` (see docs/CAPTURE-CHECKLIST.md); try `-EchoCredential` |
| `… already exists (use -Force …)` / *Exists* | Use case with that title already in Echo | Expected on re-runs. Delete it in Echo or use `-ExistingUseCase Duplicate`. |
| Characters like `Â` in logs | Old version of these scripts on Windows PowerShell 5.1 | Fixed in 1.0.0 (responses are decoded as UTF-8) |
| It stopped part-way | Network/service interruption | `-Resume -RunFolder <folder>` |

Every HTTP request and response is saved in `<run folder>\http\` (secrets redacted). `run.log` records each step, and failures include the script line number.

---

## Security and data handling

- **Credentials:**
  - The LogRhythm token comes from a SecureString, `$env:LR_API_TOKEN` or a hidden prompt, and is never written to disk.
  - Passwords, tokens and `Authorization` headers are redacted in every saved capture.
- **Read-only against LogRhythm.**
- **Changes in Echo:**
  - Creates use cases and adds logs. Existing use cases are never changed.
  - The only delete is rolling back an empty use case it has just created, if Echo then rejects the logs.
- **No code from files is executed:** `.llx` files are parsed by LLX-Tool's own reader, never by .NET deserialisation.
- **`-SkipCertificateCheck`** disables certificate validation for this PowerShell session's web requests. Use it only on a trusted management network.
- **The run folder contains real customer log data** (drilldown responses, `.llx` files, HTTP captures). Store it like any SIEM export and delete it when done. `anonymisation-map.csv` reverses anonymisation, so keep it private.
