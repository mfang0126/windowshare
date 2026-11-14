#!/usr/bin/env python3
"""Run production cleanup with a recording poster; never post native input."""

# Native event posting is forbidden for every verify subprocess.
import os as _verify_os
_verify_os.environ['WINDOWSHARE_TEST_NO_NATIVE_POST'] = '1'
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
 fatalError("native post guard did not fire")
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
precondition(blocked.perform(["t":"down", "x":0.5, "y":0.5], gate: pass))
locked = true
precondition(!blocked.cleanup() && events.count == before + 1)
locked = false
precondition(blocked.cleanup() && events.count == before + 2 && events.last!.0 == .leftMouseUp)
let partial = InputController(window: window, poster: { events.append(($0.type, $0.flags, $0.location)) }, isLocked: { false })
partial.testFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
partial.testFailCreateAt = 2
let d = InputController.Diagnostic()
precondition(!partial.perform(["t":"click", "x":0.5, "y":0.5], diagnostic: d, gate: pass))
precondition(d.postedDown == 1 && d.postedUp == 0)
partial.testFailCreateAt = partial.testCreateCount + 1
let beforeFailedCleanup = events.count
precondition(!partial.cleanup() && events.count == beforeFailedCleanup)
partial.testFailCreateAt = 0
precondition(partial.cleanup() && events.last!.0 == .leftMouseUp)
events = []
precondition(test.perform(["t":"down", "x":0.2, "y":0.2], gate: pass))
test.testHits = [false]
precondition(test.perform(["t":"up", "x":0.9, "y":0.9], gate: pass))
precondition(events.map { $0.0 } == [.leftMouseDown, .leftMouseUp] && events.last!.2 == CGPoint(x:20,y:20))
let n = events.count
precondition(!test.perform(["t":"up", "x":0.5, "y":0.5], gate: pass) && events.count == n)
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
 events = []; var gates = 0
 precondition(!test.perform(["t":"key","key":"v","mods":["cmd","shift"]]) { effect in gates += 1; return gates <= refuseAt && effect() })
 precondition(events.filter { $0.0 == .flagsChanged }.last.map { $0.1.isEmpty } ?? true)
 let after = events.count
 precondition(test.cleanup() && events.count == after)
}
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
print("PASS production input: click, chord, lock, deferred cleanup, release targeting and partial failures")
''')
    subprocess.run(['swiftc','-D','WINDOWSHARE_TEST',str(root/'host/Sources/InputController.swift'),str(d/'stubs.swift'),str(d/'main.swift'),'-o',str(d/'test')],check=True)
    env = dict(os.environ, WINDOWSHARE_TEST_NO_NATIVE_POST='1')
    subprocess.run([str(d/'test')],check=True,env=env)
    guard = subprocess.run([str(d/'test'),'guard'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    assert guard.returncode != 0 and 'native event post forbidden in test process' in guard.stderr, guard.stderr
    print('PASS real poster guard prevents native event')
