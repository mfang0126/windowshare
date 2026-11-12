#!/bin/bash
# Resize → restore round-trip via the control WS, verified through /status.json rect.
set -uo pipefail
BASE=http://127.0.0.1:8777
rect() { curl -s -m 3 "$BASE/status.json" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('rect'))"; }

echo "before:  $(rect)"
node --input-type=module -e '
const ws = new WebSocket("ws://127.0.0.1:8778/");
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; setTimeout(() => rej(new Error("ws timeout")), 5000); });
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.message) console.log("  ack:", m.message, m.size ? m.size.map(Math.round) : ""); };
ws.send(JSON.stringify({ t: "arm", on: true }));
await new Promise(r => setTimeout(r, 300));
ws.send(JSON.stringify({ t: "resize", w: 420, h: 720 }));
await new Promise(r => setTimeout(r, 1200));
ws.send(JSON.stringify({ t: "restore" }));
await new Promise(r => setTimeout(r, 1200));
ws.send(JSON.stringify({ t: "arm", on: false }));
ws.close();
' 2>&1
echo "after:   $(rect)"
