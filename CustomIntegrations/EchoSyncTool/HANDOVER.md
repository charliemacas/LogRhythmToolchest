# LR-Echo-Coverage: Technical Handover (for engineers and AI assistants)

**Audience:** engineers and AI coding assistants supporting or extending `Build-EchoCoverage.ps1`.
**User guides:** `docs/Build-EchoCoverage.md`, `docs/LLX-Tool.md`. **LLX format and LLX-Tool internals:** `docs/LLX-Tool-HANDOVER.md`. **Format capture checklist:** `docs/CAPTURE-CHECKLIST.md`.

---

## 0. TL;DR for an AI assistant picking this up

- **Goal:** *"X enabled AIE rules → which fired in the last N days → one Echo use case per rule that fired"*. Each use case is built from the logs that triggered the alarm and **titled with the alarm name**, and there's a customer-friendly HTML report covering every enabled rule.
- **Pipeline:**
  1. EMDB/CSV rules
  2. Alarm API (paged, grouped by alarm name, `alarmDataCached=Y` first)
  3. Drilldown Cache API (raw logs per rule block)
  4. type-ID lookup by name
  5. JSON records → `LLX-Tool.ps1 Compile` → `.llx`
  6. Echo `/api/unpackLLXFile` (acceptance check)
  7. Echo `POST /api/usecase` (plain JSON) + `POST /api/addLogs`
  8. `coverage-report.html/csv`
