#!/usr/bin/env python3
"""ADR 0003 share ending, through the production MenuBarController end path.

R1: a stale limit event of share A never ends a newer share B nor releases B's lock.
R2: a live but idle host's agent.json does not block the share that now holds the lock.
S1: the boss pressing 「完成」 ends the share: link 410, cookie 401, lock released, `[share] ended reason=done`,
    and the agent can still read the final `done`.
N1: old host A checks agent.json is its own, new share B takes the file over, then A removes: B's file survives.
    Two real processes on a copy of AgentRequest.swift with a stdin barrier between A's owner check and its remove.
N2: CLI share A ends with 「完成」, share B starts from the menu during the 10 s grace: A's exit does not end B.
N3: A's opener exits, its exit event is still queued when A ends and B starts from the menu: B is not terminated.
N4: agent.lock cannot be opened (mode 0400): A's exit cleanup neither checks nor removes; agent.json is kept.

The share-end methods are copied verbatim from MenuBarController.swift (from `stopSharing()` up to `show(`) into
a harness whose UI, capture and input are inert stubs. Injected clock, temp lock dir, no listeners, capture,
input or GUI. Usage (repo root): python3 Scripts/verify-share-ending.py [--source <repo root to test>]
"""
import re, select, subprocess, sys, tempfile
from pathlib import Path

root = Path(sys.argv[sys.argv.index("--source") + 1] if "--source" in sys.argv else Path(__file__).resolve().parent.parent)
menu = (root / "host/Sources/MenuBarController.swift").read_text()
start = re.search(r"^    (@objc )?private func stopSharing\(\)", menu, re.M).start()
region = menu[start:menu.index("    private func show(")]
observe = re.search(r"private func (observeShare\w*)\(\)", region).group(1)
region = region.replace("@objc private func", "func").replace("private func", "func")

