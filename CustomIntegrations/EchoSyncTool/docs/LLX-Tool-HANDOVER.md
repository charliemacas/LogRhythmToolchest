# LLX-Tool: Technical Handover

**Audience:** engineers and AI coding assistants supporting or extending `LLX-Tool.ps1`.
**Goal:** give enough detail to diagnose user problems and change the code safely without reverse-engineering the format again.
**User documentation:** see `docs/LLX-Tool.md`.

---

## 0. TL;DR for an AI assistant picking this up

- `LLX-Tool.ps1` is one self-contained PowerShell script with 4 modes: `View`, `Export`, `Compile`, `BulkCompile`.
- A LogRhythm `.llx` is **GZip( MS-NRBF( `SC.Message.Export.LogMessageCollection` ) )**. MS-NRBF is the .NET BinaryFormatter wire format.
- The script embeds a C# reader/writer for that format, compiled at runtime with `Add-Type`. **It never calls `BinaryFormatter`**, and must not. That is a hard security requirement (§7).
- The writer reproduces LogRhythm's output **byte for byte** in the uncompressed payload. It was verified against a genuine LogRhythm 7.25 export (§6).
- Constraints when editing: the C# must stay **C# 5** (Windows PowerShell 5.1 compiles it with the old `csc`), and the PowerShell must stay **5.1-compatible** (§8).
- First diagnostic step for any user issue: run `Tests\Test-LLXTool.ps1`, then reproduce with `-Verbose`. The playbook is in §9.
- **Never ask a user to send real `.llx` or log content.** Ask for redacted samples or `View -Summary` output instead.

---

## 1. Status and provenance

| Item | State |
|---|---|
| Version | 1.1.1 (1.1.0: JSON record input with per-message log source IDs; 1.1.1: *Auto* split only treats a file as Windows event XML when a line **starts** with `<Event`, so formats that embed `<Event>` elements, such as McAfee ePO, stay intact) |
| Format derived from | Reverse-engineering a genuine LogRhythm 7.25 `.llx` export (assembly `scvbcomn, Version=7.25.0.1000`) |
| Writer fidelity | Uncompressed payload byte-identical to the genuine file when given the same inputs (GUID, timestamp, IDs, text) |
| Independent validation | Generated files (1, 2, 40, 500 and 50,000 messages) deserialised by Microsoft's `BinaryFormatter` into stub classes with identical type/field names, in an isolated test harness only |
| Self-test | 19 automated tests (`Tests\Test-LLXTool.ps1`), all passing on PowerShell 7.4 |
| Hostile-input testing | GZip bomb, 5,000-level nesting, 2-billion-element arrays, null-run overflow, non-LLX input, XXE payload, 2,000 random byte-mutation fuzz cases: all rejected cleanly, no hangs or crashes |
| **Not yet verified** | (a) Execution under **Windows PowerShell 5.1** (written for it but only run on 7.4). (b) **Import of a generated file into a live LogRhythm system.** (c) Behaviour with LogRhythm versions other than 7.25. |

If a user reports a problem, check first whether it falls in one of the "not yet verified" areas.

---

## 2. Folder layout

```
LLX-Tool.ps1                  Script (PowerShell + embedded C#), tool folder root
docs/LLX-Tool.md              User guide
docs/LLX-Tool-HANDOVER.md     This document
Examples/*.txt                Synthetic inputs (no real data)
Tests/Test-LLXTool.ps1        Self-test (exit code 0 = pass)
```

---

## 3. File format specification

### 3.1 Outer layer: GZip (RFC 1952)

| Offset | Bytes | Value written by LogRhythm / this tool |
|---|---|---|
| 0 | 2 | `1F 8B` magic |
| 2 | 1 | `08` (deflate) |
| 3 | 1 | `08` FLG = FNAME |
| 4 | 4 | MTIME, Unix seconds (UTC) = `DateSubmitted` |
| 8 | 1 | XFL `00` |
| 9 | 1 | OS `0B` (NTFS) |
| 10 | n+1 | Zero-terminated original filename: `SubmittedLogs_<LicenseID>_<yyyyMMdd>_<HHmmssff>.llx.txt` (time = DateSubmitted, UTC) |
| … | … | Raw deflate stream |
| end-8 | 4 | CRC32 of uncompressed payload (LE) |
| end-4 | 4 | ISIZE (LE) |

