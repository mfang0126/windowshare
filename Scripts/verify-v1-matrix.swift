import Foundation
precondition(InputController.lockedSession(nil))
precondition(!InputController.lockedSession([:]))
precondition(!InputController.lockedSession(["CGSSessionScreenIsLocked": false]))
precondition(InputController.lockedSession(["CGSSessionScreenIsLocked": true]))
precondition(!InputController.lockedSession(["CGSSessionScreenIsLocked": "invalid"]))
// textEntry(roleError:role:subroleError:subrole:) preconditions
import ApplicationServices
// AXTextArea + subroleError .attributeUnsupported -> true
precondition(InputController.textEntry(roleError: .success, role: kAXTextAreaRole, subroleError: .attributeUnsupported, subrole: nil))
// AXTextField + subroleError .success + subrole nil -> true
precondition(InputController.textEntry(roleError: .success, role: kAXTextFieldRole, subroleError: .success, subrole: nil))
// AXTextField + subroleError .success + subrole "" -> true
precondition(InputController.textEntry(roleError: .success, role: kAXTextFieldRole, subroleError: .success, subrole: ""))
// AXTextField + subrole kAXSecureTextFieldSubrole (success) -> false
precondition(!InputController.textEntry(roleError: .success, role: kAXTextFieldRole, subroleError: .success, subrole: kAXSecureTextFieldSubrole))
// roleError .failure (role nil) -> false
precondition(!InputController.textEntry(roleError: .failure, role: nil, subroleError: .success, subrole: nil))
// roleError .attributeUnsupported with role "AXTextArea" -> false
precondition(!InputController.textEntry(roleError: .attributeUnsupported, role: "AXTextArea", subroleError: .success, subrole: nil))
// AXTextArea + subroleError .noValue -> false
precondition(!InputController.textEntry(roleError: .success, role: kAXTextAreaRole, subroleError: .noValue, subrole: nil))
// AXTextArea + subroleError .failure -> false
precondition(!InputController.textEntry(roleError: .success, role: kAXTextAreaRole, subroleError: .failure, subrole: nil))
// AXTextArea + .cannotComplete -> false
precondition(!InputController.textEntry(roleError: .success, role: kAXTextAreaRole, subroleError: .cannotComplete, subrole: nil))
// AXButton + .attributeUnsupported -> false
precondition(!InputController.textEntry(roleError: .success, role: kAXButtonRole, subroleError: .attributeUnsupported, subrole: nil))
// AXComboBox + .attributeUnsupported -> false
precondition(!InputController.textEntry(roleError: .success, role: kAXComboBoxRole, subroleError: .attributeUnsupported, subrole: nil))
// AXTextField + subrole kAXSearchFieldSubrole (success) -> true (existing behaviour)
precondition(InputController.textEntry(roleError: .success, role: kAXTextFieldRole, subroleError: .success, subrole: kAXSearchFieldSubrole))
// Unknown or unreadable subrole on a text role, and a secure field reported as a role, fail closed
precondition(!InputController.textEntry(roleError: .success, role: kAXTextAreaRole, subroleError: .success, subrole: "AXUnreadableSubrole"))
precondition(!InputController.textEntry(roleError: .success, role: kAXTextAreaRole, subroleError: .success, subrole: "AXUnknown"))
precondition(!InputController.textEntry(roleError: .success, role: "AXSecureTextField", subroleError: .attributeUnsupported, subrole: nil))

var clock = 100.0
let token = String(repeating: "ab", count: 32)
let secretReason = "SECRET-REASON-登录"
PairingSession.leaveGrace = 45
var locked = false
let notifications = NotificationCenter()
let identity = PairingSession(now: { clock }, screenLocked: { locked }, screenNotifications: notifications)
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
        precondition(Set(e.keys) == Set(["seq", "kind", "request_id", "at", "reason"] + (e["kind"] as? String == "disconnected" ? ["hint"] : [])), "keys \(e.keys)")
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
/// What the page does: a `leave` message on its own control socket, the socket closes, then /session/close.
func leave(_ v: (cookies: [String: String], context: PairingSession.Context), _ source: String) {
    identity.leave(v.context, source: source); identity.disconnect(v.context)
    _ = phone("POST", "/session/close", [:], v.cookies)
    alive.removeAll { $0 == v.context }
}
func request(_ timeout: Int = 300) -> String {
    let r = reply("POST", "/agent/request", ["reason": secretReason, "timeout_sec": timeout])
    precondition(r.status == 201)
    return json(r)["id"] as! String
}
func shareAlive() -> Bool { reply("GET", "/agent/status").body.count > 0 && json(reply("GET", "/agent/status"))["entry"] is String }