harness = r'''import Foundation
import AppKit
/// Counts NSApp.terminate instead of quitting (no NSApplication is started).
final class StubApp { var terminations = 0; func terminate(_ sender: Any?) { terminations += 1 }; func window(withWindowNumber: Int) -> NSWindow? { nil } }
let NSApp = StubApp()
final class StubCapture { func stopCapture() async {} }
final class Controller {
    let identity: PairingSession
    var capture: StubCapture?
    var selection: PairingSession.Binding?
    var targetLabel = ""
    var lastEnded: PairingSession.Binding?
    var autoShare: Int? = nil
    func stopControl() {}
    func rebuildMenu() {}
    init(_ s: PairingSession) { identity = s; OBSERVE() }
''' .replace("OBSERVE", observe) + region + r'''}
var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }
func cookie(_ reply: PairingSession.Reply) -> String {
    String(reply.cookies.first?.split(separator: ";").first?.dropFirst("ws-session=".count) ?? "")
}
@main struct VerifyShareEnding {
    static func main() {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        r2(dir.appendingPathComponent("r2"))
        var clock = 1000.0
        let s = PairingSession(now: { clock })
        let controller = Controller(s)
        let lockDir = dir.appendingPathComponent("lock")
        func session(_ fields: [String: Any], cookies: [String: String] = [:]) -> PairingSession.Reply {
            var out = PairingSession.Reply(status: 0, body: Data())
            s.respond(method: "POST", path: "/session", fields: fields, cookies: cookies) { out = $0 }
            return out
        }
        // R1: A hits the 12-hour limit; its main-queue callback is still pending when A is stopped and B starts.
        try! ShareLock.acquire(owner: "A", in: lockDir)
        let a = s.selectWindow(); controller.selection = a; _ = s.activate(a)
        clock += 12 * 3600
        _ = s.isCurrent(a) // expiry runs; its event to the controller is queued on main
        controller.stopSharing()
        try! ShareLock.acquire(owner: "B", in: lockDir)
        let b = s.selectWindow(); controller.selection = b; _ = s.activate(b)
        DispatchQueue.main.async {
            check(s.isCurrent(b) && controller.selection == b, "R1 stale A limit event leaves B shared")
            check(ShareLock.isHeld, "R1 B keeps its lock")
            s1(s, controller, lockDir, session: session)
        }
        dispatchMain()
    }
    static func s1(_ s: PairingSession, _ controller: Controller, _ lockDir: URL,
                   session: @escaping ([String: Any], [String: String]) -> PairingSession.Reply) {
        // A fresh share C, independent of how R1 went.
        controller.stopSharing()
        try! ShareLock.acquire(owner: "C", in: lockDir)
        let c = s.selectWindow(); controller.selection = c; _ = s.activate(c)
        let token = String(repeating: "ab", count: 32)
        s.configureAgent(token: token, entry: "http://127.0.0.1:1/")
        func agent(_ method: String, _ path: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            var body: [String: Any] = [:]
            s.respond(method: method, path: path, fields: fields, cookies: [:], authorization: "Bearer " + token, loopback: true) {
                body = (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] ?? [:]
            }
            return body
        }
        let joined = session(["window_id": c.windowID], [:])
        let human = ["ws-session": cookie(joined)]
        let id = agent("POST", "/agent/request", ["reason": "login", "timeout_sec": 60])["id"] as? String ?? ""
        var decided = 0
        s.respond(method: "POST", path: "/request/decision", fields: ["id": id, "decision": "done"], cookies: human) { decided = $0.status }
        check(joined.status == 200 && decided == 200, "S1 boss pressed 完成 (decision 200)")
        check(session(["window_id": c.windowID], [:]).status == 410, "S1 link dead at once (410)")
        check(session([:], [:]).status == 403, "S1 bare entry 403")
        var meta = 0
        s.respond(method: "GET", path: "/w/\(c.windowID)/meta", fields: [:], cookies: human) { meta = $0.status }
        check(meta == 401, "S1 old cookie rejected (\(meta))")
        check(agent("GET", "/agent/request/" + id)["status"] as? String == "done", "S1 agent still reads done")
        DispatchQueue.main.async {
            check(controller.selection == nil && !ShareLock.isHeld && ShareLock.holder(in: lockDir) == nil, "S1 share ended and lock released")
            n2(s, controller, lockDir)
        }
    }
    /// N2: CLI process; A ends with 完成 (10 s grace), B starts from the menu inside the grace, A's grace elapses.
    static func n2(_ s: PairingSession, _ controller: Controller, _ lockDir: URL) {
        controller.autoShare = 1
        try! ShareLock.acquire(owner: "A", in: lockDir)
        let a = s.selectWindow(); controller.selection = a; _ = s.activate(a)
        controller.endShare(a, reason: "done")
        try! ShareLock.acquire(owner: "B", in: lockDir) // what the menu's share() does first
        let b = s.selectWindow(); controller.selection = b; _ = s.activate(b)
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
            check(NSApp.terminations == 0, "N2 A's done grace does not terminate the host (terminations=\(NSApp.terminations))")
            check(s.isCurrent(b) && controller.selection == b && ShareLock.isHeld, "N2 B still shared and holds its lock")
            controller.endShare(b, reason: "window_closed") // B's own end still exits the CLI process
            DispatchQueue.main.async {
                check(NSApp.terminations == 1, "N2 B's own end exits the CLI process (terminations=\(NSApp.terminations))")
                n3(s, controller, lockDir)
            }
        }
    }
    /// N3: the CLI opener's exit ends only its own share; an exit event already queued when A ends must not reach B.
    static func n3(_ s: PairingSession, _ controller: Controller, _ lockDir: URL) {
        let opener = Process(), input = Pipe()
        opener.executableURL = URL(fileURLWithPath: "/bin/cat"); opener.standardInput = input; opener.standardOutput = FileHandle.nullDevice
        try! opener.run()
        controller.watchOpener(pid: opener.processIdentifier, persistent: false)
        try! ShareLock.acquire(owner: "A", in: lockDir)
        let a = s.selectWindow(); controller.selection = a; _ = s.activate(a)
        let before = NSApp.terminations
        input.fileHandleForWriting.closeFile(); usleep(800_000) // opener exits; main is blocked, so its exit event stays queued
        controller.endShare(a, reason: "done")
        try! ShareLock.acquire(owner: "B", in: lockDir)
        let b = s.selectWindow(); controller.selection = b; _ = s.activate(b)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            check(!opener.isRunning && NSApp.terminations == before, "N3 ended A's opener exit does not terminate menu share B (terminations=\(NSApp.terminations - before))")
            check(s.isCurrent(b) && controller.selection == b && ShareLock.isHeld, "N3 B still shared and holds its lock")
            finish()
        }
    }
    static func finish() -> Never {
        fflush(stdout)
        print(failures == 0 ? "PASS share ending (R1 R2 S1 N2 N3)" : "FAILED \(failures) check(s)"); exit(failures == 0 ? 0 : 1)
    }
    /// R2: host A (alive, its share ended) still owns agent.json; B holds the share lock and must take it over.
    static func r2(_ dir: URL) {
        let idle = Process()
        idle.executableURL = URL(fileURLWithPath: "/bin/sleep"); idle.arguments = ["30"]
        try! idle.run()
        defer { idle.terminate(); idle.waitUntilExit() }
        let a = idle.processIdentifier
        try! AgentFile.write(port: 1, token: "a", entry: "http://a/", in: dir, pid: a)
        check((try? AgentFile.write(port: 2, token: "b", entry: "http://b/", in: dir)) == nil, "R2 no takeover without the share lock")
        try! ShareLock.acquire(owner: "B", in: dir)
        defer { ShareLock.release() }
        do { try AgentFile.write(port: 2, token: "b", entry: "http://b/", in: dir) } catch { check(false, "R2 share holder takes agent.json from idle host: \(error)"); return }
        check(AgentFile.read(in: dir)?["pid"] as? Int == Int(getpid()) && AgentFile.read(in: dir)?["port"] as? Int == 2, "R2 agent.json points at the current share")
        AgentFile.remove(in: dir, pid: a)
        check(AgentFile.read(in: dir)?["port"] as? Int == 2, "R2 idle host cleanup leaves the new registration")
        // A pre-lock (legacy) host never says its share ended; its file is never taken.
        let legacy = try! JSONSerialization.data(withJSONObject: ["v": 1, "port": 8777, "token": "x", "entry": "http://x/", "entries": [], "pid": Int(a)])
        try! legacy.write(to: dir.appendingPathComponent("agent.json"))
        check((try? AgentFile.write(port: 3, token: "c", entry: "http://c/", in: dir)) == nil, "R2 legacy live host keeps its agent.json")
    }
}
'''

