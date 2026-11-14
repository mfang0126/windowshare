#!/usr/bin/env python3
"""R1 production cleanup scheduling regression; substitutes native input only.

--source-root accepts a saved pre-fix tree. --case replacement reproduces the
exact delayed A-after-B defect using the same API on both implementations.
No capture, browser, native input, or authority implementation substitution.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STUB = r'''
import Foundation
final class InputController {
    static let keys = ["enter": 36]
    static let modifiers = ["cmd": 1]
    static func allowedChord(key: String, mods: [String]) -> Bool { true }
    var cleanups = 0
    var held = false
    var succeeds = true
    var onCleanup: (() -> Void)?
    func geometry() -> [Double]? { [0, 0, 800, 600, 2] }
    func measure() -> Result<[Double], PairingSession.GeometryFailure> { .success([0, 0, 800, 600, 2]) }
    func perform(_ object: [String: Any], diagnostic: Diagnostic? = nil, gate: (() -> Bool) -> Bool) -> Bool {
        gate { self.held = true; return true }
    }
    func cleanup() -> Bool {
        cleanups += 1
        onCleanup?()
        if succeeds { held = false }
        return succeeds
    }
}
'''
EXTENSION = r'''
extension PairingSession {
    // Retain exactly the callback produced under the production authority lock,
    // modelling preemption after unlock but before the deferred loop invokes it.
    func harnessTakeCleanup() -> () -> Void {
        lock.lock()
        scheduleCleanup()
        let work = deferred
        deferred.removeAll()
        lock.unlock()
        precondition(work.count == 1)
        return work[0]
    }
    func harnessPending() -> Bool { lock.lock(); defer { lock.unlock() }; return cleanupPending != nil }
    func harnessFailed() -> Bool { lock.lock(); defer { lock.unlock() }; return cleanupFailed }
    func harnessLockHeld() -> Bool {
        if lock.try() { lock.unlock(); return false }
        return true
    }
    func harnessStopTimer() { expiryTimer?.cancel() }
}
'''
MAIN = r'''
import Foundation
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    if !value() { print("FAIL: \(label)"); fflush(stdout); exit(1) }
}
let scenario = CommandLine.arguments[1]
let identity = PairingSession()
identity.harnessStopTimer()
let binding = identity.selectWindow()
check(identity.activate(binding), "activate initial binding")
let old = InputController()
let control = ControlServer(port: 23998, input: old, identity: identity, origin: "http://localhost:23997")
try control.start()
func done(_ detail: String) {
    print("PASS \(scenario): \(detail)"); fflush(stdout); exit(0)
}
func next(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }
next {
    let a = identity.harnessTakeCleanup()
    check(identity.harnessPending(), "current cleanup barrier set")
    if scenario == "replacement" || scenario == "same-attachment" {
        let replacement: InputController
        if scenario == "replacement" {
            old.held = true
            identity.revokeWindow()
            // Preserve the old menu's explicit detach cleanup on a pre-fix tree;
            // the fixed setInput must perform this itself (checked in detach cases).
            _ = old.cleanup()
            control.setInput(nil)
            let binding = identity.selectWindow()
            check(identity.activate(binding), "activate replacement binding")
            replacement = InputController()
            control.setInput(replacement)
        } else { replacement = old }
        let b = identity.harnessTakeCleanup()
        b()
        next {
            check(!identity.harnessPending(), "B releases its own cleanup barrier")
            let count = replacement.cleanups
            check(count == 1, "B cleans attached input exactly once")
            replacement.held = true
            a()
            next {
                check(replacement.cleanups == count && replacement.held,
                      "delayed A after B must not release current held input")
                check(!identity.harnessPending(), "A cannot recreate completed barrier")
                done("delayed A rejected before native effects after B completed")
            }
        }
    } else if scenario == "detach" || scenario == "detach-failure" {
        old.held = true
        old.succeeds = scenario != "detach-failure"
        identity.revokeWindow()
        control.setInput(nil)
        check(old.cleanups == 1, "detach synchronously cleans old attachment")
        check(old.held == !old.succeeds, "detach records cleanup outcome")
        let newBinding = identity.selectWindow()
        check(identity.activate(newBinding), "activate after detach")
        let replacement = InputController()
        control.setInput(replacement)
        replacement.held = true
        a()
        next {
            check(old.cleanups == 1, "detached callback cannot repeat native cleanup")
            check(replacement.cleanups == 0 && replacement.held, "old current callback stays bound to detached lifetime")
            check(identity.harnessPending() == !old.succeeds, "detach result controls current barrier")
            check(identity.harnessFailed() == !old.succeeds, "failed detach stays fail closed")
            done("synchronous detach result reused without native replay or replacement effects")
        }
    } else if scenario == "superseded-barrier" {
        let b = identity.harnessTakeCleanup()
        a()
        next {
            check(old.cleanups == 0, "obsolete A cannot run before pending B")
            check(identity.harnessPending(), "A cannot clear B barrier")
            old.held = true
            b()
            next {
                check(old.cleanups == 1 && !old.held, "current B clears held input")
                check(!identity.harnessPending(), "current B clears barrier")
                b()
                next {
                    check(old.cleanups == 1, "duplicate B cannot repeat native effects")
                    done("obsolete/duplicate callbacks rejected, current cleanup retained")
                }
            }
        }
    } else if scenario == "authority-order" {
        let attempted = DispatchSemaphore(value: 0)
        let transitioned = DispatchSemaphore(value: 0)
        old.onCleanup = {
            check(identity.harnessLockHeld(), "authority lock held across cleanup effect")
            check(identity.harnessLockHeld(), "no separate precheck/effect lock gap")
            DispatchQueue.global().async {
                attempted.signal()
                let b = identity.harnessTakeCleanup()
                b()
                transitioned.signal()
            }
            check(attempted.wait(timeout: .now() + 2) == .success, "concurrent transition starts")
            check(transitioned.wait(timeout: .now() + 0.05) == .timedOut,
                  "new authority transition cannot pass in-flight cleanup effect")
            old.onCleanup = nil
        }
        a()
        next {
            check(transitioned.wait(timeout: .now() + 2) == .success, "concurrent transition resumes after effect/ack")
            // B is enqueued before transitioned signals, so the next main turn follows B.
            next {
                check(old.cleanups == 2 && !identity.harnessPending(), "new B cleanup/ack completes without deadlock")
                done("concurrent producer serialized across effect and acknowledgement")
            }
        }
    } else { check(false, "unknown scenario") }
}
dispatchMain()
'''


def verify_input_diagnostics(path, source):
    # Execute the production pointer path and cleanup with inert platform doubles.
    # No AppKit/ApplicationServices import, window lookup, or real CGEvent exists here.
    diagnostic = source.split('    final class Diagnostic {', 1)[1].split('    private let window:', 1)[0]
    mouse = source.split('    private func mouse(', 1)[1].split('    static let keys:', 1)[0]
    perform = source.split('    func perform(', 1)[1].split('        if type == "scroll"', 1)[0]
    cleanup = source.split('    func cleanup()', 1)[1].split('\n}', 1)[0]
    keypath = source.split('        if type == "key" || type == "text" {', 1)[1].split('        if type == "resize"', 1)[0]
    sequence = source.split('    static func keySequence(', 1)[1].split('    static let modifiers:', 1)[0]
    release = source.split('    private func releaseKey(', 1)[1].split('    /// Only releases', 1)[0]
    harness = r'''
import Foundation
import CoreGraphics
enum CGMouseButton: Hashable { case left, right }
enum CGEventType { case leftMouseDown, rightMouseDown, leftMouseUp, rightMouseUp, leftMouseDragged, mouseMoved, keyDown, keyUp, flagsChanged }
enum Field { case mouseEventClickState }
enum Tap { case cghidEventTap }
typealias CGKeyCode = Int
final class CGEvent {
    static var posts = 0
    static var creates = 0
    static var failAt = 0
    static var posted: [(CGEventType?, CGPoint, CGEventFlags)] = []
    var location = CGPoint.zero
    var type: CGEventType?
    var flags: CGEventFlags = []
    init?(mouseEventSource: Int?, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) {
        Self.creates += 1
        if Self.creates == Self.failAt { return nil }
        location = mouseCursorPosition; type = mouseType
    }
    init?(keyboardEventSource: Int?, virtualKey: Int, keyDown: Bool) { type = keyDown ? .keyDown : .keyUp; flags = keyDown ? [] : .maskCommand }
    func setIntegerValueField(_ field: Field, value: Int64) {}
    func post(tap: Tap) { Self.posts += 1; Self.posted.append((type, location, flags)) }
    func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UInt16>?) {}
}
final class InputController {
    typealias Gate = (() -> Bool) -> Bool
    var armed = false
    var heldButtons: [CGMouseButton: CGPoint] = [:]
    var heldKeys: Set<CGKeyCode> = []
    static let modifierKeys: [(flag: CGEventFlags, code: CGKeyCode)] = [(.maskShift, 56), (.maskCommand, 55)]
    static let keys: [String: CGKeyCode] = ["v": 9]
    static let modifiers: [String: CGEventFlags] = ["cmd": .maskCommand, "shift": .maskShift]
    var focusQueue: [Bool] = []
    func focused() -> Bool { focusQueue.isEmpty ? true : focusQueue.removeFirst() }
    var lastPoint: CGPoint?
    var live = true
    var hits = true
    var hitQueue: [Bool] = []
    func liveRect() -> CGRect? { live ? CGRect(x: 0, y: 0, width: 100, height: 100) : nil }
    func hit(_ point: CGPoint) -> Bool { hitQueue.isEmpty ? hits : hitQueue.removeFirst() }
    func restore(gate: Gate) -> Bool { gate { true } }
'''
    harness += '    final class Diagnostic {' + diagnostic
    harness += '    private func mouse(' + mouse
    harness += '    static func keySequence(' + sequence
    harness += '    private func releaseKey(' + release
    harness += '    func perform(' + perform + '        if type == "key" || type == "text" {' + keypath + '        return false\n    }\n'
    harness += '    func cleanup()' + cleanup + '\n}\n'
    harness += r'''
let click: [String: Any] = ["t": "click", "x": 0.5, "y": 0.5, "count": 3]
for scenario in ["live", "create", "authority", "hit", "partial", "partial-create", "success"] {
    let input = InputController(), d = InputController.Diagnostic()
    CGEvent.posts = 0; CGEvent.creates = 0; CGEvent.failAt = 0
    if scenario == "live" { input.live = false }
    if scenario == "create" { CGEvent.failAt = 1 }
    if scenario == "partial-create" { CGEvent.failAt = 2 }
    if scenario == "hit" { input.hits = false }
    var gates = 0
    let ok = input.perform(click, diagnostic: d) { effect in
        gates += 1
        d.stage = .submitAuthority
        if scenario == "authority" || (scenario == "partial" && gates == 2) { return false }
        return effect()
    }
    let partial = scenario == "partial" || scenario == "partial-create"
    precondition(ok == (scenario == "success"))
    precondition(d.postedDown == (ok ? 3 : partial ? 1 : 0))
    precondition(d.postedUp == (ok ? 3 : 0))
    precondition(CGEvent.posts == d.postedDown + d.postedUp)
    let stages: [String: InputController.Diagnostic.Stage] = ["live": .liveTarget, "create": .eventCreate,
        "authority": .submitAuthority, "hit": .hit, "partial": .submitAuthority,
        "partial-create": .eventCreate, "success": .effectPosted]
    precondition(d.stage == stages[scenario])
    // Failed cleanup retains held state; successful retry releases it, without
    // adding cleanup posts to the request's down/up counters.
    if partial {
        CGEvent.failAt = CGEvent.creates + 1
        precondition(!input.cleanup() && input.heldButtons.count == 1)
        CGEvent.failAt = 0
    }
    let before = CGEvent.posts
    precondition(input.cleanup())
    // +1: cleanup always ends with a flagsChanged carrying no flags.
    precondition(CGEvent.posts == before + (partial ? 1 : 0) + 1)
    precondition(CGEvent.posted.last!.0 == .flagsChanged && CGEvent.posted.last!.2.isEmpty)
    precondition(input.heldButtons.isEmpty && !input.armed)
    precondition(d.postedDown == (ok ? 3 : partial ? 1 : 0) && d.postedUp == (ok ? 3 : 0))
    precondition(input.cleanup() && CGEvent.posts == before + (partial ? 1 : 0) + 2)
    print("PASS input diagnostics: \(scenario)")
}
// A release is never skipped (H1 2026-10-27): if its point fails the hit test it is posted at the last verified
// point, so the button is freed and a drag cannot drop onto another window. A release without our press posts nothing.
do {
    let input = InputController(), pass: (() -> Bool) -> Bool = { $0() }
    CGEvent.posts = 0; CGEvent.creates = 0; CGEvent.failAt = 0; CGEvent.posted = []
    precondition(input.perform(["t": "down", "x": 0.2, "y": 0.2], gate: pass))
    input.hitQueue = [false]
    precondition(input.perform(["t": "up", "x": 0.9, "y": 0.9], gate: pass))
    precondition(CGEvent.posted.count == 2 && CGEvent.posted[1].0 == .leftMouseUp && CGEvent.posted[1].1 == CGPoint(x: 20, y: 20))
    precondition(input.heldButtons.isEmpty)
    precondition(!input.perform(["t": "up", "x": 0.5, "y": 0.5], gate: pass) && CGEvent.posts == 2)
    input.hitQueue = [true, false]
    precondition(input.perform(["t": "click", "x": 0.5, "y": 0.5], gate: pass))
    precondition(CGEvent.posted.last!.0 == .leftMouseUp && CGEvent.posted.last!.1 == CGPoint(x: 50, y: 50) && input.heldButtons.isEmpty)
    precondition(input.perform(["t": "down", "x": 0.3, "y": 0.3], gate: pass) && input.cleanup())
    let afterCleanup = CGEvent.posts
    input.armed = true
    precondition(!input.perform(["t": "up", "x": 0.3, "y": 0.3], gate: pass) && CGEvent.posts == afterCleanup)
    // Nothing verifies (window moved away): the release still goes out, at the press point.
    precondition(input.perform(["t": "down", "x": 0.4, "y": 0.4], gate: pass))
    input.hits = false
    precondition(input.perform(["t": "up", "x": 0.9, "y": 0.9], gate: pass))
    precondition(CGEvent.posted.last!.0 == .leftMouseUp && CGEvent.posted.last!.1 == CGPoint(x: 40, y: 40) && input.heldButtons.isEmpty)
    print("PASS release never skipped, lands on a verified point; no release without our press or after cleanup")
}
// A held modifier is released as a flagsChanged with no flags, and cleanup's last event never carries flags (H1:
// Command stayed held after ⌘V and after the host exited).
do {
    let input = InputController()
    CGEvent.posted = []
    input.heldKeys = [55, 0]
    precondition(input.cleanup() && input.heldKeys.isEmpty)
    // The fake key-up starts with Command set, so a modifier released as a plain key-up would keep it.
    precondition(CGEvent.posted.filter { $0.0 != .keyUp }.allSatisfy { $0.2.isEmpty } && CGEvent.posted.filter { $0.0 == .flagsChanged }.count == 2)
    precondition(CGEvent.posted.count == 3 && CGEvent.posted.last!.0 == .flagsChanged && CGEvent.posted.last!.2.isEmpty)
    print("PASS cleanup releases modifiers and ends with no flags")
}
// A chord ends with no flags and nothing held; refused part-way (focus moved after the modifier downs), it releases
// what it pressed at once, last event without flags, before any cleanup.
do {
    let input = InputController(), pass: (() -> Bool) -> Bool = { $0() }
    CGEvent.posted = []
    precondition(input.perform(["t": "key", "key": "v", "mods": ["cmd", "shift"]], gate: pass))
    precondition(CGEvent.posted.count == 6 && CGEvent.posted.last!.0 == .flagsChanged && CGEvent.posted.last!.2.isEmpty && input.heldKeys.isEmpty)
    for refuseAt in 1...5 {
        CGEvent.posted = []
        input.focusQueue = Array(repeating: true, count: refuseAt) + [false]
        precondition(!input.perform(["t": "key", "key": "v", "mods": ["cmd", "shift"]], gate: pass))
        precondition(input.heldKeys.isEmpty, "held after refusal at \(refuseAt)")
        precondition(CGEvent.posted.filter { $0.0 == .flagsChanged }.last.map { $0.2.isEmpty } ?? true, "modifier left at \(refuseAt)")
    }
    // The gate itself refusing (authority lost) is handled the same way.
    for refuseAt in 1...5 {
        CGEvent.posted = []; var gates = 0
        precondition(!input.perform(["t": "key", "key": "v", "mods": ["cmd", "shift"]]) { effect in gates += 1; return gates <= refuseAt && effect() })
        precondition(input.heldKeys.isEmpty && (CGEvent.posted.filter { $0.0 == .flagsChanged }.last.map { $0.2.isEmpty } ?? true))
    }
    // Text refused between a character's down and up releases that character.
    input.focusQueue = [true, true, true, false]; CGEvent.posted = []
    precondition(!input.perform(["t": "text", "text": "ab"], gate: pass) && input.heldKeys.isEmpty)
    precondition(CGEvent.posted.map { $0.0 } == [.keyDown, .keyUp, .keyDown, .keyUp])
    print("PASS chord ends with no flags; a refused chord releases its keys at once")
}
'''
    file = path / 'input-diagnostics.swift'
    file.write_text(harness)
    subprocess.run(['swiftc', str(file), '-o', str(path / 'input-diagnostics')], check=True)
    subprocess.run([str(path / 'input-diagnostics')], check=True, timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--case', choices=['replacement', 'same-attachment', 'detach', 'detach-failure',
                                         'superseded-barrier', 'authority-order'])
    args = parser.parse_args()
    sources = args.source_root / 'host/Sources'
    with tempfile.TemporaryDirectory(prefix='windowshare-cleanup-') as temp:
        path = Path(temp)
        (path / 'PairingSession.swift').write_text((sources / 'PairingSession.swift').read_text() + EXTENSION)
        input_source = (sources / 'InputController.swift').read_text()
        diagnostic = input_source.split('    final class Diagnostic {', 1)[1].split('    private let window:', 1)[0]
        diagnostic = '    final class Diagnostic {' + diagnostic
        (path / 'Input.swift').write_text(STUB.replace('    static let keys', diagnostic + '    static let keys'))
        verify_input_diagnostics(path, input_source)
        (path / 'main.swift').write_text(MAIN)
        command = ['swiftc', '-o', str(path / 'verify'), str(path / 'PairingSession.swift')]
        command += [str(sources / name) for name in ['ControlServer.swift', 'EntryConfiguration.swift', 'AgentRequest.swift',
                                                    'ViewerPage.swift']]
        command += [str(path / 'Input.swift'), str(path / 'main.swift')]
        subprocess.run(command, check=True)
        for case in [args.case] if args.case else ['replacement', 'same-attachment', 'detach',
                                                 'detach-failure', 'superseded-barrier', 'authority-order']:
            subprocess.run([str(path / 'verify'), case], check=True, timeout=15)


if __name__ == '__main__':
    main()
