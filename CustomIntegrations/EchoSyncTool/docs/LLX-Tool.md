# LLX-Tool

A single PowerShell script for working with LogRhythm **`.llx`** log message files.

| I want to…                                            | Mode          |
|-------------------------------------------------------|---------------|
| See what's inside an `.llx` file                      | `View`        |
| Get the log lines out of an `.llx` into a `.txt`      | `Export`      |
| Turn a `.txt` of log lines into an `.llx`             | `Compile`     |
| Turn a whole folder of `.txt` files into `.llx` files | `BulkCompile` |

It needs no LogRhythm software, makes no network connections and changes nothing except the output files you ask it to write.

---

## Contents

1. [Where the files are](#where-the-files-are)
2. [Requirements](#requirements)
3. [Setup (one-off)](#setup-one-off)
4. [Before you compile: the IDs LogRhythm needs](#before-you-compile-the-ids-logrhythm-needs)
5. [View an LLX file](#1-view-an-llx-file)
6. [Export an LLX file to TXT](#2-export-an-llx-file-to-txt)
7. [Compile a TXT file into an LLX file](#3-compile-a-txt-file-into-an-llx-file)
8. [Bulk-convert a folder of TXT files](#4-bulk-convert-a-folder-of-txt-files)
9. [How your TXT file is split into log messages](#how-your-txt-file-is-split-into-log-messages)
10. [Full parameter reference](#full-parameter-reference)
11. [Troubleshooting](#troubleshooting)
12. [Security notes](#security-notes)
13. [Getting more help](#getting-more-help)

---

## Where the files are

| File | Location |
|---|---|
| `LLX-Tool.ps1` | Repository root |
| This guide and the technical handover | `docs/LLX-Tool.md`, `docs/LLX-Tool-HANDOVER.md` |
| Sample logs to practise with | `Examples/sample-*.txt` |
| Self-test | `Tests/Test-LLXTool.ps1` |

Commands below are run from the tool folder, `CustomIntegrations\EchoSyncTool` (where `LLX-Tool.ps1` is). All example data is invented (`example.com` hosts, documentation-only IP ranges).

---

## Requirements

- Windows with **Windows PowerShell 5.1** (built into Windows 10/11 and Server 2016+) **or PowerShell 7+** on any OS
- Permission to run local scripts (see Setup)

---

## Setup (one-off)

1. **Get the files**: clone the [LogRhythmToolchest](../../../README.md) repository or download it as a zip and extract it, e.g. to `C:\Tools\LogRhythmToolchest-main`.

2. **Open PowerShell** in that folder:

   ```powershell
   cd C:\Tools\LogRhythmToolchest-main\CustomIntegrations\EchoSyncTool
   ```

3. **Unblock the files.** Windows marks downloaded files as untrusted:

   ```powershell
   Get-ChildItem -Recurse | Unblock-File
   ```

4. **Only if scripts are blocked:** allow them in this PowerShell window only (`Get-ExecutionPolicy -List` shows the policy; the common `RemoteSigned` needs nothing). This doesn't change any system setting and wears off when you close the window:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```

   > If your organisation only allows signed scripts, ask your administrator to sign `LLX-Tool.ps1` with your code-signing certificate.

5. **Run the self-test.** It takes a few seconds and confirms everything works on your machine:

   ```powershell
   .\Tests\Test-LLXTool.ps1
   ```

   You should see `All 19 tests passed`.

---

## Before you compile: the IDs LogRhythm needs

Every `.llx` file carries a few identifiers. **Viewing and exporting don't need any of them**; they only matter when you **create** `.llx` files.

| Value             | What it is                                                         | Default if not given        |
|-------------------|--------------------------------------------------------------------|-----------------------------|
| `MsgSourceTypeID` | The LogRhythm **log source type** the logs belong to. **Most important.** | `0` (with a warning)        |
| `MsgSourceID`     | The specific LogRhythm log source                                  | `0`                         |
| `LicenseID`       | Your LogRhythm licence ID                                          | `0` (with a warning)        |
| `SubmittedBy`     | Name shown as the submitter                                        | `LogRhythm Administrator`   |
| `MPERuleID`       | MPE rule the message is matched to; `-1` means none               | `-1`                        |

### The easy way: use a template

If you have **any `.llx` file exported from your own LogRhythm system**, use it as a template. The tool copies all of the values above from it:

```powershell
.\LLX-Tool.ps1 Compile .\mylogs.txt -TemplateLlx .\from-my-logrhythm.llx
```

To see a template's values first:

```powershell
.\LLX-Tool.ps1 View .\from-my-logrhythm.llx -Summary
```

### The manual way

Give the values directly:

```powershell
.\LLX-Tool.ps1 Compile .\mylogs.txt -MsgSourceTypeID <TypeID> -MsgSourceID <SourceID> -LicenseID <LicenseID>
```

Your LogRhythm administrator can look these up. Anyone with read access to the LogRhythm EMDB database can list log source types with:

```sql
SELECT MsgSourceTypeID, Name FROM LogRhythmEMDB.dbo.MsgSourceType ORDER BY Name;
```

You can use a template and override individual values. Explicit values always win:

```powershell
.\LLX-Tool.ps1 Compile .\mylogs.txt -TemplateLlx .\from-my-logrhythm.llx -MsgSourceTypeID <DifferentTypeID>
```

---

## 1. View an LLX file

```powershell
.\LLX-Tool.ps1 View .\export.llx
```

This shows the file header (licence ID, submitter, date, message count) and then each message.

**Useful variations**

```powershell
# Open the messages in a sortable, filterable window (Windows only)
.\LLX-Tool.ps1 View .\export.llx -GridView

# Windows event logs: add EventID, Provider, Channel, Computer, TimeCreated, EventData columns
.\LLX-Tool.ps1 View .\export.llx -ExpandEventXml

# One summary line per file, for a whole folder
.\LLX-Tool.ps1 View D:\LLX -Recurse -Summary

# Search messages
.\LLX-Tool.ps1 View .\export.llx | Where-Object Message -match 'Failed password'

# Save what you're viewing to a spreadsheet-friendly CSV
.\LLX-Tool.ps1 View .\export.llx -ExpandEventXml | Export-Csv .\export.csv -NoTypeInformation
```

---

## 2. Export an LLX file to TXT

```powershell
.\LLX-Tool.ps1 Export .\export.llx
```

This creates `export.txt` next to the original, one log message per line (UTF-8).

**Choose where it goes**

```powershell
.\LLX-Tool.ps1 Export .\export.llx -OutputPath D:\Out\export.txt
```

**Export a whole folder** (subfolders are mirrored with `-Recurse`):

```powershell
.\LLX-Tool.ps1 Export D:\LLX -Recurse -OutputPath D:\TXT
```

> If any message spans several lines, messages are separated by a **blank line** and you'll see a warning. To turn that file back into an `.llx`, compile it with `-SplitMode BlankLine`.

---

## 3. Compile a TXT file into an LLX file

1. Put your log lines in a text file, **one log message per line**. Blank lines are ignored. (For Windows event XML or multi-line logs, see [How your TXT file is split](#how-your-txt-file-is-split-into-log-messages).)
2. Run:

   ```powershell
   .\LLX-Tool.ps1 Compile .\mylogs.txt -TemplateLlx .\from-my-logrhythm.llx
   ```

3. `mylogs.llx` is created next to `mylogs.txt`. The tool reads the new file back to check it before reporting success.

**Try it with the bundled example:**

```powershell
.\LLX-Tool.ps1 Compile .\Examples\sample-syslog.txt -MsgSourceTypeID 1 -LicenseID 1
.\LLX-Tool.ps1 View .\Examples\sample-syslog.llx
```

**Other options**

```powershell
# Choose the output name
.\LLX-Tool.ps1 Compile .\mylogs.txt -TemplateLlx .\t.llx -OutputPath D:\Out\firewall-sample.llx

# Overwrite an existing .llx
.\LLX-Tool.ps1 Compile .\mylogs.txt -TemplateLlx .\t.llx -Force

# Add a comment to the file header
.\LLX-Tool.ps1 Compile .\mylogs.txt -TemplateLlx .\t.llx -Comments 'Sample for new MPE rule'
```

> **First time?** Compile a small file and load it into LogRhythm to confirm your system accepts it before converting a large batch.

### Logs from several log source types in one file (JSON input)

A `.txt` gives every message the same log source type. If one `.llx` needs logs from several types (for example, the logs behind one AIE alarm), compile a `.json` file instead. It's an array of records, and only `Message` is required:

```json
[
  { "Message": "<raw log 1>", "MsgSourceTypeID": 1000030, "MsgSourceID": 12 },
  { "Message": "<raw log 2>", "MsgSourceTypeID": 1000301, "MPERuleID": -1 },
  { "Message": "<raw log 3>" }
]
```

```powershell
.\LLX-Tool.ps1 Compile .\records.json -TemplateLlx .\from-my-logrhythm.llx
```

Missing IDs fall back to `-TemplateLlx` or the parameters. `.json` files are detected automatically; for another extension add `-JsonInput`.

---

## 4. Bulk-convert a folder of TXT files

Every `.txt` in the folder becomes its own `.llx` with the same name:

```powershell
.\LLX-Tool.ps1 BulkCompile D:\Samples -TemplateLlx .\from-my-logrhythm.llx
```

**Include subfolders and write everything to a separate folder** (the subfolder layout is kept):

```powershell
.\LLX-Tool.ps1 BulkCompile D:\Samples -Recurse -OutputPath D:\LLX -TemplateLlx .\from-my-logrhythm.llx
```

What happens:

- Each output is listed with its message count, followed by `Compiled N file(s).`
- Empty `.txt` files are skipped with a warning.
- A file that fails is reported and the rest carry on.
- Existing `.llx` files are **not** overwritten unless you add `-Force`.
- Use `-Filter '*.log'` to pick up files with a different extension.

---

## How your TXT file is split into log messages

Choose with `-SplitMode` (works for both `Compile` and `BulkCompile`):

| `-SplitMode`        | Use it for                                     | Behaviour |
|---------------------|------------------------------------------------|-----------|
| `Auto` *(default)*  | Most files                                      | If lines start with Windows `<Event …>` XML, each event is one message, flattened onto one line as LogRhythm stores it. Otherwise each non-blank line is one message, so logs that merely *contain* `<Event>` elements (e.g. McAfee ePO) stay whole. Trailing spaces are trimmed. |
| `Line`              | Syslog, CSV-style, one-event-per-line logs      | Each non-blank line is one message. |
| `BlankLine`         | Multi-line logs (stack traces, etc.)            | Messages are separated by one or more blank lines. See `Examples\sample-multiline.txt`. |
| `Regex`             | Anything else                                   | Each match of `-SplitPattern` is one message. |

Examples:

```powershell
.\LLX-Tool.ps1 Compile .\Examples\sample-windows-events.txt -MsgSourceTypeID 1 -LicenseID 1           # Auto finds 2 events
.\LLX-Tool.ps1 Compile .\Examples\sample-multiline.txt -SplitMode BlankLine -MsgSourceTypeID 1 -LicenseID 1
.\LLX-Tool.ps1 Compile .\app.txt -SplitMode Regex -SplitPattern '(?m)^\d{4}-\d{2}-\d{2} .*$' -TemplateLlx .\t.llx
```

Text files can be UTF-8, UTF-16 or ANSI. The encoding is detected automatically.

---

## Full parameter reference

| Parameter            | Modes                     | Description |
|----------------------|---------------------------|-------------|
| `Mode` (1st value)   | all                       | `View`, `Export`, `Compile` or `BulkCompile` |
| `Path` (2nd value)   | all                       | File(s), folder(s) or wildcards. Accepts pipeline input. |
| `-OutputPath`        | Export, Compile, BulkCompile | Output file (single input) or folder (several inputs, or BulkCompile). Default: next to the input. |
| `-Recurse`           | all                       | Include subfolders. Output keeps the subfolder layout. |
| `-Filter`            | all                       | File pattern for folder input. Default `*.llx` (View/Export) or `*.txt` (Compile/BulkCompile). |
| `-Force`             | Export, Compile, BulkCompile | Overwrite existing output files. |
| `-TemplateLlx`       | Compile, BulkCompile      | Copy IDs and settings from an existing `.llx`. |
| `-MsgSourceTypeID`   | Compile, BulkCompile      | Log source type ID. |
| `-MsgSourceID`       | Compile, BulkCompile      | Log source ID. |
| `-LicenseID`         | Compile, BulkCompile      | LogRhythm licence ID. |
| `-SubmittedBy`       | Compile, BulkCompile      | Submitter name. Default `LogRhythm Administrator`. |
| `-Comments`          | Compile, BulkCompile      | Free-text comment in the file header. |
| `-MPERuleID`         | Compile, BulkCompile      | Default `-1` (none). |
| `-SplitMode`         | Compile, BulkCompile      | `Auto`, `Line`, `BlankLine`, `Regex`. |
| `-SplitPattern`      | Compile, BulkCompile      | Regular expression for `-SplitMode Regex`. |
| `-JsonInput`         | Compile, BulkCompile      | Treat input as JSON records (automatic for `.json`). |
| `-AssemblyVersion`   | Compile, BulkCompile      | LogRhythm component version written into the file. Default `7.25.0.1000`. `-TemplateLlx` sets it automatically. |
| `-ExpandEventXml`    | View                      | Add Windows event columns. |
| `-GridView`          | View                      | Show results in a window (Windows). |
| `-Summary`           | View                      | One line per file. |
| `-Raw`               | View                      | Full decoded structure as JSON, for diagnostics. |
| `-MaxDecompressedMB` | View, Export, template    | Safety limit for very large or malicious files. Default 1024. |

Built-in help is also available:

```powershell
Get-Help .\LLX-Tool.ps1 -Full
```

---

## Troubleshooting

| Message / symptom | What it means | Fix |
|---|---|---|
| `...cannot be loaded because running scripts is disabled` | PowerShell execution policy | Run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` in the same window, or have the script signed. |
| `...is not digitally signed` / `cannot be loaded` after download | File is blocked | `Get-ChildItem -Recurse \| Unblock-File` |
| `already exists (use -Force to overwrite)` | Output file exists | Add `-Force`, or choose a different `-OutputPath`. |
| `No -MsgSourceTypeID or -TemplateLlx given` warning | The file will carry log source type 0 | Add `-TemplateLlx` or `-MsgSourceTypeID`. |
| `Not an LLX file` | Input isn't a LogRhythm `.llx` | Check you picked the right file. |
| `...is truncated or corrupt` | File is incomplete (e.g. interrupted copy) | Get a fresh copy. The tool shows whatever it could recover. |
| `File expands beyond the -MaxDecompressedMB limit` | Unusually large (or malicious) file | If you trust the file, raise the limit, e.g. `-MaxDecompressedMB 4096`. |
| `no log messages found, skipped` | The `.txt` is empty or only blank lines | Check the file content / `-SplitMode`. |
| Wrong number of messages from a `.txt` | Split mode doesn't suit the file | See [How your TXT file is split](#how-your-txt-file-is-split-into-log-messages). Check the count with `View ... -Summary`. |
| Windows events come out as many small messages | File uses `-SplitMode Line` | Use the default `Auto`, or check every event has a closing `</Event>`. |
| LogRhythm rejects or ignores a compiled file | IDs or version don't match your system | Recompile with `-TemplateLlx` pointing at an `.llx` from **your** LogRhythm. If it still fails, see [Getting more help](#getting-more-help). |
| `-GridView` shows nothing / warns | `Out-GridView` isn't available (Server Core, Linux) | Use the normal console view or pipe to `Export-Csv`. |
| Changes to the script don't take effect | PowerShell caches the compiled helper code per window | Close PowerShell and open a new window. |

**Re-run the self-test** at any point: `.\Tests\Test-LLXTool.ps1`. Add `-KeepFiles` to inspect what it produced.

---

## Security notes

- **Reading `.llx` files is safe even if they come from an untrusted source.** The tool decodes the file format itself and **never** uses .NET's `BinaryFormatter`, which can run code hidden in a file.
- Malformed or hostile files are rejected with a clear message. There are limits on size, nesting depth and element counts, and decompression bombs are stopped by `-MaxDecompressedMB`.
- Windows event XML is parsed with DTDs and external entities disabled.
- User-supplied split patterns run with a 60-second timeout.
- No network access, no registry changes, no elevated rights needed.
- It writes only the output files you ask for, and won't overwrite existing files without `-Force`.
- `.llx` files contain real log data. Handle them, and anything you export from them, under your organisation's data-handling rules.

---

## Getting more help

`docs/LLX-Tool-HANDOVER.md` explains exactly how the file format and the script work. If something isn't working:

1. Run `.\Tests\Test-LLXTool.ps1` and note any `FAIL` lines.
2. Re-run the failing command with `-Verbose` and copy the full output.
3. Note your PowerShell version: `$PSVersionTable.PSVersion`.
4. Give `docs/LLX-Tool-HANDOVER.md`, `LLX-Tool.ps1` and the above to your support contact or an AI assistant.

   **Remove or redact real log content first.** Any `.llx` or `.txt` you share may contain hostnames, usernames and IP addresses.
