#!/usr/bin/env python3
"""Run production cleanup with a recording poster; never post native input."""

from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    (d/'stubs.swift').write_text('''import Foundation
import CoreGraphics
struct WindowInfo { let id: CGWindowID; let ownerPID: pid_t }
final class PairingSession {
 struct GeometryFailure: Error {
  enum Check { case launchDate, windowCount, windowIdentity, bounds, displayCount, displayMode, modeWidth, nonFinite }
  var check: Check
  var launchOK = false, windows = -1, idOK = false, pidOK = false, boundsOK = false
  var displayQueryOK = false, displays = -1, modeOK = false, modeWidthOK = false
 }
}
''')
    (d/'main.swift').write_text('''import Foundation
import CoreGraphics
let window = WindowInfo(id: 0, ownerPID: 0)
if CommandLine.arguments.contains("guard") {
 let input = InputController(window: window, isLocked: { false })
 input.testTrackKey(0)
 _ = input.cleanup()
 precondition(InputController.testNativePostAttempts == 1)
 print("PASS native post attempt recorded and execution continued")
 exit(0)
}
var events: [(CGEventType, CGEventFlags, CGPoint)] = []
let input = InputController(window: window, poster: { events.append(($0.type, $0.flags, $0.location)) }, isLocked: { false })
input.testTrackKey(0)
precondition(input.cleanup())
precondition(events.count == 1 && events[0].0 == .keyUp && events[0].1.isEmpty)
input.testTrackKey(55)
precondition(input.cleanup())
precondition(events.count == 2 && events[1].0 == .flagsChanged && events[1].1.isEmpty)
print("PASS production cleanup recorded keyUp and modifier release with empty flags")
let test = InputController(window: window, poster: { events.append(($0.type, $0.flags, $0.location)) }, isLocked: { false })
test.testFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
let pass: InputController.Gate = { $0() }
// Explicitly provide enough approvals for the following successful actions.
test.testHits = Array(repeating: true, count: 64)
test.testFocus = Array(repeating: true, count: 64)
events = []
precondition(test.perform(["t":"click", "x":0.5, "y":0.5, "count":3], gate: pass))
precondition(events.map { $0.0 } == [.leftMouseDown,.leftMouseUp,.leftMouseDown,.leftMouseUp,.leftMouseDown,.leftMouseUp])
precondition(test.perform(["t":"key", "key":"v", "mods":["cmd", "shift"]], gate: pass))
precondition(Array(events.suffix(6)).map { $0.0 } == [.flagsChanged,.flagsChanged,.keyDown,.keyUp,.flagsChanged,.flagsChanged])
let both: CGEventFlags = [.maskShift, .maskCommand]
precondition(Array(events.suffix(6)).map { $0.1 } == [.maskShift, both, both, both, .maskShift, []])
precondition(test.cleanup())
var locked = true
let blocked = InputController(window: window, poster: { events.append(($0.type, $0.flags, $0.location)) }, isLocked: { locked })
blocked.testFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
let before = events.count
for obj: [String: Any] in [["t":"click", "x":0.5, "y":0.5], ["t":"scroll", "dx":0, "dy":1], ["t":"key", "key":"v", "mods":["cmd"]], ["t":"text", "text":"a"]] {
 precondition(!blocked.perform(obj, gate: pass))
}
precondition(events.count == before)
locked = false
blocked.testHits = [true]
precondition(blocked.perform(["t":"down", "x":0.5, "y":0.5], gate: pass))
locked = true
precondition(!blocked.cleanup() && events.count == before + 1)
locked = false
precondition(blocked.cleanup() && events.count == before + 2 && events.last!.0 == .leftMouseUp)
let partial = InputController(window: window, poster: { events.append(($0.type, $0.flags, $0.location)) }, isLocked: { false })
partial.testFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
partial.testHits = [true]
partial.testFailCreateButtons = [.left]
partial.testFailCreateMouseTypes = [.leftMouseUp]
let d = InputController.Diagnostic()
precondition(!partial.perform(["t":"click", "x":0.5, "y":0.5], diagnostic: d, gate: pass))
precondition(d.postedDown == 1 && d.postedUp == 0)

let beforeFailedCleanup = events.count
precondition(!partial.cleanup() && events.count == beforeFailedCleanup)
partial.testFailCreateButtons = []
precondition(partial.cleanup() && events.last!.0 == .leftMouseUp)
events = []
precondition(test.perform(["t":"down", "x":0.2, "y":0.2], gate: pass))
test.testHits = [false]
precondition(test.perform(["t":"up", "x":0.9, "y":0.9], gate: pass))
precondition(events.map { $0.0 } == [.leftMouseDown, .leftMouseUp] && events.last!.2 == CGPoint(x:20,y:20))
let n = events.count
precondition(!test.perform(["t":"up", "x":0.5, "y":0.5], gate: pass) && events.count == n)
test.testHits = Array(repeating: true, count: 64)
for kind in ["down", "move", "drag", "up"] {
 precondition(test.perform(["t":kind,"x":0.5,"y":0.5],gate:pass))
}
precondition(test.perform(["t":"scroll","dx":0,"dy":1],gate:pass))
precondition(test.perform(["t":"text","text":"a"],gate:pass))
events = []
test.testFocus = [true, true, true, false]
precondition(!test.perform(["t":"text","text":"ab"], gate: pass))
precondition(events.map { $0.0 } == [.keyDown, .keyUp, .keyDown, .keyUp])
for refuseAt in 1...5 {
 events = []
 test.testFocus = Array(repeating: true, count: refuseAt) + [false]
 precondition(!test.perform(["t":"key","key":"v","mods":["cmd","shift"]],gate:pass))
 precondition(events.filter { $0.0 == .flagsChanged }.last.map { $0.1.isEmpty } ?? true)
 let after = events.count
 precondition(test.cleanup() && events.count == after)
}
for refuseAt in 1...5 {
 test.testFocus = Array(repeating: true, count: 64)
 events = []; var gates = 0
 precondition(!test.perform(["t":"key","key":"v","mods":["cmd","shift"]]) { effect in gates += 1; return gates <= refuseAt && effect() })
 precondition(events.filter { $0.0 == .flagsChanged }.last.map { $0.1.isEmpty } ?? true)
 let after = events.count
 precondition(test.cleanup() && events.count == after)
}
let exhausted = InputController(window: window, poster: { _ in events.append((.null, [], .zero)) }, isLocked: { false })
exhausted.testFrame = CGRect(x:0,y:0,width:100,height:100)
let beforeExhausted = events.count
precondition(!exhausted.perform(["t":"down","x":0.5,"y":0.5],gate:pass) && events.count == beforeExhausted)
exhausted.testHits = [true]
precondition(exhausted.perform(["t":"down","x":0.5,"y":0.5],gate:pass))
precondition(!exhausted.perform(["t":"key","key":"v"],gate:pass))
exhausted.testFocus = [true, true, true]
precondition(exhausted.perform(["t":"key","key":"v"],gate:pass))
precondition(exhausted.cleanup())
let failure = InputController(window: window, poster: { _ in events.append((.null, [], .zero)) }, isLocked: { false })
failure.testTrackButton(.right, point: .zero); failure.testTrackButton(.left, point: .zero)
failure.testTrackKey(0); failure.testTrackKey(55)
failure.testFailCreateButtons = [.right]; failure.testFailCreateMouseTypes = [.rightMouseUp]
failure.testFailCreateKeys = [55]
let beforeFailure = events.count
precondition(!failure.cleanup() && events.count == beforeFailure + 2)
failure.testFailCreateButtons = []; failure.testFailCreateKeys = []
precondition(failure.cleanup() && events.count == beforeFailure + 4)
var ordered: [String] = []
precondition(InputController.releaseTracked(buttons: [.right: .zero, .left: .zero], keys: [55, 0], releaseButton: { b, _ in ordered.append("b\(b.rawValue)"); return true }, releaseKey: { k in ordered.append("k\(k)"); return true }))
precondition(ordered == ["b0", "b1", "k0", "k55"])
let missing = InputController(window: window, poster: { events.append(($0.type, $0.flags, $0.location)) }, isLocked: { false })
let diag = InputController.Diagnostic()
precondition(!missing.perform(["t":"click","x":0.5,"y":0.5], diagnostic:diag,gate:pass) && diag.stage == .liveTarget)
let denied = InputController(window: window, poster: { events.append(($0.type, $0.flags, $0.location)) }, isLocked: { false })
denied.testFrame = CGRect(x:0,y:0,width:100,height:100)
let deniedDiag = InputController.Diagnostic()
denied.testHits = [false]
precondition(!denied.perform(["t":"click","x":0.5,"y":0.5],diagnostic:deniedDiag,gate:pass) && deniedDiag.stage == .hit)
precondition(!denied.perform(["t":"click","x":0.5,"y":0.5],gate:{ _ in false }))
var lockedDuringCleanup = false
var releaseCount = 0
let interrupted = InputController(window: window, poster: { _ in releaseCount += 1; lockedDuringCleanup = true }, isLocked: { lockedDuringCleanup })
interrupted.testTrackButton(.left, point: .zero); interrupted.testTrackButton(.right, point: .zero)
precondition(!interrupted.cleanup() && releaseCount == 1)
lockedDuringCleanup = false
precondition(interrupted.cleanup() && releaseCount == 2)
// Long mixed text exercises the real native executor with only a recording poster.
let mixed = String(repeating: "中文Ab9🙂", count: 80)
let typing = InputController(window: window, poster: { events.append(($0.type, $0.flags, $0.location)) }, isLocked: { false })
typing.testFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
typing.testFocus = Array(repeating: true, count: mixed.count * 2)
let typed = InputController.Diagnostic(), startText = events.count
var gates = 0
precondition(typing.perform(["t":"text", "text":mixed], diagnostic:typed, gate:{ effect in gates += 1; return effect() }))
precondition(typed.postedEffects == mixed.count * 2 && gates == mixed.count * 2 && events.count - startText == mixed.count * 2)
precondition(typed.stage == .effectPosted)
let focusDenied = InputController.Diagnostic()
typing.testFocus = [false]
precondition(!typing.perform(["t":"text", "text":"中"], diagnostic:focusDenied, gate:pass))
precondition(focusDenied.stage == .focus && focusDenied.postedEffects == 0)
let scroll = InputController.Diagnostic()
typing.testHits = [true]
precondition(typing.perform(["t":"scroll", "dx":0, "dy":120], diagnostic:scroll, gate:pass))
precondition(scroll.postedEffects == 1 && scroll.stage == .effectPosted && events.last!.0 == .scrollWheel)
let scrollDenied = InputController.Diagnostic()
typing.testHits = [false]
precondition(!typing.perform(["t":"scroll", "dx":0, "dy":120], diagnostic:scrollDenied, gate:pass))
precondition(scrollDenied.postedEffects == 0 && scrollDenied.stage == .hit)
print("PASS long Chinese/English/emoji text and scrolling; focus/hit rejection has no effects")
precondition(InputController.testNativePostAttempts == 0, "unexpected native post attempts")
print("PASS production input: click, chord, lock, deferred cleanup, release targeting and partial failures")
''')
    subprocess.run(['swiftc','-D','WINDOWSHARE_TEST',str(root/'host/Sources/InputController.swift'),str(d/'stubs.swift'),str(d/'main.swift'),'-o',str(d/'test')],check=True)
    env = os.environ.copy()
    subprocess.run([str(d/'test')],check=True,env=env)
    guard = subprocess.run([str(d/'test'),'guard'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    assert guard.returncode != 0 and 'PASS native post attempt recorded' in guard.stdout and 'unexpected native post attempts' in guard.stderr, (guard.stdout, guard.stderr)
    print('PASS real poster guard records without terminating')
