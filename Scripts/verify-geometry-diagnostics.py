#!/usr/bin/env python3
"""F-4 geometryUnavailable diagnostics: every native geometry check, failed one at a time, from every caller.

Compiles the production InputController / PairingSession and replaces only the native reads (`InputController.Probe`)
with fakes, so no window, display, capture or input is touched. For each failure and each caller (capture, input,
commit_gate) it asserts: exactly one `[geometry] unavailable` line naming that check and that caller with the right
booleans and counts, the share is revoked at once (fail-closed, nothing retried), and the log carries no title, link,
token or coordinate. It also checks that the three production call sites pass their own caller name.
Usage (repo root): python3 Scripts/verify-geometry-diagnostics.py [--source <repo root to test>]
"""
from pathlib import Path
import subprocess, sys, tempfile

root = Path(sys.argv[sys.argv.index('--source') + 1] if '--source' in sys.argv else Path(__file__).resolve().parent.parent)
src = root / 'host/Sources'
failures = []

# The callers name themselves: capture per frame, input before perform, commit_gate inside the submission gate.
control = (src / 'ControlServer.swift').read_text()
capture = (src / 'CaptureController.swift').read_text()
pre = 'let observed = identity.observeGeometry(input.measure(), source: .input, binding: context.binding)'
gate = 'guard identity.observeGeometry(input.measure(), source: .commitGate, binding: context.binding) == geometry'
if pre not in control or gate not in control or control.index(pre) > control.index(gate):
    failures.append('ControlServer does not pass source .input before perform and .commitGate inside the gate')
if 'identity.observeGeometry(reading, source: .capture, binding: binding)' not in capture:
    failures.append('CaptureController does not pass source .capture')
for name, text in [('ControlServer', control), ('CaptureController', capture)]:
    if 'observeGeometry(input.geometry()' in text or 'observeGeometry(live,' in text:
        failures.append(f'{name} still observes geometry without a source')

HARNESS = r'''
import Foundation
import CoreGraphics
let secret = "WS-SECRET-TITLE https://example.invalid/w/abc?token=tok-123"
func row(id: Int = 42, pid: Int = 4242, x: CGFloat = 1234.5, w: CGFloat = 777, bounds: Bool = true) -> [String: Any] {
    var r: [String: Any] = [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
                            kCGWindowName as String: secret, kCGWindowOwnerName as String: secret]
    if bounds { r[kCGWindowBounds as String] = ["X": x, "Y": 678.25 as CGFloat, "Width": w, "Height": 555 as CGFloat] }
    return r
}
func probe(launch: Bool = true, rows: [[String: Any]]? = [row()], displays: [CGDirectDisplayID]? = [7],
           mode: (width: Int, pixelWidth: Int)? = (width: 1512, pixelWidth: 3024)) -> InputController.Probe {
    InputController.Probe(launchMatches: { launch }, rows: { rows }, displays: { _ in displays }, mode: { _ in mode })
}
let cases: [(String, InputController.Probe)] = [
    ("launch_date", probe(launch: false)),
    ("window_count_nil", probe(rows: nil)),
    ("window_count_zero", probe(rows: [])),
    ("window_count_two", probe(rows: [row(), row()])),
    ("window_identity_id", probe(rows: [row(id: 43)])),
    ("window_identity_pid", probe(rows: [row(pid: 4243)])),
    ("bounds_missing", probe(rows: [row(bounds: false)])),
    ("bounds_width", probe(rows: [row(w: 0)])),
    ("display_count_query", probe(displays: nil)),
    ("display_count_zero", probe(displays: [])),
    ("display_count_two", probe(displays: [7, 8])),
    ("display_mode", probe(mode: nil)),
    ("mode_width", probe(mode: (width: 0, pixelWidth: 3024))),
    ("non_finite", probe(rows: [row(x: .nan)])),
]
let sources: [PairingSession.GeometrySource] = [.capture, .input, .commitGate]
func say(_ s: String) { fputs(s + "\n", stderr) }
// The happy path observes and logs nothing.
do {
    let identity = PairingSession(now: { 100 })
    let binding = identity.selectWindow(); precondition(identity.activate(binding))
    say("CASE ok capture")
    precondition(identity.observeGeometry(InputController.measure(id: 42, pid: 4242, probe: probe()), source: .capture, binding: binding) == 1)
    precondition(identity.isCurrent(binding))
}
for (name, p) in cases {
    for source in sources {
        let identity = PairingSession(now: { 100 })
        let binding = identity.selectWindow(); precondition(identity.activate(binding))
        precondition(identity.observeGeometry([0, 0, 800, 600, 2], binding: binding) == 1)
        say("CASE \(name) \(source.rawValue)")
        let reading = InputController.measure(id: 42, pid: 4242, probe: p)
        let revokedNow = identity.observeGeometry(reading, source: source, binding: binding) == nil && !identity.isCurrent(binding)
        // A later good reading must not revive it: no retry, no grace window.
        let revived = identity.observeGeometry(InputController.measure(id: 42, pid: 4242, probe: probe()), source: source, binding: binding) != nil
        say("RESULT revoked=\(revokedNow) revived=\(revived)")
    }
}
// A finite-count violation that reaches the session as a value is still named.
let identity = PairingSession(now: { 100 })
let binding = identity.selectWindow(); precondition(identity.activate(binding))
say("CASE short_value capture")
say("RESULT revoked=\(identity.observeGeometry([1, 2, 3], binding: binding) == nil && !identity.isCurrent(binding)) revived=false")
say("END")
'''

