Full .exe available if you want to install this as a application and service. 

It should just install, appear as a service and accept webhooks. There is a config.json you need to edit if you want to change the IP and properly get the logs in LR. All the files should be in C:\Program Files (x86)\Webhooker. 

Powershell Test Script To Generate A Valid Webhook & Send To a target IP e.g. the one you have set within the config.json where the Webhooker is installed - "C:\Program Files (x86)\Webhooker\config.json"

{
  "syslog_host": "172.17.5.11",
  "syslog_port": 514,
  "hostname": "testhost",
  "tag": "grafana"
}

________________________________________________________________________________________

$uri = "http://10.20.30.40:5000/webhook"

$payload = @{
  alerts = @(
    @{
      labels = @{
        alertname = "TestAlert"
        instance  = "host01"
        severity  = "high"
      }
      annotations = @{
        summary = "Test webhook from PowerShell -> syslog"
      }
    }
  )
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Uri $uri -Method POST -Body $payload -ContentType "application/json"
 
____________________________________________________
.py version, essentially the same logic but without a compiler, still suggest to install as a service. 

This is essentially a Python script that listens for Webhooks and allows you to convert those webhooks into a Syslog stream you can send to LogRhythm. A good example of this would be sending Grafana alerts to a Webhook, and then into the SIEM so they can be integrated with AIE. 

![image](https://github.com/user-attachments/assets/d485fd7f-dac5-409f-a72a-689a55436e03)

![image](https://github.com/user-attachments/assets/3d6e2f0d-2d0f-466b-94e3-cc635de00107)
