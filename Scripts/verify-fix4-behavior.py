#!/usr/bin/env python3
"""Run unchanged PairingSession with inert input and an in-process notification center."""

# Native event posting is forbidden for every verify subprocess.
import os as _verify_os
_verify_os.environ['WINDOWSHARE_TEST_NO_NATIVE_POST'] = '1'
import argparse, os, subprocess, tempfile
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
p.add_argument('--case', choices=['notification', 'failure-event', 'failure-kind', 'backoff', 'restart'], required=True)
a = p.parse_args(); root = a.source_root
with tempfile.TemporaryDirectory(prefix='ws-fix4-behavior-') as d:
 d = Path(d)
 source = (root/'host/Sources/PairingSession.swift').read_text()
 # The extension is test code compiled in the same file solely to observe state and stop the timer.
 (d/'PairingSession.swift').write_text(source + '''
extension PairingSession {
 func testStopTimer() { expiryTimer?.cancel() }
 func testEvents() -> [(String, String)] { lock.lock(); defer { lock.unlock() }; return events.map { ($0.body["kind"] as! String, $0.body["reason"] as! String) } }
 func testRetryAt() -> Double { lock.lock(); defer { lock.unlock() }; return cleanupRetryAt }
}
''')
 (d/'stubs.swift').write_text('''import Foundation
final class InputController { static func screenLocked() -> Bool { false } }
final class DistributedNotificationCenter {
 static let center = NotificationCenter()
 static func `default`() -> NotificationCenter { center }
}
''')
 (d/'main.swift').write_text(r'''import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
 if !condition() { print("FAIL: " + message); fflush(stdout); exit(1) }
}
var clock = 100.0
var isLocked = false
var cleanups: [Int] = []
func setup() -> (PairingSession, PairingSession.Context) {
 let s = PairingSession(now: { clock }, screenLocked: { isLocked })
 s.testStopTimer()
 s.installCleanup { cleanups.append($0) }
 let b = s.selectWindow(); check(s.activate(b), "activate")
 var r: PairingSession.Reply!
 s.respond(method: "POST", path: "/session", fields: ["window_id": b.windowID], cookies: [:], authorization: nil, loopback: false) { r = $0 }
 let parts = r.cookies[0].components(separatedBy: ";")[0].components(separatedBy: "=")
 s.respond(method: "POST", path: "/w/\(b.windowID)/connect", fields: [:], cookies: [parts[0]: parts[1]], authorization: nil, loopback: false) { r = $0 }
 let t = try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]
 return (s, s.authenticate(ticket: t["ticket"] as! String, resource: t["resource"] as! String, cancel: {})!)
}
let (s, context) = setup()
check(s.acquire(context, operation: UUID().uuidString, ttl: 300) == "ok", "acquire")
let scenario = CommandLine.arguments[1]
if scenario == "notification" {
 DistributedNotificationCenter.center.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
 check(cleanups.count == 1, "lock notification must revoke without polling or lock probe")
 check(s.state(context)!["mode"] as? String == "View", "notification changes mode")
 s.finishCleanup(epoch: cleanups[0], success: false)
 let count = cleanups.count
 DistributedNotificationCenter.center.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
 check(cleanups.count == count + 1, "unlock notification retries immediately")
 s.finishCleanup(epoch: cleanups.last!, success: true)
 check(s.state(context)!["busy"] as? Bool == false, "retry clears busy")
} else {
 isLocked = true
 _ = s.state(context)
 check(cleanups.count == 1, "revoke cleanup")
 isLocked = false
 for failure in 1...7 {
   let epoch = cleanups.last!
   s.finishCleanup(epoch: epoch, success: false)
   let delay = s.testRetryAt() - clock
   if scenario == "backoff" { check(delay == min(30, pow(2, Double(min(5, failure - 1)))), "retry delay \(failure): \(delay)") }
   if failure < 7 {
     clock += delay
     if let nonce = s.heartbeat(context) { _ = s.pong(context, nonce: nonce) }
     _ = s.state(context)
     check(cleanups.count == failure + 1, "retry callback")
   }
 }
 if scenario == "failure-event" || scenario == "failure-kind" {
   let ev = s.testEvents()
   if scenario == "failure-event" { check(ev.filter { $0.0 == "interact_revoked" }.count == 1, "revoke emitted once: \(ev)") }
   else { check(ev.filter { $0.0 == "cleanup_failed" }.count == 1, "cleanup failure emitted once: \(ev)") }
 }
 if scenario == "restart" {
   cleanups = []
   let (fresh, c) = setup()
   check(fresh.acquire(c, operation: UUID().uuidString, ttl: 300) == "ok", "fresh process/session can acquire")
 }
}
print("PASS \(scenario)")
''')
 exe=d/'test'
 files=[d/'PairingSession.swift',root/'host/Sources/EntryConfiguration.swift',root/'host/Sources/AgentRequest.swift',root/'host/Sources/ViewerPage.swift',d/'stubs.swift',d/'main.swift']
 subprocess.run(['swiftc',*[str(x) for x in files],'-o',str(exe)],check=True)
 subprocess.run([str(exe),a.case],check=True,env=dict(os.environ,WINDOWSHARE_TEST_NO_NATIVE_POST='1'),timeout=15)
