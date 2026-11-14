import Foundation
import CoreFoundation
import CryptoKit
import Security

/// Window-bound network sessions, frame ownership and single-driver authority.
final class PairingSession {
    struct Binding: Equatable {
        let windowID: String
        let generation: String
        var json: [String: Any] { ["window_id": windowID, "window_generation": generation] }
    }
    struct Reply {
        var status: Int
        var body: Data
        var type = "application/json"
        var cookies: [String] = []
        var headers: [String: String] = [:]
        static func json(_ status: Int, _ value: [String: Any]) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        }
    }
    /// F-4: which caller observed the geometry that revoked the share.
    enum GeometrySource: String { case capture, input, commitGate = "commit_gate" }
    /// F-4: which native geometry check failed (checks run in this order and stop at the first failure; fields of
    /// later checks keep false / -1). Only a fixed check name, booleans and counts are ever logged: never a title,
    /// coordinate, pixel, link or token.
    struct GeometryFailure: Error, CustomStringConvertible {
        enum Check: String {
            case launchDate = "launch_date", windowCount = "window_count", windowIdentity = "window_identity", bounds
            case displayCount = "display_count", displayMode = "display_mode", modeWidth = "mode_width", nonFinite = "non_finite"
            case noReader = "no_reader"
        }
        var check: Check
        var launchOK = false, windows = -1, idOK = false, pidOK = false, boundsOK = false
        var displayQueryOK = false, displays = -1, modeOK = false, modeWidthOK = false, values = -1
        var description: String {
            "check=\(check.rawValue) launch_ok=\(launchOK) windows=\(windows) id_ok=\(idOK) pid_ok=\(pidOK) bounds_ok=\(boundsOK) " +
            "display_query_ok=\(displayQueryOK) displays=\(displays) mode_ok=\(modeOK) mode_width_ok=\(modeWidthOK) values=\(values)"
        }
    }
    private struct Pair {
        let binding: Binding; let deadline: TimeInterval
        let principal = UUID().uuidString
        let id = UUID().uuidString
    }
    private struct Session { let pair: String; let binding: Binding; let deadline: TimeInterval; let id = UUID().uuidString }
    struct Context: Equatable {
        let principalID: String
        let pairingID: String
        let sessionID: String
        let connectionID: String
        let sessionEpoch: String
        let binding: Binding
    }
    private struct Ticket { let session: String; let resource: String; let deadline: TimeInterval }
    private struct Connection {
        let context: Context; let session: String; let cancel: () -> Void
        var pongAt: TimeInterval; var nonce: String?; var pingAt: TimeInterval
    }
    private struct Lease {
        let id: String; let epoch: Int; let owner: Context; let deadline: TimeInterval
        let operation: String; let ttl: Int
        var sequence = 0
        var execution: UUID?
    }
    private let sessionEpoch = UUID().uuidString
    private var tickets: [String: Ticket] = [:]
    private var connections: [String: Connection] = [:]
    private var lease: Lease?
    private var leaseEpoch = 0
    private var cleanupSerial = 0
    private var cleanupFailed = false
    private func controlAllowed(_ context: Context) -> Bool {
        active && binding == context.binding
    }
    private var cleanupPending: Int?
    private var cleanupHandler: ((Int) -> Void)?
    private var deferred: [() -> Void] = []
    private var geometry: [Double]?
    private var geometryEpoch = 0
    private var geometrySince: UInt64 = 0
    struct FrameProvenance {
        fileprivate let binding: Binding
        fileprivate let geometry: [Double]
        fileprivate let epoch: Int
        fileprivate let displayTime: UInt64
        fileprivate let size: [Int]
    }
    private var frameProvenance: FrameProvenance?
    private var retiredOperations: Set<String> = []
    private var releasedDecisions: [String: String] = [:]
    private struct Stream {
        let session: String
        let binding: Binding
        let cancel: () -> Void
    }
    private var streams: [UUID: Stream] = [:]
    private var frameSequence: UInt64 = 0
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var binding: Binding?
    private var active = false
    private var frame: Data?
    private var size: [Int] = []
    private var pairs: [String: Pair] = [:]
    private var sessions: [String: Session] = [:]
    private var expiryTimer: DispatchSourceTimer?
    private var agentToken: String?
    private var agentEntry = ""
    private var agentEntries: [String] = []
    /// Share limit (ADR 0003): every share ends `shareLimit` after it starts, with a reminder `shareWarning` before.
    /// Measured on this object's clock, so tests inject time instead of waiting.
    static var shareLimit: TimeInterval = 12 * 3600
    static var shareWarning: TimeInterval = 600
    private var shareDeadline: TimeInterval?
    private var shareWarned = false
    private var shareObserver: ((String, Binding) -> Void)?
    /// Told (outside the lock) "reminder" once, then "limit" or "done" once that share has ended, always with the
    /// binding of the share it is about: the observer acts only while that share is still its current one.
    func observeShare(_ observer: ((String, Binding) -> Void)?) { locked { shareObserver = observer } }
    private var agentRequest: AgentRequest?
    /// Agent event channel (`GET /agent/events/<after>`, loopback + Bearer only). Each event carries only
    /// seq / kind / request_id / at / reason (+ optional hint): never a title, pixel, link, share id, token or request text.
    private var events: [(seq: Int, body: [String: Any])] = []
    private var eventSeq = 0
    static let eventRetention = 64
    /// N: how long no viewer may be connected before `left` (after an explicit leave) or `disconnected` (no explicit leave)
    /// is recorded; a reconnect within N records nothing. Default 45 s, pending Ming's decision; `WINDOWSHARE_LEAVE_SEC` (1–3600).
    static var leaveGrace: TimeInterval = ProcessInfo.processInfo.environment["WINDOWSHARE_LEAVE_SEC"]
        .flatMap(Double.init).flatMap { (1...3600).contains($0) ? $0 : nil } ?? 45
    private var viewerSeen = false
    private var viewerGoneAt: TimeInterval?
    private var leaveReason: String?
    private var lossHint = "connection_closed"
    private var goneRequest: String? // the request pending when the last viewer went (not when N ran out), else nil
    private var agentWindow: [String: Any]?
    private var interactObserver: ((Bool) -> Void)?
    /// Told (outside the lock) whenever a lease starts or ends, so capture can tune itself for Interact (M2-a).
    func observeInteract(_ observer: ((Bool) -> Void)?) { locked { interactObserver = observer } }

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "windowshare.expiry"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.locked { self?.expire() } }
        timer.resume()
        expiryTimer = timer
    }
    deinit { expiryTimer?.cancel() }

    private func locked<T>(_ action: () -> T) -> T {
        lock.lock()
        expire(); pruneControl()
        defer {
            pruneControl(); pruneStreams(); trackPresence()
            let work = deferred; deferred.removeAll()
            lock.unlock()
            for callback in work { callback() }
        }
        return action()
    }
    private static func secret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func digest(_ value: String?) -> String? {
        guard let value, value.utf8.count == 43,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func cookie(_ name: String, _ value: String = "") -> String {
        "ws-\(name)=\(value); HttpOnly; SameSite=Strict; Path=/" + (value.isEmpty ? "; Max-Age=0" : "")
    }
    func configureAgent(token: String, entry: String, entries: [String] = []) {
        locked { agentToken = token; agentEntry = entry; agentEntries = entries.isEmpty ? [entry] : entries }
    }
    /// The share link (ADR 0003 rule 5): `<entry>w/<id of this share>`; it stops working the moment the share ends.
    static func shareLink(_ entry: String, _ binding: Binding) -> String {
        (entry.hasSuffix("/") ? entry : entry + "/") + "w/" + binding.windowID
    }
    /// Metadata of the shared window for `/agent/status`; reported only while a window is active.
    func configureAgentWindow(_ info: [String: Any]) { locked { agentWindow = info } }
    private func clearWindow(_ reason: StaticString) {
        fputs("[session] window revoked reason=\(reason)\n", stderr)
        finishRequest(.cancelled, "share_ended")
        if binding != nil { emit("share_ended", "\(reason)") }
        viewerSeen = false; viewerGoneAt = nil; leaveReason = nil // the share is over: no left / disconnected for it
        active = false // revoke before clearing output and credentials
        binding = nil; frame = nil; size = []
        shareDeadline = nil
        geometry = nil; geometryEpoch += 1; frameProvenance = nil; geometrySince = mach_absolute_time()
        pairs.removeAll(); sessions.removeAll()
    }
    /// `startedAt` (this object's clock): when the agent sent the start command; the 12 hours count from there.
    @discardableResult func selectWindow(startedAt: TimeInterval? = nil) -> Binding {
        locked {
            clearWindow("select")
            let next = Binding(windowID: UUID().uuidString, generation: UUID().uuidString)
            binding = next
            shareDeadline = (startedAt ?? now()) + Self.shareLimit; shareWarned = false
            return next
        }
    }
    /// Called only after the particular capture start completes. Never revives a stopped selection.
    func activate(_ expected: Binding) -> Bool {
        locked { guard binding == expected else { return false }; active = true; return true }
    }
    func isCurrent(_ expected: Binding) -> Bool { locked { binding == expected } }
    func revokeWindow(_ expected: Binding? = nil) {
        locked { if expected == nil || binding == expected { clearWindow("revokeWindow") } }
    }
    /// Called before conversion with geometry from the sample, never a publication-time relabel.
    func frameProvenance(geometry value: [Double], size: [Int], displayTime: UInt64,
                         binding expected: Binding) -> FrameProvenance? {
        locked {
            guard active, binding == expected, geometry == value,
                  displayTime >= geometrySince, displayTime <= mach_absolute_time(),
                  size.count == 2, size.allSatisfy({ $0 > 0 && $0 <= 2560 }) else { return nil }
            return FrameProvenance(binding: expected, geometry: value, epoch: geometryEpoch,
                                   displayTime: displayTime, size: size)
        }
    }
    func publish(_ data: Data, size: [Int], binding expected: Binding, provenance: FrameProvenance? = nil) {
        locked {
            expire()
            guard active, binding == expected, let provenance,
                  provenance.binding == expected,
                  provenance.geometry == geometry, provenance.epoch == geometryEpoch,
                  provenance.displayTime >= geometrySince, provenance.size == size,
                  frameProvenance.map({ provenance.displayTime > $0.displayTime }) ?? true,
                  data.count <= 16 * 1024 * 1024 else { return }
            frameSequence &+= 1
            frame = data; self.size = size; frameProvenance = provenance
        }
    }
    private func expire() {
        let time = now()
        guard time.isFinite else { clearWindow("nonFiniteTime"); return }
        if let deadline = shareDeadline, let current = binding {
            if time >= deadline {
                clearWindow("shareLimit")
                if let shareObserver { deferred.append { shareObserver("limit", current) } }
            } else if !shareWarned, time >= deadline - Self.shareWarning {
                shareWarned = true
                if let shareObserver { deferred.append { shareObserver("reminder", current) } }
            }
        }
        if let request = agentRequest {
            if request.status == .pending, time >= request.deadline { finishRequest(.timeout, "request_timeout") }
            if let end = request.finishedAt, time - end >= AgentRequest.retention { agentRequest = nil }
        }
        let pairCount = pairs.count, sessionCount = sessions.count
        pairs = pairs.filter { $0.value.deadline > time }
        sessions = sessions.filter { $0.value.deadline > time && pairs[$0.value.pair] != nil }
        if pairCount != pairs.count || sessionCount != sessions.count { frame = nil; size = [] }
    }

    private func valid(_ stream: Stream) -> Bool {
        guard active, binding == stream.binding, let session = sessions[stream.session],
              session.binding == stream.binding, session.deadline > now(),
              let pair = pairs[session.pair], pair.deadline > now() else { return false }
        return pair.binding == stream.binding
    }
    private func pruneStreams() {
        for (id, stream) in streams where !valid(stream) {
            streams[id] = nil
            stream.cancel() // Must be nonblocking; never reenter this authority.
        }
    }
    /// Header commit and registration share the same authorization boundary as frame sends.
    func openStream(path: String, cookies: [String: String], cancel: @escaping () -> Void,
                    commit: (UUID?, Reply) -> Void) {
        locked {
            expire()
            guard let key = Self.digest(cookies["ws-session"]), let session = sessions[key] else {
                commit(nil, .json(401, ["status": "rejected"])); return
            }
            let stream = Stream(session: key, binding: session.binding, cancel: cancel)
            guard valid(stream) else { commit(nil, .json(401, ["status": "rejected"])); return }
            guard path == "/w/\(session.binding.windowID)/stream" else {
                commit(nil, .json(403, ["status": "rejected"])); return
            }
            let id = UUID()
            streams[id] = stream
            commit(id, Reply(status: 200, body: Data(), type: "multipart/x-mixed-replace; boundary=windowshare"))
        }
    }
    func closeStream(_ id: UUID) { locked { streams[id] = nil } }
    /// Called only when the peer has no send in flight. No per-peer frame queue.
    func sendFrame(_ id: UUID, after sequence: UInt64, commit: (Data, UInt64) -> Void) {
        locked {
            expire()
            guard let stream = streams[id], valid(stream), frameSequence != sequence, let frame else { return }
            commit(frame, frameSequence)
        }
    }

    // H2: callbacks must enqueue work, never synchronously wait for the main queue.
    func installCleanup(_ handler: @escaping (Int) -> Void) { locked { cleanupHandler = handler } }
    // The effect is lazy: validate before native work, and keep authority transitions
    // excluded through the effect and acknowledgement. It must not reenter this object.
    func finishCleanup(epoch: Int, success: @autoclosure () -> Bool) {
        locked {
            guard cleanupPending == epoch, !cleanupFailed else { return }
            guard success() else { cleanupFailed = true; return }
            cleanupPending = nil
        }
    }
    private func current(_ context: Context) -> Bool {
        guard let connection = connections[context.connectionID], connection.context == context,
              now() - connection.pongAt < 15 else { return false }
        return valid(Stream(session: connection.session, binding: context.binding, cancel: {}))
    }
    private func scheduleCleanup() {
        cleanupSerial += 1; cleanupPending = cleanupSerial; cleanupFailed = false
        if let cleanupHandler { let epoch = cleanupSerial; deferred.append { cleanupHandler(epoch) } }
    }
    private func revokeLease(_ reason: StaticString) {
        guard let previous = lease else { return }
        fputs("[session] lease revoked reason=\(reason)\n", stderr)
        lease = nil
        if let interactObserver { deferred.append { interactObserver(false) } }
        retiredOperations.insert(previous.owner.sessionID + ":" + previous.operation)
        scheduleCleanup()
    }
    private func pruneControl() {
        tickets = tickets.filter { _, ticket in
            guard ticket.deadline > now(), let session = sessions[ticket.session] else { return false }
            return valid(Stream(session: ticket.session, binding: session.binding, cancel: {}))
        }
        for (id, connection) in connections where !current(connection.context) {
            lossHint = now() - connection.pongAt >= 15 ? "heartbeat_timeout" : "connection_closed"
            connections[id] = nil
            sessions[connection.session] = nil
            deferred.append(connection.cancel)
        }
        for key in Array(pairs.keys) where !sessions.values.contains(where: { $0.pair == key }) {
            pairs[key] = nil
        }
        if let lease, lease.deadline <= now() || !current(lease.owner) || !controlAllowed(lease.owner) { revokeLease("expiredOrNotAllowed") }
        // Replay guards only matter while their session or connection is alive; without this the 256 caps lock control for good.
        let liveSessions = Set(sessions.values.map(\.id))
        retiredOperations = retiredOperations.filter { liveSessions.contains(String($0.prefix(36))) }
        releasedDecisions = releasedDecisions.filter { connections[String($0.key.prefix(36))] != nil }
    }
    func authenticate(ticket: String, resource: String, cancel: @escaping () -> Void) -> Context? {
        locked {
            expire(); pruneControl()
            guard let digest = Self.digest(ticket), let issued = tickets.removeValue(forKey: digest),
                  issued.resource == resource, issued.deadline > now(),
                  let session = sessions[issued.session], let pair = pairs[session.pair],
                  valid(Stream(session: issued.session, binding: session.binding, cancel: {})) else { return nil }
            for (id, old) in connections where old.session == issued.session {
                if lease?.owner == old.context { revokeLease("reconnect") }
                connections[id] = nil; deferred.append(old.cancel)
            }
            let context = Context(principalID: pair.principal, pairingID: pair.id, sessionID: session.id,
                                  connectionID: UUID().uuidString, sessionEpoch: sessionEpoch, binding: session.binding)
            connections[context.connectionID] = Connection(context: context, session: issued.session, cancel: cancel,
                                                           pongAt: now(), pingAt: now())
            return context
        }
    }
    private func emit(_ kind: String, _ reason: String, hint: String? = nil, request: String?? = nil) {
        eventSeq += 1
        var body: [String: Any] = ["seq": eventSeq, "kind": kind, "reason": reason,
                                   "at": Date().timeIntervalSince1970, "request_id": (request ?? agentRequest?.id) ?? NSNull()]
        if let hint { body["hint"] = hint }
        events.append((eventSeq, body))
        if events.count > Self.eventRetention { events.removeFirst() } // no log line: a stalled stdout must not hold up callers
    }
    private func finishRequest(_ status: AgentRequest.Status, _ reason: String) {
        guard agentRequest?.status == .pending else { return }
        agentRequest?.finish(status, at: now())
        emit(status.rawValue, reason)
    }
    /// Runs after every locked call (and the 1 s expiry tick). A viewer counts as present while it has a live control
    /// connection; with several viewers only the last one to go decides: `left` if it sent a leave signal, else
    /// `disconnected`. Neither revokes anything: the share, link and capture stay (only `done` ends it).
    /// `disconnected` cannot tell a closed page from a dead network; its `hint` is only what the host last saw.
    private func trackPresence() {
        guard active, binding != nil else { return }
        if !connections.isEmpty { viewerSeen = true; viewerGoneAt = nil; leaveReason = nil; return }
        guard viewerSeen else { return }
        let time = now()
        guard let gone = viewerGoneAt else {
            viewerGoneAt = time; goneRequest = agentRequest?.status == .pending ? agentRequest?.id : nil; return
        }
        guard time - gone >= Self.leaveGrace else { return }
        if let leaveReason { emit("left", leaveReason, request: .some(goneRequest)) }
        else { emit("disconnected", "connection_lost", hint: lossHint, request: .some(goneRequest)) }
        viewerSeen = false; viewerGoneAt = nil; leaveReason = nil
    }
    /// True once the share this viewer authenticated for is over (window cleared or replaced), as opposed to a
    /// dropped connection or an expired session of a share that is still running.
    func shareEnded(_ context: Context) -> Bool { locked { binding != context.binding } }
    func disconnect(_ context: Context) {
        locked {
            guard let connection = connections[context.connectionID], connection.context == context else { return }
            sessions[connection.session] = nil
        }
    }
    func heartbeat(_ context: Context) -> String? {
        locked {
            expire(); pruneControl()
            guard current(context), var connection = connections[context.connectionID], now() - connection.pingAt >= 5 else { return nil }
            let nonce = UUID().uuidString
            connection.nonce = nonce; connection.pingAt = now(); connections[context.connectionID] = connection
            return nonce
        }
    }
    func pong(_ context: Context, nonce: String) -> Bool {
        locked {
            guard current(context), var connection = connections[context.connectionID], connection.nonce == nonce else { return false }
            connection.pongAt = now(); connection.nonce = nil; connections[context.connectionID] = connection
            return true
        }
    }
    func state(_ context: Context) -> [String: Any]? {
        locked {
            expire(); pruneControl()
            guard current(context) else { return nil }
            var result: [String: Any] = ["t": "state", "mode": "View", "role": "human",
                "session_id": context.sessionID, "connection_id": context.connectionID,
                "session_epoch": context.sessionEpoch, "window_id": context.binding.windowID,
                "window_generation": context.binding.generation, "geometry_epoch": geometryEpoch,
                "controls_enabled": controlAllowed(context),
                "window": active && binding == context.binding ? "shared" : "none",
                "busy": lease != nil || cleanupPending != nil]
            if let request = agentRequest, request.status == .pending {
                result["request"] = ["id": request.id, "reason": request.reason, "remaining_sec": request.remaining(now())]
            }
            if let lease, lease.owner == context {
                result["mode"] = "Interact"; result["lease_id"] = lease.id; result["lease_epoch"] = lease.epoch
                result["expires_in"] = max(0, lease.deadline - now())
            }
            return result
        }
    }
    func acquire(_ context: Context, operation: String, ttl: Int) -> String {
        locked {
            expire(); pruneControl()
            guard current(context), controlAllowed(context), (30...3600).contains(ttl), UUID(uuidString: operation) != nil else { return "rejected" }
            if let lease {
                return lease.owner == context && lease.operation == operation && lease.ttl == ttl ? "ok" : "busy"
            }
            guard cleanupPending == nil, retiredOperations.count < 256,
                  !retiredOperations.contains(context.sessionID + ":" + operation),
                  let connection = connections[context.connectionID], let session = sessions[connection.session],
                  let pair = pairs[session.pair] else { return "rejected" }
            leaseEpoch += 1
            lease = Lease(id: UUID().uuidString, epoch: leaseEpoch, owner: context,
                          deadline: min(now() + Double(ttl), session.deadline, pair.deadline), operation: operation, ttl: ttl)
            if let interactObserver { deferred.append { interactObserver(true) } }
            return "ok"
        }
    }
    func cancelInput(_ context: Context, id: String, epoch: Int) {
        locked { if let lease, lease.owner == context, lease.id == id, lease.epoch == epoch { revokeLease("rejectedInput") } }
    }
    func release(_ context: Context, id: String, epoch: Int, decision: String) -> String {
        locked {
            expire(); pruneControl()
            guard current(context), UUID(uuidString: decision) != nil else { return "rejected" }
            let key = context.connectionID + ":" + decision
            let payload = id + ":" + String(epoch)
            if let old = releasedDecisions[key] { return old == payload ? "ok" : "rejected" }
            guard let lease, lease.owner == context, lease.id == id, lease.epoch == epoch,
                  releasedDecisions.count < 256 else { return "rejected" }
            releasedDecisions[key] = payload
            revokeLease("release")
            return "ok"
        }
    }
    /// Geometry is read on main from the exact native window, never from cached capture metadata.
    func observeGeometry(_ value: [Double], binding expected: Binding) -> Int? {
        observeGeometry(.success(value), source: .capture, binding: expected)
    }
    /// Any failure revokes frames and input at once (fail-closed, no retry); the one log line names the check and
    /// the caller that triggered the revocation (F-4).
    func observeGeometry(_ reading: Result<[Double], GeometryFailure>, source: GeometrySource, binding expected: Binding) -> Int? {
        var revoked: GeometryFailure?
        defer { if let revoked { fputs("[geometry] unavailable source=\(source.rawValue) \(revoked)\n", stderr) } } // after unlock
        return locked {
            guard active, binding == expected else { return nil }
            var failure: GeometryFailure
            switch reading {
            case .failure(let f): failure = f
            case .success(let v): failure = GeometryFailure(check: .nonFinite); failure.values = v.count
            }
            guard case .success(let value) = reading, value.count == 5, value.allSatisfy({ $0.isFinite }) else {
                revoked = failure
                clearWindow("geometryUnavailable"); return nil
            }
            if geometry != value {
                if geometry != nil {
                    geometryEpoch += 1; revokeLease("geometryChanged")
                }
                geometrySince = mach_absolute_time()
                frame = nil; size = []; frameProvenance = nil
            }
            geometry = value
            return geometryEpoch
        }
    }
    /// Each short native submission rechecks authority. The same execution UUID permits only
    /// the remaining submissions of this input; a later input cannot replay its consumed seq.
    func submit(_ context: Context, id: String, epoch: Int, sequence: Int,
                generation: String, geometry: Int, execution: UUID, effect: () -> Bool) -> Bool {
        locked {
            expire(); pruneControl()
            guard current(context), cleanupPending == nil, var value = lease,
                  value.owner == context, value.id == id, value.epoch == epoch,
                  value.deadline > now(), generation == context.binding.generation,
                  geometry == geometryEpoch, self.geometry != nil, frame != nil,
                  frameProvenance?.epoch == geometryEpoch,
                  sequence > 0, sequence <= 9_007_199_254_740_991,
                  sequence > value.sequence || (sequence == value.sequence && value.execution == execution) else { return false }
            if !controlAllowed(context) { revokeLease("controlNotAllowed"); return false }
            value.sequence = sequence; value.execution = execution; lease = value
            return effect()
        }
    }

    /// The nonblocking NWConnection.send call happens while authorization is still locked.
    /// ponytail: global lock for one shared window; split authorities only for multi-window support.
    func respond(method: String, path: String, fields: [String: Any], cookies: [String: String], authorization: String? = nil, loopback: Bool = false, commit: (Reply) -> Void) {
        locked { expire(); commit(route(method: method, path: path, fields: fields, cookies: cookies, authorization: authorization, loopback: loopback)) }
    }
    private func route(method: String, path: String, fields: [String: Any], cookies: [String: String], authorization: String?, loopback: Bool) -> Reply {
        func error(_ code: Int) -> Reply { .json(code, ["status": "rejected"]) }
        func exact(_ keys: Set<String>) -> Bool { Set(fields.keys) == keys }
        if path.hasPrefix("/agent/") { return agentRoute(method: method, path: path, fields: fields, cookies: cookies, authorization: authorization, loopback: loopback) }
        // Only /agent/* takes a Bearer credential; every human route rejects Authorization.
        guard authorization == nil else { return error(cookies.isEmpty ? 401 : 403) }
        let pairKey = Self.digest(cookies["ws-session"]).flatMap { sessions[$0]?.pair }
        let sessionKey = Self.digest(cookies["ws-session"])
        if method == "POST" {
            switch path {
            case "/session":
                // Only this share's link joins it (ADR 0003 rule 5): the bare entry never attaches to whatever is shared now,
                // and an ended share's id is gone for good (410), even after a new share starts on the same port.
                if exact([]) { return .json(403, ["status": "rejected", "reason": "share_link_required"]) }
                guard exact(["window_id"]) || exact(["window_id", "window_generation"]) else { return error(400) }
                guard let binding, fields["window_id"] as? String == binding.windowID else { return .json(410, ["status": "ended"]) }
                guard active else { return error(503) }
                guard fields["window_generation"] == nil || fields["window_generation"] as? String == binding.generation else { return error(403) }
                let key: String
                let pair: Pair
                if let pairKey, let existing = pairs[pairKey], existing.binding == binding {
                    key = pairKey; pair = existing
                } else {
                    guard pairs.count < 64, let token = Self.secret(), let digest = Self.digest(token) else { return error(503) }
                    key = digest; pair = Pair(binding: binding, deadline: now() + 8 * 3600)
                    pairs[key] = pair
                }
                guard let bearer = Self.secret(), let digest = Self.digest(bearer) else { return error(503) }
                sessions = sessions.filter { $0.value.pair != key }
                sessions[digest] = Session(pair: key, binding: pair.binding, deadline: min(now() + 900, pair.deadline))
                var body = pair.binding.json; body["mode"] = "View"; body["role"] = "human"
                body["principal_id"] = pair.principal; body["expires_in"] = min(900, pair.deadline - now())
                body["tuning"] = Tuning.page
                var reply = Reply.json(200, body)
                reply.cookies = [Self.cookie("session", bearer)]
                return reply
            case "/request/decision":
                guard exact(["id", "decision"]) else { return error(400) }
                guard let sessionKey, let session = sessions[sessionKey],
                      valid(Stream(session: sessionKey, binding: session.binding, cancel: {})) else { return error(401) }
                guard let id = fields["id"] as? String, let decision = fields["decision"] as? String,
                      ["done", "cancel"].contains(decision) else { return error(400) }
                guard agentRequest?.id == id, agentRequest?.status == .pending else { return .json(409, ["status": "rejected"]) }
                finishRequest(decision == "done" ? .done : .cancelled, decision == "done" ? "phone_done" : "phone_cancel")
                // 「完成」 ends this share (ADR 0003 rule 2/5): link dead now; the agent can still read `done`.
                if decision == "done", let ended = binding {
                    clearWindow("done")
                    if let shareObserver { deferred.append { shareObserver("done", ended) } }
                }
                return .json(200, ["status": agentRequest!.status.rawValue])
            case "/session/close":
                // 「停止观看」 sends {}; the page sends {"source":"unload"} on pagehide (best effort, may never arrive).
                guard exact([]) || (exact(["source"]) && fields["source"] as? String == "unload") else { return error(400) }
                guard let sessionKey, sessions.removeValue(forKey: sessionKey) != nil else { return error(401) }
                if active { leaveReason = fields.isEmpty ? "stop_watching" : "page_unload" } // counts only after a viewer connected
                frame = nil; size = []
                var reply = Reply.json(200, ["status": "closed"]); if authorization == nil { reply.cookies = [Self.cookie("session")] }; return reply
            default:
                guard exact([]), let sessionKey, let session = sessions[sessionKey],
                      valid(Stream(session: sessionKey, binding: session.binding, cancel: {})),
                      path == "/w/\(session.binding.windowID)/connect", cleanupHandler != nil,
                      let token = Self.secret(), let digest = Self.digest(token) else { return error(403) }
                tickets = tickets.filter { $0.value.session != sessionKey }
                let resource = "/w/\(session.binding.windowID)/events"
                tickets[digest] = Ticket(session: sessionKey, resource: resource, deadline: min(now() + 30, session.deadline))
                return .json(200, ["ticket": token, "resource": resource, "expires_in": 30])
            }
        }
        guard method == "GET", let sessionKey, let session = sessions[sessionKey],
              pairs[session.pair] != nil, active, session.binding == binding else {
            return error(401)
        }
        let base = "/w/\(session.binding.windowID)"
        if path == base {
            return Reply(status: 200, body: Data(ViewerPage.html.utf8), type: "text/html; charset=utf-8")
        }
        if path == base + "/meta" {
            var body = session.binding.json
            body["available"] = frame != nil; body["size"] = size; body["dpi"] = "unknown"
            body["mode"] = "View"; body["disabled_reason"] = "controls_not_enabled"
            body["server_time"] = Date().timeIntervalSince1970
            return .json(200, body)
        }
        // `/snapshot/<seq>`: 204 until a frame newer than seq exists; HTTPServer retries it as a long poll.
        let after = path.hasPrefix(base + "/snapshot/") && Tuning.push ? UInt64(path.dropFirst(base.count + 10)) : nil
        if path == base + "/snapshot" || after != nil {
            guard let frame, let provenance = frameProvenance, provenance.epoch == geometryEpoch else { return error(503) }
            if after == frameSequence { return Reply(status: 204, body: Data(), type: "image/jpeg") }
            var reply = Reply(status: 200, body: frame, type: "image/jpeg")
            reply.headers["X-WindowShare-Geometry-Epoch"] = String(provenance.epoch)
            reply.headers["X-WindowShare-Frame-Seq"] = String(frameSequence)
            return reply
        }
        return error(403)
    }
    /// Loopback + Bearer token + no Origin (the HTTP layer rejects Origin before this; browsers cannot reach it).
    private func agentRoute(method: String, path: String, fields: [String: Any], cookies: [String: String], authorization: String?, loopback: Bool) -> Reply {
        guard loopback, cookies.isEmpty else { return .json(403, ["status": "rejected"]) }
        guard AgentFile.authorized(authorization, token: agentToken) else { return .json(401, ["status": "rejected"]) }
        if method == "POST", path == "/agent/request" {
            guard Set(fields.keys) == ["reason", "timeout_sec"], let reason = fields["reason"] as? String,
                  (1...200).contains(reason.count), !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let timeout = fields["timeout_sec"] as? Int, (30...1800).contains(timeout) else { return .json(400, ["error": "bad_request"]) }
            guard active, binding != nil else { return .json(409, ["error": "no_window"]) }
            if agentRequest?.status == .pending { return .json(409, ["error": "busy"]) }
            let request = AgentRequest(reason: reason, deadline: now() + Double(timeout))
            agentRequest = request
            print("[agent] request status=pending")
            return .json(201, ["id": request.id, "entry": Self.shareLink(agentEntry, binding!)])
        }
        if method == "GET", path == "/agent/status" {
            guard active, let binding else { return .json(200, ["entry": NSNull(), "entries": [String](), "window": NSNull()]) }
            return .json(200, ["entry": Self.shareLink(agentEntry, binding), "entries": agentEntries.map { Self.shareLink($0, binding) },
                               "window": agentWindow.map { $0 as Any } ?? NSNull(),
                               "ends_in_sec": shareDeadline.map { Int(max(0, $0 - now())) } ?? 0])
        }
        let feed = "/agent/events/"
        if method == "GET", path.hasPrefix(feed) {
            // Events newer than <after>; 204 when none (HTTPServer holds it as a long poll). Reading never consumes:
            // any number of readers with the same cursor get the same events.
            guard let after = Int(path.dropFirst(feed.count)), after >= 0 else { return .json(400, ["error": "bad_request"]) }
            let reset = after > eventSeq // cursor from an earlier host process: start over from what is kept
            let newer = events.filter { reset || $0.seq > after }.map(\.body)
            guard reset || !newer.isEmpty else { return Reply(status: 204, body: Data()) }
            var body: [String: Any] = ["events": newer, "next": eventSeq]
            if reset { body["reset"] = true }
            if let first = events.first?.seq, !reset, after < first - 1 { body["truncated"] = true }
            return .json(200, body)
        }
        let prefix = "/agent/request/"
        if method == "GET", path.hasPrefix(prefix), let request = agentRequest, request.id == String(path.dropFirst(prefix.count)) {
            return .json(200, ["status": request.status.rawValue, "remaining_sec": request.remaining(now())])
        }
        return .json(404, ["status": "rejected"])
    }
}
