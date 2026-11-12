// Run: swiftc -parse-as-library Scripts/verify-capture-geometry.swift -o /tmp/verify-capture-geometry && /tmp/verify-capture-geometry
// Only captures the window created by our owned child process. No permission request, input, ports or image files.
import AppKit
import ScreenCaptureKit
import CoreMedia

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}
func vector(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }

final class Probe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let id: CGWindowID
    let pid: pid_t
    let queue = DispatchQueue(label: "controlled.geometry.samples")
    let lock = NSLock()
    var phase = "initial"
    var expected: [Int] = []
    var since: UInt64 = 0
    var updating = false
    var counts: [String: Int] = [:]
    var accepts: [String: Int] = [:]
    var complete = 0
    var failed = false
    init(id: CGWindowID, pid: pid_t) { self.id = id; self.pid = pid }
    func state(_ phase: String, size: [Int]? = nil, updating: Bool = false, barrier: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.phase = phase; self.updating = updating
        if let size { expected = size }
        if barrier { since = mach_absolute_time() }
        emit(["event": "phase", "phase": phase, "expected": expected, "configurationSince": since, "updating": updating])
    }
    func live() -> [Double]? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }),
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 8, &displays, &count) == .success, count == 1,
              let mode = CGDisplayCopyDisplayMode(displays[0]), mode.width > 0 else { return nil }
        return vector(rect) + [Double(mode.pixelWidth) / Double(mode.width)]
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.lock(); defer { lock.unlock() }
        let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
        let status = info[.status] as? Int
        counts[phase, default: 0] += 1
        var row: [String: Any] = ["event": "frame", "phase": phase, "status": status ?? -1, "callbackTime": mach_absolute_time(), "configurationSince": since,
                                   "keys": info.keys.map { $0.rawValue }.sorted()]
        let fields: [(String, SCStreamFrameInfo)] = [("screenRect", .screenRect), ("contentRect", .contentRect), ("scaleFactor", .scaleFactor), ("contentScale", .contentScale), ("displayTime", .displayTime)]
        for (name, key) in fields {
            if let value = info[key] { row[name] = value; row[name + "Type"] = String(describing: Swift.type(of: value)) }
        }
        let pb = sample.imageBuffer
        let size = pb.map { [CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)] } ?? []
        let current = live()
        row["pixels"] = size; row["expected"] = expected; row["live"] = current ?? []
        if let timestamp = info[.displayTime] as? NSNumber {
            row["displayTimeBeforeConfiguration"] = timestamp.uint64Value < since
        }
        var reasons: [String] = []
        if !sample.isValid { reasons.append("invalid") }
        if status != SCFrameStatus.complete.rawValue { reasons.append("notComplete") } else { complete += 1 }
        if let screenValue = info[.screenRect] as? [String: Any], let screen = CGRect(dictionaryRepresentation: screenValue as CFDictionary),
           let contentValue = info[.contentRect] as? [String: Any], let content = CGRect(dictionaryRepresentation: contentValue as CFDictionary),
           let scale = info[.scaleFactor] as? Double, let contentScale = info[.contentScale] as? Double,
           let timestamp = info[.displayTime] as? NSNumber, size.count == 2 {
            let geometry = vector(screen) + [scale]
            if !(1...4).contains(scale) || !contentScale.isFinite || contentScale <= 0 || screen.width <= 0 || screen.height <= 0 || !geometry.allSatisfy({ $0.isFinite }) { reasons.append("invalidGeometry") }
            if content.origin != .zero { reasons.append("contentOrigin") }
            if abs(content.width * scale - Double(size[0])) >= 0.01 || abs(content.height * scale - Double(size[1])) >= 0.01 { reasons.append("contentDoesNotFillSurface") }
            if abs(screen.width * contentScale - content.width) >= 0.01 || abs(screen.height * contentScale - content.height) >= 0.01 { reasons.append("screenContentScale") }
            if current != geometry { reasons.append("liveGeometryMismatch") }
            if timestamp.uint64Value < since { reasons.append("preConfigurationTime") }
        } else { reasons.append("missingOrUnsupportedMetadata") }
        if size != expected { reasons.append("configurationSize") }
        if updating { reasons.append("configurationUpdating") }
        row["capturePredicateRejections"] = reasons
        if reasons.isEmpty { accepts[phase, default: 0] += 1 }
        // Attachments are scalars/dictionaries only; never serialize pixel data or other windows.
        emit(row)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); failed = true; lock.unlock()
        emit(["event": "streamError", "error": String(describing: error)])
    }
    func summary() -> Bool {
        lock.lock(); defer { lock.unlock() }
        emit(["event": "summary", "samplesByPhase": counts, "capturePredicateAcceptedByPhase": accepts, "completeFrames": complete, "streamFailed": failed,
              "scope": "native samples; mirrored CaptureController attachment/config/live predicate only; no PairingSession publication or input"])
        return complete > 0 && !failed
    }
}

