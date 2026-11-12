// Run from repo root:
// swiftc -parse-as-library host/Sources/{CaptureController,InputController,PairingSession,ViewerPage,EntryConfiguration,AgentRequest}.swift Scripts/verify-lifecycle.swift -o /tmp/verify-lifecycle && /tmp/verify-lifecycle
import Foundation
import AppKit

@main struct VerifyLifecycle {
    /// A phone joins only through this share's link while it is active; an ended share's link is gone (410).
    static func sessionStatus(_ identity: PairingSession, _ binding: PairingSession.Binding) -> Int {
        var status = 0
        identity.respond(method: "POST", path: "/session", fields: ["window_id": binding.windowID], cookies: [:]) { status = $0.status }
        return status
    }
    static func main() {
        let identity = PairingSession()
        let old = identity.selectWindow()
        assert(identity.activate(old))
        let capture = CaptureController(identity: identity, binding: old)
        var notifications = 0
        capture.onInvalidated = { notifications += 1 }
        identity.publish(Data([1]), size: [1, 1], binding: old)
        capture.invalidate()
        assert(!identity.isCurrent(old))
        assert(!identity.activate(old))
        assert(sessionStatus(identity, old) == 410)
        assert(notifications == 1)

        let fresh = identity.selectWindow()
        assert(identity.activate(fresh))
        capture.invalidate() // delayed old detector must not revoke new selection
        identity.publish(Data([2]), size: [1, 1], binding: old)
        assert(identity.isCurrent(fresh))
        assert(sessionStatus(identity, fresh) == 200)
        assert(sessionStatus(identity, old) == 410)
        assert(notifications == 1)

        let row: [String: Any] = [kCGWindowNumber as String: NSNumber(value: 42),
                                 kCGWindowOwnerPID as String: NSNumber(value: 123)]
        assert(CaptureController.containsTarget([row], id: 42, pid: 123))
        assert(!CaptureController.containsTarget([row], id: 43, pid: 123))
        assert(!CaptureController.containsTarget([row], id: 42, pid: 124))
        assert(!CaptureController.containsTarget(nil, id: 42, pid: 123))
        assert(!CaptureController.containsTarget([], id: 42, pid: 123))
        assert(!CaptureController.containsTarget([[:]], id: 42, pid: 123))
        print("PASS: actual scoped invalidation, stale binding and window predicate (not OS-event evidence)")
    }
}