The genuine file used deflate level 9. The tool uses .NET `CompressionLevel.Optimal`, so the **compressed** bytes differ, but the **decompressed payload** is identical. Readers (including LogRhythm, which uses GZipStream) don't care about the compression level.

The reader also accepts an un-gzipped NRBF payload (`Gz.Expand` passes non-GZip data through).

### 3.2 Inner layer: MS-NRBF object graph

Logical model (field order matters; it is the serialised member order):

```
SC.Message.Export.LogMessageCollection          (assembly scvbcomn)
    MsgsHashtable : System.Collections.Hashtable   Guid -> LogMessage
    LicenseID     : Int32
    SubmittedBy   : String
    Comments      : String
    DateSubmitted : DateTime

SC.Message.Export.LogMessage                    (assembly scvbcomn)
    Version         : Int32    always 1 in observed data
    MsgSourceID     : Int32
    MsgSourceTypeID : Int32
    MPERuleID       : Int32    -1 = unassigned
    Message         : String   raw log text (single line for Windows event XML)
    Comments        : String   "" in observed data
    Status          : Int32    0 in observed data
```

**Exact record sequence** written by `LlxWriter.BuildPayload` (n = message count). Object IDs are deterministic:

| # | Record (type byte) | Object ID | Notes |
|---|---|---|---|
| 1 | SerializationHeader (`00`) | – | RootId=1, HeaderId=-1, Major=1, Minor=0 |
| 2 | BinaryLibrary (`0C`) | 2 | `scvbcomn, Version=7.25.0.1000, Culture=neutral, PublicKeyToken=null` |
| 3 | ClassWithMembersAndTypes (`05`) | 1 | LogMessageCollection. BinaryTypes `03 00 01 01 00`; AdditionalInfo: `"System.Collections.Hashtable"`, Int32(`08`), DateTime(`0D`); LibraryId 2 |
| 3a | ├ MsgsHashtable | | MemberReference (`09`) → 3 |
| 3b | ├ LicenseID | | Int32 inline |
| 3c | ├ SubmittedBy | 4 | BinaryObjectString (`06`) |
| 3d | ├ Comments | 5 | BinaryObjectString, or MemberReference if same value already written |
| 3e | └ DateSubmitted | | Int64: `Ticks | (Kind << 62)`, Kind=1 (UTC) → `0x40…` |
| 4 | SystemClassWithMembersAndTypes (`04`) | 3 | Hashtable: LoadFactor(Single), Version(Int32), Comparer(SystemClass IComparer), HashCodeProvider(SystemClass IHashCodeProvider), HashSize(Int32), Keys(ObjectArray), Values(ObjectArray) |
| 4a | values | | `0.72f`, version, ObjectNull, ObjectNull, hashSize, ref 6, ref 7 |
| 5 | ArraySingleObject (`10`) | 6 | Keys: n × MemberReference → 8 … 8+n-1 |
| 6 | ArraySingleObject (`10`) | 7 | Values: n × MemberReference → 8+n … 8+2n-1 |
| 7 | SystemClassWithMembersAndTypes (`04`) | 8 | First `System.Guid`: members `_a`.._k`, all Primitive; types Int32, Int16, Int16, 8 × Byte; 16 bytes = `Guid.ToByteArray()` |
| 8 | ClassWithId (`01`) | 9 … 8+n-1 | Remaining Guids, MetadataId 8 |
| 9 | ClassWithMembersAndTypes (`05`) | 8+n | First LogMessage. BinaryTypes `00 00 00 00 01 01 00`; primitive types all Int32; LibraryId 2 |
| 10 | ClassWithId (`01`) | 8+n+1 … | Remaining LogMessages, MetadataId 8+n |
| – | Strings inside messages | 8+2n … | BinaryObjectString, **deduplicated by value**: repeats become MemberReference |
| 11 | MessageEnd (`0B`) | – | |

This mirrors BinaryFormatter's breadth-first emission order. NRBF permits forward references, so ordering is not semantically required, but matching it keeps output byte-identical to LogRhythm's.

**Hashtable sizing.** `HashtableSizing()` simulates a default `System.Collections.Hashtable` growing from size 3, load factor 0.72, expanding to `GetPrime(2 × size)` using the .NET `HashHelpers` prime table, and increments `version` per insert and per rehash. On deserialisation .NET re-buckets from the Keys/Values arrays, so an imperfect HashSize/Version would not break loading. The simulation exists for fidelity.

**String deduplication.** BinaryFormatter dedups by *reference*. The genuine file shows `""` written once and referenced again. The writer dedups by *value*, which is valid NRBF and reproduces the observed output.

**Message order.** The reader preserves on-disk order of the Keys/Values arrays. The writer writes messages in input order. LogRhythm-generated files are in Hashtable bucket order, which looks random.

### 3.3 Fields with uncertain semantics

| Field | Observed | Tool behaviour | Risk |
|---|---|---|---|
| `Version` | 1 | Always 1 | Low |
| `Status` | 0 | Always 0 | Unknown meaning; may be a review/submit state |
| `MessageComments` | "" | Always "" | Low |
| `LicenseID` | Customer's licence ID | From template/param, default 0 | LogRhythm *may* validate it. Use `-TemplateLlx`. |
| Assembly version | 7.25.0.1000 | From template/param | Assembly is not strong-named (`PublicKeyToken=null`), so .NET normally ignores the version when binding. Low risk. |

---

## 4. Script architecture

### 4.1 Execution flow

```
param()  ->  begin { StrictMode; capture caller's ErrorAction as $ReportEA; ErrorActionPreference=Stop
                     Add-Type C# (once per session, guarded by 'LlxTool.Nrbf' -as [type])
                     define helper functions
                     if Compile/BulkCompile: build $compileSettings (defaults <- template <- explicit params) }
         ->  process { collect -Path values (pipeline-friendly) }
         ->  end { switch ($Mode) { View | Export | Compile/BulkCompile } }
