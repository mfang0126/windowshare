// Touch drag continuity, both modes. Arms first, then holds past the 350ms threshold.
const PORT = process.env.PAGE_PORT || "8779";
const list = await (await fetch("http://127.0.0.1:9334/json")).json();
const page = list.find(t => t.type === "page" && t.url.includes(PORT));
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); } };
await new Promise(r => ws.onopen = r);
await send("Runtime.enable");
const ev = async (e) => (await send("Runtime.evaluate", { expression: e, returnByValue: true }))?.result?.value;
const touch = (type, tx, ty) => send("Input.dispatchTouchEvent", { type, touchPoints: type === "touchEnd" ? [] : [{ x: tx, y: ty, id: 1 }] });

await ev("document.getElementById('arm').click()");
await new Promise(r => setTimeout(r, 600));
console.log("armed:", await ev("document.getElementById('state').textContent"));

for (const want of ["鼠标", "触控"]) {
  if ((await ev("document.getElementById('mode').textContent")) !== want) {
    await ev("document.getElementById('mode').click()");
    await new Promise(r => setTimeout(r, 300));
  }
  const rect = JSON.parse(await ev("JSON.stringify(document.getElementById('stage').getBoundingClientRect())"));
  let x = Math.round(rect.x + rect.width * 0.25), y = Math.round(rect.y + rect.height * 0.35);
  const pos = async () => await ev("document.getElementById('cursor').style.left + ',' + document.getElementById('cursor').style.top");
  await touch("touchStart", x, y);
  const samples = [];
  for (let i = 1; i <= 14; i++) {
    x += 12; y += 8;
    await touch("touchMove", x, y);
    await new Promise(r => setTimeout(r, 140));
    samples.push(`${(i * 0.14).toFixed(2)}s ${await pos()}`);
  }
  await touch("touchEnd", x, y);
  const uniq = new Set(samples.map(s => s.split(" ")[1])).size;
  console.log(`\n[${want}] distinct ${uniq}/${samples.length}`);
  console.log(samples.slice(0, 3).join("\n"));
  console.log("  ...");
  console.log(samples.slice(-3).join("\n"));
  console.log("state:", await ev("document.getElementById('state').textContent"));
  await new Promise(r => setTimeout(r, 400));
}
await ev("document.getElementById('arm').click()");
ws.close();
