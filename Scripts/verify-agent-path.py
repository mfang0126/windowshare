#!/usr/bin/env python3
"""Run the shipped Agent CLI against real loopback HTTP/WebSocket with an inert input substitute."""
from pathlib import Path
import subprocess, tempfile, socket, json, os, time, http.client, urllib.parse
root=Path(__file__).resolve().parents[1]
ns={'__name__':'fixture','__file__':str(root/'Scripts/verify-cleanup-lifetime.py')}
exec((root/'Scripts/verify-cleanup-lifetime.py').read_text(),ns)
with tempfile.TemporaryDirectory(prefix='ws-agent-') as tmp:
 d=Path(tmp)
 stub=ns['STUB'].replace('func sensitiveFocus() -> Bool { true }','func sensitiveFocus() -> Bool { precondition(Thread.isMainThread); fputs("AX_MAIN\\n", stderr); return FileManager.default.fileExists(atPath: CommandLine.arguments[2]) }')
 (d/'Input.swift').write_text(stub)
 (d/'main.swift').write_text(r'''import Foundation
let port=UInt16(CommandLine.arguments[1])!
let s=PairingSession(screenLocked:{false},screenNotifications:NotificationCenter())
let b=s.selectWindow();precondition(s.activate(b))
let config=try! EntryConfiguration(port:port)
let control=ControlServer(configuration:config,input:InputController(),identity:s);try! control.start()
let http=HTTPServer(identity:s);try! http.start(configuration:config)
s.configureAgent(token:String(repeating:"ab",count:32),entry:"http://127.0.0.1:\(port)/")
let timer=DispatchSource.makeTimerSource(queue:.main)
timer.schedule(deadline:.now(),repeating:.milliseconds(50))
timer.setEventHandler {
 let g:[Double]=[0,0,800,600,2]
 _ = s.observeGeometry(g,binding:b)
 s.observeSensitiveFocus(FileManager.default.fileExists(atPath:CommandLine.arguments[2]),binding:b)
 if let proof=s.frameProvenance(geometry:g,size:[800,600],displayTime:mach_absolute_time(),binding:b) {
  s.publish(Data([0xff,0xd8,0xff,0xd9]),size:[800,600],binding:b,provenance:proof)
 }
}
timer.resume();RunLoop.main.run()
''')
 files=['PairingSession','ControlServer','HTTPServer','EntryConfiguration','AgentRequest','ViewerPage','WebAppAssets']
 subprocess.run(['swiftc','-D','WINDOWSHARE_TEST',*[str(root/f'host/Sources/{f}.swift') for f in files],str(d/'Input.swift'),str(d/'main.swift'),'-o',str(d/'server')],check=True)
 for attempt in range(100):
  port=31000+int.from_bytes(os.urandom(2),'big')%10000
  try:
   with socket.socket() as x,socket.socket() as y:x.bind(('127.0.0.1',port));y.bind(('127.0.0.1',port+1))
   break
  except OSError:continue
 marker=d/'sensitive'
 proc=subprocess.Popen([str(d/'server'),str(port),str(marker)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 try:
  (d/'agent.json').write_text(json.dumps({'port':port,'token':'ab'*32,'pid':proc.pid}))
  env={**os.environ,'WINDOWSHARE_AGENT_JSON':str(d/'agent.json')}
  for _ in range(100):
   try:
    with socket.create_connection(('127.0.0.1',port),timeout=.1):break
   except OSError:time.sleep(.02)
  def run(*args,data=None):return subprocess.run([str(root/'Scripts/windowshare-agent'),*args],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=15)
  frame=run('frame');assert frame.returncode==0 and frame.stdout==bytes([255,216,255,217]),(frame.returncode,frame.stderr)
  click=run('click','.5','.5');assert click.returncode==0,(click.returncode,click.stderr)
  # Each CLI operation has a 15 s timeout: acquire and synchronous input gate must return, not deadlock.
  secret='NEVER_LOG_中文🙂'*40
  text=run('text',data=secret.encode());assert text.returncode==0,(text.returncode,text.stderr)
  marker.touch();time.sleep(.1)
  blocked=run('frame');assert blocked.returncode==3 and b'handoff_required' in blocked.stdout
  denied=run('text',data=b'never-type-password');assert denied.returncode==3 and b'handoff_required' in denied.stdout
  assert secret.encode() not in text.stdout+text.stderr
  conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
  conn.request('GET','/agent/snapshot',headers={'Authorization':'Bearer '+'ab'*32})
  response=conn.getresponse();assert response.status==423 and b'password_focused' in response.read();conn.close()
  waiter=subprocess.Popen([str(root/'Scripts/windowshare-agent'),'handoff','--reason','fixture login','--timeout','30'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,text=True)
  try:
   waiting=json.loads(waiter.stdout.readline());assert waiting['status']=='waiting_for_page_close'
   link=urllib.parse.urlparse(waiting['entry']);window_id=link.path.split('/')[-1]
   headers={'Origin':f'http://127.0.0.1:{port}','Content-Type':'application/json'}
   conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5);conn.request('POST','/session',json.dumps({'window_id':window_id}),headers)
   response=conn.getresponse();assert response.status==200;cookie=response.getheader('Set-Cookie').split(';')[0];response.read();conn.close()
   conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5);conn.request('POST','/session/end','{}',{**headers,'Cookie':cookie})
   response=conn.getresponse();assert response.status==200;response.read();conn.close()
   out,err=waiter.communicate(timeout=10);assert waiter.returncode==0 and json.loads(out)['status']=='page_closed',(out,err)
  finally:
   if waiter.poll() is None:waiter.terminate();waiter.wait(timeout=5)
  print('PASS shipped Agent CLI: single frame, click, chunked Chinese text via real restricted lease; sensitive/unknown state hands off without frame or input')
 finally:
  proc.terminate();_,logs=proc.communicate(timeout=5)
  assert logs.count(b'AX_MAIN') >= 5, 'acquire and input gates must observe AX on main'
  assert b'NEVER_LOG' not in logs and b'never-type-password' not in logs,'input leaked into host logs'
