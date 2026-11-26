#!/usr/bin/env python3
"""
Mock LogRhythm (Alarm API + AIE Drilldown Cache API) and LogRhythm Echo API servers,
for testing Build-EchoCoverage.ps1 without a real deployment.

All data is synthetic (example.com hosts, documentation IP ranges, invented values).
Request/response shapes mirror formats confirmed against a live LogRhythm 7.x + Echo 2.x
system (HANDOVER.md section 4). If a real system differs, update this mock first.

    python3 mock_lr_echo.py --cert cert.pem --key key.pem [--lr-port 8501] [--echo-port 33333]

LogRhythm token: "testtoken"   Echo login: admin / password
State dump: GET https://localhost:<echo-port>/mock/state
"""
import argparse, gzip, io, json, re, ssl, struct, threading, datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

NOW = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)

def iso(d): return d.strftime('%Y-%m-%dT%H:%M:%S.000Z')

def win_event(eid, user, host, ip, ts):
    return ("<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System>"
            "<Provider Name='Microsoft-Windows-Security-Auditing'/><EventID>%d</EventID>"
            "<TimeCreated SystemTime='%s'/><Channel>Security</Channel><Computer>%s</Computer></System>"
            "<EventData><Data Name='TargetUserName'>%s</Data><Data Name='TargetDomainName'>CORP</Data>"
            "<Data Name='WorkstationName'>WKS-%s</Data><Data Name='IpAddress'>%s</Data></EventData></Event>"
            % (eid, ts, host, user, user.upper(), ip))

_seq = [0]
def ddlog(msg, tid, tname, sid, sname, d):
    # Field names as returned by a real LogRhythm drilldown (lab-confirmed): logSourceType holds the type ID
    _seq[0] += 1
    return {"logMessage": msg, "logSourceType": tid, "logSourceTypeName": tname,
            "logSourceId": sid, "logSourceName": sname, "normalDate": iso(d), "ruleBlockNumber": 1,
            "sequenceNumber": _seq[0], "vendorMessageId": "", "mpeRuleId": -1, "mpeRuleName": ""}

# ---------------------------------------------------------------- synthetic LogRhythm data
ALARMS = []          # {alarmId, alarmRuleName, dateInserted, entityName}
DRILLDOWN = {}       # alarmId -> (status, body)
_next = [5000]

def add_alarm(rule, minutes_ago, dd=None, rule_id=None):
    _next[0] += 1
    aid = _next[0]
    ALARMS.append({"alarmId": aid, "alarmRuleName": rule, "alarmStatus": "New",
                   "dateInserted": iso(NOW - dt.timedelta(minutes=minutes_ago)), "entityName": "Primary Site"})
    if dd is None:
        DRILLDOWN[aid] = (204, None)
    else:
        blocks = []
        for i, (logs, aie, dx) in enumerate(dd, 1):
            for _l in logs: _l["ruleBlockNumber"] = i
            blocks.append({"RuleBlockID": i, "RuleBlockType": 1, "DrillDownLogs": json.dumps(logs),
                           "AIECount": aie, "DXCount": dx, "SummaryFields": []})
        DRILLDOWN[aid] = (202, {"statusCode": 202, "Data": {"DrillDownResults": {
            "AlarmID": aid, "AIERuleID": rule_id, "Status": "Completed", "RuleBlocks": blocks}}})
    return aid

t0 = NOW - dt.timedelta(hours=2)
# Brute force: newest alarm has no drilldown, the older one does
add_alarm("AIE: Brute Force Login", 30, None)
add_alarm("AIE: Brute Force Login", 90, [([ddlog(win_event(4625, "jdoe", "DC01.corp.example", "203.0.113.%d" % i, iso(t0)),
                                                 1000301, "MS Windows Event Logging XML - Security", 21, "DC01 XML Security", t0 + dt.timedelta(seconds=i)) for i in range(1, 6)], 5, 5)],
          rule_id=1001)
add_alarm("AIE: Brute Force Login", 600, None)
# Malware: two rule blocks, two log source types
add_alarm("AIE: Malware Then Outbound", 45, [
    ([ddlog("<38>Nov 26 09:00:01 av01 AV: Threat Trojan.Gen detected on 192.0.2.10 user=asmith@corp.example file=C:\\temp\\x.exe",
            1000111, "Syslog - Generic AV", 33, "AV Server", t0)], 1, 1),
    ([ddlog("<14>Nov 26 09:00:09 fw01 FW: allow src=192.0.2.10 dst=198.51.100.7 dport=443 bytes=99999",
            1000222, "Syslog - Generic Firewall", 34, "Edge FW", t0 + dt.timedelta(seconds=8))], 1, 1)], rule_id=1002)
