#!/usr/bin/env python3
"""No-injection v1 authority, cleanup and FPS regression."""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
if not shutil.which('swiftc'):
    print('SKIP: swiftc unavailable')
    raise SystemExit(0)
with tempfile.TemporaryDirectory() as d:
    files = ['PairingSession.swift','ViewerPage.swift','EntryConfiguration.swift','InputController.swift','CaptureController.swift','AgentRequest.swift','CLI.swift']
    main = Path(d)/'main.swift'
    main.write_text((root/'Scripts/verify-v1-matrix.swift').read_text())
    subprocess.run(['swiftc', *[str(root/'host/Sources'/x) for x in files], str(main), '-o', str(Path(d)/'test')], check=True)
    for configured, expected in [(None, '24'), ('1', '24'), ('2', '2'), ('17', '17'), ('60', '60'), ('61', '24'), ('bad', '24'), ('', '24')]:
        env = dict(os.environ, EXPECTED_FPS=expected)
        env.pop('WINDOWSHARE_VIEW_FPS', None)
        if configured is not None: env['WINDOWSHARE_VIEW_FPS'] = configured
        subprocess.run([str(Path(d)/'test')], check=True, env=env)
    print('PASS view FPS default, 1, 2, 17, 60, 61, nonnumeric and empty')
