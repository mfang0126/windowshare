#!/usr/bin/env python3
"""Regression contracts for the first v1 matrix; no capture or input injection."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
p = (root/'host/Sources/PairingSession.swift').read_text()
i = (root/'host/Sources/InputController.swift').read_text()
c = (root/'host/Sources/CaptureController.swift').read_text()
s = (root/'host/Sources/ControlServer.swift').read_text()
v = (root/'host/Sources/ViewerPage.swift').read_text()
checks = {
 'events': all(x in p for x in ['emit("share_started"', 'emit("interact_granted"', 'emit("interact_revoked"']),
 'locked': all(x in p+s+v+i for x in ['CGSessionCopyCurrentDictionary', 'screenLocked', 'Mac 已锁屏，请先解锁']),
 'cleanup': 'releaseTracked(buttons: heldButtons, keys: heldKeys' in i and 'Always end with a flagsChanged' not in i,
 'view_fps': 'viewFPS' in c and '?? 24' in c,
}
for name, ok in checks.items(): print(f'{name}: {"PASS" if ok else "FAIL"}')
if not all(checks.values()): sys.exit(1)

# Execute the real authority and cleanup planner with synthetic lock state, without posting events.
import ast, subprocess, tempfile
source = ast.parse((root/'Scripts/verify-agent-events.py').read_text())
unit = next(ast.literal_eval(n.value) for n in source.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'UNIT' for t in n.targets))
prefix = unit[:unit.index('// Auth: same gate')].replace('let identity = PairingSession(now: { clock })', 'var locked = false\nlet identity = PairingSession(now: { clock }, screenLocked: { locked })')
harness = prefix + r'''
let first = json(reply("GET", "/agent/events/0"))["events"] as! [[String: Any]]
precondition(first.count == 1 && first[0]["kind"] as? String == "share_started")
_ = drain()
var cleanupEpochs: [Int] = []
identity.installCleanup { cleanupEpochs.append($0) }
let control = viewer()
locked = true
precondition(identity.acquire(control.context, operation: UUID().uuidString, ttl: 300) == "screenLocked")
locked = false
precondition(identity.acquire(control.context, operation: UUID().uuidString, ttl: 300) == "ok")
precondition(kinds(drain()) == ["interact_granted:lease_acquired"])
locked = true
let state = identity.state(control.context)!
precondition(state["mode"] as? String == "View" && state["screen_locked"] as? Bool == true)
precondition(kinds(drain()) == ["interact_revoked:screenLocked"])
precondition(cleanupEpochs.count == 1)
identity.finishCleanup(epoch: cleanupEpochs[0], success: false)
locked = false
_ = identity.state(control.context)
precondition(cleanupEpochs.count == 2 && cleanupEpochs[0] == cleanupEpochs[1], "retry cleanup after unlock")
identity.finishCleanup(epoch: cleanupEpochs[1], success: true)
var calls = 0
precondition(InputController.releaseTracked(buttons: [:], keys: [], releaseButton: { _, _ in calls += 1; return true }, releaseKey: { _ in calls += 1; return true }))
precondition(calls == 0, "no tracked downs means no post")
precondition(CaptureController.viewFPS == (ProcessInfo.processInfo.environment["EXPECTED_FPS"].flatMap(Int.init) ?? 24))
print("PASS runtime: share start, lock acquire denial, grant, lock revoke, no empty cleanup events, view 24fps")
'''
with tempfile.TemporaryDirectory() as d:
    f = Path(d)/'main.swift'; f.write_text(harness)
    files = ['PairingSession.swift','ViewerPage.swift','EntryConfiguration.swift','InputController.swift','CaptureController.swift','AgentRequest.swift','CLI.swift']
    subprocess.run(['swiftc', *[str(root/'host/Sources'/x) for x in files], str(f), '-o', str(Path(d)/'test')], check=True)
    import os
    for configured, expected in [(None, '24'), ('17', '17'), ('99', '24')]:
        env = dict(os.environ, EXPECTED_FPS=expected)
        env.pop('WINDOWSHARE_VIEW_FPS', None)
        if configured is not None: env['WINDOWSHARE_VIEW_FPS'] = configured
        subprocess.run([str(Path(d)/'test')], check=True, env=env)
    print('PASS view FPS default, configured 17, invalid value fallback')
