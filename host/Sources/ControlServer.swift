import Foundation
import CoreFoundation
import Network

/// Dedicated loopback WS listener. URI is not observable in Network's handshake callback;
/// the first message binds a one-use ticket to its exact resource instead.
final class ControlServer {
    private let port: UInt16
    private let origin: String
    private let allowLAN: Bool
    private var configuration: EntryConfiguration { try! EntryConfiguration(port: port - 1, externalOrigin: origin, allowLAN: allowLAN) }
    private let identity: PairingSession
    // Accessed only on the main queue in production; listener can start before window selection.
    private var input: InputController?
    private final class InputAttachment {
        let input: InputController?
        // Main-queue confined. A detached lifetime can never produce native effects again.
        var detachedResult: Bool?
        init(_ input: InputController?) { self.input = input }
        func cleanup() -> Bool { detachedResult ?? (input?.cleanup() ?? true) }
    }
    private var attachment: InputAttachment
    func setInput(_ input: InputController?) {
        dispatchPrecondition(condition: .onQueue(.main))
        attachment.detachedResult = attachment.cleanup()
        self.input = input
        attachment = InputAttachment(input)
        installCleanup()
    }
    private func installCleanup() {
        identity.installCleanup { [attachment, identity] epoch in
            DispatchQueue.main.async {
                identity.finishCleanup(epoch: epoch, success: attachment.cleanup())
            }
        }
    }
    private let queue = DispatchQueue(label: "windowshare.control")
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private final class Client {
        let connection: NWConnection
        let opened = ProcessInfo.processInfo.systemUptime
        var context: PairingSession.Context?
        var busy = false
        var sends = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private var clients: [ObjectIdentifier: Client] = [:]
    init(port: UInt16, input: InputController?, identity: PairingSession, origin: String, allowLAN: Bool = false) {
        self.port = port; self.input = input; self.identity = identity; self.origin = origin; self.allowLAN = allowLAN
        self.attachment = InputAttachment(input)
    }
    convenience init(configuration: EntryConfiguration, input: InputController?, identity: PairingSession) {
        self.init(port: configuration.controlPort, input: input, identity: identity, origin: configuration.origin, allowLAN: configuration.allowLAN)
    }
    /// Configuration does not establish TLS or enable input authorization.
    func start() throws {
        guard listener == nil, port > 1,
              origin == "http://localhost:\(port - 1)" || EntryConfiguration.validExternalOrigin(origin)
        else { throw NSError(domain: "WindowShare.Control", code: 1) }
        let ws = NWProtocolWebSocket.Options()
        ws.maximumMessageSize = 4096
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { protocols, headers in
            let origins = headers.filter { $0.name.lowercased() == "origin" }.map(\.value)
            let config = self.configuration // carries allowLAN; without it LAN viewers never got a control channel
            let hosts = headers.filter { $0.name.lowercased() == "host" }.map(\.value)
            let validHost = hosts.count == 1 && (config.proxied ? hosts[0] == config.host :
                (hosts[0].hasSuffix(":\(self.port)") && config.accepts(host: String(hosts[0].dropLast(":\(self.port)".count)) + ":\(self.port - 1)")))
            return .init(status: validHost && origins.count == 1 && config.accepts(origin: origins[0]) && protocols.isEmpty ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.bindHost), port: NWEndpoint.Port(rawValue: port)!)
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let next = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var started = false
        next.stateUpdateHandler = { state in
            switch state {
            case .ready: resultLock.lock(); started = true; resultLock.unlock(); ready.signal()
            case .failed: ready.signal()
            default: break
            }
        }
        next.newConnectionHandler = { [weak self] in self?.accept($0) }
        next.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { next.cancel(); throw NSError(domain: "WindowShare.Control", code: 2) }
        resultLock.lock(); let success = started; resultLock.unlock()
        guard success else { next.cancel(); throw NSError(domain: "WindowShare.Control", code: 3) }
        installCleanup()
        listener = next
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }
    /// Called only when the process is about to exit: tell each viewer the share ended (WebSocket close 1001, going away)
    /// so the phone shows 「共享已结束」 instead of retrying a dead host. Waits at most 1 s, also for the 1001 that
    /// `close` already sent when the share ended inside `PairingSession` (12-hour limit, window closed, and every end
    /// path that revokes the window before calling this). The wait only delays transport cleanup: frames and input must
    /// already be revoked by then.
    func stop() {
        let deadline = DispatchTime.now() + 1
        let started = DispatchGroup()
        started.enter()
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.timer?.cancel(); self.timer = nil
            for client in Array(self.clients.values) {
                guard client.context != nil else { self.close(client); continue }
                self.clients.removeValue(forKey: ObjectIdentifier(client.connection))
                self.goAway(client)
            }
            started.leave()
        }
        _ = started.wait(timeout: deadline)
        _ = ending.wait(timeout: deadline)
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 32, configuration.acceptsPeer(connection.endpoint) else { connection.cancel(); return }
        let client = Client(connection); clients[ObjectIdentifier(connection)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                guard self.configuration.acceptsLocal(connection.currentPath?.localEndpoint) else { self.close(client); return }
                self.receive(client)
            case .failed, .cancelled: self.close(client)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    /// Closing handshakes still in flight; `stop()` waits for them before the process exits.
    private let ending = DispatchGroup()
    /// Close 1001, then read until the browser answers with its own close (or 1 s) before cancelling. Cancelling or
    /// exiting with the viewer's unread polls still buffered resets the TCP connection, and the reset can drop the 1001.
    private func goAway(_ client: Client) {
        ending.enter()
        var finished = false
        let finish = { [ending] in
            guard !finished else { return }
            finished = true; client.connection.cancel(); ending.leave()
        }
        func drain() {
            client.connection.receiveMessage { _, context, _, error in
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if error != nil || metadata == nil || metadata?.opcode == .close { finish() } else { drain() }
            }
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.goingAway)
        client.connection.send(content: nil, contentContext: .init(identifier: "close", metadata: [metadata]), isComplete: true,
                               completion: .contentProcessed { error in if error != nil { finish() } else { drain() } })
        queue.asyncAfter(deadline: .now() + 1, execute: finish)
    }
    private func close(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client.connection)) != nil else { return }
        // The share this viewer watched is over (limit, window closed, 「完成」, menu stop): say so with close 1001 before
        // dropping the transport. Frames and input already stopped when PairingSession cleared the window, and the client
        // is out of `clients`, so its messages are ignored.
        if let context = client.context, identity.shareEnded(context) { goAway(client) } else { client.connection.cancel() }
        // Fence transport now; revoke authority on the next queue turn.
        if let context = client.context { queue.async { self.identity.disconnect(context) } }
    }
    private func tick() {
        for client in Array(clients.values) {
            guard let context = client.context else {
                if ProcessInfo.processInfo.systemUptime - client.opened >= 5 { close(client) }
                continue
            }
            guard identity.state(context) != nil else { close(client); continue }
            if let nonce = identity.heartbeat(context) { reply(["t": "heartbeat", "nonce": nonce], client) }
        }
    }
    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, self.clients[ObjectIdentifier(client.connection)] != nil else { return }
            guard error == nil, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { self.close(client); return }
            if metadata.opcode == .ping || metadata.opcode == .pong {
                guard client.context != nil else { self.close(client); return }
                self.receive(client); return
            }
            guard metadata.opcode == .text, let data, data.count <= 4096,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = object["t"] as? String else { self.close(client); return }
            self.handle(object, type: type, client)
            if self.clients[ObjectIdentifier(client.connection)] != nil { self.receive(client) }
        }
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else { return nil }
        return Int(value)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private func handle(_ object: [String: Any], type: String, _ client: Client) {
        func exact(_ keys: Set<String>) -> Bool { Set(object.keys) == keys }
        func status(_ result: String) { reply(["t": result == "ok" ? "ack" : "error", "status": result], client) }
        guard let context = client.context else {
            guard exact(["t", "ticket", "resource"]), type == "auth", let ticket = object["ticket"] as? String,
                  let resource = object["resource"] as? String,
                  let context = identity.authenticate(ticket: ticket, resource: resource, cancel: { [weak self] in
                      // Through `close`, so a share that ended in PairingSession tells the viewer (1001) first.
                      self?.queue.async { self?.close(client) } }) else { close(client); return }
            client.context = context
            if let state = identity.state(context) { reply(state, client) } else { close(client) }
            return
        }
        guard identity.state(context) != nil else { close(client); return }
        if type == "auth" { close(client); return }
        if type == "pong" {
            guard exact(["t", "nonce"]), let nonce = object["nonce"] as? String, identity.pong(context, nonce: nonce) else { status("rejected"); return }
            return
        }
        if type == "state" {
            guard exact(["t"]) else { status("rejected"); return }
            if let state = identity.state(context) { reply(state, client) }; return
        }
        if type == "leave" { // tells the Bot event feed this viewer left on purpose (`left`), see PairingSession.leave
            guard exact(["t", "source"]), let source = object["source"] as? String, ["stop", "unload"].contains(source) else { status("rejected"); return }
            identity.leave(context, source: source); return
        }
        if type == "lease.acquire" {
            guard exact(["t", "operation_id", "lease_ttl_sec"]), let operation = object["operation_id"] as? String,
                  let ttl = Self.integer(object["lease_ttl_sec"]) else { status("rejected"); return }
            status(identity.acquire(context, operation: operation, ttl: ttl))
            if let state = identity.state(context) { reply(state, client) }; return
        }
        if type == "lease.release" {
            guard exact(["t", "lease_id", "lease_epoch", "decision_id"]), let id = object["lease_id"] as? String,
                  let epoch = Self.integer(object["lease_epoch"]), let decision = object["decision_id"] as? String else { status("rejected"); return }
            status(identity.release(context, id: id, epoch: epoch, decision: decision)); return
        }
        let payloads: [String: Set<String>] = ["click": ["x", "y", "button", "count"], "move": ["x", "y"],
            "down": ["x", "y"], "drag": ["x", "y"], "up": ["x", "y"], "scroll": ["dx", "dy"],
            "text": ["text"], "key": ["key", "mods"], "resize": ["w", "h"], "restore": []]
        guard ["click", "move", "down", "drag", "up", "scroll", "text", "key"].contains(type),
              let fields = payloads[type] else { status("not_enabled"); return }
        let common: Set<String> = ["t", "lease_id", "lease_epoch", "input_seq", "window_generation", "geometry_epoch"]
        guard exact(common.union(fields)), let id = object["lease_id"] as? String,
              let epoch = Self.integer(object["lease_epoch"]), let sequence = Self.integer(object["input_seq"]), sequence > 0,
              let generation = object["window_generation"] as? String, let geometry = Self.integer(object["geometry_epoch"]) else { status("rejected"); return }
        for field in fields.intersection(["x", "y", "dx", "dy", "w", "h"]) {
            guard let value = Self.number(object[field]) else { status("rejected"); return }
            let valid: Bool
            switch field {
            case "x", "y": valid = (0...1).contains(value)
            case "w", "h": valid = (320...4000).contains(value)
            default: valid = abs(value) <= 4096
            }
            if !valid { status("rejected"); return }
        }
        if type == "click" {
            guard let button = object["button"] as? String, ["left", "right"].contains(button),
                  let count = Self.integer(object["count"]), (1...3).contains(count) else { status("rejected"); return }
        }
        if type == "text" {
            guard let text = object["text"] as? String, !text.isEmpty, text.count <= 256, text.utf8.count <= 2048 else { status("rejected"); return }
        }
        if type == "key" {
            guard let key = object["key"] as? String, InputController.keys[key] != nil,
                  let mods = object["mods"] as? [String], mods.count <= 4, Set(mods).count == mods.count,
                  mods.allSatisfy({ InputController.modifiers[$0] != nil }),
                  InputController.allowedChord(key: key, mods: mods) else { status("rejected"); return }
        }
        guard !client.busy else { status("busy"); return }
        client.busy = true
        let execution = UUID()
        DispatchQueue.main.async { [self] in
            let diagnostic = InputController.Diagnostic()
            var accepted = false
            defer {
                fputs("[input] seq=\(sequence) stage=\(diagnostic.stage.rawValue) accepted=\(accepted) posted_down=\(diagnostic.postedDown) posted_up=\(diagnostic.postedUp)\n", stderr)
            }
            guard let input else {
                identity.cancelInput(context, id: id, epoch: epoch)
                queue.async { client.busy = false; self.reply(["t": "error", "status": "rejected"], client) }
                return
            }
            diagnostic.stage = .preGeometry
            let observed = identity.observeGeometry(input.measure(), source: .input, binding: context.binding)
            let ok = observed == geometry && input.perform(object, diagnostic: diagnostic) { effect in
                diagnostic.stage = .gateGeometry
                guard identity.observeGeometry(input.measure(), source: .commitGate, binding: context.binding) == geometry else { return false }
                diagnostic.stage = .submitAuthority
                return identity.submit(context, id: id, epoch: epoch, sequence: sequence, generation: generation,
                                       geometry: geometry, execution: execution, effect: effect)
            }
            accepted = ok
            if !ok { identity.cancelInput(context, id: id, epoch: epoch) }
            queue.async {
                client.busy = false
                guard self.clients[ObjectIdentifier(client.connection)] != nil else { return }
                self.reply(["t": ok ? "ack" : "error", "status": ok ? "ok" : "rejected", "input_seq": sequence], client)
                if let state = self.identity.state(context) { self.reply(state, client) }
            }
        }
    }
    private func reply(_ object: [String: Any], _ client: Client) {
        guard clients[ObjectIdentifier(client.connection)] != nil, client.sends < 8,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 4096 else { close(client); return }
        client.sends += 1
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        client.connection.send(content: data, contentContext: .init(identifier: "ws", metadata: [metadata]), isComplete: true,
                               completion: .contentProcessed { [weak self] error in
            client.sends -= 1
            if error != nil { self?.close(client) }
        })
    }
}
