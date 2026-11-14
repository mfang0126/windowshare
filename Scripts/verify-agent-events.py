#!/usr/bin/env python3
"""Agent event channel (GET /agent/events/<after>): every event kind, auth, repeated subscribers, no sensitive fields,
left/disconnected never revoke the share, and the real HTTP long poll (`windowshare-show --events` is in verify-windowshare-show.py). No GUI, capture or input."""
from pathlib import Path
import http.client, json, os, socket, subprocess, tempfile, threading, time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['PairingSession.swift', 'ViewerPage.swift', 'EntryConfiguration.swift', 'InputController.swift',
           'CaptureController.swift', 'AgentRequest.swift', 'CLI.swift']
TOKEN = 'ab' * 32

UNIT = r'''import Foundation
var clock = 100.0
let token = String(repeating: "ab", count: 32)
let secretReason = "SECRET-REASON-登录"
PairingSession.leaveGrace = 45
let identity = PairingSession(now: { clock })
identity.installCleanup { _ in }
identity.configureAgent(token: token, entry: "http://100.1.2.3:8790/")
var binding = identity.selectWindow()
precondition(identity.activate(binding))
func reply(_ method: String, _ path: String, _ fields: [String: Any] = [:], _ cookies: [String: String] = [:],
           auth: String? = "Bearer " + token, loopback: Bool = true) -> PairingSession.Reply {
    var r: PairingSession.Reply!
    identity.respond(method: method, path: path, fields: fields, cookies: cookies, authorization: auth, loopback: loopback) { r = $0 }
    return r
}
func phone(_ method: String, _ path: String, _ fields: [String: Any] = [:], _ cookies: [String: String] = [:]) -> PairingSession.Reply {
    reply(method, path, fields, cookies, auth: nil, loopback: false)
}
func json(_ r: PairingSession.Reply) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:] }
var cursor = 0
/// New events since the last call (asserts the reply shape and that nothing sensitive is in it).
func drain() -> [[String: Any]] {
    let r = reply("GET", "/agent/events/\(cursor)")
    if r.status == 204 { return [] }
    precondition(r.status == 200, "events status \(r.status)")
    let text = String(decoding: r.body, as: UTF8.self)
    for bad in [token, secretReason, binding.windowID, binding.generation, "http", "/w/", "title", "entry", "window"] {
        precondition(!text.contains(bad), "sensitive \(bad) in \(text)")
    }
    let body = json(r)
    let list = body["events"] as! [[String: Any]]
    for e in list {
        precondition(Set(e.keys).isSubset(of: ["seq", "kind", "request_id", "at", "reason", "hint"]), "keys \(e.keys)")
        precondition(e["at"] is Double && e["reason"] is String && e["seq"] is Int && e.keys.contains("request_id"))
    }
    cursor = body["next"] as! Int
    return list
}
func kinds(_ list: [[String: Any]]) -> [String] { list.map { "\($0["kind"]!):\($0["reason"]!)" + (($0["hint"] as? String).map { "/" + $0 } ?? "") } }
func expect(_ want: [String], _ what: String, line: Int = #line) {
    let got = kinds(drain())
    precondition(got == want, "line \(line) \(what): got \(got) want \(want)")
}
var alive: [PairingSession.Context] = [] // viewers that answer heartbeats (a live phone page)
func tick(_ seconds: Double) { // the 1 s expiry tick, deterministically
    let end = clock + seconds
    while clock < end {
        clock += 1; _ = reply("GET", "/agent/status")
        for c in alive { if let nonce = identity.heartbeat(c) { _ = identity.pong(c, nonce: nonce) } }
    }
}
func viewer(keep: Bool = false) -> (cookies: [String: String], context: PairingSession.Context) {
    if !keep { for c in alive { identity.disconnect(c) } } // one phone page at a time unless asked
    let r = phone("POST", "/session", ["window_id": binding.windowID])
    precondition(r.status == 200)
    let kv = r.cookies[0].components(separatedBy: ";")[0].components(separatedBy: "=")
    let cookies = [kv[0]: kv[1]]
    let t = json(phone("POST", "/w/\(binding.windowID)/connect", [:], cookies))
    let context = identity.authenticate(ticket: t["ticket"] as! String, resource: t["resource"] as! String, cancel: {})!
    alive = keep ? alive + [context] : [context]
    return (cookies, context)
}
func request(_ timeout: Int = 300) -> String {
    let r = reply("POST", "/agent/request", ["reason": secretReason, "timeout_sec": timeout])
    precondition(r.status == 201)
    return json(r)["id"] as! String
}
func shareAlive() -> Bool { reply("GET", "/agent/status").body.count > 0 && json(reply("GET", "/agent/status"))["entry"] is String }

// Auth: same gate as every agent route.
precondition(reply("GET", "/agent/events/0", auth: nil).status == 401, "no token")
precondition(reply("GET", "/agent/events/0", auth: "Bearer " + String(repeating: "cd", count: 32)).status == 401, "wrong token")
precondition(reply("GET", "/agent/events/0", auth: token).status == 401, "token without Bearer")
precondition(reply("GET", "/agent/events/0", loopback: false).status == 403, "non-loopback")
precondition(reply("GET", "/agent/events/0", ["x": 1], ["ws-session": "x"]).status == 403, "cookies refused")
precondition(phone("GET", "/agent/events/0").status == 403, "phone route without loopback")
for bad in ["/agent/events/", "/agent/events/-1", "/agent/events/abc", "/agent/events/99999999999999999999999"] {
    precondition(reply("GET", bad).status == 400, bad)
}
precondition(reply("GET", "/agent/events/0").status == 204, "nothing yet")

// done: request + share end at once (the only event that revokes).
var id = request()
var v = viewer()
precondition(phone("POST", "/request/decision", ["id": id, "decision": "done"], v.cookies).status == 200)
var list = drain()
precondition(kinds(list) == ["done:phone_done", "share_ended:done"] && list.allSatisfy { $0["request_id"] as? String == id }, "\(kinds(list))")
precondition(!shareAlive(), "done ends the share at once")
tick(60); expect([], "no left/disconnected after the share ended")

// cancelled by the phone: request ends, share stays.
binding = identity.selectWindow(); precondition(identity.activate(binding))
id = request(); v = viewer()
precondition(phone("POST", "/request/decision", ["id": id, "decision": "cancel"], v.cookies).status == 200)
expect(["cancelled:phone_cancel"], "phone cancel")
precondition(shareAlive(), "cancel keeps the share")

// timeout.
id = request(30)
tick(31)
expect(["timeout:request_timeout"], "request timeout")
precondition(shareAlive(), "timeout keeps the share")

// left, explicit 「停止观看」: recorded only after N with no viewer, share kept.
id = request(1800) // outlives every step below
precondition(phone("POST", "/session/close", [:], v.cookies).status == 200); alive = []
tick(40); expect([], "before N")
tick(6); list = drain()
precondition(kinds(list) == ["left:stop_watching"] && list[0]["request_id"] as? String == id, "\(kinds(list))")
precondition(shareAlive(), "left keeps the share")
tick(60); expect([], "left is recorded once")

// left, page unload signal; a reload (new viewer) within N records nothing.
v = viewer(); _ = drain()
precondition(phone("POST", "/session/close", ["source": "unload"], v.cookies).status == 200); alive = []
tick(10); v = viewer(); tick(60); expect([], "reload within N is not a leave")
precondition(phone("POST", "/session/close", ["source": "unload"], v.cookies).status == 200); alive = []
tick(46); expect(["left:page_unload"], "page unload")
precondition(phone("POST", "/session/close", ["source": "other"], viewer().cookies).status == 400, "unknown source")
tick(2); _ = drain()

// disconnected, socket closed without a leave signal (closed tab, killed app, lost network: not told apart).
v = viewer(); _ = drain()
identity.disconnect(v.context); alive = []
tick(46); expect(["disconnected:connection_lost/connection_closed"], "socket closed")
precondition(shareAlive(), "disconnected keeps the share")

// disconnected, heartbeat timeout (no pong for 15 s).
v = viewer(); tick(2); _ = drain(); alive = [] // the phone stops answering (network gone)
tick(12); expect([], "heartbeat still in time")
tick(50); expect(["disconnected:connection_lost/heartbeat_timeout"], "heartbeat timeout")
precondition(shareAlive(), "disconnected keeps the share")

// The request id is the one current when the last viewer went, not when N ran out (request A ends, B starts meanwhile).
binding = identity.selectWindow(); precondition(identity.activate(binding)); _ = drain() // ends the pending request
var rA = request(30); v = viewer(); _ = drain()
identity.disconnect(v.context); alive = []
tick(31); expect(["timeout:request_timeout"], "A times out during N")
var rB = request(1800)
tick(20); list = drain()
precondition(kinds(list) == ["disconnected:connection_lost/connection_closed"] && list[0]["request_id"] as? String == rA && rA != rB, "attributed to A: \(list)")
_ = reply("GET", "/agent/status")
// No request when the viewer went: null, even if a request starts during N.
binding = identity.selectWindow(); precondition(identity.activate(binding)); _ = drain()
v = viewer(); identity.disconnect(v.context); alive = []; tick(2)
rB = request(1800); tick(45); list = drain()
precondition(kinds(list) == ["disconnected:connection_lost/connection_closed"] && list[0]["request_id"] is NSNull, "no request at loss: \(list)")

// Several viewers: only the last one to go decides.
var first = viewer(), second = viewer(keep: true); _ = drain()
precondition(phone("POST", "/session/close", [:], first.cookies).status == 200); alive = [second.context]
tick(50); expect([], "another viewer is still connected")
identity.disconnect(second.context); alive = []
tick(46); expect(["disconnected:connection_lost/connection_closed"], "last viewer dropped silently")
first = viewer(); second = viewer(keep: true); _ = drain()
identity.disconnect(second.context); alive = [first.context]; tick(5)
precondition(phone("POST", "/session/close", [:], first.cookies).status == 200); alive = []
tick(46); expect(["left:stop_watching"], "last viewer said it left")
_ = rA; _ = rB

// A page that closes without ever connecting a viewer records nothing.
binding = identity.selectWindow(); precondition(identity.activate(binding)); _ = drain()
let lone = phone("POST", "/session", ["window_id": binding.windowID])
let kv = lone.cookies[0].components(separatedBy: ";")[0].components(separatedBy: "=")
precondition(phone("POST", "/session/close", [:], [kv[0]: kv[1]]).status == 200)
tick(60); expect([], "closed without a viewer connection")
rB = request(1800)

// N is configurable.
PairingSession.leaveGrace = 5
v = viewer(); _ = drain(); identity.disconnect(v.context); alive = []
tick(3); expect([], "N=5 not yet"); tick(3); expect(["disconnected:connection_lost/connection_closed"], "N=5")
PairingSession.leaveGrace = 45

// share end with a pending request: cancelled then share_ended (reason is a fixed host word).
precondition(reply("POST", "/agent/request", ["reason": "x", "timeout_sec": 30]).status == 409, "still pending")
v = viewer(); _ = drain()
identity.revokeWindow()
list = drain()
precondition(kinds(list) == ["cancelled:share_ended", "share_ended:revokeWindow"] && list.allSatisfy { $0["request_id"] as? String == rB }, "\(kinds(list))")
tick(60); expect([], "no disconnected after the share ended")

// Repeated subscriptions: reading never consumes; same cursor, same events, for every reader.
let a = reply("GET", "/agent/events/0"), b = reply("GET", "/agent/events/0")
precondition(a.status == 200 && a.body == b.body, "same events for every reader")
let last = json(a)["next"] as! Int
precondition(reply("GET", "/agent/events/\(last)").status == 204 && reply("GET", "/agent/events/\(last)").status == 204, "caught up")
let reset = json(reply("GET", "/agent/events/\(last + 100)"))
precondition(reset["reset"] as? Bool == true && reset["next"] as? Int == last, "cursor from an older host process resets")
// Retention: only the newest 64 are kept; a reader that fell behind is told so.
binding = identity.selectWindow(); precondition(identity.activate(binding))
for _ in 0..<40 { _ = request(); _ = reply("GET", "/agent/status"); identity.revokeWindow(); binding = identity.selectWindow(); precondition(identity.activate(binding)) }
let old = json(reply("GET", "/agent/events/0"))
precondition((old["events"] as! [Any]).count == PairingSession.eventRetention && old["truncated"] as? Bool == true, "retention")
print("PASS agent events: done/cancelled/timeout/left(stop,unload)/disconnected(closed,heartbeat)/share_ended, N config, reload within N, auth 401/403/400, repeated readers, reset, retention, no sensitive fields, only done revokes, request id from loss time, last viewer decides")
'''

