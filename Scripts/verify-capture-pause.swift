import Foundation
actor Recorder {
 var values: [Bool] = []
 func record(_ value: Bool) async { values.append(value); try? await Task.sleep(nanoseconds: 20_000_000) }
 func read() -> [Bool] { values }
}
@main struct CapturePauseTest {
 static func main() async throws {
  let r = Recorder(), driver = CapturePauseDriver { await r.record($0) }
  try await driver.setPaused(true); try await driver.setPaused(true)
  try await driver.setPaused(false)
  let pausing = Task { try await driver.setPaused(true) }
  try await Task.sleep(nanoseconds: 2_000_000)
  try await driver.setPaused(false)
  try await driver.finish(); try await pausing.value
  try await driver.setPaused(false)
  let values = await r.read()
  precondition(values == [true,false,true], "finish overrides a pending resume and prevents resurrection")
  var clock = 100.0, locked = false
  let s = PairingSession(now:{clock},screenLocked:{locked},screenNotifications:NotificationCenter())
  s.installCleanup { epoch in s.finishCleanup(epoch:epoch,success:true) }
  let binding = s.selectWindow(); precondition(s.activate(binding))
  var pauses: [Bool] = [];s.observeCaptureActivity { pauses.append($0) }
  var reply: PairingSession.Reply!
  s.respond(method:"POST",path:"/session",fields:["window_id":binding.windowID],cookies:[:]) { reply=$0 }
  let kv=reply.cookies[0].components(separatedBy:";")[0].components(separatedBy:"=")
  let cookies=[kv[0]:kv[1]]
  s.respond(method:"POST",path:"/w/\(binding.windowID)/connect",fields:[:],cookies:cookies) { reply=$0 }
  let ticket=try! JSONSerialization.jsonObject(with:reply.body) as! [String:Any]
  let context=s.authenticate(ticket:ticket["ticket"] as! String,resource:ticket["resource"] as! String,cancel:{})!
  precondition(!s.shouldPauseCapture(binding))
  locked=true;s.screenDidLock();precondition(s.shouldPauseCapture(binding))
  locked=false;_ = s.state(context);precondition(!s.shouldPauseCapture(binding))
  s.disconnect(context);precondition(s.shouldPauseCapture(binding))
  clock+=60;_ = s.state(context);precondition(s.shouldPauseCapture(binding),"loss event must not resume capture")
  precondition(pauses == [false,true,false,true])
  print("PASS capture pause/resume deduplication, teardown overrides resume, lock/unlock, background disconnect stays paused")
 }
}
