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
    final class Diagnostic {
        enum Stage: String {
            case preTarget = "pre_target", preGeometry = "pre_geometry"
            case liveTarget = "perform_live_target", eventCreate = "event_create"
            case gateDemo = "gate_demo", gateGeometry = "gate_geometry"
            case submitAuthority = "submit_authority", hit, heldButton = "held_button"
            case effectPosted = "effect_posted"
        }
        var stage: Stage = .preTarget
        var postedEffects = 0
        var postedDown = 0
        var postedUp = 0
    }
    static func screenLocked() -> Bool { false }
    static let keys = ["enter": 36]
    static let modifiers = ["cmd": 1]
    static func allowedChord(key: String, mods: [String]) -> Bool { true }
    var cleanups = 0
    var held = false
    var succeeds = true
    var onCleanup: (() -> Void)?
    func sensitiveFocus() -> Bool { true }
    func focusedTextEntry() -> Bool { false }
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
        (path / 'Input.swift').write_text(STUB)
        subprocess.run(['python3', str(ROOT / 'Scripts/verify-input-poster.py')], check=True)
        (path / 'main.swift').write_text(MAIN)
        command = ['swiftc', '-D', 'WINDOWSHARE_TEST', '-o', str(path / 'verify'), str(path / 'PairingSession.swift')]
        command += [str(sources / name) for name in ['ControlServer.swift', 'EntryConfiguration.swift', 'AgentRequest.swift',
                                                    'ViewerPage.swift']]
        command += [str(path / 'Input.swift'), str(path / 'main.swift')]
        subprocess.run(command, check=True)
        for case in [args.case] if args.case else ['replacement', 'same-attachment', 'detach',
                                                 'detach-failure', 'superseded-barrier', 'authority-order']:
            subprocess.run([str(path / 'verify'), case], check=True, timeout=15)


if __name__ == '__main__':
    main()
