#!/bin/bash
# Viewport sync probe: can we drive a page to phone width and have it reflow?
# Usage: ./Scripts/viewport-probe.sh [url]
set -euo pipefail
URL="${1:-http://127.0.0.1:8777/}"
PORT=9335
PROFILE=/tmp/ws-vp-profile
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if ! curl -s -m 2 "http://127.0.0.1:$PORT/json/version" >/dev/null; then
  "$CHROME" --headless=new --remote-debugging-port=$PORT --user-data-dir=$PROFILE \
    --no-first-run --no-default-browser-check about:blank >/tmp/ws-vp-chrome.log 2>&1 &
  for _ in $(seq 1 30); do
    curl -s -m 1 "http://127.0.0.1:$PORT/json/version" >/dev/null && break
    sleep 0.3
  done
fi

URL="$URL" PORT="$PORT" node --input-type=module -e '
const port = process.env.PORT, url = process.env.URL;
const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const page = list.find(t => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } };
await new Promise(r => ws.onopen = r);
await send("Page.enable"); await send("Runtime.enable");
const read = async () => {
  const r = await send("Runtime.evaluate", { expression:
    "JSON.stringify({w:innerWidth,h:innerHeight,dpr:devicePixelRatio,phone:matchMedia(\"(max-width:480px)\").matches})",
    returnByValue: true });
  return JSON.parse(r.result.value);
};
await send("Page.navigate", { url });
await new Promise(r => setTimeout(r, 1500));
const desktop = await read();
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
await new Promise(r => setTimeout(r, 800));
const phone = await read();
const shot = await send("Page.captureScreenshot", { format: "jpeg", quality: 60 });
const fs = await import("node:fs");
fs.writeFileSync("/tmp/ws-vp-phone.jpg", Buffer.from(shot.data, "base64"));
await send("Emulation.clearDeviceMetricsOverride");
console.log(JSON.stringify({ desktop, phone, screenshot: "/tmp/ws-vp-phone.jpg" }, null, 2));
ws.close();
'
