// Viewer recovery check: with Interact on in a CDP-reachable Chrome (e.g. headless --remote-debugging-port=9444),
// stall the long poll past its 5 s timeout, then drop the network for 2 s; prints state/detail/frame count.
// Usage: CDP=9444 TAB=127.0.0.1:8777 node Scripts/viewer-netdrop.mjs
const list = await (await fetch(`http://127.0.0.1:${process.env.CDP}/json`)).json();
const page = list.find(t => t.type === "page" && t.url.includes(process.env.TAB));
const ws = new WebSocket(page.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pending = new Map(); const paused = [];
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id) pending.get(m.id)?.(m.result); if (m.method === "Fetch.requestPaused") paused.push(m.params.requestId); };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await send("Runtime.evaluate", { expression: e, returnByValue: true })).result.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const look = () => ev("[document.getElementById('state').textContent, document.getElementById('detail').textContent, frameProbe()]");
await ev("window.__frames=0; window.frameProbe=()=>window.__frames; new MutationObserver(()=>window.__frames++).observe(document.getElementById('stream'),{attributes:true,attributeFilter:['src']}); 1");
await sleep(1500); console.log("before     ", JSON.stringify(await look()));
await send("Fetch.enable", { patterns: [{ urlPattern: "*/snapshot*" }] });
await sleep(6500); console.log("stalled 6.5s", JSON.stringify(await look()), "held", paused.length);
await send("Fetch.disable");
await sleep(3000); console.log("released +3s", JSON.stringify(await look()));
await send("Network.enable"); await send("Network.emulateNetworkConditions", { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
await sleep(2000); console.log("offline 2s ", JSON.stringify(await look()));
await send("Network.emulateNetworkConditions", { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
await sleep(3000); console.log("back +3s   ", JSON.stringify(await look()));
ws.close();
