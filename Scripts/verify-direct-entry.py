#!/usr/bin/env python3
"""Direct network sessions and production lease authority; no GUI/capture/native input."""
from pathlib import Path
import subprocess
import tempfile
import http.client
import json
import socket
import time

ROOT = Path(__file__).resolve().parents[1]
MAIN = r'''import Network
import Foundation
var clock = 100.0
let identity = PairingSession(now: { clock })
let binding = identity.selectWindow()
precondition(identity.activate(binding))
var cleanup: Int?
identity.installCleanup { cleanup = $0 }
func request(_ path: String, _ fields: [String: Any] = [:], _ cookies: [String: String] = [:]) -> PairingSession.Reply {
    var reply: PairingSession.Reply!
    identity.respond(method: "POST", path: path, fields: fields, cookies: cookies) { reply = $0 }
    return reply
}
func connect() -> PairingSession.Context {
    let reply = request("/session", ["window_id": binding.windowID])
    precondition(reply.status == 200)
    let value = reply.cookies[0].components(separatedBy: ";")[0].components(separatedBy: "=")
    let ticket = request("/w/" + binding.windowID + "/connect", [:], [value[0]: value[1]])
    let body = try! JSONSerialization.jsonObject(with: ticket.body) as! [String: Any]
    return identity.authenticate(ticket: body["ticket"] as! String, resource: body["resource"] as! String, cancel: {})!
}
precondition(request("/pair/claim", ["invite_secret": "obsolete"]).status != 200)
precondition(request("/pair/finish").status != 200)
precondition(request("/session", ["window_id": UUID().uuidString]).status == 410) // not this share's link
precondition(request("/session").status == 403) // bare entry never attaches (ADR 0003 rule 5)
let a = connect(), b = connect()
precondition(identity.state(a)!["mode"] as! String == "View")
precondition(identity.state(a)!["controls_enabled"] as! Bool)
precondition(identity.observeGeometry([0,0,800,600,2], binding: binding) == 1)
precondition(identity.acquire(a, operation: UUID().uuidString, ttl: 30) == "ok")
precondition(identity.acquire(b, operation: UUID().uuidString, ttl: 30) == "busy")
let state = identity.state(a)!
let id = state["lease_id"] as! String, epoch = state["lease_epoch"] as! Int
var effects = 0
func submit(_ owner: PairingSession.Context, _ seq: Int, generation: String? = nil) -> Bool {
    identity.submit(owner, id: id, epoch: epoch, sequence: seq, generation: generation ?? binding.generation, geometry: 1, execution: UUID()) { effects += 1; return true }
}
precondition(!submit(a, 1))
let proof = identity.frameProvenance(geometry: [0,0,800,600,2], size: [1600,1200], displayTime: mach_absolute_time(), binding: binding)!
identity.publish(Data("controlled".utf8), size: [1600,1200], binding: binding, provenance: proof)
precondition(!submit(b, 1))
precondition(!submit(a, 1, generation: UUID().uuidString))
precondition(submit(a, 1)); precondition(!submit(a, 1))
identity.disconnect(a)
precondition(!submit(a, 2)); precondition(cleanup != nil)
precondition(identity.acquire(b, operation: UUID().uuidString, ttl: 30) != "ok")
identity.finishCleanup(epoch: cleanup!, success: true)
precondition(identity.acquire(b, operation: UUID().uuidString, ttl: 30) == "ok")
for _ in 0..<6 {
    clock += 5
    if let nonce = identity.heartbeat(b) { precondition(identity.pong(b, nonce: nonce)) }
}
precondition(identity.state(b)!["mode"] as! String == "View")
identity.finishCleanup(epoch: cleanup!, success: true)
precondition(identity.acquire(b, operation: UUID().uuidString, ttl: 30) == "ok")
_ = identity.observeGeometry([1,0,800,600,2], binding: binding)
precondition(identity.state(b)!["mode"] as! String == "View")
// Replay guards are pruned with their session, so long uptime never exhausts the 256 caps.
identity.finishCleanup(epoch: cleanup!, success: true)
for _ in 0..<300 {
    let c = connect()
    precondition(identity.acquire(c, operation: UUID().uuidString, ttl: 30) == "ok")
    identity.disconnect(c); identity.finishCleanup(epoch: cleanup!, success: true)
}
precondition(identity.acquire(b, operation: UUID().uuidString, ttl: 30) == "ok")
identity.revokeWindow()
precondition(identity.state(b) == nil)
precondition(request("/session", ["window_id": binding.windowID]).status == 410) // ended share's link is dead
precondition(effects == 1)
let config = try! EntryConfiguration(port: 20861)
precondition(config.accepts(host: "127.0.0.1:20861"))
precondition(config.accepts(origin: "http://127.0.0.1:20861"))
precondition(!config.accepts(host: "evil.example:20861"))
precondition(!config.accepts(origin: "https://evil.example"))
let external = try! EntryConfiguration(port: 20861, externalOrigin: "https://host.example")
precondition(external.accepts(origin: "https://host.example"))
precondition(!external.accepts(origin: "http://127.0.0.1:20861"))
func peer(_ ip: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(ip), port: 1) }
precondition(config.acceptsPeer(peer("127.0.0.1")) && config.acceptsPeer(peer("::1")) && config.acceptsPeer(peer("100.101.2.3")))
precondition(!config.acceptsPeer(peer("192.168.50.20")) && !config.acceptsPeer(peer("10.0.0.2")) && !config.acceptsPeer(peer("100.128.0.1")))
precondition(!config.accepts(host: "192.168.50.20:20861"))
precondition(config.acceptsLocal(peer("127.0.0.1")) && !config.acceptsLocal(peer("192.168.50.20")) && !config.acceptsLocal(peer("100.99.99.99")) && !config.acceptsLocal(nil))
precondition(try! EntryConfiguration(port: 20861, allowLAN: true).acceptsPeer(peer("192.168.50.20")))
for (key, mods) in [("a", []), ("enter", ["shift"]), ("v", ["cmd"]), ("z", ["command", "shift"]), ("left", ["alt"])] {
    precondition(InputController.allowedChord(key: key, mods: mods), key)
}
for (key, mods) in [("tab", ["cmd"]), ("space", ["cmd"]), ("left", ["ctrl"]), ("3", ["cmd", "shift"]), ("escape", ["cmd", "alt"]), ("q", ["cmd"]), ("q", ["ctrl", "cmd"])] {
    precondition(!InputController.allowedChord(key: key, mods: mods), key)
}
// A chord posts real modifier downs and ups; the last event carries no flags, so no modifier stays set (H1).
for mods in [[], ["cmd"], ["shift"], ["cmd", "shift"], ["ctrl", "alt", "shift", "cmd"]] {
    let flags = mods.reduce(into: InputController.modifiers["cmd"]!.subtracting(InputController.modifiers["cmd"]!)) { $0.insert(InputController.modifiers[$1]!) }
    let steps = InputController.keySequence(code: 0, flags: flags)
    precondition(steps.count == 2 + 2 * mods.count)
    precondition(steps.filter { $0.modifier }.allSatisfy { s in InputController.modifierKeys.contains { $0.code == s.code } })
    precondition(steps.filter { !$0.modifier }.allSatisfy { $0.flags == flags && $0.code == 0 })
    let downs: [Int] = steps.filter { $0.down }.map { Int($0.code) }, ups: [Int] = steps.filter { !$0.down }.map { Int($0.code) }
    precondition(Set(downs) == Set(ups))
    if !mods.isEmpty { precondition(steps.last!.modifier && steps.last!.flags.isEmpty && !steps.last!.down) }
}

// The Dock's screen-sized layer-20 window must not block clicks inside the visible area (regressed in 3fd9e3f);
// every other Dock window (menus, Mission Control, Launchpad) and every other owner still blocks.
let screen = (frame: CGRect(x: 0, y: 0, width: 2368, height: 1332), visible: CGRect(x: 0, y: 30, width: 2368, height: 1220))
let mid = CGPoint(x: 700, y: 400)
precondition(InputController.dockPath == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")
precondition(!InputController.occludes(owner: InputController.dockPath, layer: 20, bounds: screen.frame, point: mid, screens: [screen]))
precondition(InputController.occludes(owner: InputController.dockPath, layer: 20, bounds: screen.frame, point: CGPoint(x: 700, y: 1300), screens: [screen]))
precondition(InputController.occludes(owner: InputController.dockPath, layer: 20, bounds: screen.frame, point: CGPoint(x: 700, y: 10), screens: [screen]))
precondition(InputController.occludes(owner: InputController.dockPath, layer: 101, bounds: screen.frame, point: mid, screens: [screen]))
precondition(InputController.occludes(owner: InputController.dockPath, layer: 20, bounds: CGRect(x: 600, y: 300, width: 400, height: 300), point: mid, screens: [screen]))
precondition(InputController.occludes(owner: "/Applications/Evil.app/Contents/MacOS/Evil", layer: 20, bounds: screen.frame, point: mid, screens: [screen]))
// The cursor is a WindowServer window at the cursor level over the last event point; only that one passes.
let cursorLevel = 2147483630, cursor = CGRect(x: 690, y: 390, width: 23, height: 22)
precondition(!InputController.occludes(owner: InputController.windowServerPath, layer: cursorLevel, bounds: cursor, point: mid, screens: [screen]))
precondition(InputController.occludes(owner: "/Applications/Evil.app/Contents/MacOS/Evil", layer: cursorLevel, bounds: cursor, point: mid, screens: [screen]))
precondition(InputController.occludes(owner: InputController.windowServerPath, layer: cursorLevel, bounds: screen.frame, point: mid, screens: [screen]))
precondition(InputController.occludes(owner: nil, layer: cursorLevel, bounds: cursor, point: mid, screens: [screen]))
precondition(InputController.occludes(owner: InputController.windowServerPath, layer: 0, bounds: cursor, point: mid, screens: [screen]))
precondition(InputController.occludes(owner: "/Applications/Evil.app/Contents/MacOS/Evil", layer: 0, bounds: CGRect(x: 600, y: 300, width: 400, height: 300), point: mid, screens: [screen]))

// CLI and menu entries share one policy: all interfaces, Tailscale + loopback peers, LAN only when allowed.
let cli = try! EntryConfiguration(port: 20861)
precondition(cli.bindHost == "0.0.0.0" && !cli.acceptsPeer(peer("192.168.50.20")) && cli.acceptsPeer(peer("100.101.102.103")) && cli.acceptsPeer(peer("127.0.0.1")))
precondition(try! EntryConfiguration(port: 20861, allowLAN: true).acceptsPeer(peer("192.168.50.20")))
// LAN mode accepts only private peers: never a public address (no internet exposure).
let lanCfg = try! EntryConfiguration(port: 20861, allowLAN: true)
precondition(["10.0.0.2", "172.20.1.1", "169.254.3.4", "fd12::1", "fe80::1", "::ffff:192.168.50.20", "100.101.102.103", "127.0.0.1"].allSatisfy { lanCfg.acceptsPeer(peer($0)) })
precondition(!["203.0.113.9", "8.8.8.8", "172.32.0.1", "2001:db8::1", "::ffff:8.8.8.8"].contains { lanCfg.acceptsPeer(peer($0)) })
precondition(!cli.acceptsPeer(peer("fd12::1")) && cli.entries().allSatisfy { EntryConfiguration.isTailscale(URL(string: $0)!.host!) })
// LAN mode: arrival must still be on one of this Mac's own private or Tailscale addresses, never a public one.
precondition(lanCfg.acceptsLocal(peer("127.0.0.1")) && lanCfg.acceptsLocal(peer("fe80::1")) && !lanCfg.acceptsLocal(peer("203.0.113.9")) && !lanCfg.acceptsLocal(peer("10.255.255.254")))
precondition(lanCfg.entries().allSatisfy { $0.hasPrefix("http://") && $0.hasSuffix(":20861/") })

// --- agent request interface (offline; fake clock) ---
do {
    var t = 1000.0
    let s = PairingSession(now: { t })
    s.installCleanup { _ in }
    let tok = String(repeating: "ab", count: 32)
    s.configureAgent(token: tok, entry: "http://localhost:20861/")
    let auth = "Bearer " + tok
    func agent(_ method: String, _ path: String, _ fields: [String: Any] = [:], auth: String? = auth, loopback: Bool = true, cookies: [String: String] = [:]) -> (Int, [String: Any]) {
        var r: PairingSession.Reply!
        s.respond(method: method, path: path, fields: fields, cookies: cookies, authorization: auth, loopback: loopback) { r = $0 }
        return (r.status, (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:])
    }
    func human(_ path: String, _ fields: [String: Any], _ cookies: [String: String]) -> Int {
        var r: PairingSession.Reply!
        s.respond(method: "POST", path: path, fields: fields, cookies: cookies) { r = $0 }
        return r.status
    }
    let ok: [String: Any] = ["reason": "please log in", "timeout_sec": 60]
    // auth / peer
    precondition(agent("POST", "/agent/request", ok, auth: nil).0 == 401)
    precondition(agent("POST", "/agent/request", ok, auth: "Bearer " + String(repeating: "cd", count: 32)).0 == 401)
    precondition(agent("POST", "/agent/request", ok, auth: "Bearer " + tok + "0").0 == 401)
    precondition(agent("POST", "/agent/request", ok, auth: tok).0 == 401)
    precondition(agent("POST", "/agent/request", ok, loopback: false).0 == 403)
    precondition(agent("GET", "/agent/request/x", [:], loopback: false).0 == 403)
    // no window: selected but not active, then nothing selected
    precondition(agent("POST", "/agent/request", ok).1["error"] as? String == "no_window")
    var bind = s.selectWindow()
    precondition(agent("POST", "/agent/request", ok).1["error"] as? String == "no_window")
    precondition(s.activate(bind))
    // validation
    for bad: [String: Any] in [["reason": "", "timeout_sec": 60], ["reason": String(repeating: "x", count: 201), "timeout_sec": 60],
                               ["reason": "r", "timeout_sec": 29], ["reason": "r", "timeout_sec": 1801], ["reason": "r"],
                               ["reason": "r", "timeout_sec": "60"], ["reason": "r", "timeout_sec": 60, "extra": 1]] {
        precondition(agent("POST", "/agent/request", bad).0 == 400, "\(bad)")
    }
    precondition(agent("POST", "/agent/request", ["reason": String(repeating: "x", count: 200), "timeout_sec": 30]).0 == 201)
    // busy; first request is pending
    precondition(agent("POST", "/agent/request", ok).1["error"] as? String == "busy")
    // human session
    func humanCookie() -> [String: String] {
        var r: PairingSession.Reply!
        s.respond(method: "POST", path: "/session", fields: ["window_id": bind.windowID], cookies: [:]) { r = $0 }
        precondition(r.status == 200)
        let v = r.cookies[0].components(separatedBy: ";")[0].components(separatedBy: "=")
        return [v[0]: v[1]]
    }
    var cookie = humanCookie()
    func connectCtx() -> PairingSession.Context {
        var r: PairingSession.Reply!
        s.respond(method: "POST", path: "/w/" + bind.windowID + "/connect", fields: [:], cookies: cookie) { r = $0 }
        let body = try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        return s.authenticate(ticket: body["ticket"] as! String, resource: body["resource"] as! String, cancel: {})!
    }
    var ctx = connectCtx()
    // Fresh request needs a clean slate: cancel the 200-char one via the human, then create the real one.
    var st = s.state(ctx)!
    var req = st["request"] as! [String: Any]
    precondition(st["window"] as? String == "shared" && (req["reason"] as! String).count == 200 && (req["remaining_sec"] as! Int) == 30)
    precondition(human("/request/decision", ["id": req["id"] as! String, "decision": "cancel"], cookie) == 200)
    precondition(s.state(ctx)!["request"] == nil)
    // human route auth: no cookie / bad cookie / bad decision / bad id
    func newRequest(_ timeout: Int = 60) -> String {
        let r = agent("POST", "/agent/request", ["reason": "please log in", "timeout_sec": timeout])
        precondition(r.0 == 201 && r.1["entry"] as? String == "http://localhost:20861/w/" + bind.windowID)
        return r.1["id"] as! String
    }
    var rid = newRequest()
    precondition(human("/request/decision", ["id": rid, "decision": "done"], [:]) == 401)
    precondition(human("/request/decision", ["id": rid, "decision": "maybe"], cookie) == 400)
    precondition(human("/request/decision", ["id": UUID().uuidString, "decision": "done"], cookie) == 409)
    // human routes still reject Authorization; agent routes reject cookies
    var rr: PairingSession.Reply!
    s.respond(method: "POST", path: "/request/decision", fields: ["id": rid, "decision": "done"], cookies: cookie, authorization: auth) { rr = $0 }
    precondition(rr.status == 403)
    s.respond(method: "POST", path: "/session", fields: [:], cookies: [:], authorization: auth) { rr = $0 }
    precondition(rr.status == 401)
    precondition(agent("GET", "/agent/request/" + rid, cookies: cookie).0 == 403)
    // pending shape + agent never sees reason/window details
    var g = agent("GET", "/agent/request/" + rid)
    precondition(g.0 == 200 && g.1["status"] as? String == "pending" && g.1["remaining_sec"] as? Int == 60 && g.1.count == 2)
    t += 10
    st = s.state(ctx)!; req = st["request"] as! [String: Any]
    precondition(Set(req.keys) == ["id", "reason", "remaining_sec"] && req["remaining_sec"] as? Int == 50 && req["id"] as? String == rid)
    precondition(agent("GET", "/agent/request/" + UUID().uuidString).0 == 404)
    // done (老板点「完成」) -> the share ends (ADR 0003): link 410, cookie and connection dead; agent still reads done
    var d = [String: Any]()
    precondition(human("/request/decision", ["id": rid, "decision": "done"], cookie) == 200)
    g = agent("GET", "/agent/request/" + rid)
    precondition(g.1["status"] as? String == "done" && g.1["remaining_sec"] as? Int == 0)
    precondition(human("/request/decision", ["id": rid, "decision": "cancel"], cookie) == 401)
    precondition(human("/session", ["window_id": bind.windowID], [:]) == 410 && s.state(ctx) == nil)
    precondition(agent("POST", "/agent/request", ok).1["error"] as? String == "no_window")
    // the next share is a new one
    bind = s.selectWindow(); precondition(s.activate(bind))
    cookie = humanCookie(); ctx = connectCtx()
    precondition(s.state(ctx)!["request"] == nil)
    // terminal kept: a new request is allowed, old id still readable until 10 minutes
    rid = newRequest()
    precondition(human("/request/decision", ["id": rid, "decision": "cancel"], cookie) == 200)
    precondition(agent("GET", "/agent/request/" + rid).1["status"] as? String == "cancelled")
    // timeout
    rid = newRequest(30)
    t += 29.5
    precondition(agent("GET", "/agent/request/" + rid).1["status"] as? String == "pending")
    t += 1
    g = agent("GET", "/agent/request/" + rid)
    precondition(g.1["status"] as? String == "timeout")
    precondition(human("/request/decision", ["id": rid, "decision": "done"], humanCookie()) == 409) // idle connection pruned the old cookie
    // retention: cleared after 10 minutes
    t += 601
    precondition(agent("GET", "/agent/request/" + rid).0 == 404)
    // window revocation cancels an active request
    rid = newRequest()
    s.revokeWindow()
    d = agent("GET", "/agent/request/" + rid).1
    precondition(d["status"] as? String == "cancelled")
    precondition(agent("POST", "/agent/request", ok).1["error"] as? String == "no_window")
    // /agent/status: the share link and window metadata only while a share is active; no link after it ends
    var status = agent("GET", "/agent/status")
    precondition(status.0 == 200 && status.1["entry"] is NSNull && status.1["window"] is NSNull)
    precondition(agent("GET", "/agent/status", auth: nil).0 == 401 && agent("GET", "/agent/status", loopback: false).0 == 403)
    s.configureAgentWindow(["window_id": 7, "app": "TextEdit", "title": "t", "interact": false])
    let next = s.selectWindow()
    precondition(s.activate(next))
    status = agent("GET", "/agent/status")
    precondition((status.1["window"] as? [String: Any])?["window_id"] as? Int == 7)
    precondition(status.1["entry"] as? String == "http://localhost:20861/w/" + next.windowID && next.windowID != bind.windowID)
    precondition(status.1["entries"] as? [String] == ["http://localhost:20861/w/" + next.windowID])
    s.revokeWindow()
    precondition(agent("GET", "/agent/status").1["window"] is NSNull)
}
// Tailscale detection: missing CLI and a failing `tailscale ip -4` both fail with a fix-it message; never a fallback.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-ts-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func tool(_ name: String, _ body: String) -> String {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\n" + body + "\n").utf8), attributes: [.posixPermissions: 0o755])
        return path
    }
    guard case .failure(let missing) = CLI.tailscaleAddress(tools: [dir.appendingPathComponent("none").path]) else { preconditionFailure() }
    precondition(missing.message.contains("install"))
    guard case .failure(let down) = CLI.tailscaleAddress(tools: [tool("down", "exit 1")]) else { preconditionFailure() }
    precondition(down.message.contains("not connected"))
    guard case .failure = CLI.tailscaleAddress(tools: [tool("lan", "echo 192.168.50.20")]) else { preconditionFailure() }
    guard case .success(let address) = CLI.tailscaleAddress(tools: [tool("up", "echo 100.101.102.103")]), address == "100.101.102.103" else { preconditionFailure() }
}
// agent.json: 0600 file, 0700 dir, 64-hex token, atomic replace, removal
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-agent-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let token = AgentFile.newToken()!
    precondition(token.count == 64 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase } && token != AgentFile.newToken()!)
    try! AgentFile.write(port: 8777, token: token, entry: "http://localhost:8777/", in: dir)
    try! AgentFile.write(port: 8777, token: token, entry: "http://localhost:8777/", in: dir)
    func mode(_ url: URL) -> Int { (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
    let file = dir.appendingPathComponent("agent.json")
    precondition(mode(file) == 0o600 && mode(dir) == 0o700)
    precondition(try! FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["agent.json", "agent.lock"]) // no temp file left; agent.lock is the N1 flock
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    precondition(json["v"] as? Int == 1 && json["port"] as? Int == 8777 && json["token"] as? String == token && json["entry"] as? String == "http://localhost:8777/")
    precondition(json["pid"] as? Int == Int(getpid()))
    // Another live instance's file (pid 1 = launchd) is neither replaced nor removed; a dead owner's file is replaced.
    AgentFile.remove(in: dir, pid: 1)
    precondition(FileManager.default.fileExists(atPath: file.path))
    AgentFile.remove(in: dir)
    try! AgentFile.write(port: 8777, token: token, entry: "e", in: dir, pid: 1)
    do { try AgentFile.write(port: 8777, token: token, entry: "e", in: dir); preconditionFailure("overwrote a live owner") }
    catch AgentFile.Failure.ownedByOther(let owner) { precondition(owner == 1) } catch { preconditionFailure("\(error)") }
    AgentFile.remove(in: dir)
    precondition(FileManager.default.fileExists(atPath: file.path))
    try! FileManager.default.removeItem(at: file)
    try! AgentFile.write(port: 8777, token: token, entry: "e", in: dir, pid: 999_999)
    try! AgentFile.write(port: 8777, token: token, entry: "http://localhost:8777/", in: dir)
    AgentFile.remove(in: dir)
    precondition(!FileManager.default.fileExists(atPath: file.path))
    // status reads AgentFile.current: a killed owner (pid 999_999) falls back to the live host it displaced (pid 1).
    let killed: [String: Any] = ["v": 1, "port": 8790, "token": "t", "entry": "e", "pid": 999_999,
                                 "displaced": [["v": 1, "port": 8777, "token": "m", "entry": "e", "pid": 1]]]
    try! JSONSerialization.data(withJSONObject: killed).write(to: file)
    precondition(AgentFile.current(in: dir)?["port"] as? Int == 8777)
    try! JSONSerialization.data(withJSONObject: ["v": 1, "port": 8790, "token": "t", "entry": "e", "pid": 1]).write(to: file)
    precondition(AgentFile.current(in: dir)?["port"] as? Int == 8790)
}
// loopback-only peer check, independent of LAN mode
precondition(EntryConfiguration.isLoopback(peer("127.0.0.1")) && EntryConfiguration.isLoopback(peer("::1")))
precondition(!EntryConfiguration.isLoopback(peer("192.168.50.20")) && !EntryConfiguration.isLoopback(peer("100.101.2.3")) && !EntryConfiguration.isLoopback(nil))
precondition(try! EntryConfiguration(port: 20861, allowLAN: true).acceptsPeer(peer("192.168.50.20")) && !EntryConfiguration.isLoopback(peer("192.168.50.20")))
print("PASS agent request interface: auth/peer, no_window/busy/400, done/cancel/timeout/revoke, state fields, agent.json")
print("PASS direct View, explicit single driver, frame/generation/replay gates, disconnect cleanup, TTL, geometry, window revocation, Host/Origin policy")
'''
with tempfile.TemporaryDirectory(prefix='windowshare-direct-') as directory:
    d = Path(directory)
    (d / 'main.swift').write_text(MAIN)
    sources = ['PairingSession.swift', 'ViewerPage.swift', 'EntryConfiguration.swift', 'InputController.swift', 'CaptureController.swift', 'AgentRequest.swift', 'CLI.swift']
    subprocess.run(['swiftc', *[str(ROOT / 'host/Sources' / f) for f in sources], str(d / 'main.swift'), '-o', str(d / 'check')], check=True)
    subprocess.run([str(d / 'check')], check=True)
    viewer = (ROOT / 'host/Sources/ViewerPage.swift').read_text().split('<script>')[1].split('</script>')[0]
    (d / 'viewer.js').write_text(viewer)
    subprocess.run(['node', '--check', str(d / 'viewer.js')], check=True)
    # v1 input set: pointer + scroll + text + key enabled; window resize/restore stays off.
    control = (ROOT / 'host/Sources/ControlServer.swift').read_text()
    assert 'guard ["click", "move", "down", "drag", "up", "scroll", "text", "key"].contains(type),' in control
    assert "['click','move','down','drag','up','scroll','text','key'].includes(payload.t)" in viewer
    # Text is cleared only after the host acks it, so a failed send never loses what the user typed.
    assert "if(sentText!==null&&el('text').value===sentText)el('text').value=''" in viewer
    assert viewer.count("el('text').value=''") == 2 and 'data-mod="ctrl"' not in (ROOT / 'host/Sources/ViewerPage.swift').read_text()
    # A mouse release must never be skipped by the hit test, or the button stays held at OS level (H1, 2026-10-27).
    inp = (ROOT / 'host/Sources/InputController.swift').read_text()
    mouse = inp[inp.index('private func mouse('):inp.index('static let keys')]
    rel = mouse[mouse.index('if release {'):mouse.index('} else {')]
    assert 'liveRect' not in rel and 'guard let held = self.heldButtons[button]' in rel and '[point, self.lastPoint, held].compactMap({ $0 }).first(where: { self.hit($0) })' in rel
    assert 'self.hit(point)' in mouse[mouse.index('} else {'):]
    menu = (ROOT / 'host/Sources/MenuBarController.swift').read_text()
    assert 'next.liveFrameProvider = { nextInput.liveRect() }' in menu and 'next.startFrameWatcher()' in menu
    # SIGTERM/SIGINT/SIGHUP and a normal exit must release held input: signal → NSApp.terminate →
    # applicationWillTerminate → stopControl → setInput(nil), which detaches and cleans the attachment.
    entry = (ROOT / 'host/Sources/main.swift').read_text()
    assert 'signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN)' in entry
    assert '[SIGTERM, SIGINT, SIGHUP].map' in entry and 'source.setEventHandler { NSApp.terminate(nil) }' in entry
    will = menu[menu.index('func applicationWillTerminate('):].split('\n', 1)[0]
    assert 'stopControl()' in will
    stop = menu[menu.index('private func stopControl()'):].split('\n    }', 1)[0]
    assert 'control?.setInput(nil)' in stop

    # Real HTTP parser and cookie/CSP behavior, on an ephemeral independent port.
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    server = r'''import Foundation
let identity = PairingSession()
let binding = identity.selectWindow()
precondition(identity.activate(binding))
identity.configureAgent(token: String(repeating: "ab", count: 32), entry: "http://localhost:\(CommandLine.arguments[1])/")
try! binding.windowID.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
let server = HTTPServer(identity: identity)
try server.start(port: UInt16(CommandLine.arguments[1])!)
RunLoop.main.run()
'''
    (d / 'main.swift').write_text(server)
    subprocess.run(['swiftc', *[str(ROOT / 'host/Sources' / f) for f in sources + ['HTTPServer.swift', 'WebAppAssets.swift']], str(d / 'main.swift'), '-o', str(d / 'http')], check=True)
    process = subprocess.Popen([str(d / 'http'), str(port), str(d / 'share-id')], stdout=subprocess.DEVNULL)
    def request(method, path, host=None, origin=None, cookie=None, auth=None, body=None, extra=None):
        conn = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
        headers = {'Host': host or f'127.0.0.1:{port}'}
        if origin is not None: headers['Origin'] = origin
        if cookie: headers['Cookie'] = cookie
        if auth: headers['Authorization'] = auth
        headers.update(extra or {})
        if method == 'POST':
            headers['Content-Type'] = 'application/json'
            body = body or '{}'
        conn.request(method, path, body, headers)
        response = conn.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        conn.close()
        return result
    try:
        for _ in range(50):
            try:
                page = request('GET', '/')
                break
            except OSError: time.sleep(.02)
        else: raise AssertionError('listener did not start')
        assert page[0] == 200 and b'id="invite"' not in page[2]
        assert f'ws://127.0.0.1:{port + 1}' in page[1]['Content-Security-Policy']
        assert request('POST', '/session')[0] == 403
        assert request('POST', '/session', origin='http://evil.example')[0] == 403
        assert request('GET', '/', host=f'evil.example:{port}')[0] == 403
        share = (d / 'share-id').read_text()
        assert request('POST', '/session', origin=f'http://127.0.0.1:{port}')[0] == 403  # bare entry: share link required
        response = request('POST', '/session', origin=f'http://127.0.0.1:{port}', body=json.dumps({'window_id': share}))
        assert response[0] == 200
        assert 'HttpOnly' in response[1]['Set-Cookie'] and 'SameSite=Strict' in response[1]['Set-Cookie']
        cookie = response[1]['Set-Cookie'].split(';')[0]
        window = json.loads(response[2])['window_id']
        assert request('GET', f'/w/{window}/meta', cookie=cookie)[0] == 200
        assert request('POST', '/pair/finish', origin=f'http://127.0.0.1:{port}')[0] != 200
        # agent routes over the real parser: Bearer + no Origin + loopback; human routes still reject Authorization
        bearer = 'Bearer ' + 'ab' * 32
        agent_body = '{"reason":"login please","timeout_sec":60}'
        assert request('POST', '/agent/request', body=agent_body)[0] == 401
        assert request('POST', '/agent/request', auth='Bearer ' + 'cd' * 32, body=agent_body)[0] == 401
        assert request('POST', '/agent/request', auth=bearer, origin=f'http://127.0.0.1:{port}', body=agent_body)[0] == 403
        assert request('POST', '/agent/request', auth=bearer, origin='http://evil.example', body=agent_body)[0] == 403
        assert request('GET', '/agent/request/x', auth=bearer, origin=f'http://127.0.0.1:{port}')[0] == 403
        assert request('POST', '/agent/request', auth=bearer, cookie=cookie, body=agent_body)[0] == 403
        created = request('POST', '/agent/request', auth=bearer, body=agent_body)
        assert created[0] == 201 and json.loads(created[2])['entry'] == f'http://localhost:{port}/w/{share}'
        rid = json.loads(created[2])['id']
        assert request('POST', '/agent/request', auth=bearer, body=agent_body)[0] == 409
        polled = request('GET', f'/agent/request/{rid}', auth=bearer)
        assert polled[0] == 200 and json.loads(polled[2])['status'] == 'pending'
        origin = f'http://127.0.0.1:{port}'
        assert request('POST', '/request/decision', cookie=cookie, auth=bearer, body=json.dumps({'id': rid, 'decision': 'done'}))[0] == 403
        assert request('POST', '/request/decision', origin=origin, cookie=cookie, auth=bearer, body=json.dumps({'id': rid, 'decision': 'done'}))[0] == 403
        assert request('POST', '/request/decision', body=json.dumps({'id': rid, 'decision': 'done'}))[0] == 403
        assert request('POST', '/request/decision', origin=origin, body=json.dumps({'id': rid, 'decision': 'done'}))[0] == 401
        assert request('POST', '/session', auth=bearer)[0] == 403
        assert request('GET', f'/w/{window}/meta', cookie=cookie, auth=bearer)[0] == 403
        decided = request('POST', '/request/decision', origin=origin, cookie=cookie, body=json.dumps({'id': rid, 'decision': 'done'}))
        assert decided[0] == 200 and json.loads(decided[2]) == {'status': 'done'}
        # 「完成」 ended the share (ADR 0003): the cookie and the link are dead at once; the agent still reads done.
        assert request('POST', '/request/decision', origin=origin, cookie=cookie, body=json.dumps({'id': rid, 'decision': 'cancel'}))[0] == 401
        assert request('GET', f'/w/{window}/meta', cookie=cookie)[0] == 401
        assert request('POST', '/session', origin=origin, body=json.dumps({'window_id': share}))[0] == 410
        assert json.loads(request('GET', f'/agent/request/{rid}', auth=bearer)[2])['status'] == 'done'
        assert request('GET', f'/agent/request/{rid}', host=f'localhost:{port}', auth=bearer)[0] == 200
        for fwd in ({'X-Forwarded-For': '203.0.113.9'}, {'Forwarded': 'for=203.0.113.9'}):
            assert request('GET', f'/agent/request/{rid}', auth=bearer, extra=fwd)[0] == 403
        # Agent routes need a loopback Host, so a proxied (loopback-peer) entry cannot reach them.
        assert '"127.0.0.1:\\(configuration.port)", "localhost:\\(configuration.port)"].contains(headers["host"] ?? "")' in (ROOT / 'host/Sources/HTTPServer.swift').read_text()
        print('PASS real HTTP agent routes: token, Origin 403, cookie/Authorization separation, human decision; 完成 ends the share')
        print('PASS real HTTP direct session, LAN cookie/CSP, missing/cross Origin, hostile Host, removed pairing route')
        # --window / --app CLI: bad combinations exit 2 before any capture or listener starts.
        binary = subprocess.run(['swift', 'build', '--package-path', str(ROOT / 'host'), '--show-bin-path'], check=True, capture_output=True, text=True).stdout.strip() + '/WindowShareHost'
        subprocess.run(['swift', 'build', '--package-path', str(ROOT / 'host')], check=True, capture_output=True)
        for bad in (['--interact'], ['--window'], ['--window', 'a', '--window', 'b'], ['--window', 'a', '--external-origin', 'https://x.example'], ['--window', '--interact'], ['--app'], ['--app', 'a', '--window', 'b'], ['--app', 'a', '--app', 'b'], ['--app', '--interact'], ['list', '--interact'], ['status', '--window', 'x'], ['--json'], ['list', 'status'], ['--window', 'x', 'list'], ['--lan', '--no-lan'], ['--no-lan', '--no-lan']):
            assert subprocess.run([binary, *bad], capture_output=True, timeout=20).returncode == 2, bad
        # User decision 2026-10-27: no confirmation dialog; the exact-title, single-match guard precedes share().
        menu = (ROOT / 'host/Sources/MenuBarController.swift').read_text()
        auto = menu[menu.index('guard let autoShare'):menu.index('private func publishAgentFile')]
        assert 'NSAlert' not in auto and auto.index('matches.count == 1') < auto.index('share(target, input: autoShare.interact,')
        # The control listener of a direct entry binds all interfaces so Tailscale phones reach it (peers filtered by acceptsPeer).
        (d / 'probe').mkdir()
        probe = d / 'probe' / 'main.swift'
        probe.write_text('import Foundation\nlet c = try! EntryConfiguration(port: 20871)\n'
                         'let s = ControlServer(configuration: c, input: nil, identity: PairingSession())\ntry! s.start()\nprint("ready"); fflush(stdout)\n'
                         'withExtendedLifetime(s) { dispatchMain() }\n')
        subprocess.run(['swiftc', *[str(ROOT / 'host/Sources' / f) for f in sources + ['ControlServer.swift']], str(probe), '-o', str(d / 'probe' / 'bin')], check=True)
        p2 = subprocess.Popen([str(d / 'probe' / 'bin')], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            assert p2.stdout.readline().strip() == 'ready'
            listen = subprocess.run(['lsof', '-nP', '-a', '-p', str(p2.pid), '-iTCP:20872', '-sTCP:LISTEN'], capture_output=True, text=True).stdout
            assert '*:20872' in listen, listen
        finally:
            p2.terminate(); p2.wait(timeout=5)
        print('PASS --window CLI option validation, all-interface control port, exact single title match before share')
    finally:
        process.terminate()
        process.wait(timeout=5)

# --- T3 request card / no-window page checks (self-contained, offline) ---
import pathlib as _pl, re as _re, shutil as _sh
_vp = (_pl.Path(__file__).resolve().parent.parent / 'host/Sources/ViewerPage.swift').read_text()
for _s in ('id="reqcard"', 'id="nowin"', '无共享窗口：请在 Mac 菜单栏选择窗口', "'/request/decision'", "reqDecide('done')", "reqDecide('cancel')", "m.window==='none'", 'Math.max(0,'):
    assert _s in _vp, _s
assert "if(path==='/session'){noWin=r.status===503;el('nowin').hidden=!noWin;}" in _vp
assert '交给 Agent' not in _vp and '>画质<' not in _vp
assert 'innerHTML' not in _vp
if _sh.which('node'):
    _js = _re.search(r'<script>\n(.*?)</script>', _vp, _re.S).group(1)
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as _f: _f.write(_js)
    subprocess.run(['node', '--check', _f.name], check=True)
print('PASS T3 request card and no-window page structure, node --check')