- **Status:** every API format the pipeline depends on was confirmed against a live LogRhythm 7.x + Echo lab (§4). The mock server reproduces those formats exactly.
- **First step on any problem:** read `<run>\run.log`, then the matching numbered file in `<run>\http\`. Every HTTP exchange is captured, with secrets redacted. `-Mode Discover` captures fresh samples read-only.
- **Tests:** `Tests/Test-EchoCoverage.ps1` (11 end-to-end tests against `Tests/MockServers/mock_lr_echo.py`) and `Tests/Test-LLXTool.ps1` (19 tests). When a format changes, update the mock first, then the code, then run both.
- **Never ask the user for unredacted logs.** Field names and structure are enough.

---

## 1. Status

| Item | State |
|---|---|
| Version | Build-EchoCoverage 1.0.0, LLX-Tool 1.1.1, Lab scripts (single-alarm quick-start) |
| Runtime | Windows PowerShell 5.1 (lab-verified for the Lab scripts and LLX-Tool) and PowerShell 7 (tests) |
| Live lab proof | Alarm → drilldown REST → LLX → Echo unpack → use case created via API (titled with alarm name) → replay → logs landed and parsed with the same MPE rule/metadata as the originals |
| Tests | 11/11 end-to-end (mock), 19/19 LLX-Tool |
| Not yet proven live | The full multi-rule pipeline run on a customer system; EMDB "enabled rules" default query (use `-RulesQuery`/`-RulesCsv` if counts differ); Echo instances that require a login |
| Dependencies | `LLX-Tool.ps1` 1.1.0+ (JSON input). `System.Data.SqlClient`. |

---

## 2. Files and run-folder layout

```
README.md                   repository overview (start here)
docs/Build-EchoCoverage.md  pipeline user guide
docs/LLX-Tool.md            LLX-Tool user guide
docs/LLX-Tool-HANDOVER.md   LLX format (MS-NRBF) and LLX-Tool internals
docs/CAPTURE-CHECKLIST.md   which API samples to capture when a format differs
Build-EchoCoverage.ps1      pipeline (single file, no modules)
LLX-Tool.ps1                LLX reader/writer (invoked as a child script)
Tests/Test-EchoCoverage.ps1 end-to-end tests (needs the mocks running)
Tests/Test-LLXTool.ps1      LLX-Tool self-test
Tests/MockServers/mock_lr_echo.py   mock Alarm/Drilldown/Echo APIs (lab-confirmed formats) + minimal LLX reader
Lab/Invoke-LlxLabPoc.ps1     single alarm: drilldown -> .llx -> Echo unpack (stage by stage, pauses)
Lab/New-EchoUseCaseFromLab.ps1   single alarm: create the Echo use case via API from a lab run
```

Each run writes to `<RunFolder>`:

| Path | Content |
|---|---|
| `run.log` | Timestamped steps; failures include the script line number and stack |
| `state.json` | Resumable state: one record per rule (§3) |
| `alarms.json` | Every alarm kept from the lookback window (ID, rule name, date, entity) |
| `drilldown/<RuleID>_<AlarmID>.json` | Raw drilldown response used for the rule |
| `drilldown/<RuleID>_<name>.logs.json` | Normalised, ordered, capped (and anonymised) logs for the rule |
| `llx/<RuleID>_<name>.json` / `.llx` | LLX-Tool input records and the resulting LLX |
| `echo/<RuleID>_<name>.payload.json` | Dry-run payloads |
| `http/NNNNN_<METHOD>_<path>.json` | Every HTTP request/response (secrets redacted; bodies > 2 MB truncated) |
| `discover/` | Discover-mode probes + `DISCOVER-SUMMARY.txt` (key inventory of each response) |
| `coverage-report.csv/.html` | Final report |
| `anonymisation-map.csv` | Only with `-Anonymise`; reverses the mapping (sensitive) |

---

## 3. State model

`state.json` holds `{ Version, Created, LookbackDays, Anonymised, Rules[] }`. Each rule:

```
RuleID, Name, Status, Detail,
AlarmCount, AlarmIDs[], AlarmCandidates[{AlarmID, Date}], AlarmUsed, AlarmDate,
RuleBlocks, Logs, LogSourceTypes, AieCount, DxCount,
LlxFile, EchoUseCaseID, EchoTitle, EchoLogs,
Done { Alarms, Drilldown, Llx, Echo },  Notes[]
```

- **Statuses:** `Pending → NoAlarms | (LogsFound → LlxBuilt → Created | Exists | DryRun) | NoDrilldown | Failed`.
- **Resume:** `Done.*` flags gate each stage. `-Resume` reloads state and retries `Failed` rules from the first incomplete stage. The rule list is **not** re-queried on resume.
- `state.json` is saved after every rule-level change.

---

## 4. API formats: confirmed vs assumed

**Confirmed in a live lab (LogRhythm 7.x, Echo 2.x, Windows PowerShell 5.1):**

| # | Fact | Where in code |
|---|---|---|
| C1 | `GET https://<pm>:8501/lr-drilldown-cache-api/drilldown/{alarmId}` returns **202** with data. **It returns HTTP 400 `{"Data":null,"Error":{"Message":"Invalid request at route /drilldown/{id}."}}` unless `Content-Type: application/json` is sent, even on a GET with no body.** `Accept: application/json` alone is not enough. `/summary` behaves the same. | `Get-LrHeaders`, `Invoke-Api` (PS7 moves Content-Type to `-ContentType`) |
| C2 | Drilldown body: `Data.DrillDownResults{AlarmID, AIERuleID, AIERuleName, Status, RetryCount, LastDxTimeStamp, RuleBlocks[]}`. `RuleBlocks[].DrillDownLogs` is a **JSON string**. | `ConvertFrom-Drilldown` |
| C3 | Each drilldown log has: `logMessage` (raw log), `logSourceType` (type ID), `logSourceTypeName`, `logSourceId`, `logSourceName`, `logSourceHost*`, `ruleBlockNumber`, `sequenceNumber`, `normalDate`, `normalDateMin/Max`, `insertedDate`, `vendorMessageId`, `mpeRuleId/Name`, `commonEventId/Name`, `classification*`, entity/host/zone fields, `messageId`, `keyField`, `count`. The type ID may be missing; the name is then resolved (`Resolve-TypeIds`). | `$MsgKeys`, `$TypeIdKeys`, … |
| C4 | Alarm list `GET /lr-alarm-api/alarms?count=&offset=&orderby=dateInserted&dir=descending` → `{alarmsSearchDetails[{alarmId, alarmRuleName, alarmStatus, alarmDataCached ('Y'/'N'), associatedCases, entityName, dateInserted}], alarmsCount, statusCode, statusMessage, responseMessage}` | `Get-RecentAlarms` |
| C5 | Alarm detail `GET /lr-alarm-api/alarms/{id}` → `{alarmDetails{alarmRuleID, alarmId, alarmRuleName, alarmDate, dateInserted, eventCount, alarmDataCached, …}}` | Lab scripts |
| C6 | `GET /lr-alarm-api/alarms/{id}/events` returns the **AIE event** (its `logMessage` is `<aie v="1"><_0 … RuleBlockType NormalMsgDateLower/Upper …/><_ AIERuleID=…/></aie>`), **not** the raw logs. A possible future fallback: search for logs in that window. | – |
| C7 | The AIE rule ID differs from the alarm rule ID (e.g. AIE rule N → alarm rule N+1). Alarm names are `AIE: <AIE rule name>`, and the drilldown's `AIERuleName` has no `AIE: ` prefix. Matching is by name with the prefix ignored (`Get-NameKey`), and the drilldown `AIERuleID` is checked against the EMDB rule ID. | grouping in Main, `Get-RuleDrilldown` |
| C8 | Echo API at `https://<host>:33333` needed **no login** in the lab | `Connect-Echo` |
| C9 | Echo `POST /api/usecase`: **JSON:API → 415** (empty body). **Plain JSON `{title, description, timedelay}` → 201** with `{dateupdated, description, enabled, hosts[], id, logs[], pcaps[], timedelay, title}` | `New-EchoUseCase` (plain first) |
| C10 | Echo `POST /api/addLogs` accepts `[{owner_id, description, message, log, msg_src_id, msg_src_name, timestamp, customtime, play_order}]`, with `msg_src_id` = log source **type** ID. Echo shows the logs under that type and replays them through `Echo_<n>_<typeId>` log sources / `EchoTestEntity`. | `Get-EchoLogPayload` |
| C11 | Echo `POST /api/unpackLLXFile` (multipart, field `file`) accepts LLX-Tool output (HTTP 200) | `Invoke-EchoUnpack` |
| C12 | Echo `GET /api/usecases`, `GET /api/msgsourcetypes`, `GET /api/usecasesByIds/{id}` respond 200 | `Get-EchoUseCaseIndex`, `Initialize-EchoTypes`, verify |
| C13 | Replayed logs parsed identically to the originals (same MPE rule, common event, metadata) when the raw text was unaltered | – |

