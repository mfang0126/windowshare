#!/usr/bin/env python3
"""Host-side close 1001 on every immediate CLI end path, over a real loopback WebSocket.

terminate (SIGTERM / Quit / opener exit order), unavailable (sleep / lock), limit (12-hour share limit, injected
clock) and window_closed (CaptureController.invalidate) must each send WebSocket close 1001 before the transport
goes away, so the phone shows 「共享已结束」 instead of retrying a dead host. Frames must stop at the end, not after
the handshake (P2-2): the client never answers the close, a controlled frame is published 150 ms after the end, and
200 ms after the 1001 the old cookie asks the production HTTPServer for `/w/<id>/snapshot`; that frame must not come back. Compiles the production ControlServer,
PairingSession and CaptureController with the end-path methods copied verbatim from MenuBarController.swift
(`stopSharing()` up to `show(`, plus the body of `applicationWillTerminate` for terminate); UI, agent.json and
NSApp.terminate are stubs. No capture, input, GUI or agent.json.
Usage (repo root): python3 Scripts/verify-host-close.py [--source <repo root to test>]
"""
from pathlib import Path
import subprocess,socket,json,os,struct,base64,re,select,sys,tempfile,time,http.client,random
root=Path(sys.argv[sys.argv.index('--source')+1] if '--source' in sys.argv else Path(__file__).resolve().parent.parent)
ev=Path(tempfile.mkdtemp(prefix='verify-host-close-'))
menu=(root/'host/Sources/MenuBarController.swift').read_text()
a=re.search(r'^    (@objc )?private func stopSharing\(\)',menu,re.M).start()
region=menu[a:menu.index('    private func show(')].replace('@objc private func','func').replace('private func','func')
terminate=re.search(r'func applicationWillTerminate\(_ notification: Notification\) \{ AgentFile\.remove\(\); (.*) \}$',menu,re.M).group(1)
region+='    func terminatePath() { '+terminate+' }\n'
source='''import Foundation
import AppKit
final class StubApp {
    func terminate(_ sender: Any?) { print("TERMINATED"); fflush(stdout); exit(0) }
    func window(withWindowNumber: Int) -> NSWindow? { nil }
}
let NSApp = StubApp()
final class Clock {
    private let lock = NSLock()
    private var value = 1000.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Double) { lock.lock(); value = v; lock.unlock() }
}
final class Controller {
    let identity: PairingSession
    var capture: CaptureController?
    var selection: PairingSession.Binding?
    var targetLabel = ""
    var lastEnded: PairingSession.Binding?
    var autoShare: Int? = 1
    var control: ControlServer?
    func stopControl() { control?.setInput(nil) }
    func rebuildMenu() {}
    init(_ s: PairingSession, _ c: ControlServer) { identity=s; control=c; observeShare() }
''' + region + '''
}
@main struct Probe {
    static func main() throws {
        let port = UInt16(CommandLine.arguments[1])!, mode = CommandLine.arguments[2]
        let clock = Clock(), identity = PairingSession(now: { clock.read() })
        let config = try EntryConfiguration(port: port, externalOrigin: "https://localhost")
        let control = ControlServer(configuration: config, input: nil, identity: identity)
        try control.start()
        let http = HTTPServer(identity: identity); try http.start(configuration: config)
        let controller = Controller(identity, control)
        let binding = identity.selectWindow(startedAt: 1000); precondition(identity.activate(binding)); controller.selection=binding
        clock.set(1000 + PairingSession.shareLimit - 1)
        let capture = CaptureController(identity: identity, binding: binding); controller.capture=capture
        capture.onInvalidated = { DispatchQueue.main.async { controller.endShare(binding, reason: "window_closed") } }
        var response = PairingSession.Reply(status: 0, body: Data())
        identity.respond(method: "POST", path: "/session", fields: ["window_id": binding.windowID], cookies: [:]) { response=$0 }
        precondition(response.status == 200)
        let cookie = String(response.cookies.first!.split(separator: ";").first!.dropFirst("ws-session=".count))
        identity.respond(method: "POST", path: "/w/\\(binding.windowID)/connect", fields: [:], cookies: ["ws-session": cookie]) { response=$0 }
        precondition(response.status == 200)
        let geometry: [Double] = [0, 0, 800, 600, 2]
        _ = identity.observeGeometry(geometry, binding: binding)
        let proof = identity.frameProvenance(geometry: geometry, size: [1600, 1200], displayTime: mach_absolute_time(), binding: binding)!
        identity.publish(Data("CONTROLLED_FRAME".utf8), size: [1600, 1200], binding: binding, provenance: proof)
        var streamID: UUID?
        identity.openStream(path: "/w/\\(binding.windowID)/stream", cookies: ["ws-session": cookie], cancel: {}) { id, reply in
            precondition(reply.status == 200); streamID = id
        }
        let stream = streamID!
        var fixture = try! JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        fixture["fixture_cookie"] = cookie; fixture["fixture_window"] = binding.windowID
        print(String(decoding: try! JSONSerialization.data(withJSONObject: fixture), as: UTF8.self)); fflush(stdout)
        DispatchQueue.global().async {
            guard readLine() == "go" else { exit(3) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                let fresh = identity.frameProvenance(geometry: geometry, size: [1600, 1200], displayTime: mach_absolute_time(), binding: binding)
                identity.publish(Data("NEW_FRAME_DURING_END".utf8), size: [1600, 1200], binding: binding, provenance: fresh)
                var sent = false
                identity.sendFrame(stream, after: 1) { _, _ in sent = true }
                print("DURING_END mode=\\(mode) current=\\(identity.isCurrent(binding)) frame_sent=\\(sent)"); fflush(stdout)
            }
            DispatchQueue.main.async {
                switch mode {
                case "limit": clock.set(1000 + PairingSession.shareLimit + 1); _ = identity.isCurrent(binding)
                case "window_closed": capture.invalidate()
                case "unavailable": controller.endShare(binding, reason: "unavailable")
                case "terminate": controller.terminatePath(); NSApp.terminate(nil)
                default: exit(4)
                }
            }
        }
        dispatchMain()
    }
}
'''
(ev/'host-close.swift').write_text(source)
src=[str(root/'host/Sources'/f'{x}.swift') for x in ['CaptureController','InputController','PairingSession','ViewerPage','EntryConfiguration','AgentRequest','ControlServer','HTTPServer','WebAppAssets']]
cmd=['swiftc','-parse-as-library',*src,str(ev/'host-close.swift'),'-o',str(ev/'host-close')]
build=subprocess.run(cmd,capture_output=True,text=True,timeout=60);(ev/'host-close-build.log').write_text(build.stdout+build.stderr)
print('build_exit',build.returncode);assert build.returncode==0,build.stderr
results=[]
def readexact(s,n):
 data=b''
 while len(data)<n:
  part=s.recv(n-len(data))
  if not part:raise EOFError()
  data+=part
 return data
