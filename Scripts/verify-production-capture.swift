// Self-check: swiftc -parse-as-library -o /tmp/vpc Scripts/verify-production-capture.swift host/Sources/{CaptureController,InputController,PairingSession,ViewerPage,EntryConfiguration,AgentRequest}.swift && /tmp/vpc --diagnostics-self-check
// Compile with frozen CaptureController, InputController, PairingSession and ViewerPage sources.
// Argument: frozen verify-capture-geometry executable; only its --owned-window child is captured.
// No listeners, input injection, permission requests, saved images or production access bypass.
import AppKit
import ScreenCaptureKit
import Vision

private func record(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self)); fflush(stdout)
}
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "ProductionCaptureProbe", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class Child {
    var pid: pid_t = 0
    var input: FileHandle!
    var output: FileHandle!
    var directory: URL?
    var windowID: CGWindowID = 0
    var application: NSRunningApplication?
    var isRunning: Bool { application?.isTerminated == false }
    @MainActor func start(_ executable: String) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("production-owned-\(UUID().uuidString)")
        directory = root
        let bundle = root.appendingPathComponent("Controlled.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: executable), to: macOS.appendingPathComponent("Controlled"))
        let info: [String: Any] = ["CFBundleExecutable": "Controlled", "CFBundleIdentifier": "local.windowshare.probe.\(UUID().uuidString)",
                                   "CFBundleName": "WindowShare controlled fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let stdinPath = root.appendingPathComponent("stdin").path
        let stdoutPath = root.appendingPathComponent("stdout").path
        try require(mkfifo(stdinPath, 0o600) == 0 && mkfifo(stdoutPath, 0o600) == 0, "Fixture FIFO creation failed")
        let inFD = open(stdinPath, O_RDWR | O_NONBLOCK), outFD = open(stdoutPath, O_RDWR | O_NONBLOCK)
        try require(inFD >= 0 && outFD >= 0, "Fixture FIFO open failed")
        input = FileHandle(fileDescriptor: inFD, closeOnDealloc: true)
        output = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-n", "-i", stdinPath, "-o", stdoutPath, "--stderr", root.appendingPathComponent("stderr").path,
                            bundle.path, "--args", "--owned-window"]
        try launch.run()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == bundle.standardizedFileURL }) {
                application = app
                pid = app.processIdentifier
                record(["event": "childLaunched", "pid": pid, "directory": root.path,
                        "launchDate": app.launchDate?.timeIntervalSince1970 ?? -1])
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "Owned LaunchServices application not found", code: 1)
    }
    func reply(_ command: UInt8? = nil) async throws {
        if let command { try input.write(contentsOf: Data([command])) }
        var data = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && data.count < 4096 {
            var byte: UInt8 = 0
            let n = Darwin.read(output.fileDescriptor, &byte, 1)
            if n == 1 {
                if byte == 10 {
                    let row = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    try require((row?["pid"] as? Int32) == pid, "Child PID mismatch")
                    guard let id = row?["windowID"] as? UInt32 else { throw NSError(domain: "Child window missing", code: 1) }
                    try require(windowID == 0 || windowID == id, "Child window changed")
                    try require(command == nil || (row?["command"] as? Int) == Int(command!), "Child command mismatch")
                    windowID = id
                    record(["event": command == nil ? "childReady" : "childAck", "pid": pid,
                            "windowID": id, "command": command.map(Int.init) ?? -1])
                    return
                }
                data.append(byte)
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) { break }
            else { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        throw NSError(domain: "Child reply timeout or invalid data", code: 1)
    }
    @MainActor func close() async throws {
        if application == nil, let directory {
            application = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleURL?.standardizedFileURL == directory.appendingPathComponent("Controlled.app").standardizedFileURL
            })
            pid = application?.processIdentifier ?? 0
        }
        var errors: [String] = []
        do { try input?.close() } catch { errors.append(error.localizedDescription) }
        for _ in 0..<100 {
            if !isRunning { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if isRunning, let owned = application, let launched = owned.launchDate,
           let current = NSRunningApplication(processIdentifier: pid),
           current.launchDate == launched, current.bundleURL == owned.bundleURL,
           current.bundleURL?.standardizedFileURL == directory?.appendingPathComponent("Controlled.app").standardizedFileURL {
            if !owned.forceTerminate() { errors.append("Owned process termination request failed") }
            for _ in 0..<100 {
                if !isRunning { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        if isRunning { errors.append("Owned process still running; identity mismatch or termination failed") }
        do { try output?.close() } catch { errors.append(error.localizedDescription) }
        if !isRunning, let directory {
            do { try FileManager.default.removeItem(at: directory) } catch { errors.append(error.localizedDescription) }
        }
        let removed = directory.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        if !removed { errors.append("Owned fixture directory remains") }
        record(["event": "childCleanup", "running": isRunning, "pid": pid,
                "directoryRemoved": removed, "errors": errors])
        try require(errors.isEmpty, "Child cleanup failed: \(errors.joined(separator: "; "))")
    }
}

@main private struct ProductionCaptureProbe {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments == [CommandLine.arguments[0], "--diagnostics-self-check"] {
            // No AppKit application, capture stream, window, fixture or permission API.
            let capture = CaptureController()
            for _ in 0..<1000 { capture.recordSampleOutcome(.idle) }
            capture.recordSampleOutcome(.mapping)
            capture.recordSampleOutcome(.publicationAttempt)
            let counts = capture.stats["sampleOutcomes"] as? [String: Int]
            precondition(counts == ["idle": 1000, "mapping": 1, "publicationAttempt": 1])
            precondition(capture.stats["frames"] as? Int == 0)
            let screen = CGRect(x: 774, y: 155, width: 820, height: 748)
            let content = CGRect(x: 0, y: 0, width: 820, height: 748)
            precondition(JPEGEncoder.contentCrop(screen: screen, content: content, scale: 2,
                contentScale: 1, surface: [1644, 1500]) == CGRect(x: 0, y: 0, width: 1640, height: 1496))
            precondition(JPEGEncoder.contentCrop(screen: screen, content: content, scale: 2,
                contentScale: 1, surface: [1639, 1500]) == nil)
            precondition(JPEGEncoder.contentCrop(screen: screen, content: content, scale: 2,
                contentScale: 0.5, surface: [1644, 1500]) == nil)
            precondition(JPEGEncoder.contentCrop(screen: screen,
                content: content.offsetBy(dx: 0.25, dy: 0), scale: 2,
                contentScale: 1, surface: [1644, 1500]) == nil)
            // SCK fits the 2x window into the output and reports content = screen × contentScale; the crop must stay
            // whole pixels. A 1457×1137 pt window once got a 2559.04 px crop and never published a frame.
            for points in [CGSize(width: 1457, height: 1137), CGSize(width: 1000, height: 800), CGSize(width: 2400, height: 1300)] {
                for scale in [CGFloat(2), 1] {
                    let out = CaptureController.outputSize(points: points, scale: scale)
                    let fit = min(out.width / (points.width * 2), out.height / (points.height * 2))
                    let window = CGRect(origin: .zero, size: points)
                    let content = CGRect(x: 0, y: 0, width: points.width * fit, height: points.height * fit)
                    precondition(max(out.width, out.height) <= 2560, "output over cap for \(points)")
                    precondition(JPEGEncoder.contentCrop(screen: window, content: content, scale: 2, contentScale: fit,
                        surface: [Int(out.width), Int(out.height)]) != nil, "no whole-pixel crop for \(points) at \(scale)x")
                }
            }
            precondition(JPEGEncoder.scaled(CGSize(width: 1000, height: 800), maxEdge: 768) == [768, 614])
            precondition(JPEGEncoder.scaled(CGSize(width: 600, height: 400), maxEdge: 768) == [600, 400])
            print("PASS: bounded diagnostics and exact SCK content crop; invalid mappings rejected; large windows crop")
            return
        }
        guard CommandLine.arguments.count == 2 else { fputs("Expected owned-window executable path\n", stderr); exit(2) }
        guard CGPreflightScreenCaptureAccess() else {
            record(["event": "blocked", "reason": "Screen capture preflight false; no permission requested"]); exit(2)
        }
        // Parent-death FIFO cleanup is not guaranteed; the child also has a 40-second watchdog.
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
            record(["event": "failure", "reason": "35-second watchdog"]); exit(3)
        }
        Task { @MainActor in await run(CommandLine.arguments[1]) }
        NSApplication.shared.run()
    }

    @MainActor static func run(_ executable: String) async {
        let child = Child(), identity = PairingSession()
        let binding = identity.selectWindow()
        let capture = CaptureController(identity: identity, binding: binding)
        var cookies: [String: String] = [:]
        func request(_ method: String, _ path: String, _ fields: [String: Any] = [:]) -> PairingSession.Reply {
            var result: PairingSession.Reply!
            identity.respond(method: method, path: path, fields: fields, cookies: cookies) { result = $0 }
            for cookie in result.cookies {
                let parts = cookie.split(separator: ";", maxSplits: 1)[0].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { cookies[String(parts[0])] = String(parts[1]) }
            }
            return result
        }
        let base = "/w/\(binding.windowID)"
        func metadata() throws -> [String: Any] {
            let reply = request("GET", base + "/meta")
            try require(reply.status == 200, "Metadata unavailable")
            return try JSONSerialization.jsonObject(with: reply.body) as! [String: Any]
        }
        // Inspect authority-stored bytes, never the advisory onFrame callback.
        func accepted(_ phase: String, size: [Int], after epoch: Int? = nil, differentFrom prior: Data? = nil) async throws -> (Data, Int) {
            let deadline = Date().addingTimeInterval(4)
            var lastStatus = 0
            while Date() < deadline {
                let reply = request("GET", base + "/snapshot")
                lastStatus = reply.status
                if reply.status == 200, let image = NSBitmapImageRep(data: reply.body),
                   [image.pixelsWide, image.pixelsHigh] == size,
                   let current = Int(reply.headers["X-WindowShare-Geometry-Epoch"] ?? ""),
                   epoch.map({ current > $0 }) ?? true, prior.map({ reply.body != $0 }) ?? true {
                    let meta = try metadata()
                    try require(meta["size"] as? [Int] == size, "Stored metadata/JPEG dimensions disagree")
                    try require(meta["mode"] as? String == "View", "Unexpected control mode")
                    guard let cgImage = image.cgImage else { throw NSError(domain: "JPEG decode failed", code: 1) }
                    let text = VNRecognizeTextRequest()
                    text.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: cgImage).perform([text])
                    let recognized = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    let marker = recognized.uppercased().contains("CONTROLLED TEST CONTENT")
                    try require(marker, "Harmless content marker not found in decoded JPEG")
                    record(["event": "acceptedJPEG", "phase": phase, "size": size, "epoch": current,
                            "bytes": reply.body.count, "marker": marker, "mode": "View"])
                    return (reply.body, current)
                }
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            throw NSError(domain: "ProductionCaptureProbe", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "\(phase): no expected stored JPEG within 4s; last HTTP-style status \(lastStatus)"])
        }
        var status: Int32 = 0
        do {
            try await child.start(executable); try await child.reply()
            try await Task.sleep(nanoseconds: 300_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == child.windowID && $0.owningApplication?.processID == child.pid }) else {
                throw NSError(domain: "Exact owned window not shareable", code: 1)
            }
            let window = WindowInfo(id: target.windowID, title: target.title, ownerName: "Controlled child",
                                    ownerPID: child.pid, frame: target.frame, scWindow: target)
            record(["event": "target", "pid": child.pid, "windowID": child.windowID,
                    "frame": [target.frame.minX, target.frame.minY, target.frame.width, target.frame.height]])
            let application = NSRunningApplication(processIdentifier: child.pid)
            let exactRows = CGWindowListCopyWindowInfo(.optionIncludingWindow, child.windowID) as? [[String: Any]]
            record(["event": "productionStartPreconditions", "applicationExists": application != nil,
                    "launchDateAvailable": application?.launchDate != nil,
                    "terminated": application?.isTerminated ?? true,
                    "exactCGTarget": CaptureController.containsTarget(exactRows, id: child.windowID, pid: child.pid),
                    "bindingCurrent": identity.isCurrent(binding)])
            try await capture.startCapture(window, onFrame: { _ in })
            try require(capture.isCapturing, "Production start did not activate")
            try require(request("POST", "/session", ["window_id": binding.windowID, "window_generation": binding.generation]).status == 200, "Session failed")
            let originalSize = [Int(target.frame.width * 2), Int(target.frame.height * 2)]
            let initial = try await accepted("initial", size: originalSize)
            try await child.reply(109)
            let moved = try await accepted("same-size-move", size: originalSize, after: initial.1)
            try await child.reply(114)
            // Use production external-resize path, with exact owned-window geometry only.
            let input = InputController(window: window)
            capture.liveFrameProvider = {
                guard let g = input.geometry() else { return nil }
                return CGRect(x: g[0], y: g[1], width: g[2], height: g[3])
            }
            // AppKit acknowledgement can precede WindowServer's resized bounds.
            let resizeDeadline = Date().addingTimeInterval(2)
            while Date() < resizeDeadline && input.geometry().map({ $0[2] == 560 && $0[3] == 392 }) != true {
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            guard let geometry = input.geometry() else { throw NSError(domain: "Live geometry missing", code: 1) }
            try require(geometry[2] == 560 && geometry[3] == 392, "Owned resize did not reach WindowServer")
            capture.syncToLiveFrame(); capture.syncToLiveFrame()
            let resizedSize = [Int(geometry[2]), Int(geometry[3])] // production default reapply scale is 1
            let resized = try await accepted("resize-reapply", size: resizedSize, after: moved.1)
            capture.setQuality(scale: 0.5, fps: 12, quality: 0.6)
            let halfSize = resizedSize.map { $0 / 2 }
            let half = try await accepted("half-scale-config", size: halfSize)
            try require(half.1 == resized.1, "Output-only scale changed geometry epoch")
            capture.setQuality(scale: 0.5, fps: 10, quality: 0.7)
            // Read the baseline after the request, without OCR; a later different stored
            // image proves fresh publication, not configuration completion or FPS adoption.
            let baseline = request("GET", base + "/snapshot")
            try require(baseline.status == 200, "Post-request snapshot baseline unavailable")
            record(["event": "postRequestBaseline", "bytes": baseline.body.count])
            let sameSize = try await accepted("same-size-config", size: halfSize, differentFrom: baseline.body)
            try require(sameSize.1 == half.1, "Same-size configuration changed geometry epoch")
            identity.revokeWindow(binding)
            try require(request("GET", base + "/snapshot").status == 401, "Revoked snapshot still authorized")
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(request("GET", base + "/snapshot").status == 401, "Late native frames revived revoked snapshot")
            let replacement = identity.selectWindow()
            await capture.stopCapture()
            try require(!capture.isCapturing && identity.isCurrent(replacement), "Old stop revoked replacement or capture remains active")
            try require(!identity.activate(binding), "Stale binding reactivated")
            let stale = CaptureController(identity: identity, binding: binding)
            var rejected = false
            do { try await stale.startCapture(window, onFrame: { _ in }) } catch { rejected = true }
            await stale.stopCapture()
            try require(rejected && identity.isCurrent(replacement), "Stale capture start or stop violated binding")
            record(["event": "revocation", "lateSnapshotStatus": 401, "staleStartRejected": rejected, "replacementPreserved": true])
        } catch {
            status = 4
            record(["event": "failure", "reason": error.localizedDescription])
        }
        await capture.stopCapture()
        do { try await child.close() } catch {
            status = 5
            record(["event": "failure", "reason": error.localizedDescription])
        }
        if status == 0 {
            record(["event": "summary", "result": "PASS", "scope": "production capture/encode/store/snapshot; owned child only; controls closed"])
        }
        exit(status)
    }
}
