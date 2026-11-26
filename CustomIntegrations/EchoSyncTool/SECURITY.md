# Security

## Reporting a vulnerability
Please don't open a public issue for security problems. Contact the maintainers privately (see the repository's contact details) with a description and, if possible, a minimal **synthetic** reproduction.

## Design notes
- **Untrusted `.llx` files are safe to read.** LLX-Tool parses the .NET binary format with its own reader, and never uses `BinaryFormatter` or any type-loading deserialiser. Size, depth and element-count limits stop decompression bombs and resource exhaustion. See `docs/LLX-Tool-HANDOVER.md` §5.
- **Read-only against LogRhythm:** only GET requests to the Alarm and Drilldown APIs, and a `SELECT` against the EMDB.
- **Echo:** creates use cases and adds logs. The only delete is rolling back an empty use case the tool has just created, if Echo then rejects its logs.
- **Secrets:**
  - The LogRhythm token comes from a SecureString, `$env:LR_API_TOKEN` or a hidden prompt, and is never written to disk.
  - Passwords, tokens and `Authorization` headers are redacted in all saved HTTP captures.
- **XML** is parsed with DTDs and external entities disabled. User-supplied regexes run with timeouts.
- **`-SkipCertificateCheck`** disables certificate validation for the session's web requests. Use it only on trusted management networks.

## Data you must not publish
Run folders (`EchoCoverage_*`, `LabPoc_*`) contain real log data:
- drilldown responses
- `.llx` files
- HTTP captures
- `anonymisation-map.csv`, which reverses anonymisation

Keep them out of version control (`.gitignore` covers them), tickets and issues.
