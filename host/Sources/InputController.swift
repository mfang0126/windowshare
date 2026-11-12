import Foundation
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// All calls are main-queue confined. No native mutation is allowed without a submission gate.
final class InputController {
    typealias Gate = (() -> Bool) -> Bool
    final class Diagnostic {
        enum Stage: String {
            case preTarget = "pre_target", preGeometry = "pre_geometry"
            case liveTarget = "perform_live_target", eventCreate = "event_create"
            case gateDemo = "gate_demo", gateGeometry = "gate_geometry"
            case submitAuthority = "submit_authority", hit, heldButton = "held_button"
            case effectPosted = "effect_posted"
        }
        var stage: Stage = .preTarget
        var postedDown = 0
        var postedUp = 0
    }
    private let window: WindowInfo
    private let launchDate: Date?
    private var heldButtons: [CGMouseButton: CGPoint] = [:]
    private var heldKeys: Set<CGKeyCode> = []
    private var lastPoint: CGPoint?
    private var savedFrame: CGRect?
    private var setFrame: CGRect?
    private var armed = false

    init(window: WindowInfo) {
        self.window = window
        launchDate = NSRunningApplication(processIdentifier: window.ownerPID)?.launchDate
    }
    func liveRect() -> CGRect? {
        guard let launchDate, NSRunningApplication(processIdentifier: window.ownerPID)?.launchDate == launchDate,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.id) as? [[String: Any]],
              list.count == 1, let item = list.first,
              (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.id,
              (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == window.ownerPID,
              let bounds = item[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
              w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
    func geometry() -> [Double]? {
        guard let rect = liveRect() else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 8, &displays, &count) == .success, count == 1,
              let mode = CGDisplayCopyDisplayMode(displays[0]), mode.width > 0 else { return nil }
        let scale = Double(mode.pixelWidth) / Double(mode.width)
        return [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height), scale]
    }
    private func hit(_ point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] else { return false }
        for item in list {
            guard (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let b = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  CGRect(x: x, y: y, width: w, height: h).contains(point) else { continue }
            let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard Self.occludes(owner: pid.flatMap(Self.executablePath), layer: (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                                bounds: CGRect(x: x, y: y, width: w, height: h), point: point, screens: Self.screenRects()) else { continue }
            return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.id && pid == window.ownerPID
        }
        return false
    }
    static let dockPath = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    static let windowServerPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
    /// Whether a window containing `point` (global, top-left origin) blocks input. On macOS 26 the Dock keeps one
    /// screen-sized window on the Dock layer (20) over everything; only that window is passed through, and only
    /// inside the screen's visibleFrame (its bar and the menu bar still block). Menus, Mission Control, Launchpad and
    /// any other window block. ponytail: an auto-hidden Dock that slides out is inside visibleFrame; read the
    /// Dock's autohide preference if that ever matters.
    /// The mouse cursor is itself an on-screen WindowServer window at the cursor level and sits wherever the last event
    /// put it, so it blocked every release and the frame-centre focus check (H1). Only WindowServer's cursor-level
    /// windows pass, and only cursor-sized ones (≤256 pt covers the 4× accessibility cursor); an app window raised to
    /// that level, or any larger WindowServer overlay, still blocks.
    static func occludes(owner: String?, layer: Int, bounds: CGRect, point: CGPoint, screens: [(frame: CGRect, visible: CGRect)]) -> Bool {
        if owner == windowServerPath, layer == Int(CGWindowLevelForKey(.cursorWindow)), bounds.width <= 256, bounds.height <= 256 { return false }
        guard owner == dockPath, layer == Int(CGWindowLevelForKey(.dockWindow)), let screen = screens.first(where: { $0.frame == bounds }) else { return true }
        return !screen.visible.contains(point)
    }
    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
    private static func screenRects() -> [(frame: CGRect, visible: CGRect)] {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { (flip($0.frame), flip($0.visibleFrame)) }
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func target() -> AXUIElement? {
        guard let frame = liveRect(), hit(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(window.ownerPID), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let matches = windows.filter { element in Self.windowID(element) == window.id && rect(element) == frame }
        // Unknown IDs fail closed, never guess by title/geometry.
        return matches.count == 1 ? matches[0] : nil
    }
    /// AXWindowNumber is not universally exposed (TextEdit on macOS 26 has none, so every key/text failed in H1).
    /// `_AXUIElementGetWindow` is private but long-stable (used by window managers); it maps the AX element to its
    /// CGWindowID exactly.
    private static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var number: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &number) == .success,
           let id = (number as? NSNumber)?.uint32Value { return id }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }
    private func focused() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.ownerPID,
              let target = target() else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(window.ownerPID), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return false }
        return CFEqual(target, value)
    }
    private func mouse(_ type: CGEventType, point: CGPoint, button: CGMouseButton, count: Int = 1, diagnostic: Diagnostic?, gate: Gate) -> Bool {
        diagnostic?.stage = .eventCreate
        guard armed, let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return false }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        let release = type == .leftMouseUp || type == .rightMouseUp
        var unverified = false
        return gate {
            if release {
                // A release is never skipped: skipping it left the button held at OS level (H1: the window then got
                // dragged). It lands on the first point that passes the hit test (requested, last verified, press), so
                // a drag cannot drop onto another window; if none passes it falls back to the press point. Never the
                // frame centre: a release away from the press turned a click into a drag-select (H1, lines 11–14).
                diagnostic?.stage = .heldButton
                guard let held = self.heldButtons[button] else { return false }
                if let verified = [point, self.lastPoint, held].compactMap({ $0 }).first(where: { self.hit($0) }) {
                    event.location = verified
                } else {
                    event.location = held; unverified = true
                    fputs("[input] release posted at unverified press point\n", stderr)
                }
            } else {
                diagnostic?.stage = .liveTarget
                guard self.liveRect() != nil else { return false }
                diagnostic?.stage = .hit
                guard self.hit(point) else { return false }
            }
            event.post(tap: .cghidEventTap)
            diagnostic?.stage = .effectPosted
            if type == .leftMouseDown || type == .rightMouseDown { diagnostic?.postedDown += 1 }
            if type == .leftMouseUp || type == .rightMouseUp { diagnostic?.postedUp += 1 }
            if type == .leftMouseDown || type == .rightMouseDown { self.heldButtons[button] = point }
            if type == .leftMouseUp || type == .rightMouseUp { self.heldButtons[button] = nil }
            if !unverified { self.lastPoint = event.location }
            // Screen points only (no window content), to tell a click from a drag-select during device tests.
            if type != .mouseMoved && type != .leftMouseDragged {
                fputs("[input] \(release ? "up" : "down") at \(Int(event.location.x)),\(Int(event.location.y)) state=\(count)\n", stderr)
            }
            return true
        }
    }
    static let keys: [String: CGKeyCode] = ["enter":36,"return":36,"tab":48,"escape":53,"esc":53,"backspace":51,"delete":117,"space":49,"left":123,"right":124,"down":125,"up":126,"home":115,"end":119,"pageup":116,"pagedown":121,"a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
    static let modifierKeys: [(flag: CGEventFlags, code: CGKeyCode)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)]
    /// Real modifier downs before the key and ups after it, the last up carrying no flags. Setting flags only on the
    /// key events left them in the session flag state after the last up, so Command read as held after ⌘V (H1).
    static func keySequence(code: CGKeyCode, flags: CGEventFlags) -> [(code: CGKeyCode, down: Bool, flags: CGEventFlags, modifier: Bool)] {
        let mods = modifierKeys.filter { flags.contains($0.flag) }
        var current: CGEventFlags = [], steps: [(code: CGKeyCode, down: Bool, flags: CGEventFlags, modifier: Bool)] = []
        for m in mods { current.insert(m.flag); steps.append((m.code, true, current, true)) }
        steps += [(code, true, flags, false), (code, false, flags, false)]
        for m in mods.reversed() { current.remove(m.flag); steps.append((m.code, false, current, true)) }
        return steps
    }
    static let modifiers: [String: CGEventFlags] = ["cmd":.maskCommand,"command":.maskCommand,"shift":.maskShift,"alt":.maskAlternate,"option":.maskAlternate,"ctrl":.maskControl,"control":.maskControl]
    /// Key events go through the global HID tap, so OS shortcuts (Cmd+Tab, Cmd+Space, Ctrl+arrows,
    /// Cmd+Shift+3) would act outside the bound window. Allow only editing chords.
    static func allowedChord(key: String, mods: [String]) -> Bool {
        let set = Set(mods.map { ["command": "cmd", "option": "alt", "control": "ctrl"][$0] ?? $0 })
        let arrows: Set<String> = ["left", "right", "up", "down"]
        if set.isEmpty || set == ["shift"] { return true }
        if set == ["cmd"] { return arrows.union(["a", "c", "v", "x", "z", "backspace"]).contains(key) }
        if set == ["cmd", "shift"] { return arrows.union(["z"]).contains(key) }
        if set == ["alt"] || set == ["alt", "shift"] { return ["left", "right", "backspace"].contains(key) }
        return false
    }
    func perform(_ object: [String: Any], diagnostic: Diagnostic? = nil, gate: Gate) -> Bool {
        diagnostic?.stage = .liveTarget
        guard let type = object["t"] as? String, let frame = liveRect() else { return false }
        armed = true
        if ["click", "move", "down", "drag", "up"].contains(type) {
            guard let x = object["x"] as? Double, let y = object["y"] as? Double else { return false }
            let point = CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
            let right = object["button"] as? String == "right"
            let button: CGMouseButton = right ? .right : .left
            diagnostic?.stage = .heldButton
            switch type {
            case "click":
                for i in 1...(object["count"] as? Int ?? 1) {
                    guard mouse(right ? .rightMouseDown : .leftMouseDown, point: point, button: button, count: i, diagnostic: diagnostic, gate: gate),
                          mouse(right ? .rightMouseUp : .leftMouseUp, point: point, button: button, count: i, diagnostic: diagnostic, gate: gate) else { return false }
                }
                return true
            case "down": return mouse(.leftMouseDown, point: point, button: .left, diagnostic: diagnostic, gate: gate)
            case "drag": return heldButtons[.left] != nil && mouse(.leftMouseDragged, point: point, button: .left, diagnostic: diagnostic, gate: gate)
            case "up": return heldButtons[.left] != nil && mouse(.leftMouseUp, point: point, button: .left, diagnostic: diagnostic, gate: gate)
            default: return mouse(.mouseMoved, point: point, button: .left, diagnostic: diagnostic, gate: gate)
            }
        }
        if type == "scroll" {
            let point = lastPoint ?? CGPoint(x: frame.midX, y: frame.midY)
            guard let dy = (object["dy"] as? NSNumber)?.doubleValue, let dx = (object["dx"] as? NSNumber)?.doubleValue,
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return false }
            event.location = point
            return gate { guard self.hit(point) else { return false }; event.post(tap: .cghidEventTap); return true }
        }
        if type == "key" || type == "text" {
            let code = type == "key" ? Self.keys[object["key"] as! String]! : 0
            var flags: CGEventFlags = []
            for modifier in object["mods"] as? [String] ?? [] { flags.insert(Self.modifiers[modifier]!) }
            let chunks = type == "text" ? (object["text"] as! String).map(String.init) : [""]
            // A chord refused part-way (focus moved after the ⌘ down) releases what it pressed at once, not after the
            // revoke's cleanup hop: a key typed on the Mac in between would otherwise become a shortcut.
            var pressed: [CGKeyCode] = []
            func abandon() -> Bool { for code in pressed.reversed() where heldKeys.contains(code) { _ = releaseKey(code) }; return false }
            for chunk in chunks {
                for step in Self.keySequence(code: code, flags: flags) {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: step.code, keyDown: step.down) else { return abandon() }
                    if step.modifier { event.type = .flagsChanged }
                    event.flags = step.flags
                    if type == "text" && !step.modifier {
                        let units = Array(chunk.utf16)
                        units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
                    }
                    // Residual risk: focus can change between this check and the post; at most one event lands elsewhere.
                    guard gate({
                        guard self.focused() else { return false }
                        event.post(tap: .cghidEventTap)
                        if step.down { self.heldKeys.insert(step.code); pressed.append(step.code) } else { self.heldKeys.remove(step.code) }
                        return true
                    }) else { return abandon() }
                }
            }
            return true
        }
        if type == "resize" {
            guard let element = target() else { return false }
            var size = CGSize(width: object["w"] as! Double, height: object["h"] as! Double)
            guard let value = AXValueCreate(.cgSize, &size) else { return false }
            return gate {
                guard let current = self.target(), CFEqual(current, element), self.liveRect() == frame else { return false }
                guard AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success else { return false }
                if self.savedFrame == nil { self.savedFrame = frame }
                self.setFrame = self.liveRect()
                return self.setFrame != nil
            }
        }
        if type == "restore" { return restore(gate: gate) }
        return false
    }
    private func restore(gate: Gate) -> Bool {
        guard let saved = savedFrame else { return true }
        defer { savedFrame = nil; setFrame = nil }
        guard let setFrame, liveRect() == setFrame, let element = target() else { return true }
        var size = saved.size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return gate {
            guard self.liveRect() == setFrame, let current = self.target(), CFEqual(current, element) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
        }
    }
    /// Release-only, never gated: a modifier goes up as a flagsChanged with no flags (a plain key-up keeps the flag).
    private func releaseKey(_ code: CGKeyCode) -> Bool {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
        if Self.modifierKeys.contains(where: { $0.code == code }) { event.type = .flagsChanged; event.flags = [] }
        event.post(tap: .cghidEventTap)
        heldKeys.remove(code)
        return true
    }
    /// Only releases actually submitted downs; cleanup may run after authority is revoked.
    func cleanup() -> Bool {
        armed = false
        var success = true
        for (button, point) in heldButtons {
            if let event = CGEvent(mouseEventSource: nil, mouseType: button == .right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: button) { event.post(tap: .cghidEventTap) }
            else { success = false }
        }
        for code in heldKeys where !releaseKey(code) { success = false }
        // Always end with a flagsChanged carrying no flags, even when nothing is tracked as held: the session flag
        // state outlives our events (H1: Command read as held after the host exited).
        if let reset = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false) {
            reset.type = .flagsChanged; reset.flags = []; reset.post(tap: .cghidEventTap)
        } else { success = false }
        if success { heldButtons.removeAll(); lastPoint = nil }
        return restore(gate: { $0() }) && success
    }
}
