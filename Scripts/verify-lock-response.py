#!/usr/bin/env python3
"""Exercise real control WebSocket with inert input, no native events or lock changes."""

from pathlib import Path
import json, os, socket, subprocess, tempfile, time, uuid
root = Path(__file__).resolve().parents[1]
source = root / 'host/Sources'
with tempfile.TemporaryDirectory(prefix='windowshare-lock-') as d:
    d = Path(d)
    # Reuse the existing no-injection input double, changing only its lock probe.
    ns = {'__name__': 'fixture', '__file__': str(root / 'Scripts/verify-cleanup-lifetime.py')}
    exec((root / 'Scripts/verify-cleanup-lifetime.py').read_text(), ns)
    stub = ns['STUB'].replace('static func screenLocked() -> Bool { false }', 'static func screenLocked() -> Bool { FileManager.default.fileExists(atPath: CommandLine.arguments[2]) }')
    if 'final class Diagnostic' not in stub:
        stub = stub.replace('    static let keys', """    final class Diagnostic {
        enum Stage: String { case preTarget = "pre_target", preGeometry = "pre_geometry", liveTarget = "perform_live_target", eventCreate = "event_create", gateDemo = "gate_demo", gateGeometry = "gate_geometry", submitAuthority = "submit_authority", hit, heldButton = "held_button", effectPosted = "effect_posted" }
        var stage: Stage = .preTarget
        var postedDown = 0
        var postedUp = 0
    }
    static let keys""")
    (d/'Input.swift').write_text(stub)
    (d/'main.swift').write_text(r'''import Foundation
let port = UInt16(CommandLine.arguments[1])!
let identity = PairingSession(screenLocked: { false })
let binding = identity.selectWindow(); precondition(identity.activate(binding))
let geom: [Double] = [0, 0, 800, 600, 2]
_ = identity.observeGeometry(geom, binding: binding)
let provenance = identity.frameProvenance(geometry: geom, size: [800,600], displayTime: mach_absolute_time(), binding: binding)!
identity.publish(Data([1]), size: [800,600], binding: binding, provenance: provenance)
let control = ControlServer(port: port, input: InputController(), identity: identity, origin: "http://localhost:\(port-1)")
try! control.start()
var r: PairingSession.Reply!
identity.respond(method: "POST", path: "/session", fields: ["window_id": binding.windowID], cookies: [:], authorization: nil, loopback: false) { r = $0 }
let cookie = r.cookies[0].components(separatedBy: ";")[0].components(separatedBy: "=")
identity.respond(method: "POST", path: "/w/\(binding.windowID)/connect", fields: [:], cookies: [cookie[0]:cookie[1]], authorization: nil, loopback: false) { r = $0 }
var ticket = try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]
ticket["generation"] = binding.generation
print(String(data: try! JSONSerialization.data(withJSONObject: ticket), encoding: .utf8)!); fflush(stdout)
withExtendedLifetime(control) { dispatchMain() }
''')
    subprocess.run(['swiftc', '-D', 'WINDOWSHARE_TEST', *[str(source/x) for x in ['PairingSession.swift','ControlServer.swift','EntryConfiguration.swift','AgentRequest.swift','ViewerPage.swift']], str(d/'Input.swift'), str(d/'main.swift'), '-o', str(d/'server')], check=True)
    with socket.socket() as p:
        p.bind(('127.0.0.1', 0)); port=p.getsockname()[1]
    marker=d/'locked'
    proc=subprocess.Popen([str(d/'server'),str(port),str(marker)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        info=json.loads(proc.stdout.readline())
        # websocket-client does not inject input; loopback only.
        import websocket
        ws=websocket.create_connection(f'ws://localhost:{port}/', origin=f'http://localhost:{port-1}', timeout=3)
        def send(obj): ws.send(json.dumps(obj))
        def receive(kind):
            for _ in range(20):
                obj=json.loads(ws.recv())
                if obj.get('t') == kind: return obj
            raise AssertionError(f'missing {kind}')
        send({'t':'auth','ticket':info['ticket'],'resource':info['resource']})
        state=receive('state')
        def acquire():
            send({'t':'lease.acquire','operation_id':str(uuid.uuid4()),'lease_ttl_sec':300})
            assert receive('ack')['status']=='ok'
            return receive('state')
        lease=acquire()
        payload={'t':'key','key':'enter','mods':['cmd'],'lease_id':lease['lease_id'],'lease_epoch':lease['lease_epoch'],'input_seq':1,'window_generation':info['generation'],'geometry_epoch':lease['geometry_epoch']}
        marker.touch(); send(payload)
        error=receive('error')
        case = os.environ.get('WINDOWSHARE_RESPONSE_CASE', 'all')
        assert error['status']=='screenLocked' and error['input_seq']==1, error
        if case in ('all', 'message'): assert error.get('message')=='Mac 已锁屏，请先解锁', error
        marker.unlink()
        time.sleep(.1)
        send(payload)
        revoked = receive('error')
        if case in ('all', 'lease'): assert revoked['status'] == 'leaseRevoked' and revoked.get('message') == '租约已撤销', revoked
        lease=acquire()
        payload.update(lease_id=lease['lease_id'], lease_epoch=lease['lease_epoch'], geometry_epoch=lease['geometry_epoch'])
        send(payload)
        assert receive('ack')['status']=='ok'
        print('PASS real WebSocket: locked input rejected with exact message; same key payload succeeds after unlock and new lease; inert input')
        ws.close()
    finally:
        proc.terminate(); proc.wait(timeout=5)