def recvframe(s):
 a,b=readexact(s,2);n=b&127
 if n==126:n=struct.unpack('!H',readexact(s,2))[0]
 if n==127:n=struct.unpack('!Q',readexact(s,8))[0]
 mask=readexact(s,4) if b&128 else None
 data=readexact(s,n)
 if mask:data=bytes(v^mask[i%4] for i,v in enumerate(data))
 return a&15,data
def sendtext(s,obj):
 data=json.dumps(obj).encode();mask=os.urandom(4)
 h=bytes([0x81,0x80|len(data)]) if len(data)<126 else bytes([0x81,0xfe])+struct.pack('!H',len(data))
 s.sendall(h+mask+bytes(v^mask[i%4] for i,v in enumerate(data)))
for mode in ['terminate','unavailable','limit','window_closed']:
 for attempt in range(5): # HTTP on control_port-1, as EntryConfiguration pairs them; retry if a port got taken
  with socket.socket() as pick, socket.socket() as http_pick:
   control_port=random.randrange(30001,40000) # below the ephemeral range, where port-1 is rarely in use
   try:pick.bind(('127.0.0.1',control_port));http_pick.bind(('127.0.0.1',control_port-1))
   except OSError:continue
  proc=subprocess.Popen([str(ev/'host-close'),str(control_port-1),mode],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  assert select.select([proc.stdout],[],[],10)[0], 'no ticket response'
  line=proc.stdout.readline()
  while line and not line.startswith('{'):line=proc.stdout.readline()
  if line:break
  print('fixture did not start, retrying:',proc.stderr.read().strip().splitlines()[-1:],flush=True);proc.wait()
 s=None
 try:
  assert line,'fixture never started'
  ticket=json.loads(line)
  s=socket.create_connection(('127.0.0.1',control_port),timeout=5)
  key=base64.b64encode(os.urandom(16)).decode()
  req=f'GET {ticket["resource"]} HTTP/1.1\r\nHost: localhost\r\nOrigin: https://localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n'
  s.sendall(req.encode());headers=b''
  while not headers.endswith(b'\r\n\r\n'):headers+=readexact(s,1)
  assert headers.startswith(b'HTTP/1.1 101'),headers.splitlines()[0]
  sendtext(s,{'t':'auth','ticket':ticket['ticket'],'resource':ticket['resource']})
  op,data=recvframe(s);state=json.loads(data);assert op==1 and state['t']=='state'
  proc.stdin.write('go\n');proc.stdin.flush();close=None;ending='unknown'
  try:
   while True:
    op,data=recvframe(s)
    if op==8:close=struct.unpack('!H',data[:2])[0] if len(data)>=2 else 1005;ending='close_frame';break
  except EOFError:ending='tcp_eof_without_close'
  except ConnectionResetError:ending='tcp_reset_without_close'
  except TimeoutError:ending='read_timeout'
  time.sleep(.2);http_status=None;late_frame=False;network_error=None
  try:
   h=http.client.HTTPConnection('127.0.0.1',control_port-1,timeout=2)
   h.request('GET',f'/w/{ticket["fixture_window"]}/snapshot',headers={'Host':'localhost','Cookie':'ws-session='+ticket['fixture_cookie']})
   r=h.getresponse();http_status=r.status;late_frame=b'NEW_FRAME_DURING_END' in r.read();h.close()
  except (OSError,http.client.HTTPException) as e:network_error=type(e).__name__
  out,err=proc.communicate(timeout=8)
  (ev/f'host-{mode}.log').write_text(out+err)
  result={'case':mode,'process_exit':proc.returncode,'close_code':close,'transport_end':ending,'expected_close':1001,
          'snapshot_status_200ms':http_status,'snapshot_error':network_error,'late_frame':late_frame,
          'assertion_exit':0 if close==1001 and not late_frame else 1}
  print(json.dumps(result),flush=True);results.append(result)
 finally:
  if s:s.close()
  if proc.poll() is None:proc.kill();proc.wait()
ok=all(x['assertion_exit']==0 for x in results)
print('PASS' if ok else 'FAIL', 'host close 1001 and frames stopped at the end on terminate/unavailable/limit/window_closed', 'logs:', ev)
sys.exit(0 if ok else 1)
