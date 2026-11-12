// Latency baseline: tap the phone viewer N times over CDP, print click → displayed-frame-flip stats.
// Needs: phone Chrome open at <entry>#latency with Interact on, sharing Scripts/latency-target.html;
// `adb forward tcp:9222 localabstract:chrome_devtools_remote`. Usage: node Scripts/latency-run.mjs [taps=30] [label]
const taps = Number(process.argv[2] ?? 30), label = process.argv[3] ?? "run";
const list = await (await fetch(`http://127.0.0.1:${process.env.CDP ?? 9222}/json`)).json(); // CDP: adb-forwarded port
// TAB picks the viewer tab by URL fragment (several viewer tabs may be open); default any :8777 tab.
const tab = process.env.TAB ?? ":8777/";
const page = list.find(t => t.type === "page" && t.url.includes(tab));
if (!page) throw new Error(`no viewer tab matching ${tab}`);
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } };
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; setTimeout(() => rej(new Error("cdp timeout")), 5000); });
await send("Emulation.setTouchEmulationEnabled", { enabled: true }); // desktop/headless Chrome; no-op on a phone
const ev = async e => (await send("Runtime.evaluate", { expression: e, returnByValue: true }))?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));

if (!(await ev("!!window.__latency"))) throw new Error("open the viewer with #latency");
const c = await ev("(r=>({x:r.left+r.width/2,y:r.top+r.height/2}))(document.getElementById('stream').getBoundingClientRect())");
await ev("window.__latency.ms=[]");
for (let i = 0; i < taps; i++) {
  const tp = [{ x: c.x, y: c.y }];
  await send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: tp });
  await send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  await sleep(1500);
}
const ms = await ev("window.__latency.ms"); ws.close();
const s = [...ms].sort((a, b) => a - b), q = p => s.length ? s[Math.ceil(p * s.length) - 1] : null;
const out = { ts: new Date().toISOString(), label, taps, matched: s.length, p50: q(0.5), p95: q(0.95), max: s.at(-1) ?? null, ms };
console.log(JSON.stringify(out));