let first = json(reply("GET", "/agent/events/0"))["events"] as! [[String: Any]]
precondition(first.count == 1 && first[0]["kind"] as? String == "share_started")
_ = drain()
var cleanupEpochs: [Int] = []
let cleanupSignal = DispatchSemaphore(value: 0)
var statePushes = 0
identity.observeState { statePushes += 1 }
identity.installCleanup { cleanupEpochs.append($0); cleanupSignal.signal() }
let control = viewer()
locked = true
precondition(identity.acquire(control.context, operation: UUID().uuidString, ttl: 300) == "screenLocked")
locked = false
precondition(identity.acquire(control.context, operation: UUID().uuidString, ttl: 300) == "ok")
precondition(kinds(drain()) == ["interact_granted:lease_acquired"])
locked = true
precondition(cleanupSignal.wait(timeout: .now() + 3) == .success, "timer revokes without state read")
let state = identity.state(control.context)!
precondition(state["mode"] as? String == "View" && state["screen_locked"] as? Bool == true)
precondition(kinds(drain()) == ["interact_revoked:screenLocked"])
_ = identity.state(control.context)
precondition(drain().isEmpty, "one revoke per lock cycle")
precondition(cleanupEpochs.count == 1)
identity.finishCleanup(epoch: cleanupEpochs[0], success: false)
locked = false
notifications.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
_ = identity.state(control.context)
precondition(cleanupEpochs.count == 2 && cleanupEpochs[0] == cleanupEpochs[1], "retry cleanup after unlock")
identity.finishCleanup(epoch: cleanupEpochs[1], success: false)
clock += 1
precondition(cleanupSignal.wait(timeout: .now() + 3) == .success) // consume prior callback signal
precondition(cleanupSignal.wait(timeout: .now() + 3) == .success, "timer retries without request")
precondition(cleanupEpochs.count == 3, "retry non-lock cleanup failure")
identity.finishCleanup(epoch: cleanupEpochs[2], success: false)
clock += 2
_ = identity.state(control.context)
precondition(cleanupEpochs.count == 4, "second non-lock retry")
identity.finishCleanup(epoch: cleanupEpochs[3], success: false)
let failedState = identity.state(control.context)!
precondition(failedState["cleanup_failed"] as? Bool == true && statePushes == 1, "persistent failure pushed")
precondition(identity.acquire(control.context, operation: UUID().uuidString, ttl: 300) == "busy")
precondition(kinds(drain()) == ["cleanup_failed:cleanupFailed"], "failure event once")
clock += 4
_ = identity.state(control.context)
precondition(cleanupEpochs.count == 5)
identity.finishCleanup(epoch: cleanupEpochs[4], success: false)
precondition(PairingSession.cleanupRetryCap == 30)
precondition(PairingSession.cleanupRetryDelay(failures: 1) == 1 && PairingSession.cleanupRetryDelay(failures: 4) == 8)
precondition(PairingSession.cleanupRetryDelay(failures: 6) == 30 && PairingSession.cleanupRetryDelay(failures: 100) == 30)
if let nonce = identity.heartbeat(control.context) { precondition(identity.pong(control.context, nonce: nonce)) }
clock += 8
_ = identity.state(control.context)
precondition(cleanupEpochs.count == 6)
identity.finishCleanup(epoch: cleanupEpochs.last!, success: true)
let recovered = identity.state(control.context)!
precondition(recovered["busy"] as? Bool == false && recovered["cleanup_failed"] as? Bool == false)
precondition(identity.acquire(control.context, operation: UUID().uuidString, ttl: 300) == "ok", "acquire after cleanup")
let beforeNotification = cleanupEpochs.count
notifications.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil) // injected process-local notification
precondition(cleanupEpochs.count == beforeNotification + 1 && identity.state(control.context)!["mode"] as? String == "View", "lock notification revokes immediately")
let retryEpoch = cleanupEpochs.last!
identity.finishCleanup(epoch: retryEpoch, success: false)
let beforeUnlockNotice = cleanupEpochs.count
notifications.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
precondition(cleanupEpochs.count == beforeUnlockNotice + 1, "unlock notification retries before backoff expires")
identity.finishCleanup(epoch: retryEpoch, success: true)
precondition(identity.state(control.context)!["busy"] as? Bool == false, "notification retry clears barrier")
let restarted = PairingSession(now: { clock }, screenLocked: { false })
restarted.installCleanup { _ in }
let freshBinding = restarted.selectWindow()
precondition(restarted.activate(freshBinding))
var freshReply: PairingSession.Reply!
restarted.respond(method: "POST", path: "/session", fields: ["window_id": freshBinding.windowID], cookies: [:], authorization: nil, loopback: false) { freshReply = $0 }
precondition(freshReply.status == 200, "fresh session after restart")
let freshCookieParts = freshReply.cookies[0].components(separatedBy: ";")[0].components(separatedBy: "=")
let freshCookies = [freshCookieParts[0]: freshCookieParts[1]]
restarted.respond(method: "POST", path: "/w/\(freshBinding.windowID)/connect", fields: [:], cookies: freshCookies, authorization: nil, loopback: false) { freshReply = $0 }
let freshTicket = json(freshReply)
let freshContext = restarted.authenticate(ticket: freshTicket["ticket"] as! String, resource: freshTicket["resource"] as! String, cancel: {})!
precondition(restarted.acquire(freshContext, operation: UUID().uuidString, ttl: 300) == "ok", "acquire after restart")
var calls = 0
precondition(InputController.releaseTracked(buttons: [:], keys: [], releaseButton: { _, _ in calls += 1; return true }, releaseKey: { _ in calls += 1; return true }))
precondition(calls == 0, "no tracked downs means no post")
var releasedButtons = 0, releasedKeys = 0
precondition(InputController.releaseTracked(buttons: [.left: .zero], keys: [55], releaseButton: { _, _ in releasedButtons += 1; return true }, releaseKey: { _ in releasedKeys += 1; return true }))
precondition(releasedButtons == 1 && releasedKeys == 1, "each tracked input released once")
let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
precondition(InputController.occludes(owner: "/other", layer: 0, bounds: bounds, point: .zero, screens: []), "other windows still occlude input")
precondition(CaptureController.viewFPS == (ProcessInfo.processInfo.environment["EXPECTED_FPS"].flatMap(Int.init) ?? 24))
print("PASS runtime: share start, lock acquire denial, grant, lock revoke, no empty cleanup events, view 24fps")
