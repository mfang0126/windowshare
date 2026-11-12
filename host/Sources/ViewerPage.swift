import Foundation

/// Embedded local authenticated human viewer; the server owns every grant.
enum ViewerPage {
    static let html = #"""
<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>WindowShare</title>
<meta name="windowshare-binding" content="">
<link rel="manifest" href="/manifest.webmanifest">
<style>
:root{color-scheme:dark}*{box-sizing:border-box}
body{margin:0;background:#0e1218;color:#e9eef5;font:15px/1.5 -apple-system,"PingFang SC",sans-serif;display:flex;flex-direction:column;min-height:100dvh}
header,section{padding:12px 16px;border-bottom:1px solid #2a3542}header,.actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}h1{font-size:17px;margin:0}p{margin:8px 0;color:#aebccd}
button,input,textarea,select{font:inherit;border:1px solid #526278;border-radius:8px;padding:9px;background:#161d27;color:inherit}button{cursor:pointer}button:disabled{opacity:.5;cursor:default}button[aria-pressed=true]{background:#254b72}
.actions{margin-top:8px}label{display:block}input,textarea{max-width:100%;width:360px}textarea{min-height:80px}
main{flex:1;display:flex;align-items:center;justify-content:center;padding:8px}#stage{position:relative;max-width:100%;line-height:0}img{display:block;max-width:100%;max-height:65dvh;object-fit:contain}#stage.active{touch-action:none}#cursor{position:absolute;pointer-events:none;line-height:1;color:white;text-shadow:0 1px 3px black}[hidden]{display:none!important}
</style></head><body>
<header><h1>WindowShare</h1><span id="state" role="status" aria-live="polite">连接中</span></header>
<section><div class="actions"><button id="retry">刷新观看</button><button id="close" disabled>关闭会话</button><button id="interact" disabled>开启 Interact</button><button id="view" disabled>返回 View</button></div>
<p id="detail" role="status" aria-live="polite">默认只读；需要操作时显式开启 Interact。</p>
<div class="actions"><label for="mode">指针模式</label><select id="mode"><option value="touch">触控</option><option value="mouse">鼠标触控板</option><option value="scroll">滚动</option></select><button id="keyboard" disabled aria-expanded="false">键盘 / 中文输入</button></div>
<div id="keys" hidden><label for="text">文本（中文输入完成后点发送）</label><textarea id="text" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false"></textarea><button id="send" disabled>发送文本</button>
<div class="actions"><button data-mod="cmd" aria-pressed="false">⌘</button><button data-mod="alt" aria-pressed="false">Option</button><button data-mod="shift" aria-pressed="false">Shift</button></div>
<div class="actions"><button data-key="enter">Enter</button><button data-key="tab">Tab</button><button data-key="escape">Esc</button><button data-key="backspace">⌫</button><button data-key="left">←</button><button data-key="right">→</button><button data-key="up">↑</button><button data-key="down">↓</button><button data-key="a">A</button><button data-key="c">C</button><button data-key="v">V</button></div></div></section>
<section id="reqcard" hidden><strong id="reqreason"></strong><p id="reqleft"></p><div class="actions"><button id="reqdone">完成</button><button id="reqcancel">取消</button></div><p id="reqerr" role="alert"></p></section>
<p id="nowin" hidden role="status">无共享窗口：请在 Mac 菜单栏选择窗口</p>
<main><div id="stage"><img id="stream" alt="共享窗口画面" draggable="false" hidden><span id="cursor" hidden aria-hidden="true">↖</span></div></main>
<script>
(() => {
  let controlsEnabled=false;
  const el=id=>document.getElementById(id), image=el('stream'), stage=el('stage');
  // Latency probe (#latency): click → first displayed frame whose brightness flips. Target window: Scripts/latency-target.html.
  const lat=location.hash==='#latency'?(window.__latency={t0:0,from:0,lum:0,ms:[]}):null, lc=lat&&document.createElement('canvas').getContext('2d',{willReadFrequently:true});
  function lum(){lc.drawImage(image,0,0,4,4);const d=lc.getImageData(0,0,4,4).data;let s=0;for(let i=0;i<d.length;i+=4)s+=d[i]+d[i+1]+d[i+2];return s/(48*255);}
  function latFrame(){if(!lat)return;lat.lum=lum();if(lat.t0&&Math.abs(lat.lum-lat.from)>0.5){lat.ms.push(Math.round(performance.now()-lat.t0));lat.t0=0;}}
  let binding=null, timer=null, epoch=0, busy=false, socket=null, poll=null;
  let reconnectTimer=null, stopped=false;
  let authority=null, lease=null, wanted=false, seq=0, pending=null, latest=null, finalUp=null;
  let displayedGeometry=null, frameURL=null, snapshotTimer=null, snapshotBusy=false, frameVersion=0;
  let pointer=null, longTimer=null, dragging=false, cur={x:.5,y:.5}, composing=false;
  let authenticated=false, tuning={}, frameSeq=0;
  const RECONNECT='画面重连中…';
  const newID=()=>{const bytes=crypto.getRandomValues(new Uint8Array(16));bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;const h=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);};
  const mods=new Set(), base=()=>'/w/'+binding.window_id;
  function stopMedia(){frameVersion++;clearTimeout(snapshotTimer);snapshotBusy=false;displayedGeometry=null;image.onload=image.onerror=null;image.removeAttribute('src');image.hidden=true;if(frameURL)URL.revokeObjectURL(frameURL);frameURL=null;}
  const note=message=>{el('detail').textContent=message;};
  function raw(message){if(socket?.readyState!==WebSocket.OPEN)return false;socket.send(JSON.stringify(message));return true;}
  function resetGesture(){clearTimeout(longTimer);longTimer=null;const old=pointer;pointer=null;if(old&&stage.hasPointerCapture(old.id))stage.releasePointerCapture(old.id);dragging=false;latest=null;finalUp=null;}
  function resetInput(){resetGesture();pending=null;mods.clear();composing=false;document.querySelectorAll('[data-mod]').forEach(b=>b.setAttribute('aria-pressed','false'));}
  function ready(){return !!(controlsEnabled&&wanted&&lease&&displayedGeometry===authority?.geometry_epoch&&socket?.readyState===WebSocket.OPEN);}
  function render(){
    const active=ready();stage.classList.toggle('active',active);
    el('interact').disabled=!controlsEnabled||!authority||authority.busy||wanted;
    el('view').disabled=!wanted&&!lease;
    el('keyboard').disabled=el('send').disabled=!active;
    document.querySelectorAll('[data-key],[data-mod]').forEach(b=>b.disabled=!active);
    el('state').textContent=lease?(active?'Interact · 可操作':'Interact · 等待匹配画面'):(authority?'View · '+(authority.busy?'控制权占用或清理中':'只读'):'View · 控制未连接');
    el('cursor').hidden=!active||el('mode').value!=='mouse';drawCursor();
  }
  function clear(message){
    controlsEnabled=false;
    epoch++;frameVersion++;clearTimeout(timer);clearTimeout(snapshotTimer);clearInterval(poll);timer=poll=snapshotTimer=null;
    const old=socket;socket=null;old?.close();authority=lease=null;wanted=false;displayedGeometry=null;snapshotBusy=false;resetInput();
    image.onload=image.onerror=null;image.removeAttribute('src');image.hidden=true;if(frameURL)URL.revokeObjectURL(frameURL);frameURL=null;
    render();el('state').textContent=message;el('close').disabled=true;
  }
  function recover(message='连接暂时中断；正在自动恢复观看'){
    clear(message);clearTimeout(reconnectTimer);
    if(stopped||document.hidden)return;
    const version=epoch;
    reconnectTimer=setTimeout(()=>{if(version===epoch&&!stopped&&!document.hidden)openView().catch(e=>recover(e.message));},1500);
  }
  async function api(path,body,signal){
    const options={cache:'no-store',credentials:'same-origin',signal};
    if(body!==undefined)Object.assign(options,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    // Network errors and timeouts recover on their own (retry / recover()); say so instead of the browser's raw text.
    const r=await fetch(path,options).catch(()=>{throw Error('网络中断，重连中…');});
    if(path==='/session'){noWin=r.status===503;el('nowin').hidden=!noWin;}
    // Ended share (410) or the bare entry (403 share_link_required): this link never joins a share again; stop retrying.
    if(path==='/session'&&(r.status===410||(r.status===403&&!body.window_id))){stopped=true;binding=null;throw Error(r.status===410?'这个共享链接已失效：共享已结束，请向 Bot 要新的链接':'请用 Bot 发给你的本次共享链接打开');}
    if(!r.ok)throw Error(r.status===503?'Mac 当前没有共享窗口；等待共享恢复':r.status===401||r.status===403?'正在恢复窗口连接':'暂时无法连接 Mac；正在自动恢复');
    return r.json();
  }
  function stream(){
    if(noWin)return;
    frameVersion++;clearTimeout(snapshotTimer);snapshotBusy=false;displayedGeometry=null;
    if(frameURL)URL.revokeObjectURL(frameURL);frameURL=null;
    const version=epoch;image.onload=null;image.onerror=()=>{if(version===epoch){stopMedia();note('画面暂停或不可用。');}};
    image.src=base()+'/stream';image.hidden=false;
  }
  async function snapshot(){
    if(!lease||!wanted||snapshotBusy)return;
    snapshotBusy=true;const version=epoch, fv=frameVersion, expected=authority.geometry_epoch;let again=false;
    try{
      // Push (M2-a): /snapshot/<seq> answers when a newer frame exists (204 after 2 s without one).
      const r=await fetch(base()+'/snapshot'+(tuning.push?'/'+frameSeq:''),{cache:'no-store',credentials:'same-origin',signal:AbortSignal.timeout(5000)});
      if(r.status===204){again=true;return;}
      if(!r.ok)throw Error('等待匹配窗口画面');
      frameSeq=Number(r.headers.get('X-WindowShare-Frame-Seq'))||0;
      const header=r.headers.get('X-WindowShare-Geometry-Epoch'), geometry=Number(header);
      if(header===null||!Number.isSafeInteger(geometry)||geometry!==expected)throw Error('画面几何已改变，请重新开启 Interact');
      const blob=await r.blob();if(version!==epoch||fv!==frameVersion||!wanted)return;
      const url=URL.createObjectURL(blob), probe=new Image();probe.src=url;
      try{await probe.decode();}catch(e){URL.revokeObjectURL(url);throw e;}
      if(version!==epoch||fv!==frameVersion||!wanted||authority.geometry_epoch!==geometry){URL.revokeObjectURL(url);return;}
      // Only the actual displayed image load establishes its geometry; MJPEG never does.
      // Same-epoch refresh preserves the displayed mapping while the replacement decodes.
      image.onload=()=>{if(version!==epoch||fv!==frameVersion||image.src!==url)return;displayedGeometry=geometry;if(el('detail').textContent===RECONNECT)note('画面已恢复。');render();latFrame();};
      image.onerror=()=>{if(version===epoch)leave('画面载入失败；已返回 View');};
      const old=frameURL;frameURL=url;image.src=url;image.hidden=false;if(old)URL.revokeObjectURL(old);again=true;
    }catch(e){if(version===epoch&&fv===frameVersion){displayedGeometry=null;note(['TypeError','TimeoutError','AbortError'].includes(e.name)?RECONNECT:e.message);render();}}
    finally{if(version===epoch&&fv===frameVersion){snapshotBusy=false;if(wanted&&lease)snapshotTimer=setTimeout(snapshot,tuning.push&&again?0:250);}}
  }
  function leave(message='已返回 View；再次操作需显式开启'){
    const old=lease;wanted=false;lease=null;resetInput();
    if(old)raw({t:'lease.release',lease_id:old.lease_id,lease_epoch:old.lease_epoch,decision_id:newID()});
    raw({t:'state'});if(binding)stream();render();note(message);
  }
  let noWin=false, req=null, reqEnd=0;
  function reqTick(){if(req)el('reqleft').textContent='剩余 '+Math.max(0,Math.ceil((reqEnd-Date.now())/1000))+' 秒';}
  setInterval(reqTick,250);
  function reqShow(r){
    const was=req&&req.id;req=r&&r.id?r:null;
    el('reqcard').hidden=!req;
    if(!req)return;
    el('reqreason').textContent='Agent 请求：'+r.reason;reqEnd=Date.now()+Math.max(0,Number(r.remaining_sec)||0)*1000;
    if(was!==req.id)el('reqerr').textContent='';
    reqTick();
  }
  async function reqDecide(decision){
    if(!req)return;const id=req.id;el('reqdone').disabled=el('reqcancel').disabled=true;
    try{await api('/request/decision',{id,decision});if(req&&req.id===id)reqShow(null);el('reqerr').textContent='';
      if(decision==='done'){stopped=true;clearTimeout(reconnectTimer);clear('已完成：本次共享已结束，链接已失效');}}
    catch(e){el('reqerr').textContent='提交失败：请求可能已结束或连接异常';}
    finally{el('reqdone').disabled=el('reqcancel').disabled=false;}
  }
  el('reqdone').onclick=()=>reqDecide('done');el('reqcancel').onclick=()=>reqDecide('cancel');
  function state(m){
    reqShow(m.request);
    const none=m.window==='none';
    if(none!==noWin){noWin=none;el('nowin').hidden=!none;if(none)stopMedia();else if(binding)stream();}
    if(none)return;
    if(m.window_id!==binding.window_id||m.window_generation!==binding.window_generation){clear('窗口已改变，请打开当前共享入口');return;}
    const old=lease;authority=m;controlsEnabled=m.controls_enabled===true&&m.role==='human';
    if(!controlsEnabled){wanted=false;resetInput();}
    if(m.mode==='Interact'&&!wanted){
      raw({t:'lease.release',lease_id:m.lease_id,lease_epoch:m.lease_epoch,decision_id:newID()});
      render();return;
    }
    if(m.mode==='Interact'&&wanted){
      if(old&&(old.lease_epoch!==m.lease_epoch||old.lease_id!==m.lease_id||old.geometry_epoch!==m.geometry_epoch)){leave('控制权或几何已改变，请重新开启');return;}
      lease=m;if(!old){seq=0;resetInput();frameVersion++;image.onload=image.onerror=null;image.removeAttribute('src');displayedGeometry=null;frameSeq=0;snapshot();}
    }else{
      lease=null;
      if(old){wanted=false;resetInput();stream();note('控制权已结束；不会自动恢复。');}
    }
    render();
  }
  async function connect(version){
    if(!controlsEnabled){note('正在连接控制通道；观看保持只读。');}
    if(!['http:','https:'].includes(location.protocol))return;
    try{
      const ticket=await api(base()+'/connect',{});if(version!==epoch)return;
      const port=Number(location.port||80)+1;if(location.protocol==='http:'&&port>65535)throw Error('本机控制端口不可用');
      const address=location.protocol==='https:'?'wss://'+location.host+ticket.resource:'ws://'+location.hostname+':'+port+ticket.resource;
      const ws=new WebSocket(address);socket=ws;
      ws.onopen=()=>{if(version===epoch&&socket===ws)raw({t:'auth',ticket:ticket.ticket,resource:ticket.resource});};
      ws.onclose=()=>{if(version===epoch&&socket===ws)recover();};
      ws.onerror=()=>{if(version===epoch&&socket===ws)recover();};
      ws.onmessage=event=>{
        if(version!==epoch||socket!==ws)return;
        let m;try{m=JSON.parse(event.data);}catch{clear('控制协议错误');return;}
        if(m.t==='heartbeat'){if(!document.hidden)raw({t:'pong',nonce:m.nonce});return;}
        if(m.t==='state'){state(m);if(!authenticated&&authority){authenticated=true;note('正在观看；需要操作时开启 Interact。');}return;}
        if(m.t==='ack'||m.t==='error'){
          if(m.t==='error'){leave('控制已停止；操作可能部分执行，请查看窗口结果，不要重复提交。');return;}
          if(m.input_seq!==undefined&&pending===m.input_seq){if(sentText!==null&&el('text').value===sentText)el('text').value='';sentText=null;pending=null;const next=finalUp||latest;finalUp=latest=null;if(next)input(next);render();if(tuning.input&&!snapshotBusy&&wanted&&lease){clearTimeout(snapshotTimer);snapshot();}}
          raw({t:'state'});
        }
      };
      poll=setInterval(()=>raw({t:'state'}),1000);
    }catch(e){if(version===epoch)recover('控制连接暂不可用；正在自动恢复 View');}
  }
  async function monitor(version){
    try{
      const m=await api(base()+'/meta',undefined,AbortSignal.timeout(5000));if(version!==epoch)return;
      if(m.window_generation!==binding.window_generation)throw Error('窗口已改变，请打开当前共享入口');
      timer=setTimeout(()=>monitor(version),1500);
    }catch(e){if(version===epoch)recover(e.message);}
  }
  function watch(){clear('View · 连接中');const version=epoch;el('close').disabled=false;el('retry').disabled=false;stream();monitor(version);connect(version);}
  let sentText=null;
  function input(payload){
    if(!ready()||!['click','move','down','drag','up','scroll','text','key'].includes(payload.t))return false;
    if(pending){
      if(payload.t==='move'||payload.t==='drag')latest=payload;
      else if(payload.t==='up'){finalUp=payload;latest=null;}
      else note('等待上一操作完成；此操作未发送。');
      return false;
    }
    pending=++seq;sentText=payload.t==='text'?payload.text:null;
    const sent=raw({...payload,lease_id:lease.lease_id,lease_epoch:lease.lease_epoch,input_seq:seq,window_generation:binding.window_generation,geometry_epoch:displayedGeometry});
    if(!sent){recover();return false;}
    const version=epoch, sentSeq=seq, sentLease=lease.lease_id;
    setTimeout(()=>{if(version===epoch&&lease?.lease_id===sentLease&&pending===sentSeq)recover('操作结果未确认；自动恢复观看，不重发操作');},5000+(payload.t==='text'?40*[...payload.text].length:0));
    render();return true;
  }
  function point(e){const r=image.getBoundingClientRect();if(!r.width||!r.height||!image.naturalWidth)return null;const scale=Math.min(r.width/image.naturalWidth,r.height/image.naturalHeight),w=image.naturalWidth*scale,h=image.naturalHeight*scale;const x=(e.clientX-r.left-(r.width-w)/2)/w,y=(e.clientY-r.top-(r.height-h)/2)/h;return Number.isFinite(x)&&Number.isFinite(y)&&x>=0&&x<=1&&y>=0&&y<=1?{x,y}:null;}
  function drawCursor(){el('cursor').style.left=(cur.x*100)+'%';el('cursor').style.top=(cur.y*100)+'%';}
  stage.addEventListener('pointerdown',e=>{
    if(!ready()||pending||e.button!==0)return;
    if(pointer){leave('多指手势已取消；请重新开启 Interact');return;}
    const p=point(e);if(!p)return;e.preventDefault();
    pointer={id:e.pointerId,x:e.clientX,y:e.clientY,startX:e.clientX,startY:e.clientY,time:Date.now(),moved:0};stage.setPointerCapture(e.pointerId);
    if(el('mode').value==='touch')cur=p;
    if(el('mode').value!=='scroll')longTimer=setTimeout(()=>{if(pointer&&ready()&&!pending){dragging=input({t:'down',...cur});}},350);drawCursor();
  });
  stage.addEventListener('pointermove',e=>{
    if(!pointer||pointer.id!==e.pointerId||!ready())return;
    const p=point(e);if(!p){leave('指针离开窗口，手势已取消');return;}
    pointer.moved=Math.max(pointer.moved,Math.hypot(e.clientX-pointer.startX,e.clientY-pointer.startY));
    if(el('mode').value==='scroll'){
      const dx=e.clientX-pointer.x,dy=e.clientY-pointer.y;pointer.x=e.clientX;pointer.y=e.clientY;
      if(!pending)input({t:'scroll',dx:Math.max(-4096,Math.min(4096,dx)),dy:Math.max(-4096,Math.min(4096,dy))});return;
    }
    if(el('mode').value==='mouse'){
      const r=image.getBoundingClientRect();const next={x:cur.x+(e.clientX-pointer.x)/r.width,y:cur.y+(e.clientY-pointer.y)/r.height};
      if(next.x>=0&&next.x<=1&&next.y>=0&&next.y<=1)cur=next;
      if(!dragging&&pointer.moved>6)clearTimeout(longTimer);
    }else cur=p;
    pointer.x=e.clientX;pointer.y=e.clientY;drawCursor();
    if(dragging)input({t:'drag',...cur});else if(el('mode').value==='mouse')input({t:'move',...cur});
  });
  stage.addEventListener('pointerup',e=>{
    if(!pointer||pointer.id!==e.pointerId)return;
    const rec=pointer, wasDragging=dragging;clearTimeout(longTimer);pointer=null;dragging=false;
    if(stage.hasPointerCapture(e.pointerId))stage.releasePointerCapture(e.pointerId);
    if(!point(e)){leave('指针离开窗口，手势已取消');return;}
    if(el('mode').value==='scroll')return;
    if(wasDragging)input({t:'up',...cur});else if(rec.moved<10&&Date.now()-rec.time<350&&(!lat||(lat.t0=performance.now(),lat.from=lat.lum,1)))input({t:'click',...cur,button:'left',count:1});
  });
  stage.addEventListener('pointercancel',()=>{if(pointer)leave('手势已取消；请重新开启 Interact');});
  stage.addEventListener('lostpointercapture',()=>{if(pointer)leave('手势中断；请重新开启 Interact');});
  stage.addEventListener('contextmenu',e=>{if(!ready())return;e.preventDefault();const p=point(e);if(p)input({t:'click',...(el('mode').value==='mouse'?cur:p),button:'right',count:1});});
  stage.addEventListener('wheel',e=>{if(!ready()||!point(e))return;e.preventDefault();const scale=e.deltaMode===1?16:e.deltaMode===2?image.clientHeight:1;input({t:'scroll',dx:Math.max(-4096,Math.min(4096,-e.deltaX*scale)),dy:Math.max(-4096,Math.min(4096,-e.deltaY*scale))});},{passive:false});
  el('mode').onchange=()=>{if(wanted)leave('模式已切换，请重新开启 Interact');};
  el('interact').onclick=()=>{if(!controlsEnabled||!authority||authority.busy||wanted)return;wanted=true;resetInput();raw({t:'lease.acquire',operation_id:newID(),lease_ttl_sec:300});render();note('正在申请控制权；最多 5 分钟，不自动续期。');};
  el('view').onclick=()=>leave();
  el('keyboard').onclick=()=>{el('keys').hidden=!el('keys').hidden;el('keyboard').setAttribute('aria-expanded',String(!el('keys').hidden));if(!el('keys').hidden)el('text').focus();};
  el('text').addEventListener('compositionstart',()=>composing=true);el('text').addEventListener('compositionend',()=>composing=false);
  el('send').onclick=()=>{const text=el('text').value;if(composing||!text)return;if([...text].length>256){note('文本过长，请分段发送（每段最多 256 字）。');return;}input({t:'text',text});};
  el('text').addEventListener('keydown',e=>{if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)&&!e.isComposing){e.preventDefault();el('send').click();}});
  document.querySelectorAll('[data-key]').forEach(b=>b.onclick=()=>input({t:'key',key:b.dataset.key,mods:[...mods]}));
  document.querySelectorAll('[data-mod]').forEach(b=>b.onclick=()=>{if(!ready())return;const m=b.dataset.mod;if(mods.has(m))mods.delete(m);else mods.add(m);b.setAttribute('aria-pressed',String(mods.has(m)));});
  window.addEventListener('blur',()=>{if(wanted)leave('页面失去焦点，已返回 View');});
  document.addEventListener('visibilitychange',()=>{if(document.hidden)clear('后台已暂停控制');else if(!stopped)recover();});
  window.addEventListener('online',()=>{if(!stopped)recover();});
  window.addEventListener('pagehide',()=>clear('会话已离开'));
  window.addEventListener('resize',()=>{if(pointer)leave('视口改变，手势已取消');drawCursor();});
  window.visualViewport?.addEventListener('resize',()=>{if(pointer)leave('视口改变，手势已取消');});
  function action(id,fn){el(id).onclick=async()=>{if(busy)return;busy=true;try{await fn();}catch(e){clear(e.message);}finally{busy=false;}};}
  async function openView(){
    clearTimeout(reconnectTimer);clear('连接 View');const version=epoch;
    const requested=location.pathname.match(/^\/w\/([A-Za-z0-9-]+)$/)?.[1];
    const r=await api('/session',binding||(requested?{window_id:requested}:{}),AbortSignal.timeout(5000));
    if(version!==epoch||stopped||document.hidden)return;
    binding={window_id:r.window_id,window_generation:r.window_generation};tuning=r.tuning||{};
    history.replaceState(null,'',base());watch();
  }
  action('retry',async()=>{stopped=false;await openView();});
  action('close',async()=>{stopped=true;el('text').value='';clearTimeout(reconnectTimer);clear('已停止观看');await api('/session/close',{});});
  render();
  openView().catch(e=>recover(e.message));
})();
</script></body></html>
"""#
}