def n1_race(tmp):
    """A: registered, share ended (idle, alive); A's exit cleanup passes its owner check and stops at a barrier;
    B takes the share lock and agent.json over; A's remove resumes. True when B's registration survives."""
    agent = (root / "host/Sources/AgentRequest.swift").read_text()
    mark = re.compile(r'^(\s*)(try\? FileManager\.default\.removeItem\(at: dir\.appendingPathComponent\("agent\.json"\)\))$', re.M)
    assert len(mark.findall(agent)) == 1, "remove() line not found"
    agent = mark.sub(r'\1if CommandLine.arguments[1] == "A" { print("A_CHECKED"); fflush(stdout); _ = readLine() }\n\1\2', agent)
    (tmp / "AgentRequest-barrier.swift").write_text(agent)
    (tmp / "race.swift").write_text('''import Foundation
@main struct Race { static func main() throws {
    let mode = CommandLine.arguments[1], dir = URL(fileURLWithPath: CommandLine.arguments[2])
    try ShareLock.acquire(owner: mode, in: dir)
    try AgentFile.write(port: mode == "A" ? 1 : 2, token: mode, entry: "http://\\(mode)/", in: dir)
    if mode == "A" { ShareLock.release(); print("A_IDLE"); fflush(stdout); _ = readLine(); AgentFile.remove(in: dir) }
    else { print("B_REGISTERED"); fflush(stdout); _ = readLine(); ShareLock.release() }
}}
''')
    exe, state = tmp / "race", tmp / "n1"
    build = subprocess.run(["swiftc", "-parse-as-library", str(tmp / "AgentRequest-barrier.swift"), str(tmp / "race.swift"), "-o", str(exe)],
                           capture_output=True, text=True)
    if build.returncode: print(build.stderr[-4000:]); return False
    def line(proc, timeout):
        return proc.stdout.readline().strip() if select.select([proc.stdout], [], [], timeout)[0] else None
    a = subprocess.Popen([str(exe), "A", str(state)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    b = None
    try:
        assert line(a, 10) == "A_IDLE"
        a.stdin.write("exit\n"); a.stdin.flush()               # A's exit cleanup starts
        assert line(a, 10) == "A_CHECKED"                       # A read agent.json: still A's
        b = subprocess.Popen([str(exe), "B", str(state)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        early = line(b, 3)                                      # unguarded: B renames over A's file now
        print("info B registered before A's remove resumed:", early == "B_REGISTERED", "(blocked on agent.lock otherwise)")
        a.stdin.write("go\n"); a.stdin.flush(); a.wait(timeout=10)  # A's remove runs
        registered = early or line(b, 10)
        file = (state / "agent.json")
        owner = __import__("json").loads(file.read_text()).get("pid") if file.exists() else None
        print(f"info B={registered} agent.json pid={owner} B pid={b.pid}")
        return registered == "B_REGISTERED" and owner == b.pid
    finally:
        for proc in (a, b):
            if proc and proc.poll() is None:
                try: proc.stdin.write("\n"); proc.stdin.flush(); proc.wait(timeout=5)
                except Exception: proc.kill()

def n4_unlockable(tmp):
    """agent.lock opens read-only only: A's exit cleanup must not run its check-then-remove without the lock."""
    exe, state = tmp / "race", tmp / "n4"
    a = subprocess.Popen([str(exe), "A", str(state)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert a.stdout.readline().strip() == "A_IDLE"
        (state / "agent.lock").chmod(0o400)
        a.stdin.write("exit\n"); a.stdin.flush()
        out, err = a.communicate("go\n", timeout=10)
        kept = (state / "agent.json").exists()
        print(f"info A checked without lock={'A_CHECKED' in out} agent.json kept={kept} stderr={err.strip()!r}")
        return "A_CHECKED" not in out and kept
    finally:
        if a.poll() is None: a.kill()
        if (state / "agent.lock").exists(): (state / "agent.lock").chmod(0o600)

src = ["CaptureController", "InputController", "PairingSession", "ViewerPage", "EntryConfiguration", "AgentRequest"]
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / "harness.swift").write_text(harness)
    exe = tmp / "verify-share-ending"
    build = subprocess.run(["swiftc", "-parse-as-library", *[str(root / f"host/Sources/{n}.swift") for n in src],
                            str(tmp / "harness.swift"), "-o", str(exe)], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr[-4000:]); print("FAILED to compile harness against", root); sys.exit(1)
    run = subprocess.run([str(exe), str(tmp / "state")], capture_output=True, text=True, timeout=60)
    print(run.stdout, end=""); print(run.stderr, end="", file=sys.stderr)
    ended = "[share] ended reason=done" in run.stdout
    print(("ok   " if ended else "FAIL ") + "S1 opener told on stdout: [share] ended reason=done")
    n1 = n1_race(tmp)
    print(("ok   " if n1 else "FAIL ") + "N1 old host's cleanup (check, B takes over, remove) leaves B's agent.json")
    n4 = n1 and n4_unlockable(tmp)
    print(("ok   " if n4 else "FAIL ") + "N4 unopenable agent.lock: no lock-free check/remove, agent.json kept")
    sys.exit(run.returncode or (0 if ended and n1 and n4 else 1))
