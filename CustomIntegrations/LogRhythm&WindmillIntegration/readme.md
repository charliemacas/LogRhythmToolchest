## Charlie March 2026 ##

Built for pwsh, ensure you have installed Powershell 7. 

- actions.xml defines the schema within the actions tab of AIE, and what switches are fed to the .ps1 files during the actual run of the script. 
- The individual PS1 files are each action, and they are fairly self explanatory, just slight variations on body, to accomadate sending to other platforms. The main highlight/action this page goes into is Windmill SOAR Automation engine, via Webhook Trigger. 
- Feel free to adapt and repackage your own version in the LogRhythm console, or just download the LPI file in it's own folder within this repo.
- You will need the below things to get the main Windmill SOAR Webhook working, free Windmill cloud instances are available or you can install locally. 

<img width="1221" height="919" alt="image" src="https://github.com/user-attachments/assets/12482293-1b70-47b7-befc-27116ca2dc2f" />

Couple examples of what is possible below. 

<img width="3427" height="1386" alt="image" src="https://github.com/user-attachments/assets/2c6346b7-6e50-4d03-8626-f74bb2015a7e" />

<img width="1699" height="833" alt="image" src="https://github.com/user-attachments/assets/1c997275-935d-4478-bee8-af1e874e74d2" />

<img width="1089" height="787" alt="image" src="https://github.com/user-attachments/assets/0708c650-535e-45ba-8bb0-ea09e33d94dd" /> <img width="1125" height="633" alt="image" src="https://github.com/user-attachments/assets/bf7e83fa-7f32-4d50-a47f-228cbb56b8ea" />

________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________________

# LogRhythm + Windmill SOAR Integration

**Author:** Charlie Mac — UK TAM, March 2026