**Still assumed (lower risk):**

| # | Assumption | Where |
|---|---|---|
| A1 | `POST /api/deleteUseCases` takes `[id]` (fallback `{ids:[id]}`). Only used for rollback. | `Remove-EchoUseCase` |
| A2 | Echo login (when enabled) is `POST /api/login {username,password}` with a cookie or token | `Connect-Echo` |
| A3 | Exact shapes of `unpackLLXFile`, `usecasesByIds` and `msgsourcetypes` responses (the parsers tolerate variants; verify via `http\` captures) | respective functions |
| A4 | EMDB "enabled" = `AIERule.RecordStatus=1` (+ `Enabled`) + present in `AIERuleToEngine` | `Get-DefaultRulesQuery` |

## 5. Code map

| Area | Functions | Notes |
|---|---|---|
| Plumbing | `Write-Log`, `Save-Json`, `Read-Json`, `ConvertFrom-JsonSafe`, `Get-SafeName`, `Get-Prop`, `Find-Array`, `Get-NameKey`, `Join-Url` | `Get-Prop`/`Find-Array` give StrictMode-safe, case-insensitive lookup over several candidate names. **All parsing tolerance lives here.** |
| HTTP | `Invoke-Api`, `Protect-Text`, `Get-LrHeaders`, `Get-PlainToken` | Single choke point. 5.1: `WebException` body extraction, TLS 1.2, optional trust-all callback. 7: `-SkipHttpErrorCheck`, `-SkipCertificateCheck`. Writes the capture file. |
| Rules | `Invoke-Sql`, `Get-EmdbColumns`, `Get-DefaultRulesQuery`, `Get-EnabledRules` | `INFORMATION_SCHEMA` discovery, then a query. CSV alternative. `-RuleFilter` applied here. |
| Alarms | `Get-RecentAlarms`, `ConvertTo-DateSafe`, grouping in Main | Client-side grouping avoids depending on server-side name filters |
| Drilldown | `ConvertFrom-Drilldown`, `Get-RuleDrilldown` | Tries up to `-MaxAlarmsPerRule` newest alarms. Skips alarms whose `AIERuleID` ≠ rule ID. Records AIE vs DX counts. |
| Anonymiser | `Register-AnonTerms`, `Initialize-AnonTerms`, `Get-Alias`, `Get-AnonRegex`, `Protect-Logs` | Two passes per rule: learn terms, then one compiled regex (longest first, word-boundary-ish, 30 s timeout). Salted SHA-256 aliases. Map shared across rules. |
| LLX | `New-RuleLlx` | Writes `[{Message, MsgSourceTypeID, MsgSourceID, MPERuleID=-1}]` and calls `LLX-Tool.ps1 Compile`. LLX-Tool verifies by read-back. |
| Echo | `Connect-Echo`, `Invoke-Echo`, `Get-EchoUseCaseIndex`, `Initialize-EchoTypes`, `Invoke-EchoUnpack`, `New-EchoUseCase`, `Get-EchoLogPayload`, `Remove-EchoUseCase`, `Publish-RuleToEcho` | Manual multipart body (5.1 has no `-Form`). Rollback on addLogs failure. Title de-duplication via `-ExistingUseCase`. |
| Report | `Write-Report` | CSV + self-contained HTML (no external assets) |
| Discover | `Invoke-Discover`, `Get-KeyInventory` | Read-only probes. Writes the key inventory of each response, which is the fastest way to compare real vs assumed shapes. |

**Log ordering within a use case:** by rule block, then normal date, then the original index. This preserves sequence-rule order.

---

## 6. Security model

- **LogRhythm:** GET only. EMDB: SELECT only (`INFORMATION_SCHEMA` + rules query). The token never touches disk. It is held in memory as plain text only for header construction.
- **Echo writes:** create use case, add logs. **Delete** is limited to rolling back a use case created in the same `Publish-RuleToEcho` call. Existing use cases are never modified.
- **Captures:**
  - `Protect-Text` redacts JSON/form `password|passwd|pwd|token|access_token|secret|authorization` values and `Bearer` tokens.
  - Request headers matching `auth|token|cookie` are masked.
  - Binary bodies are logged as a size only.
- **Parsing:**
  - JSON via `ConvertFrom-Json`.
  - LLX via LLX-Tool's own NRBF reader (no BinaryFormatter; see its handover §5).
  - Regexes used on log text have timeouts.
- **TLS:** `-SkipCertificateCheck` is explicit opt-in. On 5.1 it installs a process-wide trust-all callback for the session, so document this to users.
- **Data at rest:** the run folder contains customer logs. `anonymisation-map.csv` is the de-anonymisation key.

---

## 7. Testing

```bash
# certificate for the mocks (any self-signed cert/key pair works)
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7 -subj "/CN=localhost"
python3 Tests/MockServers/mock_lr_echo.py --cert cert.pem --key key.pem --lr-port 18501 --echo-port 13333
```

```powershell
.\Tests\Test-EchoCoverage.ps1 -LrApiBaseUrl https://127.0.0.1:18501 -EchoBaseUrl https://127.0.0.1:13333
```

**Restart the mock before each run.** The tests assume a fresh Echo state.

**Mock scenarios** (rule IDs in the test CSV):

| Rule | Scenario |
|---|---|
| 1001 | Newest alarm has no drilldown (204); the older one has 5 Windows XML logs |
| 1002 | Two rule blocks, two log source types; data for the anonymiser |
| 1003 | AIECount 10 vs DXCount 3 (partial-logs warning) |
| 1004 | Only 204s (`NoDrilldown`) |
| 1005 | Echo addLogs returns 500 (rollback path) |
| 1006 | 1,200 alarms (paging) and 700 logs (`-MaxLogsPerRule`) |
| 1007 | Alarm older than the lookback |
| 1008 | Never fired (plus the rename-map test) |
| 1009 | Name collides with 1001 after stripping `AIE:`; must **not** steal 1001's alarms |
| 1010 | Drilldown logs carry only `logSourceTypeName`. The ID must be looked up from Echo's types. |
| 1011 | ePO-style syslog: an embedded `<Event>` element, a non-breaking space, a BOM character and trailing spaces. Must arrive in Echo byte-identical. |

The mock's Echo `unpackLLXFile` really decodes the uploaded LLX (minimal NRBF reader). Its `/mock/state` endpoint exposes what was created.

**When a real format is confirmed:**
1. Change the mock to emit and accept exactly that format.
2. Update the parser or payload function.
3. Run both test scripts.
4. Bump `$ScriptVersion` and record the change in §4.

---

## 8. Troubleshooting playbook

| Symptom (run.log / report) | Look at | Likely fix |
|---|---|---|
| Drilldown HTTP 400 *Invalid request at route* | Request headers in `http\*_drilldown_*.json` | `Content-Type: application/json` is missing (C1). On PS7 it must go via `-ContentType`. |
| `Â`, `ï»¿` or other mojibake in logs | Which stage first shows it | Some response was decoded as ISO-8859-1. Decode `RawContentStream` as UTF-8 (Windows PowerShell 5.1 default). |
| Logs truncated to an inner `<Event>…</Event>` | The `.txt` → `.llx` step | LLX-Tool < 1.1.1 *Auto* split mode. The pipeline uses JSON input; the lab script forces `-SplitMode Line`. |
| `No enabled AIE rules found` / wrong count | `discover/DISCOVER-SUMMARY.txt` column lists and query | Adjust `Get-DefaultRulesQuery`, or give the user a `-RulesQuery` |
| `Alarm API failed: HTTP 400` | `http/*_GET_lr-alarm-api_alarms.json` | A query parameter isn't supported (`orderby`/`dir`). Remove it in `Get-RecentAlarms`; paging still works because cutoff checks run per page. |
| Alarms fetched but every rule `NoAlarms` | `alarms.json` names vs rule names | Naming convention differs. Extend `Get-NameKey` or use `-RenameMapCsv`. |
| `drilldown had N rule block(s) but no raw logs` | The saved `drilldown/<rule>_<alarm>.json` | The raw-text key isn't in `$MsgKeys`. Add it. If `DrillDownLogs` is nested differently, adjust `ConvertFrom-Drilldown`. |
| `0 rule block(s)` with an obviously populated response | Same file | A nesting key isn't in `Find-Array`'s list. Note that one-element arrays must stay arrays (§9). |
| `alarm X skipped: it belongs to AIERuleID Y` on every alarm | Drilldown `AIERuleID` vs EMDB IDs | IDs differ in type or format (e.g. strings with leading zeros). Normalise in `Get-RuleDrilldown`. |
| `Echo login failed` | `http/*_POST_api_login.json` | Body field names or auth style. Adjust `Connect-Echo`. |
| `Echo use case create failed: HTTP 4xx` | `*_POST_api_usecase.json` (both formats are attempted) | Implement the B2-captured body in `New-EchoUseCase`. Check how the ID is returned. |
| `Echo addLogs failed` (use case rolled back) | `*_POST_api_addLogs.json` response | Field names/types in `Get-EchoLogPayload`, e.g. `owner_id` as a string, or `msg_src_id` meaning log source rather than type |
| Notes: `Echo LLX unpack failed` | `*_POST_api_unpackLLXFile.json` | Upload field name (`-EchoLlxUploadField`) or response keys in `Invoke-EchoUnpack` |
| Wrong log source type in Echo | Created logs vs `discover/echo-msgsourcetypes.json` | Map type IDs properly. Echo may want its own IDs; if so, add a lookup by name. |
| Use case exists but has no logs | addLogs capture | The endpoint accepted but ignored the body. Check the body shape against B3/B5. |
| Script error with a line number | `run.log` stack line | StrictMode issue on an unexpected shape. Usually `Get-Prop`/`Find-Array` returned `$null` or a scalar (§9). |

---

## 9. PowerShell pitfalls already hit (keep these in mind)

1. **One-element arrays unroll.** PowerShell 7's `ConvertFrom-Json` enumerates top-level arrays unless `-NoEnumerate`, and functions returning arrays unroll them. Hence `ConvertFrom-JsonSafe`, and `return , $value` in `Get-Prop`/`Find-Array`. A drilldown with exactly one rule block silently became "0 blocks" before this fix.
2. **Empty arrays become `$null`** when returned from a function without the comma (`return , @()`), and `.Count` on `$null` throws under `StrictMode 2`.
3. **`@(f)` around a function that returns `, $array` nests it.** Assign directly (`$x = Read-Json …`).
4. **`"$var:"` in a string** is parsed as a scope/drive reference. Use `"${var}:"`.
5. **`$a + $b` with a generic `List[object]`** can throw *Argument types do not match*. Use `List.Add` loops.
6. **Variable names are case-insensitive.** Never reuse a parameter name (`$Raw`, `$Mode`, …) as a local.
7. **Windows PowerShell 5.1:**
   - `Invoke-WebRequest` throws on 4xx/5xx; the body is read from `WebException.Response`.
   - No `-Form`, `-SkipCertificateCheck` or `-NoEnumerate`.
   - TLS 1.2 must be enabled explicitly.
   - The `Accept` header is dropped there (restricted-header risk).
8. **An assignment inside `$( (… = …); …)` also outputs its value**, which doubled a type ID into an array. Assign on its own line.
9. **HTTP:**
   - Windows PowerShell 5.1 decodes response text as ISO-8859-1 when no charset is sent, and encodes string request bodies the same way. Always decode and encode UTF-8 bytes yourself.
   - PowerShell 7 only sends `Content-Type` via `-ContentType`, not `-Headers`.
10. **`Add-Type` types persist per session.** LLX-Tool's C# types and the 5.1 trust-all helper can't be redefined without a new session.

---

## 10. Extension ideas (in priority order)

1. **Remove the remaining fallbacks** once A1–A3 are confirmed on a customer system.
2. **Bulk Importer output:** with a sample export ZIP (B8), add an `-Output Zip` mode that writes Echo packages to `bulkimport\Custom` instead of calling the API. This is useful where the Echo API isn't reachable.
3. **Rule-aware notes:** read the rule definition from the EMDB to flag log-source/entity filters, "not observed" blocks, thresholds and lists, which predict replay failures (README "Why a use case might not re-trigger").
4. **Server-side alarm filtering** (`alarmRuleName=` per rule) when the alarm volume is very large (C2).
5. **Fallback log source:** Alarm API events (A4) or a Data Indexer search when drilldown is unavailable.
6. **Match Echo description conventions** from an OOTB use case (D2).
7. **Replay validation loop:** run each new use case via `POST /api/execute/<id>`, then poll the Alarm API for a matching alarm. This turns "use case exists" into "use case proven to fire".
