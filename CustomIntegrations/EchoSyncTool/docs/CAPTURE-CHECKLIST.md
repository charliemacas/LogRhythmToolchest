# Capture checklist: confirming the undocumented formats

**Status:** the formats the pipeline depends on have been confirmed in a live lab (`HANDOVER.md` in the tool folder, §4, items C1–C13). Use this checklist when something behaves differently on **another LogRhythm or Echo version**, or to confirm the remaining assumptions (A1–A4: rollback delete, Echo login, some response shapes, the EMDB enabled-rules query). Each item says what it settles.

**Before sharing anything: redact** real usernames, hostnames, IPs, domains and raw log content. Replace them consistently (e.g. `jdoe` → `user1` everywhere). Remove tokens, cookies and passwords. Structure and field names matter; values don't.

---

## A. The quick way: Discover mode

```powershell
.\Build-EchoCoverage.ps1 -Mode Discover -SqlServer <PM> -LrApiBaseUrl https://<PM>:8501 `
    -EchoBaseUrl https://<echo>:33333 -EchoCredential (Get-Credential) -SkipCertificateCheck `
    -EchoProbeLlx .\any-export.llx
```

Send the redacted `discover\` folder. It covers A1–A7:

| # | Capture | Settles |
|---|---|---|
| A1 | EMDB column lists for `AIERule`, `AIERuleToEngine`, `AIEEngine` + the generated rules query + enabled count | Whether the built-in "enabled rules" query is right |
| A2 | `lr-alarms.json` (Alarm API list) | Alarm list wrapper and field names (`alarmId`, `alarmRuleName`, `dateInserted`); whether `orderby`/`dir` work |
| A3 | `lr-drilldown-<id>.json` | **Most important.** Drilldown nesting, whether `DrillDownLogs` is a JSON string or an array, raw-log and log-source-type field names, AIE/DX counts |
| A4 | `lr-alarm-events-<id>.json` | Whether the Alarm events endpoint carries raw logs (a possible fallback) |
| A5 | `echo-usecases.json`, `echo-usecase.json`, `echo-log_*.json`, `echo-host.json` | Echo list formats; whether FlaskRestless uses JSON:API |
| A6 | `echo-msgsourcetypes.json` | Field names for log source type ID and name |
| A7 | `echo-unpackLLXFile.json` (from `-EchoProbeLlx`) | Upload field name and the unpacker's response format |

---

## B. Echo UI actions, captured from browser developer tools

This is the most reliable way to learn Echo's write API, because the Echo web UI calls the same endpoints. Use a **test** use case you can delete afterwards.

1. Open the Echo web UI in Chrome or Edge, press **F12**, go to the **Network** tab and tick **Preserve log**.
2. Do each action below. For each, click the request in the Network list and copy:
   - **Headers**: Request URL, Method, `Content-Type`
   - **Payload**: the request body (for file uploads, the form field names)
   - **Response**: the response body and status code

   Right-click → **Copy → Copy as cURL (bash)** gets most of this in one go. Remove cookies and tokens before sharing.

| # | Action in the Echo UI | Request to capture | Settles |
|---|---|---|---|
| B1 | Log in | `POST /api/login` | Login body format; whether it returns a token or a cookie |
| B2 | **New Use Case** → fill title/description → Save | `POST /api/usecase` (or similar) | **Create format** (JSON:API vs plain JSON), required fields, how the new ID is returned |
| B3 | In that use case, add a log (pick a log source type, paste one raw log) → Save | `POST /api/addLog` or `/api/addLogs` | **Log fields**: `owner_id`, `msg_src_id` (is it the log source *type* ID?), `msg_src_name`, `message`/`description`, `timestamp`, `customtime`, `play_order` |
| B4 | **LLX File Browser** → Choose LLX File | `POST /api/unpackLLXFile` | Upload field name; response format |
| B5 | In the LLX browser, select logs → **Add to Use Case** | the request(s) it makes | Whether Echo adds LLX logs with a dedicated call, and what it sends |
| B6 | Open the use case (view its logs) | `GET /api/usecasesByIds/<id>` or similar | Read-back format for verification |
| B7 | Delete the test use case | `POST /api/deleteUseCases` | Delete body format (used only for rollback) |
| B8 | Export the test use case (before deleting it) | the downloaded ZIP | Use case package format: lets the tool also produce Bulk Importer ZIPs |

---

## C. LogRhythm samples (Postman is fine)

| # | Request | Settles |
|---|---|---|
| C1 | `GET https://<PM>:8501/lr-alarm-api/alarms?count=5&offset=0&orderby=dateInserted&dir=descending` | Same as A2. Also check that the newest alarm comes first. |
| C2 | `GET .../lr-alarm-api/alarms?count=5&alarmRuleName=<a rule name>` | Whether server-side filtering by rule name works (faster for large estates) |
| C3 | `GET https://<PM>:8501/lr-drilldown-cache-api/drilldown/<alarmId>` for an alarm whose drilldown shows logs in the Web Console | Same as A3. Ideally one from a **multi-block** rule, e.g. a sequence of two observed blocks. |
| C4 | The same for an alarm from a **threshold** or **unique values** rule | Whether all triggering logs are returned, or only a sample |
| C5 | Your known-good SQL for enabled AIE rules, and the enabled count shown in the Web Console | The `-RulesQuery` default |

Headers for all of them: `Authorization: Bearer <token>`.

---

## D. Files

| # | File | Settles |
|---|---|---|
| D1 | One `.llx` exported from the customer's LogRhythm | Use as `-TemplateLlx` (licence ID and version) |
| D2 | One existing **OOTB Echo use case**: its description text and one of its logs (B6 output is fine) | Matching Echo's description conventions (vertical, technology, AIE rule references) so generated use cases look native |
| D3 | `usecases.db` from a test Echo (optional) | Column-level truth for the `usecase` and `log` tables |

---

## What happens next

The captures map directly to small, isolated functions (`ConvertFrom-Drilldown`, `New-EchoUseCase`, `Get-EchoLogPayload`, `Invoke-EchoUnpack`, `Get-DefaultRulesQuery`; see `HANDOVER.md` §4–5). Corrections are usually a field-name list or a request-body shape. After updating, re-run `Tests\Test-EchoCoverage.ps1`, updating the mock in `Tests\MockServers\mock_lr_echo.py` to match the real format first.
