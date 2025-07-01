from flask import Flask, request, jsonify
import socket
import datetime

app = Flask(__name__)

# Target SIEM syslog settings
SYSLOG_HOST = "192.168.252.124"  # Update to your SIEM's IP
SYSLOG_PORT = 514
PRI = "<134>"  # local0.info
TAG = "grafana"
HOSTNAME = "testhost"  # Or use: socket.gethostname()

def send_syslog(message: str):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.sendto(message.encode(), (SYSLOG_HOST, SYSLOG_PORT))
        print(f"✅ Sent to {SYSLOG_HOST}:{SYSLOG_PORT}")
        print(f"📦 Message:\n{message}")
    except Exception as e:
        print(f"❌ Error sending syslog: {e}")

def format_syslog_messages(alert_data: dict) -> list:
    alerts = alert_data.get("alerts", [])
    messages = []

    for alert in alerts:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})

        alertname = labels.get("alertname", "UnknownAlert")
        instance = labels.get("instance", "UnknownInstance")
        severity = labels.get("severity", "N/A")
        summary = annotations.get("summary", "No summary provided.")

        # Generate timestamp like: "Jun 23 16:01:55"
        timestamp = datetime.datetime.now().strftime("%b %d %H:%M:%S")

        # Construct RFC3164-style message
        message_body = f"{alertname} triggered on {instance} (severity={severity}): {summary}"
        full_message = f"{PRI}{timestamp} {HOSTNAME} {TAG}: {message_body}"
        messages.append(full_message)

    return messages

@app.route('/webhook', methods=['POST'])
def webhook_receiver():
    try:
        payload = request.json
        print("📥 Received alert payload")

        messages = format_syslog_messages(payload)

        for msg in messages:
            send_syslog(msg)

        return jsonify({"status": f"{len(messages)} alert(s) forwarded to syslog"}), 200
    except Exception as e:
        print(f"❌ Webhook processing error: {e}")
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    print("🚀 Starting Grafana Webhook → Syslog forwarder...")
    app.run(host='0.0.0.0', port=5000)