HTTP = r'''import Foundation
let identity = PairingSession()
identity.installCleanup { _ in }
let binding = identity.selectWindow()
precondition(identity.activate(binding))
identity.configureAgent(token: String(repeating: "ab", count: 32), entry: "http://100.1.2.3:\(CommandLine.arguments[1])/")
try! binding.windowID.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
let server = HTTPServer(identity: identity)
try server.start(port: UInt16(CommandLine.arguments[1])!)
RunLoop.main.run()
'''

def main():
    with tempfile.TemporaryDirectory(prefix='windowshare-events-') as directory:
        d = Path(directory)
        (d / 'main.swift').write_text(UNIT)
        subprocess.run(['swiftc', *[str(ROOT / 'host/Sources' / f) for f in SOURCES], str(d / 'main.swift'), '-o', str(d / 'unit')], check=True)
        out = subprocess.run([str(d / "unit")], check=True, stdout=subprocess.PIPE, text=True, timeout=60).stdout
        assert 'SECRET' not in out and TOKEN not in out, 'event log lines carry nothing sensitive'
        print(out.strip().splitlines()[-1])
        # Recording an event writes no log line (a stalled stdout pipe must not hold up frames, input or cleanup).
        src = (ROOT / 'host/Sources/PairingSession.swift').read_text()
        emit = src[src.index('private func emit('):src.index('private func finishRequest(')]
        assert 'print(' not in emit and 'fputs(' not in emit, 'no log line in emit'

        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
        (d / 'main.swift').write_text(HTTP)
        subprocess.run(['swiftc', *[str(ROOT / 'host/Sources' / f) for f in SOURCES + ['HTTPServer.swift', 'WebAppAssets.swift']],
                        str(d / 'main.swift'), '-o', str(d / 'http')], check=True)
        host = subprocess.Popen([str(d / 'http'), str(port), str(d / 'share-id')], stdout=subprocess.DEVNULL)

        def call(method, path, auth='Bearer ' + TOKEN, origin=None, cookie=None, body=None, timeout=6):
            conn = http.client.HTTPConnection('127.0.0.1', port, timeout=timeout)
            headers = {'Host': f'127.0.0.1:{port}'}
            if auth: headers['Authorization'] = auth
            if origin: headers['Origin'] = origin
            if cookie: headers['Cookie'] = cookie
            if method == 'POST': headers['Content-Type'] = 'application/json'; body = body or '{}'
            conn.request(method, path, body, headers)
            r = conn.getresponse(); result = r.status, r.read(); conn.close()
            return result
        try:
            for _ in range(100):
                try: call('GET', '/agent/status'); break
                except OSError: time.sleep(.05)
            share = (d / 'share-id').read_text()
            phone = dict(auth=None, origin=f'http://127.0.0.1:{port}')
            # Auth over the real parser: no token, wrong token, Origin (browser) all refused before any wait.
            assert call('GET', '/agent/events/0', auth=None)[0] == 401
            assert call('GET', '/agent/events/0', auth='Bearer ' + 'cd' * 32)[0] == 401
            assert call('GET', '/agent/events/0', origin=f'http://127.0.0.1:{port}')[0] == 403
            # The same parser gates as /agent/request: cookies, proxy headers, a non-loopback Host.
            for extra in ({'Cookie': 'ws-session=x'}, {'Forwarded': 'for=1.2.3.4'}, {'X-Forwarded-For': '1.2.3.4'}, {'Host': f'100.1.2.3:{port}'}):
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                conn.request('GET', '/agent/events/0', None, {'Host': f'127.0.0.1:{port}', 'Authorization': 'Bearer ' + TOKEN, **extra})
                r = conn.getresponse(); status = r.status; r.read(); conn.close()
                assert status == 403, (extra, status)
            # Long poll: no event → 204 after about 3 s.
            started = time.monotonic(); status, _ = call('GET', '/agent/events/0')
            held = time.monotonic() - started
            assert status == 204 and 2.5 <= held < 4.5, (status, held)
            # A waiting reader wakes as soon as the event happens (the phone cancels the agent's request).
            s, b = call('POST', '/agent/request', body=json.dumps({'reason': '测试', 'timeout_sec': 60}))
            assert s == 201
            rid = json.loads(b)['id']
            got = {}
            def wait(name):
                got[name] = (time.monotonic(), call('GET', '/agent/events/0'))
            readers = [threading.Thread(target=wait, args=(n,)) for n in ('a', 'b')]  # two subscribers at once
            for t in readers: t.start()
            time.sleep(.3)
            conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            conn.request('POST', '/session', json.dumps({'window_id': share}), {'Host': f'127.0.0.1:{port}', 'Origin': phone['origin'], 'Content-Type': 'application/json'})
            r = conn.getresponse(); cookie = r.getheader('Set-Cookie').split(';')[0]; r.read(); conn.close()
            closed = time.monotonic()
            assert call('POST', '/request/decision', cookie=cookie, body=json.dumps({'id': rid, 'decision': 'cancel'}), **phone)[0] == 200
            for t in readers: t.join()
            for name in ('a', 'b'):
                at, (status, body) = got[name]
                events = json.loads(body)['events']
                assert status == 200 and [(e['kind'], e['reason'], e['request_id']) for e in events] == [('cancelled', 'phone_cancel', rid)], (name, status, body)
                assert at - closed < 0.5, f'woke {at - closed:.2f}s after the decision'
            assert json.loads(call('GET', '/agent/status')[1])['entry'], 'cancel keeps the share'
            # At most 4 waiting readers; the 5th is refused at once.
            results = []
            ws = [threading.Thread(target=lambda: results.append(call('GET', '/agent/events/1')[0])) for _ in range(4)]
            for t in ws: t.start()
            time.sleep(.5)
            assert call('GET', '/agent/events/1')[0] == 429
            for t in ws: t.join()
            assert results == [204] * 4, results
            # Waiters that hang up early free their slot at the latest when their 3 s hold ends.
            gone = []
            for _ in range(4):
                sock = socket.create_connection(('127.0.0.1', port))
                sock.sendall(f'GET /agent/events/1 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {TOKEN}\r\n\r\n'.encode())
                gone.append(sock)
            time.sleep(.3)
            for sock in gone: sock.close()
            time.sleep(3.5)
            assert call('GET', '/agent/events/1')[0] == 204, 'slots released after hang-ups'
            print('PASS HTTP: long poll 204 after ~3 s, two readers woken within 0.5 s by the same cancel, auth/cookie/proxy/Host refused before waiting, 5th waiter 429, hung-up waiters release slots')

        finally:
            host.terminate(); host.wait()

main()