```

### 4.2 Embedded C# (`namespace LlxTool`)

| Type | Role |
|---|---|
| `Nrbf` | Read-only MS-NRBF parser. `IsNrbf(byte[])` sniffs the header. `Parse(byte[])` returns a `ParseResult { Root, Truncated, FirstLibrary }`. Builds an ID→object map, then `Resolve()` converts it into plain values: `OrderedDictionary` for objects (with `__type`), `object[]` for arrays, `Guid`, `DateTime`, primitives. Hashtables become `{ __type, __entries: [ {Key, Value} ] }`. |
| `Gz` | `Expand(byte[], maxBytes)`: GZip decompression with a hard output cap. Passes non-GZip input through. |
| `LlxMessage` | DTO for one message (Id, Version, MsgSourceID, MsgSourceTypeID, MPERuleID, Message, Comments, Status). |
| `LlxWriter` | `FromLines()` bulk-creates messages. `BuildPayload()` writes NRBF per §3.2. `GZip()` writes the RFC 1952 container with FNAME and its own CRC32. |

All NRBF record types 0–17 are supported by the reader (including BinaryArray, null runs and primitive arrays), so `-Raw` can dump other serialised objects. Non-LLX root types produce an error in `View`/`Export`.

### 4.3 PowerShell helpers

| Function | Purpose |
|---|---|
| `Expand-LlxBytes` | `Gz.Expand` with the `-MaxDecompressedMB` cap |
| `Read-LlxFile` | File → `{ Header, Messages[], Library, Truncated, Root }`. Throws on non-LLX. |
| `Resolve-InputFiles` | Expands files, folders (`-Filter`, `-Recurse`) and wildcards to `{ File, Base }`. `Base` is used to mirror subfolders. |
| `Get-OutputFile` | Chooses the output path. Next to the input by default. If `-OutputPath` has no extension, already exists as a folder, there are several inputs, or the mode is BulkCompile, it is treated as a folder. |
| `Save-Bytes` | Refuses to overwrite without `-Force`, creates folders, writes via `WriteAllBytes` (not atomic: an interrupted write can leave a partial file, which the post-write verification reports). |
| `ConvertFrom-TextBytes` | Encoding detection: BOMs, UTF-16 heuristic, strict UTF-8, Windows-1252 fallback. |
| `Split-LogText` | Implements `-SplitMode`. Auto = Event-XML extraction when a line starts with `<Event` (1.1.1), else Line. Event mode collapses `>\s+<`. Line mode trims trailing whitespace. |
| `Get-EventXmlFields` | Safe XML parse of Windows event XML for `-ExpandEventXml` |
| `ConvertTo-SafeXml` | `XmlReader` with `DtdProcessing=Prohibit` and `XmlResolver=$null` |
| `New-SafeRegex` | Regex with a 60 s match timeout |
| `Get-ErrorText` | Innermost exception message, for user-friendly errors |
| `ConvertTo-PSValue` | `OrderedDictionary` tree → PSCustomObject (for `-Raw` JSON) |

### 4.4 Mode behaviour

- **View** prints a coloured header per file (`Write-Host`, stream 6) and emits `LlxTool.Message` objects. The default display set is narrowed with `Update-TypeData`. `-Summary`, `-Raw` and `-GridView` are alternatives.
- **Export** writes UTF-8 without BOM, CRLF, one message per line. If any message contains CR/LF, messages are separated by a blank line and a warning recommends `-SplitMode BlankLine` for recompiling.
- **Compile / BulkCompile**:
  1. read and decode the text
  2. split it into messages
  3. `FromLines`
  4. `BuildPayload`
  5. `GZip` (inner name and MTIME from the current UTC time)
  6. `Save-Bytes`
  7. **verify** by re-parsing and comparing the message count
  8. emit `{ Source, Output, Messages, MsgSourceTypeID, LicenseID }`

  BulkCompile requires folder input and always treats `-OutputPath` as a folder.

### 4.5 Settings precedence (Compile)

`built-in defaults` → `-TemplateLlx` (LicenseID, SubmittedBy, assembly string, and MsgSourceID / MsgSourceTypeID / MPERuleID of the template's **first** message) → explicit parameters (checked via `$PSBoundParameters`) → `-AssemblyVersion`.

### 4.6 Error handling

- Per-file failures: `Write-Error -ErrorAction $ReportEA`, where `$ReportEA` is the caller's preference captured before the script sets `Stop`. Processing continues with the next file unless the caller passed `-ErrorAction Stop`.
- Warnings: missing IDs, empty inputs, truncated files, multi-line export, missing `Out-GridView`.

---

## 5. Security model

**Threat:** `.llx` files may come from customers or other untrusted sources. The format is .NET BinaryFormatter, a well-known remote-code-execution vector.

| Control | Implementation |
|---|---|
| No deserialisation gadgets | Custom parser; no `BinaryFormatter`, `SoapFormatter`, `NetDataContractSerializer` or type loading. Type names are treated as strings only. |
| Decompression bomb | `Gz.Expand` stops at `-MaxDecompressedMB` (default 1024, max 8192) |
| Stack exhaustion | Inline record nesting capped at 200 (`MaxDepth`); `Resolve` depth capped at 64 |
| Memory exhaustion | Array lengths ≤ 10,000,000 (`MaxElements`), rank ≤ 32, class members ≤ 10,000, null runs bounded by declared array size, resolved-node budget 20,000,000 |
| Graph cycles / DAG blow-up | Cycle guard in `Resolve` plus node budget |
| XXE / entity expansion | `ConvertTo-SafeXml`: DTD prohibited, null resolver |
| ReDoS | All regexes built with a 60 s timeout |
| File-system safety | Writes only to computed output paths; no deletes; no overwrite without `-Force` |
| No network, registry or elevation | None used |

**Hard rule for future changes:** don't add any code path that hands file-derived bytes to a .NET deserialiser. Use the BinaryFormatter test harness (§6.3) only in an isolated test environment, and never ship it.

---

## 6. Testing

### 6.1 Self-test

```powershell
.\Tests\Test-LLXTool.ps1            # exit 0 = pass
.\Tests\Test-LLXTool.ps1 -KeepFiles # keep temp output
```

The 17 tests cover:
- the structure checks in §3.1–3.2
- header and field values
- lossless TXT round trip
- Event-XML auto-detection and flattening
- BlankLine and Regex split modes
- Unicode
- template precedence
- missing-ID warnings
- overwrite protection
- BulkCompile recursion and empty-file skipping
- folder export
- non-LLX rejection
- truncation warning
- 20k-line performance

### 6.2 Byte-identity check (needs a genuine `.llx`)

Parse a genuine file, feed its exact values back through `BuildPayload`, then compare:

```powershell
$null = & .\LLX-Tool.ps1 View .\genuine.llx -Summary          # loads LlxTool types
$raw  = [LlxTool.Gz]::Expand([IO.File]::ReadAllBytes("$PWD\genuine.llx"), 1GB)
$res  = [LlxTool.Nrbf]::Parse($raw); $root = $res.Root
$list = New-Object 'System.Collections.Generic.List[LlxTool.LlxMessage]'
foreach ($e in $root['MsgsHashtable']['__entries']) {
  $v = $e['Value']; $m = New-Object LlxTool.LlxMessage
  $m.Id = $e['Key']; $m.Version = $v['Version']; $m.MsgSourceID = $v['MsgSourceID']
  $m.MsgSourceTypeID = $v['MsgSourceTypeID']; $m.MPERuleID = $v['MPERuleID']
  $m.Message = $v['Message']; $m.Comments = $v['Comments']; $m.Status = $v['Status']; $list.Add($m) }
