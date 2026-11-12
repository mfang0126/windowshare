import Foundation
import Network

/// H1a development listener: loopback only, one bounded request per connection.
final class HTTPServer {
    let identity: PairingSession
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "windowshare.http")
    private var clients: [ObjectIdentifier: Client] = [:]
    private var configuration = try! EntryConfiguration()
    private var host = ""
    private var origin = ""
    private var controlOrigin = ""
    private final class Client {
        let conn: NWConnection
        var data = Data()
        var answered = false
        var controlOrigin = ""
        var streamID: UUID?
        var sequence: UInt64 = 0
        var sendingSince: TimeInterval?
        var timer: DispatchSourceTimer?
        init(_ conn: NWConnection) { self.conn = conn }
    }
    init(identity: PairingSession) { self.identity = identity }

    func start(port: UInt16) throws { try start(configuration: EntryConfiguration(port: port)) }
    func start(configuration: EntryConfiguration) throws {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: configuration.port) else {
            throw NSError(domain: "WindowShare.HTTP", code: 1)
        }
        self.configuration = configuration
        host = configuration.host; origin = configuration.origin
        controlOrigin = configuration.controlOrigin
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.bindHost), port: nwPort)
        let next = try NWListener(using: parameters)
        // start() returns only after bind succeeds; never mistake another host for this one.
        let ready = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var started = false
        next.stateUpdateHandler = { state in
            switch state {
            case .ready:
                resultLock.lock(); started = true; resultLock.unlock(); ready.signal()
            case .failed:
                ready.signal()
            default: break
            }
        }
        next.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        next.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { next.cancel(); throw NSError(domain: "WindowShare.HTTP", code: 2) }
        resultLock.lock(); let success = started; resultLock.unlock()
        guard success else { next.cancel(); throw NSError(domain: "WindowShare.HTTP", code: 3) }
        listener = next
        print("[http] View ready on \(configuration.bindHost):\(configuration.port)")
    }
    private func accept(_ conn: NWConnection) {
        guard clients.count < 32, configuration.acceptsPeer(conn.endpoint) else { conn.cancel(); return }
        let client = Client(conn)
        clients[ObjectIdentifier(conn)] = client
        conn.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                guard self.configuration.acceptsLocal(conn.currentPath?.localEndpoint) else { self.close(client); return }
                self.receive(client)
            case .failed, .cancelled: self.close(client)
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak client] in
            if let client, client.streamID == nil { self?.close(client) }
        }
    }
    private func close(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client.conn)) != nil else { return }
        client.timer?.cancel(); client.timer = nil
        if let id = client.streamID { identity.closeStream(id) }
        client.conn.cancel()
    }
    private func reject(_ client: Client, _ status: Int = 400) {
        send(client, .json(status, ["status": "rejected"]))
    }
    private func receive(_ client: Client) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.clients[ObjectIdentifier(client.conn)] != nil, !client.answered else { return }
            if let data { client.data.append(data) }
            guard client.data.count <= 8192 + 4096 else { self.reject(client, 413); return }
            if self.parse(client) { return }
            guard !complete, error == nil else { self.reject(client); return }
            self.receive(client)
        }
    }
    /// true = finished or rejected; false = bounded partial request.
    private func parse(_ client: Client) -> Bool {
        let data = client.data
        guard let delimiter = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count >= 8192 { reject(client, 413); return true }; return false
        }
        let bodyStart = delimiter.upperBound
        guard bodyStart <= 8192, let header = String(data: data[..<delimiter.lowerBound], encoding: .utf8) else { reject(client); return true }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].components(separatedBy: " ")
        guard request.count == 3, ["GET", "POST"].contains(request[0]), request[2] == "HTTP/1.1",
              request[1].first == "/", request[1].utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 47, 95].contains($0)
              }), !request[1].contains(".."), !request[1].contains("//") else { reject(client); return true }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { reject(client); return true }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }), headers[name] == nil else { reject(client); return true }
            headers[name] = value
        }
        guard headers["host"].map({ configuration.accepts(host: $0) }) == true, headers["transfer-encoding"] == nil,
              !(headers["authorization"] != nil && headers["cookie"] != nil), headers["upgrade"] == nil,
              headers["expect"] == nil else { reject(client, 403); return true }
        let isAgent = request[1].hasPrefix("/agent/")
        // Behind a proxy every peer is loopback, so also require a loopback Host; proxied entries then refuse agent routes.
        if isAgent, headers["origin"] != nil || headers["forwarded"] != nil || headers.keys.contains(where: { $0.hasPrefix("x-forwarded-") })
            || !EntryConfiguration.isLoopback(client.conn.endpoint)
            || !["127.0.0.1:\(configuration.port)", "localhost:\(configuration.port)"].contains(headers["host"] ?? "") { reject(client, 403); return true }
        if let suppliedOrigin = headers["origin"], !configuration.accepts(origin: suppliedOrigin) || suppliedOrigin != (configuration.proxied ? origin : "http://" + (headers["host"] ?? "")) { reject(client, 403); return true }
        client.controlOrigin = configuration.proxied ? controlOrigin : "ws://" + String(headers["host"]!.dropLast(":\(configuration.port)".count)) + ":\(configuration.controlPort)"
        let method = request[0], path = request[1]
        var length = 0
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(rawLength), value <= 4096 else { reject(client, 413); return true }
            length = value
        }
        guard method != "POST" || ((headers["origin"].map({ configuration.accepts(origin: $0) }) == true || isAgent) && headers["content-type"] == "application/json" && headers["content-length"] != nil),
              method != "GET" || length == 0 else { reject(client, 403); return true }
        guard data.count <= bodyStart + length else { reject(client); return true }
        guard data.count == bodyStart + length else { return false }
        var cookies: [String: String] = [:]
        if let raw = headers["cookie"] {
            for part in raw.components(separatedBy: ";") {
                let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, cookies[String(pair[0])] == nil else { reject(client); return true }
                cookies[String(pair[0])] = String(pair[1])
            }
        }
        var fields: [String: Any] = [:]
        if method == "POST" {
            let body = Data(data[bodyStart...])
            guard let object = try? JSONSerialization.jsonObject(with: body),
                  let dict = object as? [String: Any] else { reject(client); return true }
            fields = dict
        }
        if method == "GET", headers["authorization"] == nil,
           let asset = Self.asset(path) {
            send(client, asset)
        } else if method == "GET", headers["authorization"] == nil, (["/", "/index.html"].contains(path) || (path.hasPrefix("/w/") && path.split(separator: "/").count == 2)) {
            send(client, PairingSession.Reply(status: 200, body: Data(ViewerPage.html.utf8), type: "text/html; charset=utf-8"))
        } else if method == "GET", headers["authorization"] == nil, path.hasSuffix("/stream") {
            identity.openStream(path: path, cookies: cookies, cancel: { client.conn.cancel() }) { id, reply in
                guard let id else { send(client, reply); return }
                client.streamID = id
                client.answered = true; client.data.removeAll()
                submit(client, Data(responseHeader(reply, controlOrigin: client.controlOrigin, streaming: true).utf8))
            }
            if client.streamID != nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(33))
                timer.setEventHandler { [weak self, weak client] in
                    if let client { self?.pump(client) }
                }
                client.timer = timer; timer.resume()
                // Detect disconnects even when the capture has no new frames.
                client.conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in self?.close(client) }
            }
        } else if method == "GET", headers["authorization"] == nil, path.contains("/snapshot/") {
            longPoll(client, path: path, cookies: cookies, until: ProcessInfo.processInfo.systemUptime + 2)
        } else {
            identity.respond(method: method, path: path, fields: fields, cookies: cookies, authorization: headers["authorization"], loopback: isAgent) { send(client, $0) }
        }
        return true
    }
    /// Re-asks every 5 ms while the reply is 204 (no newer frame), for at most 2 s (under the 5 s idle close).
    /// ponytail: polling wait; switch to a publish notification if the 5 ms granularity ever shows in latency.
    private func longPoll(_ client: Client, path: String, cookies: [String: String], until deadline: TimeInterval) {
        guard clients[ObjectIdentifier(client.conn)] != nil else { return }
        identity.respond(method: "GET", path: path, fields: [:], cookies: cookies) { reply in
            if reply.status == 204, ProcessInfo.processInfo.systemUptime < deadline {
                queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in self?.longPoll(client, path: path, cookies: cookies, until: deadline) }
            } else { send(client, reply) }
        }
    }
    private static func asset(_ path: String) -> PairingSession.Reply? {
        switch path {
        case "/manifest.webmanifest": return .init(status: 200, body: Data(WebAppAssets.manifest.utf8), type: "application/manifest+json")
        case "/icon.svg": return .init(status: 200, body: Data(WebAppAssets.iconSVG.utf8), type: "image/svg+xml")
        default: return nil
        }
    }
    private func send(_ client: Client, _ reply: PairingSession.Reply) {
        guard !client.answered, clients[ObjectIdentifier(client.conn)] != nil else { return }
        client.answered = true
        client.data.removeAll()
        let header = responseHeader(reply, controlOrigin: client.controlOrigin)
        var payload = Data(header.utf8); payload.append(reply.body)
        // Single send commits header and body under the identity authority's lock.
        client.conn.send(content: payload, completion: .contentProcessed { [weak self] _ in self?.close(client) })
    }

    private func responseHeader(_ reply: PairingSession.Reply, controlOrigin: String, streaming: Bool = false) -> String {
        let cookies = reply.cookies.map { "Set-Cookie: \($0)\(configuration.proxied ? "; Secure" : "")\r\n" }.joined() +
            reply.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        return "HTTP/1.1 \(reply.status) Response\r\nContent-Type: \(reply.type)\r\n\(streaming ? "" : "Content-Length: \(reply.body.count)\r\n")Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self' \(controlOrigin); img-src 'self' blob:; worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'; form-action 'none'; base-uri 'none'\r\n\(cookies)Connection: close\r\n\r\n"
    }
    private func submit(_ client: Client, _ payload: Data) {
        client.sendingSince = ProcessInfo.processInfo.systemUptime
        client.conn.send(content: payload, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, self.clients[ObjectIdentifier(client.conn)] != nil else { return }
            if error != nil { self.close(client); return }
            client.sendingSince = nil
        })
    }
    private func pump(_ client: Client) {
        guard clients[ObjectIdentifier(client.conn)] != nil, let id = client.streamID else { return }
        if let start = client.sendingSince {
            if ProcessInfo.processInfo.systemUptime - start >= 5 { close(client) }
            return
        }
        identity.sendFrame(id, after: client.sequence) { frame, sequence in
            var part = Data("--windowshare\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
            part.append(frame); part.append(Data("\r\n".utf8))
            client.sequence = sequence
            submit(client, part)
        }
    }
}
