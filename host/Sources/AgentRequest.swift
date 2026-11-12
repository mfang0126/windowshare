import Foundation
import Security

/// One agent request asking the human to look at the shared window. Mutated only under PairingSession's lock.
struct AgentRequest {
    enum Status: String { case pending, done, cancelled, timeout }
    let id = UUID().uuidString
    let reason: String
    let deadline: TimeInterval
    var status = Status.pending
    var finishedAt: TimeInterval?
    static let retention: TimeInterval = 600

    mutating func finish(_ next: Status, at time: TimeInterval) {
        guard status == .pending else { return }
        status = next; finishedAt = time
        print("[agent] request status=\(next.rawValue)") // never the token or the reason
    }
    func remaining(_ time: TimeInterval) -> Int { status == .pending ? Int(max(0, deadline - time).rounded(.up)) : 0 }
}

/// `~/Library/Application Support/WindowShare/agent.json`: local-only credentials for the agent CLI.
enum AgentFile {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WindowShare")
    }
    static func newToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    /// The file records its writer's pid: another live instance's file is never replaced or removed.
    enum Failure: Error { case ownedByOther(pid_t) }
    static func read(in dir: URL = directory) -> [String: Any]? {
        (try? Data(contentsOf: dir.appendingPathComponent("agent.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    static func alive(_ pid: pid_t) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
    private static func pid(_ entry: [String: Any]) -> pid_t { (entry["pid"] as? Int).map(pid_t.init) ?? 0 }
    /// Registrations this file's owner took over, newest first, without the given pid and without exited processes.
    private static func chain(_ file: [String: Any], without self: pid_t) -> [[String: Any]] {
        ((file["displaced"] as? [[String: Any]]) ?? []).filter { pid($0) != self && alive(pid($0)) }
    }
    /// The registration that answers: the file's owner while it runs, else (owner killed, e.g. SIGKILL, so no hand-back
    /// ran) the newest live registration it had displaced. What `status` uses; `Scripts/windowshare-show` does the same.
    static func current(in dir: URL = directory) -> [String: Any]? {
        guard let file = read(in: dir) else { return nil }
        if file["pid"] == nil || alive(pid(file)) { return file }
        return chain(file, without: 0).first
    }
    /// While this process holds the share lock, a live lock-aware owner is idle (its share has ended), so the current
    /// share takes the file over (ADR 0003 rule 1: status/windowshare-show find the share that is open). A pre-lock
    /// owner (no `share_lock`) cannot say it is idle, so its file is never taken. The displaced registrations are kept
    /// in the file itself (`displaced`, newest first), not in this process's memory, so whichever process removes the
    /// file later can hand it back to a live idle host, in any exit order (HB1) and after a killed owner (HB3).
    static func write(port: UInt16, token: String, entry: String, entries: [String] = [], in dir: URL = directory, pid self: pid_t = getpid()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try exclusive(dir) {
            var displaced: [[String: Any]] = []
            if let file = read(in: dir) {
                let owner = pid(file)
                if owner != self, alive(owner) {
                    guard ShareLock.isHeld && file["share_lock"] as? Bool == true else { throw Failure.ownedByOther(owner) }
                    var previous = file; previous["displaced"] = nil
                    displaced = [previous]
                }
                displaced += chain(file, without: self)
            }
            var body: [String: Any] = ["v": 1, "port": Int(port), "token": token, "entry": entry, "entries": entries, "pid": Int(self), "share_lock": true]
            if !displaced.isEmpty { body["displaced"] = displaced }
            guard put(body, in: dir) else { throw NSError(domain: "WindowShare.Agent", code: 1) }
        }
    }
    private static func put(_ object: [String: Any], in dir: URL) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) else { return false } // stable bytes: a hand-back restores the original file exactly
        let temp = dir.appendingPathComponent("agent.json.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: body, attributes: [.posixPermissions: 0o600]),
              rename(temp.path, dir.appendingPathComponent("agent.json").path) == 0 else {
            try? FileManager.default.removeItem(at: temp); return false
        }
        return true
    }
    /// Own file: hand it back to the newest live displaced host (R2), else delete it. Another owner's file: only drop
    /// this process from its `displaced` list, so a host that is quitting is never written back after it exits (HB2).
    /// Without the lock the file is kept (N4): a lock-free check-then-remove could delete the next share's registration.
    static func remove(in dir: URL = directory, pid self: pid_t = getpid()) {
        guard FileManager.default.fileExists(atPath: dir.path) else { return } // no directory: nothing registered
        do {
            try exclusive(dir) {
                guard let file = read(in: dir) else { return }
                let rest = chain(file, without: self)
                if pid(file) == self {
                    if var back = rest.first {
                        if rest.count > 1 { back["displaced"] = Array(rest.dropFirst()) }
                        if put(back, in: dir) { return }
                    }
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("agent.json"))
                } else if let listed = file["displaced"] as? [[String: Any]], listed.contains(where: { pid($0) == self }) {
                    var kept = file; kept["displaced"] = rest.isEmpty ? nil : rest
                    _ = put(kept, in: dir)
                }
            }
        } catch { fputs("[agent] agent.lock unavailable; agent.json kept\n", stderr) }
    }
    /// Owner check and rename/remove of agent.json run under one cross-process flock (`agent.lock`), so an exiting
    /// host cannot delete a registration that the current share took over between its check and its remove (N1).
    /// Throws without running `body` when agent.lock cannot be opened or locked (N4).
    private static func exclusive<T>(_ dir: URL, _ body: () throws -> T) throws -> T {
        let fd = Darwin.open(dir.appendingPathComponent("agent.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: "WindowShare.Agent", code: Int(errno)) }
        defer { close(fd) } // closing drops the flock
        guard flock(fd, LOCK_EX) == 0 else { throw NSError(domain: "WindowShare.Agent", code: Int(errno)) }
        return try body()
    }
    /// Constant-time `Authorization: Bearer <token>` check.
    static func authorized(_ header: String?, token: String?) -> Bool {
        guard let header, let token, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst(7).utf8), expected = Array(token.utf8)
        var diff = given.count ^ expected.count
        for i in 0..<expected.count { diff |= Int(expected[i] ^ (i < given.count ? given[i] : 0)) }
        return diff == 0
    }
}

/// `share.lock`: one share per Mac (ADR 0003 rule 1/3). A non-blocking flock held for the whole share; the OS drops it
/// when the process exits. The file is never deleted (a new inode would allow a second lock); its body is only metadata.
enum ShareLock {
    struct Busy: Error {
        let owner: String; let pid: Int; let startedAt: Double
        /// 「正在被 X 使用」：who opened it and for how long.
        func message(now: Double = Date().timeIntervalSince1970) -> String {
            let elapsed = max(0, Int(now - startedAt))
            return "正在被 \(owner) 使用（pid \(pid)，已开 \(elapsed / 3600) 小时 \(elapsed % 3600 / 60) 分钟）；不排队，请稍后再试或问老板"
        }
    }
    static let busyExit: Int32 = 8
    private static var held: Int32 = -1
    static var isHeld: Bool { held >= 0 }
    private static func open(_ dir: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return Darwin.open(dir.appendingPathComponent("share.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    }
    /// The current holder, or nil when no process holds the lock (stale metadata of a killed process is ignored).
    static func holder(in dir: URL = AgentFile.directory) -> Busy? {
        let fd = open(dir)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }
        let body = (try? Data(contentsOf: dir.appendingPathComponent("share.lock"))) ?? Data()
        let info = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        return Busy(owner: info["owner"] as? String ?? "另一个共享", pid: info["pid"] as? Int ?? 0, startedAt: info["started_at"] as? Double ?? Date().timeIntervalSince1970)
    }
    /// Idempotent while this process already holds it; throws `Busy` immediately otherwise (never waits).
    static func acquire(owner: String, persistent: Bool = false, in dir: URL = AgentFile.directory) throws {
        guard held < 0 else { return }
        let fd = open(dir)
        guard fd >= 0 else { throw NSError(domain: "WindowShare.Lock", code: Int(errno)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw holder(in: dir) ?? Busy(owner: "另一个共享", pid: 0, startedAt: Date().timeIntervalSince1970)
        }
        held = fd
        let body = (try? JSONSerialization.data(withJSONObject: ["owner": owner, "pid": Int(getpid()), "persistent": persistent,
                                                                  "started_at": Date().timeIntervalSince1970])) ?? Data()
        ftruncate(fd, 0)
        _ = body.withUnsafeBytes { pwrite(fd, $0.baseAddress, body.count, 0) }
    }
    static func release() {
        guard held >= 0 else { return }
        ftruncate(held, 0); flock(held, LOCK_UN); close(held); held = -1
    }
}

/// The opener's lifetime (ADR 0003 rule 2/6): a normal share ends when the opener process exits; a persistent share
/// (`--persistent`) is not watched and ends only by the boss, the 12-hour limit or the Mac quitting.
enum ShareOwner {
    /// nil when persistent. `onExit` runs on `queue` once, also when the opener is already gone.
    static func watch(pid: pid_t, persistent: Bool, queue: DispatchQueue = .main, onExit: @escaping () -> Void) -> DispatchSourceProcess? {
        guard !persistent else { return nil }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { source.cancel(); onExit() }
        source.resume()
        if !AgentFile.alive(pid) { queue.async { if !source.isCancelled { source.cancel(); onExit() } } }
        return source
    }
    /// Default opener label: the parent process name and pid.
    static func label(pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &name, UInt32(name.count))
        return n > 0 ? "\(String(cString: name)) (pid \(pid))" : "pid \(pid)"
    }
}