$built = [LlxTool.LlxWriter]::BuildPayload($res.FirstLibrary, $root['LicenseID'], $root['SubmittedBy'],
          $root['Comments'], $root['DateSubmitted'], $list)
[Linq.Enumerable]::SequenceEqual($raw, $built)   # True for single-message files
```

For multi-message genuine files, expect a difference unless entries are re-ordered to match the original Hashtable order and HashSize/Version are copied. That difference is benign.

### 6.3 Independent validation with BinaryFormatter (isolated test machine only)

Run this on a throwaway VM or container with **only tool-generated files**. It proves .NET itself accepts the output.

```powershell
# PowerShell 7.4 / .NET 8. BinaryFormatter is disabled by default and removed in .NET 9.
[AppContext]::SetSwitch('System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization', $true)
Add-Type -TypeDefinition @'
using System; using System.Collections; using System.Runtime.Serialization;
namespace SC.Message.Export {
 [Serializable] public class LogMessage { public int Version; public int MsgSourceID; public int MsgSourceTypeID; public int MPERuleID; public string Message; public string Comments; public int Status; }
 [Serializable] public class LogMessageCollection { public Hashtable MsgsHashtable; public int LicenseID; public string SubmittedBy; public string Comments; public DateTime DateSubmitted; }
 public class Binder : SerializationBinder { public override Type BindToType(string asm, string type) {
   return asm.StartsWith("scvbcomn") ? typeof(LogMessage).Assembly.GetType(type, true) : Type.GetType(type + ", " + asm, true); } } }
