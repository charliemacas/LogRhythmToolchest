# Changelog

## 1.0.0

### Build-EchoCoverage.ps1 1.0.0
- Pipeline: enabled AIE rules → which fired in the lookback period (default 90 days) → one Echo use case per rule, built from its drilldown logs and **titled with the alarm name**.
- Read-only first pass with `-StopAfter Alarms`; `-DryRun`; `-Resume`; `-RuleFilter`; `-RenameMapCsv` for renamed rules; optional `-Anonymise`.
- Customer-friendly HTML report: headline numbers, one card per use case with sample logs, the reason each remaining rule has no use case, and the rules that didn't fire. Plus a CSV.
- Formats confirmed against a live system:
  - The drilldown API needs `Content-Type: application/json`, even on GET (it returns HTTP 400 without it).
  - Drilldown log fields: `logMessage`, `logSourceType`, `logSourceTypeName`, `ruleBlockNumber`, `sequenceNumber`, …
  - Echo `POST /api/usecase` takes plain JSON (JSON:API → 415).
  - Echo `POST /api/addLogs`.
- Log source type IDs are looked up from the type name when missing (Echo's list, then the EMDB).
- Alarms flagged `alarmDataCached = Y` are tried first.
- Responses are decoded as UTF-8 (Windows PowerShell 5.1 otherwise mangles non-ASCII, e.g. `Â`).

### LLX-Tool.ps1 1.1.1
- 1.1.1: *Auto* split mode only treats a file as Windows event XML when a line **starts** with `<Event`. Logs that embed `<Event>` elements (e.g. McAfee ePO) are no longer cut down.
- 1.1.0: JSON record input with per-message log source type, log source and MPE rule IDs.
- 1.0.0: View / Export / Compile / BulkCompile; own NRBF reader/writer (no BinaryFormatter); hardened against hostile files.

### Lab scripts
- `Lab/Invoke-LlxLabPoc.ps1`: a single alarm, stage by stage. Drilldown → LLX (content verified against the source) → Echo decodes the LLX.
- `Lab/New-EchoUseCaseFromLab.ps1`: creates the Echo use case from a lab run via the API, titled with the alarm name.