COMMON = ' launch_ok=true windows=1 id_ok=true pid_ok=true bounds_ok=true display_query_ok=true displays=1 mode_ok=true'
EXPECT = {
    'launch_date': 'check=launch_date launch_ok=false windows=-1 id_ok=false pid_ok=false bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'window_count_nil': 'check=window_count launch_ok=true windows=-1 id_ok=false pid_ok=false bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'window_count_zero': 'check=window_count launch_ok=true windows=0 id_ok=false pid_ok=false bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'window_count_two': 'check=window_count launch_ok=true windows=2 id_ok=false pid_ok=false bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'window_identity_id': 'check=window_identity launch_ok=true windows=1 id_ok=false pid_ok=true bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'window_identity_pid': 'check=window_identity launch_ok=true windows=1 id_ok=true pid_ok=false bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'bounds_missing': 'check=bounds launch_ok=true windows=1 id_ok=true pid_ok=true bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'bounds_width': 'check=bounds launch_ok=true windows=1 id_ok=true pid_ok=true bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'display_count_query': 'check=display_count launch_ok=true windows=1 id_ok=true pid_ok=true bounds_ok=true display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=-1',
    'display_count_zero': 'check=display_count launch_ok=true windows=1 id_ok=true pid_ok=true bounds_ok=true display_query_ok=true displays=0 mode_ok=false mode_width_ok=false values=-1',
    'display_count_two': 'check=display_count launch_ok=true windows=1 id_ok=true pid_ok=true bounds_ok=true display_query_ok=true displays=2 mode_ok=false mode_width_ok=false values=-1',
    'display_mode': 'check=display_mode launch_ok=true windows=1 id_ok=true pid_ok=true bounds_ok=true display_query_ok=true displays=1 mode_ok=false mode_width_ok=false values=-1',
    'mode_width': 'check=mode_width' + COMMON + ' mode_width_ok=false values=-1',
    'non_finite': 'check=non_finite' + COMMON + ' mode_width_ok=true values=-1',
    'short_value': 'check=non_finite launch_ok=false windows=-1 id_ok=false pid_ok=false bounds_ok=false display_query_ok=false displays=-1 mode_ok=false mode_width_ok=false values=3',
}

log = ''
with tempfile.TemporaryDirectory(prefix='verify-geometry-diag-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(HARNESS)
    files = [str(src / f'{n}.swift') for n in ['CaptureController', 'InputController', 'PairingSession', 'ViewerPage', 'EntryConfiguration', 'AgentRequest']]
    build = subprocess.run(['swiftc', *files, str(tmp / 'main.swift'), '-o', str(tmp / 'check')], capture_output=True, text=True)
    if build.returncode:
        failures.append('harness does not compile against this source (no Probe / measure / sourced observeGeometry): ' + build.stderr.strip().splitlines()[0][:300])
    else:
        run = subprocess.run([str(tmp / 'check')], capture_output=True, text=True, timeout=60)
        log = run.stderr
        if run.returncode or 'END' not in log:
            failures.append(f'harness exited {run.returncode}: {log[-500:]}')

cases = {}
current = None
for line in log.splitlines():
    if line.startswith('CASE '):
        current = tuple(line.split()[1:3]); cases[current] = []
    elif current:
        cases[current].append(line)
for (name, source), lines in cases.items():
    diag = [l for l in lines if l.startswith('[geometry]')]
    if name == 'ok':
        if diag or any('geometryUnavailable' in l for l in lines): failures.append(f'ok {source}: logged {lines}')
        continue
    want = f'[geometry] unavailable source={source} {EXPECT[name]}'
    if diag != [want]: failures.append(f'{name} {source}: want {want!r}, got {diag}')
    revoke = [i for i, l in enumerate(lines) if 'geometryUnavailable' in l]
    if [lines[i] for i in revoke] != ['[session] window revoked reason=geometryUnavailable'] or \
            not diag or lines.index(diag[0]) > revoke[0]:
        failures.append(f'{name} {source}: want the diagnostic then one geometryUnavailable revoke: {lines}')
    if 'RESULT revoked=true revived=false' not in lines: failures.append(f'{name} {source}: not revoked at once or revived: {lines}')
expected_cases = {('ok', 'capture'), ('short_value', 'capture')} | {(n, s) for n in EXPECT if n != 'short_value' for s in ['capture', 'input', 'commit_gate']}
if log and set(cases) != expected_cases: failures.append(f'cases ran {len(cases)}, want {len(expected_cases)}')
geometry_lines = '\n'.join(l for l in log.splitlines() if l.startswith('[geometry]'))
for leak in ['WS-SECRET', 'http', 'example.invalid', 'token', 'tok-123', '1234', '678', '777', '555', '3024', '1512']:
    if leak in geometry_lines: failures.append(f'diagnostic leaks {leak!r}')

for f in failures: print('FAIL', f)
if failures: sys.exit(1)
print(f'PASS geometry diagnostics: {len(cases) - 1} failure cases (14 variants of the 8 checks x capture/input/commit_gate, plus a short value) each log one'
      ' fixed check name, caller, booleans and counts, revoke at once and stay revoked; no title/link/token/coordinate')