# Partial: DX has fewer logs than AIE counted
add_alarm("AIE: Partial Logs Rule", 50, [([ddlog("<14>Nov 26 partial log %d" % i, 1000222, "Syslog - Generic Firewall", 34, "Edge FW", t0) for i in range(3)], 10, 3)], rule_id=1003)
# No drilldown at all
add_alarm("AIE: No Drilldown Rule", 70, None)
add_alarm("AIE: No Drilldown Rule", 80, None)
# Name-only log source type (no ID), as seen on a real system
_nt = [ddlog("01 15 2026 09:00:0%d 192.0.2.50 <SYSD:NOTE> ePO event %d" % (i, i), None, "Syslog - Example ePO", 40, "EPO01", t0) for i in range(2)]
for _l in _nt: _l.pop("logSourceType")
add_alarm("AIE: Name Only Type Rule", 40, [(_nt, 2, 2)], rule_id=1010)
# ePO-style syslog: embedded <Event> element, non-breaking space, BOM character (real-world shape)
_epo = ("01 15 2026 09:00:00 192.0.2.60 <SYSD:NOTE> 1 2026-01-15T09:00:00.0Z EPO01 EPOEvents - EventFwd [agentInfo@0000 tenantId=\"1\"] \ufeff<?xml version=\"1.0\"?>  "
        "<EPOEvent><MachineInfo><MachineName>host-a</MachineName></MachineInfo><SoftwareInfo><Event><EventID>1000</EventID>"
        "<ThreatName>Example detection:\u00a0synthetic</ThreatName></Event></SoftwareInfo></EPOEvent>  ")
add_alarm("AIE: ePO Style Rule", 35, [([ddlog(_epo, None, "Syslog - Example ePO", 41, "EPO01", t0)], 1, 1)], rule_id=1011)
# Echo rejects these logs
add_alarm("AIE: Echo Reject Rule", 55, [([ddlog("<14>Nov 26 FAIL_ADDLOGS marker", 1000222, "Syslog - Generic Firewall", 34, "Edge FW", t0)], 1, 1)], rule_id=1005)
# Not an AIE rule we list
add_alarm("Some Non-AIE Alarm", 20, None)
# Noise rule: many alarms (pagination); newest has 700 logs (MaxLogsPerRule)
for m in range(1200):
    add_alarm("AIE: Noisy Rule", 100 + m,
              [([ddlog("<14>Nov 26 noisy %d" % k, 1000222, "Syslog - Generic Firewall", 34, "Edge FW", t0) for k in range(700)], 700, 700)] if m == 0 else None,
              rule_id=1006)
# Old alarm outside the lookback
add_alarm("AIE: Old Rule", 60 * 24 * 90, [([ddlog("<14>old", 1000222, "Syslog - Generic Firewall", 34, "Edge FW", t0)], 1, 1)], rule_id=1007)

ALARMS.sort(key=lambda a: a["dateInserted"], reverse=True)

# ---------------------------------------------------------------- Echo state
ECHO = {"usecases": {1: {"id": 1, "title": "Existing OOTB Use Case", "description": "", "timedelay": 0}},
        "logs": [], "next_uc": 100, "next_log": 1000, "sessions": set(), "unpacks": 0, "deleted": []}
MSG_TYPES = [{"MsgSourceTypeID": 1000301, "FullName": "MS Windows Event Logging XML - Security"},
             {"MsgSourceTypeID": 1000111, "FullName": "Syslog - Generic AV"},
             {"MsgSourceTypeID": 1000222, "FullName": "Syslog - Generic Firewall"},
             {"MsgSourceTypeID": 1000901, "FullName": "Syslog - Example ePO"}]
LOCK = threading.Lock()

