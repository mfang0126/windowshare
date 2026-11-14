#!/usr/bin/env python3
"""Offline check (no GUI) of Scripts/windowshare-show against a fake loopback host."""
import json, os, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "windowshare-show")
TOKEN = "ab12" * 16
ENTRY = "http://100.1.2.3:8777/"  # agent.json: bare host entry, never handed to the person
LINK = ENTRY + "w/0b6c1f2e-1111-2222-3333-444455556666"  # this share's link from POST /agent/request

# 每个场景：POST 的应答 (code, body)，GET 依次返回的状态
class Fake(BaseHTTPRequestHandler):
    post = (201, {"id": "11111111-2222", "entry": LINK})
    statuses = ["done"]
    seen_bodies = []
    events = []  # GET /agent/events/<seq> replies in order (code, body); empty → 404 (host without the event route)
    event_paths = []

    def log_message(self, format, *args): pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def _auth(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self._send(401, {}); return False
        return True

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        if not self._auth(): return
        Fake.seen_bodies.append(json.loads(body))
        self._send(*Fake.post)

    def do_GET(self):
        if not self._auth(): return
        if self.path.startswith("/agent/events/"):
            Fake.event_paths.append(self.path)
            if not Fake.events: self._send(404, {"status": "rejected"}); return
            code, obj = Fake.events.pop(0)
            if code == 204:
                self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers(); return
            self._send(code, obj); return
        s = Fake.statuses.pop(0) if len(Fake.statuses) > 1 else Fake.statuses[0]
        self._send(200, {"status": s, "remaining_sec": 10})

def run(cfg, args=("--reason", "测试")):
    # A dead proxy in the environment must not intercept the token-bearing loopback call.
    env = dict(os.environ, WINDOWSHARE_AGENT_JSON=cfg, http_proxy="http://127.0.0.1:1", HTTP_PROXY="http://127.0.0.1:1")
    p = subprocess.run([CLI, *args], env=env, capture_output=True, text=True, timeout=30)
    return p.returncode, p.stdout, p.stderr

def main():
    srv = HTTPServer(("127.0.0.1", 0), Fake)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    d = tempfile.mkdtemp()

    def write_cfg(name, port, token=TOKEN):
        p = os.path.join(d, name)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"v": 1, "port": port, "token": token, "entry": ENTRY}, f)
        return p

    good = write_cfg("good.json", port)
    # 取一个已关闭的端口
    s = HTTPServer(("127.0.0.1", 0), Fake); dead = s.server_address[1]; s.server_close()
    closed = write_cfg("closed.json", dead)
    badtok = write_cfg("bad.json", port, "00" * 32)
    missing = os.path.join(d, "nope.json")
    # A share killed with SIGKILL leaves its own registration (dead pid, closed port); the idle menu host it displaced
    # is still listed under "displaced" and is the host that answers.
    gone = subprocess.Popen(["true"]); gone.wait()
    killed = os.path.join(d, "killed.json")
    with os.fdopen(os.open(killed, os.O_WRONLY | os.O_CREAT, 0o600), "w") as f:
        json.dump({"v": 1, "port": dead, "token": "00" * 32, "entry": ENTRY, "pid": gone.pid,
                   "displaced": [{"v": 1, "port": port, "token": TOKEN, "entry": ENTRY, "pid": os.getpid()}]}, f)

    ok_line = f"请在手机打开：{LINK}\n"
    cases = []  # (name, cfg, post, statuses, args, code, stdout_check)
    def case(name, cfg, code, out=None, post=None, statuses=None, args=("--reason", "测试")):
        cases.append((name, cfg, post, statuses, args, code, out))

    created = (201, {"id": "11111111-2222", "entry": LINK})
    case("done", good, 0, ok_line, created, ["done"])
    case("done after pending", good, 0, ok_line, created, ["pending", "done"])
    case("cancelled", good, 3, ok_line, created, ["cancelled"])
    case("timeout", good, 4, ok_line, created, ["timeout"])
    case("no_window", good, 5, "请先共享窗口：WindowShareHost --app \"<App 名>\" --interact，或在 Mac 菜单栏选择窗口\n", (409, {"error": "no_window"}))
    case("busy", good, 2, "", (409, {"error": "busy"}))
    case("bare entry is not a share link", good, 2, "", (201, {"id": "11111111-2222", "entry": ENTRY}))
    case("host not running (no file)", missing, 2, "")
    case("host not running (port closed)", closed, 2, "")
    case("bad token (401)", badtok, 2, "")
    case("killed share: displaced menu host answers", killed, 0, ok_line, created, ["done"])
    case("timeout too small", good, 2, "", args=("--reason", "x", "--timeout", "29"))
    case("timeout too large", good, 2, "", args=("--reason", "x", "--timeout", "1801"))
    case("timeout not integer", good, 2, "", args=("--reason", "x", "--timeout", "abc"))
    case("missing reason", good, 2, "", args=())

    fails = 0
    for name, cfg, post, statuses, args, code, out in cases:
        Fake.post = post or created; Fake.statuses = list(statuses or ["done"])
        rc, so, se = run(cfg, args)
        errs = []
        if rc != code: errs.append(f"exit {rc} != {code}")
        if out is not None and so != out: errs.append(f"stdout {so!r} != {out!r}")
        if TOKEN in so + se or "00" * 32 in so + se: errs.append("token leaked")
        print(("PASS " if not errs else "FAIL ") + name + ("" if not errs else ": " + "; ".join(errs)))
        fails += bool(errs)

    # 请求体：reason 与 timeout_sec 原样送达
    Fake.seen_bodies.clear(); Fake.post = created; Fake.statuses = ["done"]
    run(good, ("--reason", "登录 AWS", "--timeout", "60"))
    exp = {"reason": "登录 AWS", "timeout_sec": 60}
    good_body = Fake.seen_bodies == [exp]
    print(("PASS " if good_body else "FAIL ") + f"request body {Fake.seen_bodies}")
    fails += not good_body

    # --events: woken by the host event route instead of sleeping 2 s; exit codes unchanged; left/disconnected only noted.
    import time
    rid = "11111111-2222"
    def ev(seq, kind, reason, request_id=rid, hint=None):
        e = {"seq": seq, "kind": kind, "reason": reason, "at": 1.0, "request_id": request_id}
        if hint: e["hint"] = hint
        return e
    ecases = [
        ("events: done", ["pending", "done"], [(200, {"events": [ev(1, "done", "phone_done")], "next": 1})], 0, None, ["/agent/events/0"]),
        ("events: cancelled", ["pending", "cancelled"], [(200, {"events": [ev(1, "cancelled", "phone_cancel")], "next": 1})], 3, None, None),
        ("events: timeout", ["pending", "timeout"], [(200, {"events": [ev(4, "timeout", "request_timeout")], "next": 4})], 4, None, None),
        ("events: left noted, keeps waiting, cursor advances", ["pending", "pending", "pending", "done"],
         [(200, {"events": [ev(3, "left", "stop_watching"), ev(4, "disconnected", "connection_lost", "other-id", "heartbeat_timeout")], "next": 4}),
          (204, None), (200, {"events": [ev(5, "disconnected", "connection_lost", hint="heartbeat_timeout")], "next": 5})], 0,
         "手机端 left（reason=stop_watching）；请求仍在等待\n手机端 disconnected（reason=connection_lost hint=heartbeat_timeout）；请求仍在等待\n",
         ["/agent/events/0", "/agent/events/4", "/agent/events/4"]),
        ("events: host without event route falls back to polling", ["pending", "done"], [], 0, "事件接口不可用（HTTP 404），改回轮询\n", None),
    ]
    for name, statuses, events, code, err, paths in ecases:
        Fake.post = created; Fake.statuses = list(statuses); Fake.events = list(events); Fake.event_paths = []
        started = time.monotonic()
        rc, so, se = run(good, ("--reason", "测试", "--events"))
        took = time.monotonic() - started
        errs = []
        if rc != code: errs.append(f"exit {rc} != {code}")
        if so != ok_line: errs.append(f"stdout {so!r}")
        if err is not None and se != err: errs.append(f"stderr {se!r} != {err!r}")
        if paths is not None and Fake.event_paths != paths: errs.append(f"event paths {Fake.event_paths}")
        if events and took >= 1.5: errs.append(f"took {took:.2f}s: slept instead of waiting on events")
        if TOKEN in so + se: errs.append("token leaked")
        print(("PASS " if not errs else "FAIL ") + name + ("" if not errs else ": " + "; ".join(errs)))
        fails += bool(errs)
    Fake.events = []

    print("ALL PASS" if not fails else f"{fails} FAILED")
    sys.exit(1 if fails else 0)

main()
