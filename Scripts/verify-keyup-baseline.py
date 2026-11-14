#!/usr/bin/env python3
"""Compile the unchanged controller against in-process CGEvent and session doubles."""

# Native event posting is forbidden for every verify subprocess.
import os as _verify_os
_verify_os.environ['WINDOWSHARE_TEST_NO_NATIVE_POST'] = '1'
import argparse, os, subprocess, tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--baseline',action='store_true');a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='ws-keyup-') as td:
 d=Path(td); source=(a.source_root/'host/Sources/InputController.swift').read_text()
 (d/'InputController.swift').write_text(source + '\nextension InputController { func fixtureHeldKey(_ key: CGKeyCode) { heldKeys.insert(key) } }\n')
 (d/'stubs.swift').write_text('''import Foundation
import CoreGraphics
import CoreFoundation
struct WindowInfo { let id: CGWindowID; let ownerPID: pid_t }
final class PairingSession {
 struct GeometryFailure: Error {
  enum Check { case launchDate, windowCount, windowIdentity, bounds, displayCount, displayMode, modeWidth, nonFinite }
  var check: Check
  var launchOK = false, windows = -1, idOK = false, pidOK = false, boundsOK = false
  var displayQueryOK = false, displays = -1, modeOK = false, modeWidthOK = false
 }
}
func CGSessionCopyCurrentDictionary() -> CFDictionary? { unsafeBitCast(["CGSSessionScreenIsLocked": false] as NSDictionary, to: CFDictionary.self) }
final class CGEvent {
 static var posted: [(CGEventType, CGEventFlags)] = []
 var type: CGEventType = .null
 var flags: CGEventFlags = .maskCommand
 var location = CGPoint.zero
 init?(mouseEventSource: CGEventSource?, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) { type = mouseType; location = mouseCursorPosition }
 init?(keyboardEventSource: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool) { type = keyDown ? .keyDown : .keyUp }
 init?(scrollWheelEvent2Source: CGEventSource?, units: CGScrollEventUnit, wheelCount: Int, wheel1: Int32, wheel2: Int32, wheel3: Int32) {}
 func setIntegerValueField(_ field: CGEventField, value: Int64) {}
 func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UInt16>?) {}
 func post(tap: CGEventTapLocation) { Self.posted.append((type, flags)) }
}
''')
 (d/'main.swift').write_text('''import Foundation
import CoreGraphics
let w = WindowInfo(id: 0, ownerPID: 0)
#if BASELINE
let input = InputController(window: w)
#else
let input = InputController(window: w, poster: { $0.post(tap: .cghidEventTap) }, isLocked: { false })
#endif
input.fixtureHeldKey(0)
precondition(input.cleanup())
if CGEvent.posted.count != 1 || CGEvent.posted[0].0 != .keyUp || !CGEvent.posted[0].1.isEmpty {
 print("FAIL ordinary keyUp flags: \\(CGEvent.posted)"); exit(1)
}
print("PASS ordinary keyUp has empty flags")
''')
 cmd=['swiftc']+(['-D','BASELINE'] if a.baseline else [])+[str(d/'InputController.swift'),str(d/'stubs.swift'),str(d/'main.swift'),'-o',str(d/'test')]
 subprocess.run(cmd,check=True);subprocess.run([str(d/'test')],check=True,env=dict(os.environ,WINDOWSHARE_TEST_NO_NATIVE_POST='1'))