# ---------------------------------------------------------------- minimal NRBF reader (LLX)
def read_llx(data):
    if data[:2] == b'\x1f\x8b':
        data = gzip.decompress(data)
    b = io.BytesIO(data)
    def u8(): return b.read(1)[0]
    def i32(): return struct.unpack('<i', b.read(4))[0]
    def lpstr():
        n = 0; shift = 0
        while True:
            c = u8(); n |= (c & 0x7f) << shift; shift += 7
            if c < 0x80: break
        return b.read(n).decode('utf-8')
    prim = {1: 1, 2: 1, 6: 8, 7: 2, 8: 4, 9: 8, 11: 4, 12: 8, 13: 8, 14: 2, 15: 4, 16: 8}
    def rprim(t):
        if t == 8: return i32()
        if t == 18: return lpstr()
        return b.read(prim[t])
    classes, objs = {}, {}
    def addinfo(bt):
        if bt in (0, 7): return u8()
        if bt == 3: return lpstr()
        if bt == 4: n = lpstr(); i32(); return n
        return None
    def members(oid, ci):
        name, names, bts, adds = ci
        vals = {}
        for k, nm in enumerate(names):
            vals[nm] = rprim(adds[k]) if bts and bts[k] == 0 else record()
        objs[oid] = (name, vals); return objs[oid]
    def record():
        rt = u8()
        if rt == 0: i32(); i32(); i32(); i32(); return None
        if rt == 12: i32(); lpstr(); return record()
        if rt in (4, 5):
            oid = i32(); name = lpstr(); n = i32(); names = [lpstr() for _ in range(n)]
            bts = [u8() for _ in range(n)]; adds = [addinfo(x) for x in bts]
            if rt == 5: i32()
            classes[oid] = (name, names, bts, adds); return members(oid, classes[oid])
        if rt == 1: oid = i32(); meta = i32(); return members(oid, classes[meta])
        if rt == 6: oid = i32(); s = lpstr(); objs[oid] = s; return s
        if rt == 9: return ('ref', i32())
        if rt == 10: return None
        if rt == 16:
            oid = i32(); n = i32(); arr = [record() for _ in range(n)]; objs[oid] = arr; return arr
        if rt == 11: return 'END'
        raise ValueError('record type %d not supported by mock' % rt)
    while record() != 'END':
        pass
    def deref(v): return objs.get(v[1]) if isinstance(v, tuple) and v and v[0] == 'ref' else v
    out = []
    for oid in sorted(objs):
        o = objs[oid]
        if isinstance(o, tuple) and o[0] == 'SC.Message.Export.LogMessage':
            v = o[1]
            out.append({"Message": deref(v["Message"]), "MsgSourceTypeID": v["MsgSourceTypeID"], "MsgSourceID": v["MsgSourceID"]})
    return out

def parse_multipart(body, ctype):
    m = re.search(r'boundary=(.+)', ctype or '')
    if not m: return {}
    boundary = m.group(1).strip().strip('"').encode()
    parts = {}
    for part in body.split(b'--' + boundary):
        if b'\r\n\r\n' not in part: continue
        head, content = part.split(b'\r\n\r\n', 1)
        nm = re.search(rb'name="([^"]+)"', head)
        if nm: parts[nm.group(1).decode()] = content.rstrip(b'\r\n')
    return parts

# ---------------------------------------------------------------- handlers
class Base(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n) if n else b''
    def send(self, code, obj=None, ctype='application/json'):
        data = b'' if obj is None else (obj if isinstance(obj, bytes) else json.dumps(obj, ensure_ascii=False).encode('utf-8'))
        self.send_response(code)
        if data: self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        for k, v in getattr(self, '_extra', {}).items(): self.send_header(k, v)
        self.end_headers()
        if data: self.wfile.write(data)

class LR(Base):
    def do_GET(self):
        if self.headers.get('Authorization') != 'Bearer testtoken':
            return self.send(401, {"message": "Unauthorized"})
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == '/lr-alarm-api/alarms':
            count = int(q.get('count', ['50'])[0]); off = int(q.get('offset', ['0'])[0])
            return self.send(200, {"alarmsSearchDetails": ALARMS[off:off + count], "alarmsCount": len(ALARMS), "statusCode": 200})
        m = re.match(r'^/lr-alarm-api/alarms/(\d+)$', u.path)
        if m:
            a = next((x for x in ALARMS if x["alarmId"] == int(m.group(1))), None)
            if not a: return self.send(404, {"statusCode": 404, "responseMessage": "Alarm not found"})
            return self.send(200, {"alarmDetails": dict(a, alarmDataCached="Y"), "statusCode": 200})
        m = re.match(r'^/lr-alarm-api/alarms/(\d+)/events$', u.path)
        if m: return self.send(200, {"alarmEventsDetails": [{"alarmId": int(m.group(1)), "commonEventName": "mock"}]})
        m = re.match(r'^/lr-drilldown-cache-api/drilldown/(\d+)$', u.path)
        if m and 'application/json' not in (self.headers.get('Content-Type') or ''):
            # Real API behaviour (confirmed in a lab): 400 unless Content-Type: application/json is sent
            return self.send(400, {"Data": None, "Error": {"Message": "Invalid request at route /drilldown/%s." % m.group(1)}})
        if m:
            code, body = DRILLDOWN.get(int(m.group(1)), (204, None))
            return self.send(code, body)
        self.send(404, {"message": "not found"})

