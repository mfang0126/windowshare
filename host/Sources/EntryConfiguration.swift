import Foundation
import Darwin
import Network

/// Accept only configured HTTPS authority or local interface addresses, never arbitrary Host values.
struct EntryConfiguration {
    let port: UInt16
    let origin: String
    let host: String
    let controlOrigin: String
    /// Proxied: loopback only. Otherwise all interfaces, but peers are filtered by `acceptsPeer`.
    let bindHost: String
    /// On by default (user decision 2026-10-29): private-network peers may connect too. Off: loopback and Tailscale only.
    let allowLAN: Bool
    var controlPort: UInt16 { port + 1 }
    var entryURL: URL { URL(string: origin + "/")! }
    var proxied: Bool { origin.hasPrefix("https://") }
    enum Failure: Error { case invalid }

    init(port: UInt16 = 8777, externalOrigin: String? = nil, allowLAN: Bool = false) throws {
        guard port > 0, port < UInt16.max else { throw Failure.invalid }
        self.port = port
        bindHost = externalOrigin?.hasPrefix("https://") == true ? "127.0.0.1" : "0.0.0.0"
        self.allowLAN = allowLAN
        if let externalOrigin {
            guard Self.validExternalOrigin(externalOrigin),
                  externalOrigin.hasPrefix("https://") || URL(string: externalOrigin)?.port == Int(port) else { throw Failure.invalid }
            origin = externalOrigin
            host = String(externalOrigin.dropFirst(externalOrigin.hasPrefix("https://") ? 8 : 7))
            controlOrigin = externalOrigin.hasPrefix("https://") ? "wss://" + host : "ws://" + URL(string: externalOrigin)!.host! + ":\(port + 1)"
        } else {
            host = "localhost:\(port)"; origin = "http://" + host
            controlOrigin = "ws://localhost:\(port + 1)"
        }
    }
    func accepts(host value: String) -> Bool {
        if value == host { return true }
        guard !proxied, value.hasSuffix(":\(port)") else { return false }
        let name = String(value.dropLast(":\(port)".count))
        if ["localhost", "127.0.0.1"].contains(name) { return true }
        return (allowLAN || Self.isTailscale(name)) && Self.localAddresses().contains(name)
    }
    func accepts(origin value: String) -> Bool {
        value == origin || (!proxied && value.hasPrefix("http://") && accepts(host: String(value.dropFirst(7))))
    }
    private static func localAddresses() -> Set<String> {
        var result: Set<String> = ["localhost", "127.0.0.1", "[::1]"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }
        var cursor = list
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(String(cString: buffer))
            }
        }
        return result
    }
    /// TCP source addresses cannot be spoofed past the handshake, so this is the network-boundary check.
    /// Even with LAN allowed, only private-network peers: never a public address (no internet exposure).
    func acceptsPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        func v4(_ address: IPv4Address) -> Bool { address.isLoopback || Self.isTailscale("\(address)") || (allowLAN && Self.isPrivate("\(address)")) }
        switch host {
        case .ipv4(let address): return v4(address)
        case .ipv6(let address):
            if address.isLoopback { return true }
            if let mapped = address.asIPv4 { return v4(mapped) }
            return allowLAN && Self.isPrivate(address)
        default: return false
        }
    }
    /// IPv6 link-local fe80::/10 and unique-local fc00::/7.
    static func isPrivate(_ address: IPv6Address) -> Bool {
        let b = [UInt8](address.rawValue)
        return b.count == 16 && ((b[0] == 0xfe && b[1] & 0xc0 == 0x80) || b[0] & 0xfe == 0xfc)
    }
    /// RFC 1918 and link-local IPv4.
    static func isPrivate(_ address: String) -> Bool {
        let o = address.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }
    /// Every phone entry: Tailscale first, then this Mac's private LAN addresses when LAN is allowed.
    func entries() -> [String] {
        guard !proxied else { return [origin + "/"] }
        let lan = allowLAN ? Self.localAddresses().filter(Self.isPrivate).sorted() : []
        return (Self.tailscaleAddress().map { [$0] } ?? []) .map { "http://\($0):\(port)/" } + lan.map { "http://\($0):\(port)/" }
    }
    /// Loopback peer only, regardless of LAN mode (agent routes).
    static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }
    /// A spoofed 100.x source can complete a handshake through a hostile gateway when Tailscale is down,
    /// so the connection must also have arrived on loopback or on this Mac's own Tailscale address.
    /// LAN mode additionally allows arrival on one of this Mac's own private addresses, never on a public one.
    func acceptsLocal(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _)? = endpoint else { return false }
        let address: String
        switch host {
        case .ipv4(let v4): if v4.isLoopback { return true }; address = "\(v4)"
        case .ipv6(let v6):
            if v6.isLoopback { return true }
            guard let v4 = v6.asIPv4 else { return allowLAN && Self.isPrivate(v6) }
            if v4.isLoopback { return true }; address = "\(v4)"
        default: return false
        }
        return (Self.isTailscale(address) || (allowLAN && Self.isPrivate(address))) && Self.localAddresses().contains(address)
    }
    static func isTailscale(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
    /// Shown in the menu as the phone entry; nil when Tailscale is not up.
    static func tailscaleAddress() -> String? { localAddresses().sorted().first(where: isTailscale) }
    static func validExternalOrigin(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), let scheme = url.scheme,
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil,
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              url.port.map({ $0 > 0 && $0 < 65535 }) ?? true else { return false }
        return value == scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
    }
}

/// M2-a latency switches, each on by default so a phone session can compare them one at a time.
/// `WINDOWSHARE_M2A_OFF=push,fps,input,small` turns items off; `all` gives the pre-M2-a baseline.
enum Tuning {
    static let off = Set((ProcessInfo.processInfo.environment["WINDOWSHARE_M2A_OFF"] ?? "").split(separator: ",").map(String.init))
    private static func on(_ name: String) -> Bool { !off.contains("all") && !off.contains(name) }
    /// Interact: the viewer long-polls the next frame instead of waiting 250 ms after each snapshot.
    static let push = on("push")
    /// Interact: capture at 60 fps instead of the 15 fps idle floor.
    static let fps = on("fps")
    /// Interact without push: fetch a frame as soon as an input is acknowledged instead of at the next 250 ms tick.
    static let input = on("input")
    /// Interact: capture at 1x point size and JPEG quality 0.5 instead of 2x and 0.65.
    static let small = on("small")
    /// M2-a2, Interact: JPEG quality 0.4 instead of 0.5 (0.65 when `small` is off).
    static let q4 = on("q4")
    /// M2-a2, Interact: frames scaled at encode time to at most `capEdge` px on the long edge.
    static let cap = on("cap")
    static let capEdge = 768
    static var page: [String: Bool] { ["push": push, "input": input] }
}
