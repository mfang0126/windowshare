#!/usr/bin/env python3
"""One-use links and inactivity leases using the production authority; no capture or native input."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ws-mobile-') as tmp:
 d=Path(tmp)
 (d/'stubs.swift').write_text('import Foundation\nfinal class InputController { static func screenLocked() -> Bool { false } }')
 (d/'main.swift').write_text(r'''import Foundation
var clock = 100.0
let s = PairingSession(now: { clock }, screenLocked: { false })
s.installCleanup { epoch in s.finishCleanup(epoch: epoch, success: true) }
let b = s.selectWindow(); precondition(s.activate(b))
func call(_ path: String, _ fields: [String: Any] = [:], _ cookies: [String: String] = [:]) -> PairingSession.Reply {
 var r: PairingSession.Reply!; s.respond(method: "POST", path: path, fields: fields, cookies: cookies) { r = $0 }; return r
}
func cookie(_ r: PairingSession.Reply) -> [String: String] {
 let p = r.cookies[0].components(separatedBy: ";")[0].components(separatedBy: "="); return [p[0]:p[1]]
}
func json(_ r: PairingSession.Reply) -> [String: Any] { try! JSONSerialization.jsonObject(with:r.body) as! [String: Any] }
let first = call("/session", ["window_id":b.windowID]);precondition(first.status == 200)
precondition(call("/session", ["window_id":b.windowID]).status == 410, "uncredentialed second redemption")
var cookies = cookie(first)
func connect() -> PairingSession.Context {
 let t=json(call("/w/\(b.windowID)/connect", [:], cookies))
 return s.authenticate(ticket:t["ticket"] as! String,resource:t["resource"] as! String,cancel:{})!
}
var context=connect();s.disconnect(context)
let resumed=call("/session", ["window_id":b.windowID], cookies);precondition(resumed.status == 200)
cookies=cookie(resumed);context=connect()
let g: [Double]=[0,0,800,600,2]
let epoch=s.observeGeometry(g,binding:b)!
let provenance=s.frameProvenance(geometry:g,size:[800,600],displayTime:mach_absolute_time(),binding:b)!
s.publish(Data([1]),size:[800,600],binding:b,provenance:provenance)
precondition(s.acquire(context,operation:UUID().uuidString,ttl:300)=="ok")
let lease=s.state(context)!, id=lease["lease_id"] as! String, le=lease["lease_epoch"] as! Int
func tick(_ n:Int) { for _ in 0..<n { clock += 1;if let nonce=s.heartbeat(context){precondition(s.pong(context,nonce:nonce))} } }
func submit(_ seq:Int,_ accepted:Bool) -> Bool {
 s.submit(context,id:id,epoch:le,sequence:seq,generation:b.generation,geometry:epoch,execution:UUID(),effect:{ accepted })
}
tick(299);precondition(submit(1,true));tick(299)
precondition(s.state(context)?["mode"] as? String == "Interact", "activity resets five-minute idle deadline")
precondition(!submit(2,false));tick(2)
precondition(s.state(context)?["mode"] as? String == "View", "rejected action does not prolong lease")
precondition(!submit(3,true), "expired lease cannot revive itself")
s.revokeWindow();let newer=s.selectWindow();precondition(s.activate(newer))
precondition(call("/session",["window_id":b.windowID],cookies).status == 410)
precondition(call("/session",["window_id":newer.windowID]).status == 200)
print("PASS one-use redemption, credentialed reconnect, activity resets idle lease, rejection/expiry cannot renew, old link cannot join next share")
''')
 files=[root/'host/Sources'/f for f in ['PairingSession.swift','EntryConfiguration.swift','AgentRequest.swift','ViewerPage.swift']]
 subprocess.run(['swiftc','-D','WINDOWSHARE_TEST',*map(str,files),str(d/'stubs.swift'),str(d/'main.swift'),'-o',str(d/'test')],check=True)
 subprocess.run([str(d/'test')],check=True,timeout=20)
