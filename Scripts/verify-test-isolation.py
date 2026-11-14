#!/usr/bin/env python3
"""Check test-only hooks cannot leak into the normal release artifact."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = (root / 'host/Sources/InputController.swift').read_text()
package = (root / 'Package.swift').read_text()
release_script = (root / 'Scripts/build-app.sh').read_text()
checks = {
    'production has no environment crash switch': 'WINDOWSHARE_TEST_NO_NATIVE_POST' not in source,
    'release package and build script do not define test macro': 'WINDOWSHARE_TEST' not in package and 'WINDOWSHARE_TEST' not in release_script,
    'empty hit and focus queues fail closed': 'testHits.isEmpty ? false' in source and 'testFocus.isEmpty ? false' in source,
    'creation failure hooks are per button and key': 'testFailCreateAt' not in source and 'testFailCreateButtons' in source and 'testFailCreateKeys' in source,
    'native post attempts are recorded without crashing': 'testNativePostAttempts' in source and 'preconditionFailure("native event post forbidden' not in source,
}
for name, passed in checks.items():
    print(('PASS' if passed else 'FAIL') + ' ' + name)
if not all(checks.values()):
    sys.exit(1)

# Build in a fresh scratch directory so an incremental build cannot hide compiler flags.
import tempfile
with tempfile.TemporaryDirectory(prefix='windowshare-release-') as scratch:
    cmd = ['swift', 'build', '-c', 'release', '-v', '--scratch-path', scratch]
    build = subprocess.run(cmd, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if build.returncode:
        print(build.stdout)
        raise SystemExit(build.returncode)
    compile_lines = [line for line in build.stdout.splitlines() if 'swiftc ' in line or 'swift-frontend ' in line]
    assert compile_lines, 'no Swift compiler command found'
    assert all('WINDOWSHARE_TEST' not in line for line in compile_lines), 'release compiler command defines test macro'
    binary = Path(scratch) / 'release' / 'WindowShareHost'
    assert binary.exists(), f'missing {binary}'
    strings = subprocess.run(['strings', str(binary)], check=True, capture_output=True, text=True).stdout
    symbols = subprocess.run(['nm', str(binary)], check=True, capture_output=True, text=True).stdout
    for marker in ('native event post forbidden in test process', 'unexpected native post attempts', 'testPostGuard', 'testNativePostAttempts', 'testFailCreateButtons', 'testFailCreateKeys'):
        assert marker not in strings and marker not in symbols, f'test marker in release artifact: {marker}'
    print('PASS fresh release compiler commands and binary exclude test hooks')
