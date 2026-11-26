# Mock LogRhythm + Echo servers

`mock_lr_echo.py` simulates the LogRhythm Alarm API, the AIE Drilldown Cache API and the Echo REST API, using the formats confirmed against a live system (`HANDOVER.md` §4). It is Python 3, standard library only. All data is synthetic.

```bash
# any self-signed certificate/key pair works
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7 -subj "/CN=localhost"
python3 mock_lr_echo.py --cert cert.pem --key key.pem --lr-port 18501 --echo-port 13333
```

On Windows without OpenSSL, export any test certificate and key as PEM files, or run the mock in WSL.

- LogRhythm API token: `testtoken`
- Echo login: `admin` / `password`
- `GET https://127.0.0.1:13333/mock/state` shows what was created in the mock Echo

**Restart the mock before each test run:** `Tests/Test-EchoCoverage.ps1` expects a fresh state. The scenario list is in `HANDOVER.md` §7.