'@
$fs = [IO.File]::OpenRead('.\generated.llx')
$gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
$bf = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter
$bf.Binder = New-Object SC.Message.Export.Binder
$o = $bf.Deserialize($gz); $o.MsgsHashtable.Count
```

### 6.4 Adversarial regression ideas

GZip of 1 GB zeros; 5,000 nested `04` records; `ArraySingleObject` with length 2e9; `ObjectNullMultiple` with count 2e9; random byte mutation of a valid payload. All must end in a clean error, a warning or partial output within seconds.

---

## 7. Known limitations

1. **Live LogRhythm import is unverified.** Byte-identity with a genuine export gives high confidence, but it's not proof that LogRhythm accepts the file (e.g. LicenseID or log-source validation).
2. **Windows PowerShell 5.1 is unverified.** The code avoids 7-only syntax and C# 6+ features, but hasn't been executed on 5.1.
3. For `.txt` input a single MsgSourceID/MsgSourceTypeID/MPERuleID applies to all messages. Since 1.1.0, `.json` input (`ConvertFrom-JsonRecords`) carries per-message IDs; Build-EchoCoverage uses this.
4. The template takes source IDs from its **first** message only.
5. The whole file is held in memory. Practical limit is roughly hundreds of MB of text.
6. Event-XML Auto mode assumes `<Event ...>…</Event>` with no nested `<Event` tags. Whitespace between tags is collapsed, which could alter whitespace inside `<Data>` values that span tags.
7. `View` output formatting uses `Update-TypeData` (session-wide, harmless).
8. Generated files don't reproduce LogRhythm's random Hashtable ordering. Irrelevant on load.

---

## 8. Coding constraints and gotchas

- **C# 5 only** inside `Add-Type`: no `$"..."`, `?.`, `??=`, `out var`, `nameof`, expression-bodied members, tuples, `HashSet` (not referenced by default on 5.1; `Dictionary<int,bool>` is used instead). Don't pass `-ReferencedAssemblies`: on PowerShell 7 it **replaces** the default set and breaks the build.
- **PowerShell 5.1 syntax only**: no ternary `? :`, no `??`, no `-Parallel`, no `&&`/`||`.
- **Variable names are case-insensitive.** A local `$raw` silently overwrote the `-Raw` switch during development. Never reuse parameter names as locals.
- **`Add-Type` types are cached per session** and can't be redefined. After editing the C#, start a new PowerShell session, or rename the namespace while iterating.
- `Set-StrictMode -Version 2.0` is on: uninitialised variables and missing properties throw.
- Return byte arrays from functions with the unary comma (`return , $bytes`) so PowerShell doesn't unroll them.
- `Write-Host` output is stream 6. Tests suppress it with `6>$null`.
- On Linux and macOS PowerShell, `Out-GridView` is absent. The code warns and falls back.

---

## 9. Troubleshooting playbook

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| `Add-Type` compile error on 5.1 | C# 6+ syntax crept in, or a missing reference | Error shows the line/column inside the here-string | Rewrite in C# 5. If a framework assembly is missing, add the type through an assembly that's already loaded rather than `-ReferencedAssemblies`. |
| `Cannot add type... already exists` after editing | Session type cache | – | New PowerShell session |
| `Not an LLX file` on a real LogRhythm export | Different container (e.g. not GZip, or a new format version) | First 16 bytes: `Format-Hex .\file.llx \| Select-Object -First 2`; after gunzip, check for `00 01 00 00 00 FF FF FF FF` | Extend `Gz.Expand` / `IsNrbf` for the new container |
| `Contains a serialised 'X'` | Root type differs (other LR version) | `View -Raw` to see the structure | Map the new type/field names in `Read-LlxFile` and `BuildPayload` |
| `Unsupported NRBF record type N` | Record type outside 0–17, or corrupt input | Offset is in the message; hex-dump there | Corruption: get a fresh file. Otherwise implement the record per MS-NRBF §2.x. |
| Message count lower than expected on Compile | Split mode | `View -Summary`; try `-SplitMode Line`/`BlankLine` | Pick the right split mode / regex |
| LogRhythm rejects a generated file | IDs, licence or version mismatch; unverified import path (§7.1) | `View -Summary` on a genuine file from that system vs the generated one; compare LicenseID, MsgSourceTypeID, Assembly | Recompile with `-TemplateLlx` from that system. If it still fails, do the §6.2 byte comparison against a genuine single-message export from that system to find which field differs. |
| Garbled characters after Compile | Input encoding misdetected (e.g. ANSI that looks like valid UTF-8) | Inspect the source bytes | Re-save the source as UTF-8, or extend `ConvertFrom-TextBytes` |
| Very slow on large files | Per-item PowerShell work in a hot loop | `Measure-Command` per stage | Move the loop into C#, as was done with `FromLines` |
| `File expands beyond…` on a legitimate file | Large export | – | `-MaxDecompressedMB` (≤ 8192) |
| Output written to an unexpected place | `Get-OutputFile` folder/file heuristic | Check whether `-OutputPath` has an extension or exists | Pass an explicit folder that exists, or a full file name |

**Information to request from a user (redacted):**

1. `$PSVersionTable`
2. the exact command
3. full output with `-Verbose`
4. `Tests\Test-LLXTool.ps1` output
5. for format problems, `View -Summary` of the problem file and the first 64 bytes of its decompressed payload (`Format-Hex`), which contain only type metadata

---

## 10. Extension points

- **Per-message source IDs:** implemented in 1.1.0 as JSON input (`ConvertFrom-JsonRecords`). A CSV variant would follow the same pattern.
- **New LogRhythm versions:** the version string lives in `$DefaultAssemblyVersion`. If field lists change, update the member-name/type arrays in `BuildPayload` and the mapping in `Read-LlxFile`. Unknown extra fields are already visible via `View -Raw`.
- **Deterministic output for testing:** expose optional GUID and timestamp inputs to `BuildPayload` (the C# API already accepts them via `LlxMessage.Id` and `submittedUtc`).
- **Streaming large files:** `BuildPayload` writes to a `MemoryStream`. It could take a `Stream` and pipe directly into `DeflateStream` (CRC computed on the fly).

---

## 11. Glossary

| Term | Meaning |
|---|---|
| LLX | LogRhythm log message export file |
| MS-NRBF | .NET Remoting Binary Format, the BinaryFormatter wire format ([MS-NRBF] spec) |
| MsgSourceTypeID | LogRhythm log source type identifier |
| MsgSourceID | LogRhythm log source identifier |
| MPE / MPERuleID | Message Processing Engine and the rule a message is matched to (-1 = none) |
| scvbcomn | LogRhythm .NET assembly defining `SC.Message.Export.*` |
| EMDB | LogRhythm Event Manager database (`LogRhythmEMDB`) |
