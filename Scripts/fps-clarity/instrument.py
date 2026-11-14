#!/usr/bin/env python3
"""Temporarily instrument a disposable checkout; restore with --restore."""
import argparse
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--restore',action='store_true');args=p.parse_args()
path=Path(__file__).resolve().parents[2]/'host/Sources/CaptureController.swift'
s=path.read_text()
needle='        succeeded = true\n        print("[capture] started")'
insertion='''        if let raw = ProcessInfo.processInfo.environment["WS_MEASURE_FPS"], let fps = Int(raw), (2...60).contains(fps) {
            let env = ProcessInfo.processInfo.environment
            let scale = CGFloat(Double(env["WS_MEASURE_SCALE"] ?? "2") ?? 2)
            let quality = Double(env["WS_MEASURE_QUALITY"] ?? "0.65") ?? 0.65
            self.maxEdge = Int(env["WS_MEASURE_CAP"] ?? "")
            setQuality(scale: scale, fps: fps, quality: quality)
        }
'''
if args.restore:
 if s.count(insertion)!=1: raise SystemExit('instrumentation missing or ambiguous')
 s=s.replace(insertion,'',1)
else:
 if s.count(needle)!=1 or insertion in s: raise SystemExit('source does not match expected baseline')
 s=s.replace(needle,insertion+needle,1)
path.write_text(s)
