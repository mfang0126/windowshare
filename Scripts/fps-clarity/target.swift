import AppKit
class V:NSView {
 var n=0
 override func draw(_ dirtyRect:NSRect) {
  NSColor.white.setFill(); bounds.fill()
  let texts=["12px Sign in with your account ID 4815162342", "12px 请输入手机收到的六位验证码", "13px Forgot password? Reset it here 2718281828", "13px 登录即表示同意服务条款和隐私政策", "14px Remember this device for 30 days 1414213562", "14px 两步验证已开启，请在新设备上确认", "16px Create a new account 3141592653", "16px 欢迎回来，请选择登录方式"]
  for (i,t) in texts.enumerated() { let size:CGFloat = i < 2 ? 12 : i < 4 ? 13 : i < 6 ? 14 : 16; (t as NSString).draw(at:NSPoint(x:24,y:bounds.height-45-CGFloat(i)*26),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:NSColor.black]) }
  ("Frame \(n)" as NSString).draw(at:NSPoint(x:24,y:80),withAttributes:[.font:NSFont.systemFont(ofSize:24),.foregroundColor:NSColor.black])
 }
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let width = Double(ProcessInfo.processInfo.environment["WS_TARGET_WIDTH"] ?? "1000") ?? 1000
let w=NSWindow(contentRect:NSRect(x:100,y:100,width:width,height:800),styleMask:[.titled,.closable],backing:.buffered,defer:false)
w.title="ws-fps-clarity-controlled"; w.isReleasedWhenClosed=false
let v=V(frame:w.contentView!.bounds); v.autoresizingMask=[.width,.height]; w.contentView=v
w.orderFrontRegardless()
Timer.scheduledTimer(withTimeInterval:1.0/30.0,repeats:true){_ in v.n += 1; v.needsDisplay=true}
print("target_pid=\(getpid()) window_id=\(w.windowNumber)"); fflush(stdout)
app.run()
