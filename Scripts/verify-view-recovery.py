#!/usr/bin/env python3
"""Run shipped viewer recovery with deterministic timers; no GUI or input injection."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
js = (root / 'host/Sources/ViewerPage.swift').read_text().split('<script>')[1].split('</script>')[0]
js = js.replace('  openView().catch(e=>recover(e.message));', '''
  globalThis.test={recover,openView,clear,setup(){binding={window_id:'w',window_generation:'g'};wanted=true;lease={lease_id:'old'};pending=1;latest={t:'click'};},values(){return {wanted,lease,pending,latest,binding}}};
''')
harness = r'''
const vm=require('node:vm'),assert=require('node:assert/strict'),fs=require('node:fs');
const elements=new Map(), timers=new Map(),events={},sent=[];let next=0;
function el(id){if(!elements.has(id))elements.set(id,{value:'',style:{},classList:{toggle(){}},setAttribute(){},removeAttribute(){},addEventListener(){},hasPointerCapture(){return false}});return elements.get(id)}
const c={console,AbortSignal,TextEncoder,URL:{revokeObjectURL(){}},crypto:require('node:crypto').webcrypto,
 document:{hidden:false,getElementById:el,querySelectorAll:()=>[],addEventListener:(k,v)=>events[k]=v},
 window:{addEventListener:(k,v)=>events[k]=v},location:{pathname:'/w/w',protocol:'http:',hostname:'localhost',port:'18777'},history:{replaceState(){}},navigator:{},
 WebSocket:class{static OPEN=1;constructor(){this.readyState=1}send(x){sent.push(JSON.parse(x))}close(){}},
 setTimeout:(fn,ms)=>{timers.set(++next,{fn,ms});return next},clearTimeout:id=>timers.delete(id),setInterval:()=>0,clearInterval(){},performance:{now:()=>0}};
vm.createContext(c);vm.runInContext(fs.readFileSync(process.argv[2],'utf8'),c);const t=c.test;
(async()=>{
 t.setup();t.recover();assert.equal(t.values().wanted,false);assert.equal(t.values().lease,null);assert.equal(t.values().pending,null);assert.equal(t.values().latest,null);
 const retry=[...timers.values()].find(x=>x.ms===1500);assert(retry);
 const calls=[];c.fetch=async(path,opts)=>{calls.push([path,opts.body]);return {ok:true,json:async()=>path==='/session'?{window_id:'w',window_generation:'g'}:path.endsWith('/meta')?{window_generation:'g'}:{resource:'/w/w/events',ticket:'test'}}};
 retry.fn();for(let i=0;i<12;i++)await Promise.resolve();
 assert(calls.some(x=>x[0]==='/session'));assert.equal(t.values().wanted,false);assert.equal(t.values().lease,null);assert(!sent.some(x=>x.t==='lease.acquire'||x.t==='click'));
 timers.clear();c.document.hidden=true;events.visibilitychange();assert.equal(t.values().wanted,false);assert.equal(timers.size,0);
 c.document.hidden=false;events.visibilitychange();assert([...timers.values()].some(x=>x.ms===1500));
 await el('close').onclick();timers.clear();events.online();assert.equal(timers.size,0);
 // ADR 0003 rule 5: an ended share's link (410) and the bare entry (403) stop for good; no retry joins a later share.
 const seen=[];c.fetch=async(path,opts)=>{seen.push(JSON.parse(opts.body||'{}'));return {ok:false,status:path==='/session'?(seen.at(-1).window_id?410:403):401,json:async()=>({})}};
 timers.clear();await el('retry').onclick();assert.match(el('state').textContent,/共享链接已失效/);assert.equal(seen.at(-1).window_id,'w');
 assert.equal(timers.size,0);events.online();assert.equal(timers.size,0);
 c.location.pathname='/';await el('retry').onclick();assert.deepEqual(seen.at(-1),{});assert.match(el('state').textContent,/本次共享链接/);
 events.online();assert.equal(timers.size,0);
 console.log('PASS automatic View recovery, background return, no input/lease replay, explicit stop, ended/bare link stops');
})().catch(e=>{console.error(e);process.exitCode=1});
'''
with tempfile.TemporaryDirectory() as directory:
    p = Path(directory)
    (p / 'viewer.js').write_text(js)
    (p / 'test.cjs').write_text(harness)
    subprocess.run(['node', str(p / 'test.cjs'), str(p / 'viewer.js')], check=True)
