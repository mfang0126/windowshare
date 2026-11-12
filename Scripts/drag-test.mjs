// Mouse-mode drag continuity test: hold + drag past the 350ms long-press threshold
// and check the drawn cursor keeps moving.
const list = await (await fetch("http://127.0.0.1:9334/json")).json();
const page = list.find(t => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } };
await new Promise(r => ws.onopen = r);
await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
await send("Page.navigate", { url: process.env.PAGE_URL || "http://127.0.0.1:8777/" });
await new Promise(r => setTimeout(r, 2500));
const ev = async (e) => (await send("Runtime.evaluate", { expression: e, returnByValue: true }))?.result?.value;

await ev("document.getElementById('arm').click()");
await new Promise(r => setTimeout(r, 500));
await ev("document.getElementById('mode').click()");
await new Promise(r => setTimeout(r, 300));
console.log("mode:", await ev("document.getElementById('mode').textContent"));

const rect = JSON.parse(await ev("JSON.stringify(document.getElementById('stage').getBoundingClientRect())"));
let x = rect.x + rect.width * 0.25, y = rect.y + rect.height * 0.35;
const pos = async () => await ev("document.getElementById('cursor').style.left + ',' + document.getElementById('cursor').style.top");

await send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
const samples = [];
// 12 moves over ~1.8s: crosses the 350ms long-press mark around sample 3
for (let i = 1; i <= 12; i++) {
  x += 14; y += 9;
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y, button: "left", buttons: 1 });
  await new Promise(r => setTimeout(r, 150));
  samples.push(`${(i * 0.15).toFixed(2)}s ${await pos()}`);
}
await send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
console.log(samples.join("\n"));
const distinct = new Set(samples.map(s => s.split(" ")[1])).size;
console.log("distinct cursor positions:", distinct, "/", samples.length);
ws.close();