// Anonymous pipes carry one-byte commands and bounded JSON acknowledgements only.
// EOF closes the child even if the parent is killed; a child watchdog also bounds a stalled run.
final class OwnedWindow {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    func start() throws {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--owned-window"]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }
    func reply(_ command: UInt8? = nil) async throws -> [String: Any] {
        if let command { try input.fileHandleForWriting.write(contentsOf: Data([command])) }
        let deadline = Date().addingTimeInterval(3)
        var data = Data()
        while Date() < deadline && data.count < 4096 {
            var byte: UInt8 = 0
            let n = Darwin.read(output.fileHandleForReading.fileDescriptor, &byte, 1)
            if n == 1 {
                if byte == 10 {
                    guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (row["pid"] as? Int32) == process.processIdentifier,
                          command == nil || (row["command"] as? Int) == Int(command!) else { break }
                    emit(row)
                    return row
                }
                data.append(byte)
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) { break }
            else { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        throw NSError(domain: "ControlledGeometry", code: 2, userInfo: [NSLocalizedDescriptionKey: "Owned child reply missing, invalid, oversized or timed out (3s/4096 bytes)"])
    }
    func close() async {
        try? input.fileHandleForWriting.close()
        for _ in 0..<100 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        emit(["event": "childCleanup", "pid": process.processIdentifier, "running": process.isRunning,
              "terminationStatus": process.terminationStatus])
    }
}

@main struct NativeGeometry {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        if CommandLine.arguments.dropFirst() == ["--owned-window"] { child() }
        else { Task { @MainActor in await run() } }
        app.run()
    }
    @MainActor static func child() {
        _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) { exit(3) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let area = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = NSWindow(contentRect: CGRect(x: area.minX + 80, y: area.minY + 80, width: 480, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "WindowShare controlled geometry test — harmless contents"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "CONTROLLED TEST CONTENT\nGeometry probe only — no credentials")
        label.frame = CGRect(x: 24, y: 40, width: 430, height: 180)
        label.font = .systemFont(ofSize: 22)
        window.contentView?.addSubview(label)
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.display()
        NSAnimationContext.current.duration = 0
        let id = CGWindowID(window.windowNumber)
        var tick = 0
        _ = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            tick += 1
            label.stringValue = "CONTROLLED TEST CONTENT\nHarmless frame \(tick)"
            window.displayIfNeeded()
            var command: UInt8 = 0
            let n = Darwin.read(STDIN_FILENO, &command, 1)
            if n == 0 { window.close(); exit(0) }
            if n < 0 && errno != EAGAIN && errno != EINTR { window.close(); exit(3) }
            guard n == 1 else { return }
            switch command {
            case 109: window.setFrameOrigin(CGPoint(x: window.frame.minX + 90, y: window.frame.minY + 40)) // m
            case 114: window.setContentSize(NSSize(width: 560, height: 360)) // r
            case 113: window.setFrameOrigin(CGPoint(x: window.frame.minX + 50, y: window.frame.minY - 30)) // q
            case 120: window.close(); exit(0) // x
            default: window.close(); exit(3)
            }
            window.display()
            emit(["event": "childAck", "command": Int(command), "pid": getpid(), "windowID": id,
                  "frame": vector(window.frame), "visible": window.isVisible, "drawTicks": tick])
        }

        emit(["event": "childReady", "pid": getpid(), "windowID": id, "frame": vector(window.frame),
              "visible": window.isVisible, "drawTicks": tick, "sharingType": window.sharingType.rawValue,
              "occlusionVisible": window.occlusionState.contains(.visible), "backingScale": window.backingScaleFactor])
    }
    @MainActor static func run() async {
        guard CGPreflightScreenCaptureAccess() else {
            emit(["event": "blocked", "reason": "CGPreflightScreenCaptureAccess returned false; no permission requested; no capture attempted"])
            exit(2)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        emit(["event": "session", "onConsole": session["kCGSSessionOnConsoleKey"] ?? NSNull(),
              "loginDone": session["kCGSessionLoginDoneKey"] ?? NSNull(),
              "screenLocked": session["CGSSessionScreenIsLocked"] ?? NSNull(),
              "displays": NSScreen.screens.map { screen -> [String: Any] in
                  let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                  return ["id": id, "frame": vector(screen.frame), "scale": screen.backingScaleFactor,
                          "active": CGDisplayIsActive(id), "asleep": CGDisplayIsAsleep(id)]
              }])
        let child = OwnedWindow()
        // Parent exit closes the command pipe; EOF or the child's 40s watchdog removes its window.
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
            emit(["event": "blocked", "reason": "35-second native probe timeout"]); exit(3)
        }
        func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
        func configuration(_ width: Int, _ height: Int) -> SCStreamConfiguration {
            let cfg = SCStreamConfiguration()
            cfg.width = width; cfg.height = height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            cfg.queueDepth = 3; cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = true; cfg.capturesAudio = false
            return cfg
        }
        var stream: SCStream?
        do {
            try child.start()
            let ready = try await child.reply()
            guard let id = (ready["windowID"] as? NSNumber)?.uint32Value else { throw CocoaError(.coderInvalidValue) }
            let pid = child.process.processIdentifier
            let probe = Probe(id: id, pid: pid)
            await pause(300)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let own = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == pid }) else {
                throw NSError(domain: "ControlledGeometry", code: 1, userInfo: [NSLocalizedDescriptionKey: "Exact child-owned CGWindowID/process absent from SCShareableContent"])
            }
            emit(["event": "target", "windowID": id, "pid": pid, "parentPID": getpid(), "scFrame": vector(own.frame), "live": probe.live() ?? [], "os": ProcessInfo.processInfo.operatingSystemVersionString,
                  "onScreen": own.isOnScreen, "permissionPreflight": true])
            let cfg = configuration(Int(own.frame.width * 2), Int(own.frame.height * 2))
            probe.state("initial-start", size: [cfg.width, cfg.height], updating: true)
            let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: own), configuration: cfg, delegate: probe)
            stream = capture
            try capture.addStreamOutput(probe, type: .screen, sampleHandlerQueue: probe.queue)
            try await capture.startCapture()
            probe.state("initial", barrier: true)
            await pause(900)
            probe.state("same-size-move")
            _ = try await child.reply(109)
            await pause(900)
            probe.state("resize-old-config")
            _ = try await child.reply(114)
            await pause(900)
            probe.state("config-updating", updating: true)
            guard let resizedLive = probe.live() else { throw CocoaError(.coderInvalidValue) }
            let resized = configuration(Int(resizedLive[2] * 2), Int(resizedLive[3] * 2))
            try await capture.updateConfiguration(resized)
            probe.state("resized-config", size: [resized.width, resized.height], barrier: true)
            await pause(900)
            // Hold the real sample callback queue while WindowServer produces frames, then
            // move and update configuration. Retained native samples are never fabricated.
            probe.queue.suspend()
            probe.state("queued-before-change")
            await pause(350)
            do { _ = try await child.reply(113) }
            catch { probe.queue.resume(); throw error }
            probe.state("queued-config-updating", updating: true)
            let smaller = configuration(Int(resizedLive[2]), Int(resizedLive[3]))
            do { try await capture.updateConfiguration(smaller) }
            catch { probe.queue.resume(); throw error }
            probe.state("queued-after-config", size: [smaller.width, smaller.height], barrier: true)
            probe.queue.resume()
            await pause(1100)
            try await capture.stopCapture()
            stream = nil
            let success = probe.summary()
            await child.close()
            exit(success ? 0 : 4)
        } catch {
            if let stream { try? await stream.stopCapture() }
            emit(["event": "blocked", "error": String(describing: error)])
            if child.process.processIdentifier > 0 { await child.close() }; exit(3)
        }
    }
}
