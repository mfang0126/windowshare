// ADR 0003 share lifecycle: one share per Mac, opener lifetime, 12-hour limit, dead links after a share ends.
// Run from repo root:
// swiftc -parse-as-library host/Sources/{CaptureController,InputController,PairingSession,ViewerPage,EntryConfiguration,AgentRequest}.swift Scripts/verify-share-lifecycle.swift -o /tmp/verify-share-lifecycle && /tmp/verify-share-lifecycle
// Injected clock (no real waiting), a temp lock directory, child processes it owns. No listeners, capture, input or GUI.
import Foundation

@main struct VerifyShareLifecycle {
    /// VERIFY_KEEP_GOING=1 reports every failing check before exiting 1 (to show each scenario on an older commit).
    static var failed = false
    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        guard !ok else { return }
        fputs("FAIL line \(line): \(what)\n", stderr)
        if ProcessInfo.processInfo.environment["VERIFY_KEEP_GOING"] == nil { exit(1) }
        failed = true
    }
    static func main() {
        // Child mode: a second WindowShare instance that holds the lock until killed.
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "hold" {
            do { try ShareLock.acquire(owner: args[3], in: URL(fileURLWithPath: args[2])) } catch { exit(9) }
            print("ready"); fflush(stdout)
            sleep(60); exit(0)
        }
        // Child mode: one host process driving its own agent.json registration, one stdin command at a time.
        if args.count == 4, args[1] == "agent" { agentChild(dir: URL(fileURLWithPath: args[2]), role: args[3]) }
        lock(self: args[0]); owner(); limit(); commandStart(); link(); handBack(); relay(self: args[0])
        if failed { exit(1) }
        print("PASS ADR 0003: lock busy with opener+age, opener exit vs persistent, 12h limit with 10-min reminder from the start command, ended link 410, idle menu host registered again after a CLI share, relayed shares / menu quit / killed share keep the menu host registration")
    }

    /// Rule 1/3: a second instance is refused at once with who opened the share and for how long; OS exit frees it.
    static func lock(self exe: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        check(ShareLock.holder(in: dir) == nil, "no holder before any share")
        let child = Process(), out = Pipe()
        child.executableURL = URL(fileURLWithPath: exe); child.arguments = ["hold", dir.path, "bot-A"]; child.standardOutput = out
        try! child.run()
        check(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).hasPrefix("ready"), "child took the lock")
        let started = Date()
        do {
            try ShareLock.acquire(owner: "bot-B", in: dir)
            check(false, "second share must be refused")
        } catch let busy as ShareLock.Busy {
            check(Date().timeIntervalSince(started) < 0.5, "busy answer is immediate, no queueing")
            check(busy.owner == "bot-A" && busy.pid == Int(child.processIdentifier), "busy names the opener and its pid")
            let message = busy.message(now: busy.startedAt + 3 * 3600 + 25 * 60)
            check(message.hasPrefix("正在被 bot-A 使用") && message.contains("已开 3 小时 25 分钟"), "message: \(message)")
        } catch { check(false, "unexpected \(error)") }
        check(!ShareLock.isHeld, "refused caller holds nothing")
        child.terminate(); child.waitUntilExit()
        check(ShareLock.holder(in: dir) == nil, "OS released the lock when the holder exited; stale metadata ignored")
        do { try ShareLock.acquire(owner: "bot-B", in: dir) } catch { check(false, "lock free after holder exit") }
        check(ShareLock.isHeld, "acquired")
        check(ShareLock.holder(in: dir)?.owner == "bot-B", "holder metadata visible to other callers")
        ShareLock.release()
        check(ShareLock.holder(in: dir) == nil, "released at share end")
    }

    /// Rule 2/6: a normal share ends when its opener exits; a persistent share is not tied to it.
    static func owner() {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sleep"); opener.arguments = ["30"]
        try! opener.run()
        let queue = DispatchQueue(label: "verify.owner")
        let ended = DispatchSemaphore(value: 0)
        var persistentEnded = false
        let normal = ShareOwner.watch(pid: opener.processIdentifier, persistent: false, queue: queue) { ended.signal() }
        let persistent = ShareOwner.watch(pid: opener.processIdentifier, persistent: true, queue: queue) { persistentEnded = true }
        check(normal != nil && persistent == nil, "only a normal share watches its opener")
        check(ended.wait(timeout: .now() + 0.3) == .timedOut, "share stays while the opener runs")
        opener.terminate(); opener.waitUntilExit()
        check(ended.wait(timeout: .now() + 3) == .success, "opener exit ends the normal share")
        queue.sync {}
        check(!persistentEnded, "persistent share survives opener exit")
        // An opener already gone when the share starts ends it at once.
        let late = DispatchSemaphore(value: 0)
        let gone = ShareOwner.watch(pid: opener.processIdentifier, persistent: false, queue: queue) { late.signal() }
        check(late.wait(timeout: .now() + 3) == .success, "dead opener ends the share immediately")
        withExtendedLifetime((normal, gone)) {}
    }

    static func session(_ s: PairingSession, _ fields: [String: Any]) -> Int {
        var status = 0
        s.respond(method: "POST", path: "/session", fields: fields, cookies: [:]) { status = $0.status }
        return status
    }

    /// Rule 2: every share (persistent too) ends at 12 hours, with one reminder 10 minutes before. Injected clock.
    static func limit() {
        var clock = 1000.0
        let s = PairingSession(now: { clock })
        var events: [String] = []
        s.observeShare { event, _ in events.append(event) }
        let binding = s.selectWindow()
        check(s.activate(binding), "share active")
        let start = clock
        clock = start + 12 * 3600 - 600 - 1
        check(session(s, ["window_id": binding.windowID]) == 200 && events.isEmpty, "no reminder before 11h50m")
        clock = start + 12 * 3600 - 600
        _ = session(s, ["window_id": binding.windowID])
        check(events == ["reminder"], "reminder exactly 10 minutes ahead: \(events)")
        clock = start + 12 * 3600 - 1
        check(session(s, ["window_id": binding.windowID]) == 200 && events == ["reminder"], "one reminder only, still shared")
        clock = start + 12 * 3600
        check(session(s, ["window_id": binding.windowID]) == 410, "ended at the limit; link dead")
        check(events == ["reminder", "limit"] && !s.isCurrent(binding), "limit event, share gone: \(events)")
        // A new share gets a fresh 12 hours; durations are configurable.
        let next = s.selectWindow()
        check(s.activate(next), "next share")
        clock += 3600
        check(session(s, ["window_id": next.windowID]) == 200 && events.count == 2, "new share restarts the limit")
        PairingSession.shareLimit = 120; PairingSession.shareWarning = 30
        defer { PairingSession.shareLimit = 12 * 3600; PairingSession.shareWarning = 600 }
        let short = s.selectWindow()
        check(s.activate(short), "short share")
        clock += 90; _ = session(s, ["window_id": short.windowID])
        clock += 30; check(session(s, ["window_id": short.windowID]) == 410, "configured limit")
        check(events == ["reminder", "limit", "reminder", "limit"], "configured reminder+limit: \(events)")
    }

    /// Rule 2 (R3): the 12 hours count from the agent's start command, not from when the window was found (`--wait`).
    static func commandStart() {
        var clock = 1000.0
        let s = PairingSession(now: { clock })
        var events: [String] = []
        s.observeShare { event, _ in events.append(event) }
        let command = clock
        clock += 600 // --wait 600: the window shows up 10 minutes after the command
        let binding = s.selectWindow(startedAt: command)
        check(s.activate(binding), "share active")
        clock = command + 12 * 3600 - 600
        _ = session(s, ["window_id": binding.windowID])
        check(events == ["reminder"], "reminder at command + 11h50m: \(events)")
        clock = command + 12 * 3600
        check(session(s, ["window_id": binding.windowID]) == 410 && !s.isCurrent(binding), "ended at command + 12h")
    }

    /// Rule 5: the link belongs to one share. Bare entry never joins; after the share ends its link is gone, also once
    /// the next share runs on the same port; the next share hands out a new link.
    static func link() {
        let s = PairingSession(now: { 1 })
        let token = String(repeating: "ab", count: 32)
        s.configureAgent(token: token, entry: "http://100.1.2.3:8777/", entries: ["http://100.1.2.3:8777/", "http://192.168.0.9:8777/"])
        func agent(_ method: String, _ path: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            var body: [String: Any] = [:]
            s.respond(method: method, path: path, fields: fields, cookies: [:], authorization: "Bearer " + token, loopback: true) {
                body = (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] ?? [:]
            }
            return body
        }
        let a = s.selectWindow()
        check(s.activate(a), "share A")
        let linkA = "http://100.1.2.3:8777/w/" + a.windowID
        check(agent("GET", "/agent/status")["entry"] as? String == linkA, "status hands out A's link")
        check(agent("GET", "/agent/status")["entries"] as? [String] == [linkA, "http://192.168.0.9:8777/w/" + a.windowID], "every entry is A's link")
        check(agent("POST", "/agent/request", ["reason": "look", "timeout_sec": 60])["entry"] as? String == linkA, "request hands out A's link")
        check(session(s, ["window_id": a.windowID]) == 200, "A's link joins A")
        check(session(s, [:]) == 403, "bare entry does not join")
        s.revokeWindow()
        check(session(s, ["window_id": a.windowID]) == 410, "A's link dead right after A ends")
        check(agent("GET", "/agent/status")["entry"] is NSNull, "no link while nothing is shared")
        let b = s.selectWindow()
        check(s.activate(b) && b.windowID != a.windowID, "share B has a new id")
        check(session(s, ["window_id": a.windowID]) == 410, "A's link never joins B")
        check(session(s, [:]) == 403, "bare entry does not join B")
        check(session(s, ["window_id": b.windowID]) == 200, "B's own link joins B")
        check(agent("GET", "/agent/status")["entry"] as? String == "http://100.1.2.3:8777/w/" + b.windowID, "B's new link")
    }

    /// R2 hand-back: an idle menu host's agent.json taken over by a CLI share is restored when that share's process
    /// exits, so `status` / windowshare-show still find the menu host; a dead previous owner is not restored.
    static func handBack() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-agent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func idleMenuHost() -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["60"]; try! p.run(); return p
        }
        let menu = idleMenuHost()
        try! AgentFile.write(port: 8777, token: "menu-token", entry: "http://100.1.2.3:8777/", in: dir, pid: menu.processIdentifier)
        try! ShareLock.acquire(owner: "bot-B", in: dir)
        try! AgentFile.write(port: 8781, token: "cli-token", entry: "http://100.1.2.3:8781/", in: dir)
        check(AgentFile.read(in: dir)?["pid"] as? Int == Int(getpid()), "the CLI share took the idle menu host's registration")
        ShareLock.release(); AgentFile.remove(in: dir)
        let back = AgentFile.read(in: dir)
        check(back?["pid"] as? Int == Int(menu.processIdentifier) && back?["port"] as? Int == 8777 && back?["token"] as? String == "menu-token",
              "menu host registered again after the CLI share exits: \(String(describing: back))")
        // The previous owner is gone by the time the CLI share exits: nothing to hand back, the file is removed.
        try! ShareLock.acquire(owner: "bot-C", in: dir)
        try! AgentFile.write(port: 8783, token: "cli-token-2", entry: "http://100.1.2.3:8783/", in: dir)
        menu.terminate(); menu.waitUntilExit()
        ShareLock.release(); AgentFile.remove(in: dir)
        check(AgentFile.read(in: dir) == nil, "dead previous owner is not restored")
    }

    /// `write` (a share takes share.lock first; the menu host does not), `release`, `remove`, `exit`; "ok" after each.
    static func agentChild(dir: URL, role: String) -> Never {
        while let cmd = readLine() {
            switch cmd {
            case "write":
                if role == "share" { try! ShareLock.acquire(owner: "bot", in: dir) }
                try! AgentFile.write(port: role == "menu" ? 8777 : 8790, token: role + "-token", entry: "http://100.1.2.3/", in: dir)
            case "release": ShareLock.release()
            case "remove": AgentFile.remove(in: dir)
            default: exit(0)
            }
            print("ok"); fflush(stdout)
        }
        exit(0)
    }

    final class Host {
        let p = Process(), input = Pipe(), output = Pipe()
        init(_ exe: String, _ dir: URL, _ role: String) {
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = ["agent", dir.path, role]
            p.standardInput = input; p.standardOutput = output
            try! p.run()
        }
        var pid: Int { Int(p.processIdentifier) }
        func run(_ cmds: String...) {
            for cmd in cmds {
                input.fileHandleForWriting.write(Data((cmd + "\n").utf8))
                if cmd == "exit" { p.waitUntilExit(); continue }
                var line = Data()
                while true { let b = output.fileHandleForReading.readData(ofLength: 1); if b.isEmpty || b == Data("\n".utf8) { break }; line += b }
                check(String(decoding: line, as: UTF8.self) == "ok", "child \(pid) ran \(cmd)")
            }
        }
        func kill9() { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
    }

    /// Hand-back across processes: the menu host M stays registered whatever order shares A/B end or M quits in.
    static func relay(self exe: String) {
        func fresh() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ws-relay-" + UUID().uuidString) }
        func owner(_ dir: URL) -> Int? { AgentFile.read(in: dir)?["pid"] as? Int }
        // HB1: A ends (lock released, process still in its 10 s grace), B takes over from A, A exits, then B exits.
        for aFirst in [true, false] {
            let dir = fresh(); defer { try? FileManager.default.removeItem(at: dir) }
            let m = Host(exe, dir, "menu"), a = Host(exe, dir, "share"), b = Host(exe, dir, "share")
            m.run("write"); a.run("write", "release"); b.run("write")
            check(owner(dir) == b.pid, "B took over from A")
            if aFirst { a.run("remove", "exit"); check(owner(dir) == b.pid, "A's exit keeps B's registration"); b.run("release", "remove", "exit") }
            else { b.run("release", "remove", "exit"); check(owner(dir) == a.pid, "B hands back to A"); a.run("remove", "exit") }
            check(owner(dir) == m.pid && AgentFile.read(in: dir)?["token"] as? String == "menu-token",
                  "relay (A exits first: \(aFirst)) ends with the menu host registered: \(String(describing: AgentFile.read(in: dir)))")
            m.run("exit")
        }
        // HB2: M's quit cleanup runs while A owns the file, A exits before M does: no registration of M is left behind.
        do {
            let dir = fresh(); defer { try? FileManager.default.removeItem(at: dir) }
            let m = Host(exe, dir, "menu"), a = Host(exe, dir, "share")
            m.run("write"); a.run("write"); m.run("remove"); a.run("release", "remove", "exit")
            check(AgentFile.read(in: dir) == nil, "a quitting menu host is not written back: \(String(describing: AgentFile.read(in: dir)))")
            m.run("exit")
            check(AgentFile.read(in: dir) == nil, "no registration of the exited menu host")
        }
        // HB3: A is SIGKILLed (no cleanup runs); the next share C still hands the file back to M when it exits.
        do {
            let dir = fresh(); defer { try? FileManager.default.removeItem(at: dir) }
            let m = Host(exe, dir, "menu"), a = Host(exe, dir, "share"), c = Host(exe, dir, "share")
            m.run("write"); a.run("write"); a.kill9()
            c.run("write", "release", "remove", "exit")
            check(owner(dir) == m.pid, "after a killed share, the next share hands back to the menu host: \(String(describing: AgentFile.read(in: dir)))")
            m.run("exit")
        }
    }
}
