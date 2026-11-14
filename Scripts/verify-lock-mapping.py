#!/usr/bin/env python3
"""Exercise the actual session dictionary mapping using an in-process CGSession double."""

# Native event posting is forbidden for every verify subprocess.
import os as _verify_os
_verify_os.environ['WINDOWSHARE_TEST_NO_NATIVE_POST'] = '1'
import argparse, os, subprocess, tempfile
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[1]); a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='ws-map-') as td:
 d=Path(td)
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
var session: CFDictionary?
func CGSessionCopyCurrentDictionary() -> CFDictionary? { session }
''')
 (d/'main.swift').write_text('''import Foundation
import CoreFoundation
func dict(_ value: [String: Any]) -> CFDictionary { unsafeBitCast(value as NSDictionary, to: CFDictionary.self) }
for (name, value, expected) in [("missing session", nil as CFDictionary?, true), ("missing key", dict([:]), false), ("false", dict(["CGSSessionScreenIsLocked": false]), false), ("true", dict(["CGSSessionScreenIsLocked": true]), true), ("wrong type", dict(["CGSSessionScreenIsLocked": "bad"]), false)] {
 session = value
 let actual = InputController.screenLocked()
 if actual != expected { print("FAIL \\(name): got \\(actual), expected \\(expected)"); exit(1) }
}
print("PASS lock mapping")
''')
 subprocess.run(['swiftc',str(a.source_root/'host/Sources/InputController.swift'),str(d/'stubs.swift'),str(d/'main.swift'),'-o',str(d/'test')],check=True)
 subprocess.run([str(d/'test')],check=True,env=dict(os.environ,WINDOWSHARE_TEST_NO_NATIVE_POST='1'))
