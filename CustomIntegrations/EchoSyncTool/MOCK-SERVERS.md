# Mock servers (developers only, optional)

> **You do not need this to use LR-Echo-Coverage.** These notes are for contributors who want to run the automated pipeline tests without a real LogRhythm or Echo system. The tools themselves are PowerShell only.

`mock_lr_echo.py` simulates the three APIs the pipeline talks to, using formats confirmed against a live system (see `HANDOVER.md` §4):
- the LogRhythm Alarm API
- the AIE Drilldown Cache API
- the Echo REST API

All data in it is synthetic. It is written in Python (standard library only) because it needs to act as an HTTPS server, which PowerShell can't easily do without admin rights.

## Run the pipeline tests

1. Create a throwaway certificate and key (any self-signed pair works):
   ```bash
   openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7 -subj "/CN=localhost"
   ```
   On Windows without OpenSSL, run this in WSL or Git Bash.
2. Start the mock servers:
   ```bash
   python3 Tests/MockServers/mock_lr_echo.py --cert cert.pem --key key.pem --lr-port 18501 --echo-port 13333
   ```
3. In PowerShell, from the repository root:
   ```powershell
   .\Tests\Test-EchoCoverage.ps1 -LrApiBaseUrl https://127.0.0.1:18501 -EchoBaseUrl https://127.0.0.1:13333
   ```

Restart the mock before each test run; the tests expect a fresh state.

## Test values
| Item | Value |
|---|---|
| LogRhythm API token | `testtoken` |
| Echo login | `admin` / `password` |
| What the mock Echo has created | `GET https://127.0.0.1:13333/mock/state` |

The test scenarios (one per simulated AIE rule) are listed in `HANDOVER.md` §7.