A Smart Response Plugin (SRP) package that connects LogRhythm AIE alarms to [Windmill](https://windmill.dev) as a lightweight, open-source SOAR platform. When an AIE rule fires, LogRhythm calls a PowerShell Smart Response action which fetches full alarm context from the LogRhythm API and forwards it as a structured webhook payload to Windmill, where automated playbooks handle enrichment, notification, and response.

---

## What This Does

```
LogRhythm AIE Alarm
        │
        ▼
Smart Response Plugin (PowerShell 7)
  ├── Calls lr-alarm-api/alarms/{id}         → alarm metadata
  └── Calls lr-alarm-api/alarms/{id}/summary → group-by fields (IPs, hosts, users)
        │
        ▼
Windmill Webhook (run_wait_result)
        │
        ▼
Router Flow → branches per alarm rule
  ├── T10000 - Shrek DVD Boxset  → Slack + Teams notification
  ├── T10001 - Hot Fuzz          → Slack + Teams notification
  ├── T10002 - Dodgy IP          → VirusTotal enrichment → Slack + Teams
  └── Default                   → Exit cleanly
```

The SRP uses `run_wait_result` — meaning LogRhythm waits synchronously for Windmill to finish and captures the full playbook result in the alarm's Smart Response execution log.

---

## Prerequisites

### LogRhythm
- LogRhythm SIEM with AIE (AI Engine) licensed
- Platform Manager with Smart Response enabled
- A LogRhythm API bearer token (generated from the LogRhythm console under API settings)

### PowerShell
- **PowerShell 7 (pwsh) is required** — the scripts will not work on Windows PowerShell 5.1
- Download from: https://github.com/PowerShell/PowerShell/releases/latest
- Install the `.msi` on the LogRhythm Platform Manager server
- Verify with: `pwsh --version`
- **Restart the LogRhythm Alarming and Response Manager (ARM) service after installation** — the service must be restarted to pick up the new `pwsh` executable

> **Why PowerShell 7?** The scripts use `-SkipCertificateCheck` on `Invoke-RestMethod` to handle LogRhythm's self-signed certificate. This parameter only exists in PowerShell 7+. This matches LogRhythm's own approach in their Case Management V7 Smart Response plugin.

### Windmill
- A Windmill workspace — either:
  - **Cloud (free tier):** Sign up at [app.windmill.dev](https://app.windmill.dev) — 1,000 executions/month free
  - **Self-hosted:** Rocky Linux 9 VM + Docker Engine + Caddy reverse proxy (see Self-Hosted Setup below)
- A Windmill API token (generated from your workspace settings under Account → Tokens)

---

## Plugin Installation

### Files in This Package

| File | Purpose |
|---|---|
| `actions.xml` | Plugin schema — defines the 4 Smart Response actions and their parameters |
| `WindmillWebhook.ps1` | Sends alarm to Windmill SOAR with full context |
| `GenericWebhook.ps1` | Sends alarm as a generic JSON webhook to any endpoint |
| `SlackWebhook.ps1` | Sends a formatted Slack Block Kit notification directly |
| `TeamsWebhook.ps1` | Sends a formatted Teams Adaptive Card notification directly |

### Installing the Plugin

1. Open the **LogRhythm Console**
2. Navigate to **Deployment Manager → Smart Response → Actions**
3. Click **Import Plugin**
4. Select the `.lpi` file from the `LPI` folder in this repo
5. Verify the plugin appears as **"Webhook Suite - Send AIE Alarm As Webhook"**

> If you have previously imported an older version of this plugin, **uninstall all existing versions first** before importing. Multiple `_N` suffix versions (e.g. `_14`) will cause the wrong scripts to be called.

### Attaching to an AIE Rule

1. Open **Deployment Manager → AI Engine → Rules**
2. Open the rule you want to automate
3. Go to the **Actions** tab
4. Click **New Action** and select **Send Alarm to Windmill SOAR Webhook**
5. Fill in the parameters (see Configuration below)
6. Set **Execution Target** to **Platform Manager**
7. Save the rule

---

## Configuration

### Action Parameters

| Parameter | Switch | Description |
|---|---|---|
| LogRhythm Alarm ID | `-AlarmId` | Auto-populated from the alarm — do not change |
| Windmill Webhook Endpoint URL | `-WebhookUrl` | Your Windmill `run_wait_result` flow URL |
| LogRhythm Platform Base URL | `-LrBaseUrl` | e.g. `https://10.10.10.10:8501` |
| LogRhythm Bearer Token | `-BearerToken` | Your LogRhythm API token |
| Windmill Bearer Token | `-WindmillBearerToken` | Your Windmill API token |

### Windmill Webhook URL Format

For Windmill Cloud:
```
https://app.windmill.dev/api/w/{workspace}/jobs/run_wait_result/f/u/{username}/{flow_name}
```

For self-hosted:
```
https://your-windmill-host/api/w/{workspace}/jobs/run_wait_result/f/u/{username}/{flow_name}
```

---

## Webhook Payload Structure

Every script sends the following JSON payload to Windmill. All fields are available as `flow_input.*` within your Windmill flows.

```json
{
  "vendor": "LogRhythm",
  "product": "AIE",
  "event_type": "alarm",
  "alarm_id": "2052",
  "alarm_name": "AIE: T10002 - Dodgy IP Detected",
  "entity_name": "Global Entity",
  "alarm_time": "2026-03-11T21:55:18.003",
  "alarm_status": "New",
  "event_count": "1",
  "severity": "10",
  "rbp_max": "10",
  "message": "AIE rule '...' fired on entity '...'",

  // Promoted group-by fields — extracted from the /summary endpoint
  // These are the fields your AIE rule correlated on
  "origin_hosts":   ["10.10.10.10"],
  "impacted_hosts": [],
  "origin_users":   [],
  "impacted_users": [],
  "origin_ips":     [],
  "impacted_ips":   [],
  "common_events":  ["AIE: T10002 - Dodgy IP Detected"],

  "smartresponse": {
    "script_name": "WindmillWebhook.ps1",
    "version": "1.2",
    "host": "YOUR-LR-SERVER",
    "executed_at": "2026-03-11T15:55:23Z"
  },

  // Full raw API responses for advanced use
  "raw_alarm": { ... },
  "alarm_summary": { ... }
}
```

> **Important:** The group-by fields (`origin_hosts`, `origin_ips` etc.) are sourced from the `/alarms/{id}/summary` endpoint, not the main alarm endpoint. This is intentional — the summary endpoint returns the actual correlated event data (the fields your AIE rule grouped by), which is what downstream enrichment steps like VirusTotal need. If the summary call fails, the script continues and sends what it has.

> **Note on IPs vs Hosts:** LogRhythm may populate `originHost` with an IP address value depending on how the log source is configured. If `origin_ips` is empty but `origin_hosts` contains an IP, use `flow_input.origin_hosts` as your enrichment input.

---

## Windmill Flow Architecture

### Router Flow (`logrhythm_aie_alarm_handler`)

The entry point for all alarms. A single webhook URL receives everything, then a **Run one branch** step routes based on `flow_input.alarm_name` to the appropriate playbook subflow.

**Adding a new playbook:**
1. Create a new flow named e.g. `u/charlie/t10003_my_new_rule`
2. Define its Flow Inputs: `alarm_id` (string), `severity` (string), `raw_alarm` (object), plus any enrichment-specific fields
3. Add a new branch condition in the router: `flow_input.alarm_name == "AIE: T10003 - My New Rule"`
4. Set the branch action to call your new subflow
5. Map the flow inputs in the subflow call step

### Playbook Subflows

Each alarm rule has its own dedicated subflow. The current playbooks are:

**T10000 - Shrek DVD Boxset**
- Slack notification
- Teams notification

**T10001 - Hot Fuzz**
- Slack notification
- Teams notification

**T10002 - Dodgy IP Detected**
- VirusTotal IP lookup (`origin_hosts[0]`)
- Slack notification (includes VT enrichment results)
- Teams notification (includes VT enrichment results)

**Default**
- Exit cleanly — fires for any alarm with no matching playbook

### Subflow Input Mapping

When calling a subflow from the router, always map these fields in the subflow call step's Step Input panel:

| Subflow Input | Router Value |
|---|---|
| `alarm_id` | `flow_input.alarm_id` |
| `severity` | `flow_input.severity` |
| `raw_alarm` | `flow_input.raw_alarm` |
| `origin_hosts` | `flow_input.origin_hosts` (T10002 only) |

---

## Windmill Variables (Secrets)

Store all credentials as Windmill variables, never hardcode them. Navigate to **Variables** in your Windmill workspace sidebar.

| Variable Path | Description |
|---|---|
| `u/charlie/SlackWebhookUrl` | Slack incoming webhook URL |
| `u/charlie/TeamsWebhookUrl` | Teams workflow webhook URL |
| `u/charlie/VirusTotalKey` | VirusTotal API key |

Access in Python scripts:
```python
import wmill
slack_url = wmill.get_variable("u/charlie/SlackWebhookUrl")
```

Or wire directly in the Step Input UI by typing `variable('u/charlie/VariableName')` into the field.

---

## TLS / Certificate Handling

LogRhythm uses a self-signed certificate on its API (`https://your-lr-host:8501`). The scripts handle this with `-SkipCertificateCheck` on the specific `Invoke-RestMethod` calls to the LogRhythm API only. Outbound calls to Windmill, Slack, and Teams use full certificate validation.

This is intentional and matches the approach used in LogRhythm's own Case Management V7 Smart Response plugin. It is scoped per-call rather than process-wide, making it safer than the older `TrustAllCertsPolicy` approach.

If your organisation has an internal CA, the cleanest solution is to issue LogRhythm a properly signed certificate — at which point `-SkipCertificateCheck` can be removed entirely.

---

## Troubleshooting

### Script fails with "pwsh not found" or similar
- PowerShell 7 is not installed, or the ARM service hasn't been restarted since installation
- Install pwsh from https://github.com/PowerShell/PowerShell/releases/latest
- Restart the **LogRhythm Alarming and Response Manager** service
- Verify: open a new PowerShell window and run `pwsh --version`

### Script runs but Smart Response shows old plugin version (e.g. `_14`)
- Multiple versions of the plugin are installed
- Uninstall all versions of the plugin from the Smart Response Actions tab
- Re-import the `.lpi` file fresh
- Re-attach the action to your AIE rules

### Windmill receives the webhook but group-by fields are empty
- The alarm rule may not populate `originIp` — check `origin_hosts` instead
- Verify by looking at the raw run input in Windmill's Runs page
- Use Postman to call `/lr-alarm-api/alarms/{id}/summary` directly to see what fields are populated for your specific rule type

### Windmill flow shows "No inputs" on a subflow call step
- The subflow hasn't been saved/deployed yet, or its Flow Input schema hasn't been defined
- Open the subflow, click the **Input** node, and add the required fields with their types
- Deploy the subflow, then return to the router — the fields should appear

### VT enrichment shows "Enrichment not available"
- `vt_result` parameter in the notification step is not wired to the VT step's result
- In the Slack/Teams step's Step Input panel, set `vt_result` to `results.{vt_step_id}`
- Also ensure `ip_to_check` in the VT step is set to `${}` expression mode (not `static`)

### Alarm fires but Windmill shows matched: false
- The alarm rule name in the router branch condition doesn't exactly match the `alarm_name` in the payload
- Check the exact string in a recent Windmill run input and match it character for character

---

## Self-Hosted Windmill Setup

For production deployments where alarm data should not leave your network.

**Recommended spec:** Rocky Linux 9 VM, 4 vCPU, 8GB RAM, 50GB disk

```bash
# Install Docker Engine
sudo dnf install -y docker
sudo systemctl enable --now docker

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Pull Windmill docker-compose
curl -o docker-compose.yml https://raw.githubusercontent.com/windmill-labs/windmill/main/docker-compose.yml

# Start Windmill
docker-compose up -d
```

Windmill will be available on port `8000`. Place Caddy or nginx in front for TLS termination.

**Default credentials — change immediately:**
- Username: `admin@windmill.dev`
- Password: `changeme`

**Firewall — only one port needed from LogRhythm:**
```
LogRhythm Platform Manager → Windmill VM : TCP 443 (outbound from LR perspective)
```

No inbound connections from Windmill to LogRhythm are required — the SRP script initiates all communication outbound.

---

## Extending This Integration

### Adding a New Enrichment API

The pattern used for VirusTotal applies to any enrichment API:

1. Add a new Python step to the playbook subflow before the notification steps
2. Fetch the relevant field from `flow_input` (e.g. `flow_input.origin_hosts`)
3. Call the API and return a structured dict
4. In the Slack/Teams notification steps, add `enrichment_result: dict = None` as a parameter
5. Wire it to `results.{step_id}` in the Step Input panel
6. Add a conditional block to the notification payload that only renders if the dict is populated

### Suggested Next Integrations

| API | Use Case | Free Tier |
|---|---|---|
| AbuseIPDB | IP abuse confidence score, complements VT | Yes |
| GreyNoise | Distinguish targeted vs internet background noise | Yes |
| Shodan | What services are exposed on an IP | Yes (limited) |
| URLScan.io | URL/domain analysis with screenshots | Yes |
| MalwareBazaar | File hash lookups | Yes (free) |
| Microsoft Graph | Azure AD user lookups, disable accounts | Yes (with Azure subscription) |
| HaveIBeenPwned | User email breach history | Yes (limited) |
| Jira | Auto-create tickets from alarms | Yes (free tier) |

---

## Repository Structure

```
LogRhythmToolchest/
└── CustomIntegrations/
    └── LogRhythm&WindmillIntegration/
        ├── readme.md
        ├── actions.xml              # Plugin schema
        ├── WindmillWebhook.ps1      # Main SOAR webhook script
        ├── GenericWebhook.ps1       # Generic JSON webhook
        ├── SlackWebhook.ps1         # Direct Slack notification
        ├── TeamsWebhook.ps1         # Direct Teams notification
        └── LPI/
            └── WebhookSuite.lpi     # Importable LogRhythm plugin package
```

---

## Version History

| Version | Date | Changes |
|---|---|---|
| 1.2 | March 2026 | Added `/summary` API call for group-by fields. Promoted `origin_hosts`, `origin_ips`, `origin_users` etc. to top-level payload fields. All scripts updated. |
| 1.1 | March 2026 | Migrated from PS5.1 `TrustAllCertsPolicy` to PS7 `-SkipCertificateCheck`. Removed `Install-LrCertificate.ps1`. |
| 1.0 | March 2026 | Initial release. Basic webhook forwarding, Slack, Teams, Windmill actions. |
