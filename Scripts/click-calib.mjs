// Click calibration: drive WindowShare and read where the page saw the click.
const list = await (await fetch("http://127.0.0.1:9336/json")).json();
const page = list.find(t => t.type === "page" && t.title === "calib-grid");
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } };
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; setTimeout(() => rej(new Error("cdp timeout")), 5000); });
await send("Runtime.enable");
const ev = async (e) => (await send("Runtime.evaluate", { expression: e, returnByValue: true }))?.result?.value;
console.log("inner:", await ev("JSON.stringify({w:innerWidth,h:innerHeight})"));

const ctl = new WebSocket("ws://127.0.0.1:8778/");
await new Promise((res, rej) => { ctl.onopen = res; ctl.onerror = rej; setTimeout(() => rej(new Error("ctl timeout")), 5000); });
ctl.onmessage = (e) => { const m = JSON.parse(e.data); if (m.probe) console.log("  probe ->", m.probe, "rect", m.rect); };
ctl.send(JSON.stringify({ t: "arm", on: true }));
await new Promise(r => setTimeout(r, 400));

for (const [nx, ny] of [[0.5, 0.5], [0.25, 0.25], [0.75, 0.75]]) {
  await ev("window.__clicks = []; document.getElementById('out').textContent = 'no click yet'");
  ctl.send(JSON.stringify({ t: "probe", x: nx, y: ny }));
  ctl.send(JSON.stringify({ t: "click", x: nx, y: ny }));
  await new Promise(r => setTimeout(r, 800));
  console.log(`norm (${nx},${ny}) -> page saw ${await ev("JSON.stringify(window.__clicks)")}`);
}
ctl.send(JSON.stringify({ t: "arm", on: false }));
ws.close(); ctl.close();