class Echo(Base):
    def authed(self):
        c = self.headers.get('Cookie') or ''
        return any(('session=%s' % s) in c for s in ECHO["sessions"])
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == '/mock/state':
            with LOCK: return self.send(200, {"usecases": list(ECHO["usecases"].values()), "logs": ECHO["logs"], "unpacks": ECHO["unpacks"], "deleted": ECHO["deleted"]})
        if not self.authed(): return self.send(401, {"error": "login required"})
        with LOCK:
            if u.path == '/api/getechoversion': return self.send(200, {"version": "2.0.14-mock"})
            if u.path == '/api/usecases':
                return self.send(200, [dict(uc, logcount=sum(1 for l in ECHO["logs"] if l["owner_id"] == uc["id"])) for uc in ECHO["usecases"].values()])
            if u.path == '/api/msgsourcetypes': return self.send(200, MSG_TYPES)
            if u.path in ('/api/usecase', '/api/log', '/api/host'):
                return self.send(200, {"data": [], "meta": {"total": 0}, "jsonapi": {"version": "1.0"}}, 'application/vnd.api+json')
            m = re.match(r'^/api/usecasesByIds/([\d,]+)$', u.path)
            if m:
                ids = [int(x) for x in m.group(1).split(',')]
                return self.send(200, [dict(ECHO["usecases"][i], logs=[l for l in ECHO["logs"] if l["owner_id"] == i]) for i in ids if i in ECHO["usecases"]])
        self.send(404, {"error": "not found"})
    def do_POST(self):
        u = urlparse(self.path); raw = self.body()
        if u.path == '/api/login':
            j = json.loads(raw or b'{}')
            if j.get('username') == 'admin' and j.get('password') == 'password':
                sid = 'sess%d' % (len(ECHO["sessions"]) + 1); ECHO["sessions"].add(sid)
                self._extra = {'Set-Cookie': 'session=%s; Path=/' % sid}
                return self.send(200, {"result": "ok"})
            return self.send(401, {"error": "bad credentials"})
        if not self.authed(): return self.send(401, {"error": "login required"})
        with LOCK:
            if u.path == '/api/usecase':
                # A live Echo rejected JSON:API and accepted plain JSON (lab-confirmed); mirror that
                if 'application/vnd.api+json' in (self.headers.get('Content-Type') or ''):
                    return self.send(415, None)   # live Echo: 415 with an empty body
                attrs = json.loads(raw)
                if not attrs.get('title'): return self.send(400, {"errors": [{"detail": "title required"}]})
                ECHO["next_uc"] += 1; uid = ECHO["next_uc"]
                ECHO["usecases"][uid] = {"id": uid, "title": attrs["title"], "description": attrs.get("description", ""), "timedelay": attrs.get("timedelay", 0)}
                # live Echo response shape (lab-confirmed)
                return self.send(201, dict(ECHO["usecases"][uid], dateupdated=None, enabled=False, hosts=[], logs=[], pcaps=[]))
            if u.path == '/api/addLogs':
                logs = json.loads(raw)
                if not isinstance(logs, list): return self.send(400, {"error": "expected a list"})
                for l in logs:
                    for f in ("owner_id", "log", "msg_src_id", "play_order"):
                        if f not in l: return self.send(400, {"error": "missing " + f})
                    if l["owner_id"] not in ECHO["usecases"]: return self.send(400, {"error": "unknown owner_id"})
                    if 'FAIL_ADDLOGS' in l["log"]: return self.send(500, {"error": "simulated failure"})
                for l in logs:
                    ECHO["next_log"] += 1; ECHO["logs"].append(dict(l, id=ECHO["next_log"]))
                return self.send(200, {"result": "ok", "count": len(logs)})
            if u.path == '/api/deleteUseCases':
                ids = json.loads(raw)
                for i in ids:
                    ECHO["usecases"].pop(int(i), None); ECHO["logs"] = [l for l in ECHO["logs"] if l["owner_id"] != int(i)]
                    ECHO["deleted"].append(int(i))
                return self.send(200, {"result": "ok"})
            if u.path == '/api/unpackLLXFile':
                parts = parse_multipart(raw, self.headers.get('Content-Type'))
                if 'file' not in parts: return self.send(400, {"error": "no file field"})
                try:
                    logs = read_llx(parts['file'])
                except Exception as e:
                    return self.send(400, {"error": "bad llx: %s" % e})
                ECHO["unpacks"] += 1
                return self.send(200, {"logs": logs})
        self.send(404, {"error": "not found"})

def serve(handler, port, ctx):
    httpd = ThreadingHTTPServer(('127.0.0.1', port), handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--cert', required=True); ap.add_argument('--key', required=True)
    ap.add_argument('--lr-port', type=int, default=8501); ap.add_argument('--echo-port', type=int, default=33333)
    a = ap.parse_args()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(a.cert, a.key)
    serve(LR, a.lr_port, ctx); serve(Echo, a.echo_port, ctx)
    print('mock LogRhythm API on https://127.0.0.1:%d , mock Echo on https://127.0.0.1:%d' % (a.lr_port, a.echo_port), flush=True)
    threading.Event().wait()
