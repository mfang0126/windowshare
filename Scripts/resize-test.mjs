// Resize → restore round-trip against a real Chrome window.
const CDP = "http://127.0.0.1:9336";
let list = await (await fetch(`${CDP}/json`)).json();
if (!list.find(t => t.type === "page" && t.title === "calib-grid")) {
  await fetch(`${CDP}/json/new?file:///tmp/calib.html`, { method: "PUT" });
  await new Promise(r => setTimeout(r, 1200));
  list = await (await fetch(`${CDP}/json`)).json();
}
const page = list.find(t => t.type === "page" && t.title === "calib-grid");
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } };
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; setTimeout(() => rej(new Error("cdp timeout")), 5000); });
const win = await send("Browser.getWindowForTarget", { targetId: page.id });
const before = (await send("Browser.getWindowBounds", { windowId: win.windowId })).bounds;
console.log("before:", JSON.stringify(before));

const ctl = new WebSocket("ws://127.0.0.1:8778/");
await new Promise((res, rej) => { ctl.onopen = res; ctl.onerror = rej; setTimeout(() => rej(new Error("ctl timeout")), 5000); });
const acks = [];
ctl.onmessage = (e) => { const m = JSON.parse(e.data); if (m.message) acks.push(m.message + (m.size ? " " + m.size.map(Math.round) : "")); };
ctl.send(JSON.stringify({ t: "arm", on: true }));
await new Promise(r => setTimeout(r, 300));

ctl.send(JSON.stringify({ t: "resize", w: 420, h: 720 }));
await new Promise(r => setTimeout(r, 1200));
const mid = (await send("Browser.getWindowBounds", { windowId: win.windowId })).bounds;
console.log("after resize:", JSON.stringify(mid), "acks:", acks.join(" | "));

ctl.send(JSON.stringify({ t: "restore" }));
await new Promise(r => setTimeout(r, 1200));
const after = (await send("Browser.getWindowBounds", { windowId: win.windowId })).bounds;
console.log("after restore:", JSON.stringify(after));
console.log("restored:", after.width === before.width && after.height === before.height ? "YES" : "NO");

ctl.send(JSON.stringify({ t: "arm", on: false }));
ws.close(); ctl.close();
