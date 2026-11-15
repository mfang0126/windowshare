import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String?
    let ownerName: String
    let ownerPID: pid_t
    let frame: CGRect
    let scWindow: SCWindow
}

enum CaptureError: Error, LocalizedError {
    case noWindows
    case windowNotFound
    case alreadyCapturing

    var errorDescription: String? {
        switch self {
        case .noWindows: return "no capturable windows found"
        case .windowNotFound: return "target window disappeared before capture started"
        case .alreadyCapturing: return "capture already running"
        }
    }
}

/// Single-window capture via ScreenCaptureKit → JPEG frames.
/// Source: window-share M1 (2026-10-13). SCShareableContent timeout+retry
/// pitfall adopted from SideScreen MacHost (Apple bug FB12114396).
final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var currentWindow: WindowInfo?
    private var config: SCStreamConfiguration?
    private var jpegQuality: Double = 0.65
    private let frameLock = NSLock()
    private var frameCount: Int64 = 0
    enum SampleOutcome: String {
        case inactive, invalidSample, idle, incomplete, noImage, metadata, mapping
        case configuration, authority, geometryUnavailable, geometryMismatch, provenance, encoding
        case publicationAttempt
    }
    private var sampleOutcomes: [String: Int] = [:]

    // Fixed labels only: no pixels, attachment values, window identity or credentials.
    @discardableResult func recordSampleOutcome(_ outcome: SampleOutcome) -> Bool {
        frameLock.lock()
        sampleOutcomes[outcome.rawValue, default: 0] += 1
        let first = sampleOutcomes[outcome.rawValue] == 1
        frameLock.unlock()
        if first { fputs("[capture] first sample outcome=\(outcome.rawValue)\n", stderr) }
        return first
    }
    private var onFrame: ((Data) -> Void)?
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?
    private let encodeQueue = DispatchQueue(label: "windowshare.encode", qos: .userInitiated)
    private let lifecycleLock = NSLock()
    private var cancelled = false
    private var starting = false
    private var outputPaused = false
    private var activityDriver: CapturePauseDriver?
    private let identity: PairingSession?
    private let binding: PairingSession.Binding?
    private var targetWatcher: DispatchSourceTimer?
    private var captureSize: [Int] = []
    private var configurationSince: UInt64 = 0
    private var configurationUpdating = false
    private var privacyReader: (() -> Bool)?
    private var geometryReader: (() -> Result<[Double], PairingSession.GeometryFailure>)?
    var onInvalidated: (() -> Void)?

    /// Shared by OS detection and stream failure; always scoped to this capture generation.
    func invalidate() {
        if let binding { identity?.revokeWindow(binding) }
        let notify = lifecycle { () -> (() -> Void)? in
            guard !cancelled else { return nil }
            cancelled = true
            return onInvalidated
        }
        notify?()
        Task { await stopCapture() }
    }

    static func containsTarget(_ windows: [[String: Any]]?, id: CGWindowID, pid: pid_t) -> Bool {
        windows?.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id &&
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
        } == true
    }

    private func targetExists(_ window: WindowInfo, application: NSRunningApplication, launchDate: Date) -> Bool {
        guard !application.isTerminated,
              NSRunningApplication(processIdentifier: window.ownerPID)?.launchDate == launchDate else { return false }
        return Self.containsTarget(CGWindowListCopyWindowInfo(.optionIncludingWindow, window.id) as? [[String: Any]],
                                   id: window.id, pid: window.ownerPID)
    }

    @MainActor private func watchTarget(_ window: WindowInfo, application: NSRunningApplication, launchDate: Date) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.targetExists(window, application: application, launchDate: launchDate) { self.invalidate() }
        }
        lifecycle { targetWatcher = timer }
        timer.resume()
    }

    deinit { targetWatcher?.cancel() }

    init(identity: PairingSession? = nil, binding: PairingSession.Binding? = nil) {
        self.identity = identity; self.binding = binding
        super.init()
    }
    private func lifecycle<T>(_ action: () -> T) -> T {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return action()
    }
    var isCapturing: Bool { lifecycle { stream != nil && !cancelled } }

    // MARK: - Window listing

    func listWindows(includeOffscreen: Bool = false) async throws -> [WindowInfo] {
        let content = try await shareableContentWithTimeout(includeOffscreen: includeOffscreen)
        return content.windows
            .filter { Self.selectableWindow(onScreen: $0.isOnScreen, layer: $0.windowLayer, includeOffscreen: includeOffscreen) }
            .filter { ($0.title ?? "").isEmpty == false }
            .filter { $0.owningApplication?.processID != getpid() }
            .map {
                WindowInfo(
                    id: $0.windowID,
                    title: $0.title,
                    ownerName: $0.owningApplication?.applicationName ?? "(unknown)",
                    ownerPID: $0.owningApplication?.processID ?? 0,
                    frame: $0.frame,
                    scWindow: $0
                )
            }
            .sorted { "\($0.ownerName) \($0.title ?? "")" < "\($1.ownerName) \($1.title ?? "")" }
    }

    static func selectableWindow(onScreen: Bool, layer: Int, includeOffscreen: Bool) -> Bool {
        layer == 0 && (onScreen || includeOffscreen)
    }

    @MainActor func ownedWindow(_ window: NSWindow) async throws -> WindowInfo {
        let number = window.windowNumber
        guard number > 0, window.isVisible, NSApp.window(withWindowNumber: number) === window else { throw CaptureError.windowNotFound }
        let content = try await shareableContentWithTimeout()
        guard window.windowNumber == number, window.isVisible,
              let live = content.windows.first(where: { $0.windowID == CGWindowID(number) && $0.owningApplication?.processID == getpid() }) else { throw CaptureError.windowNotFound }
        return WindowInfo(id: live.windowID, title: live.title, ownerName: "WindowShare CLI SIMULATION",
                          ownerPID: getpid(), frame: live.frame, scWindow: live)
    }

    private func shareableContentWithTimeout(seconds: Int = 10, includeOffscreen: Bool = false) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: !includeOffscreen)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw NSError(
                    domain: "WindowShare", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "SCShareableContent timed out after \(seconds)s (possible Apple bug FB12114396)"])
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Capture

    @MainActor func startCapture(_ window: WindowInfo, includeOffscreen: Bool = false, onFrame: @escaping (Data) -> Void) async throws {
        guard lifecycle({
            guard stream == nil, !starting, !cancelled else { return false }
            starting = true; self.onFrame = onFrame; return true
        }) else { throw CaptureError.alreadyCapturing }
        var succeeded = false
        defer {
            lifecycle { starting = false }
            if !succeeded { invalidate() }
        }
        guard let application = NSRunningApplication(processIdentifier: window.ownerPID),
              let launchDate = application.launchDate else {
            fputs("[capture] initial application missing\n", stderr)
            throw CaptureError.windowNotFound
        }
        guard targetExists(window, application: application, launchDate: launchDate) else {
            fputs("[capture] initial target missing\n", stderr)
            throw CaptureError.windowNotFound
        }
        watchTarget(window, application: application, launchDate: launchDate)
        // Re-resolve the exact ID, including offscreen Agent targets; never activate another window.
        let content = try await shareableContentWithTimeout(includeOffscreen: includeOffscreen)
        guard targetExists(window, application: application, launchDate: launchDate) else {
            fputs("[capture] revalidation target missing\n", stderr)
            throw CaptureError.windowNotFound
        }
        guard let live = content.windows.first(where: { $0.windowID == window.id && $0.owningApplication?.processID == window.ownerPID }) else {
            fputs("[capture] revalidation SCK window missing\n", stderr)
            throw CaptureError.windowNotFound
        }
        guard lifecycle({ !cancelled }), binding.map({ identity?.isCurrent($0) == true }) ?? true else {
            fputs("[capture] revalidation authority rejected\n", stderr)
            throw CaptureError.windowNotFound
        }

        if !live.isOnScreen {
            fputs("[capture] selected offscreen window by exact ID; no window activation. Minimized or non-rendering Space windows may not provide frames; show only the intended Space and reselect its verified window ID if needed.\n", stderr)
        }
        let filter = SCContentFilter(desktopIndependentWindow: live)
        let config = SCStreamConfiguration()
        if #available(macOS 14.0, *) { config.ignoreShadowsSingleWindow = true }

        // Output size: 2x point size for text readability, long edge capped at 2560.
        let output = Self.outputSize(points: live.frame.size, scale: 2)
        config.width = Int(output.width)
        config.height = Int(output.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.viewFPS)) // idle policy floor; StreamTuningPolicy later
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: encodeQueue)
        try await stream.startCapture()
        let targetStillExists = targetExists(window, application: application, launchDate: launchDate)
        let accepted = lifecycle {
            guard targetStillExists, !cancelled, binding.map({ identity?.activate($0) == true }) ?? true else { return false }
            self.stream = stream
            self.config = config
            self.captureSize = [config.width, config.height]
            self.configurationSince = mach_absolute_time()
            let input = InputController(window: window)
            self.geometryReader = { input.measure() }
            self.privacyReader = { input.sensitiveFocus() }
            self.currentWindow = WindowInfo(
                id: live.windowID, title: live.title,
                ownerName: live.owningApplication?.applicationName ?? "(unknown)",
                ownerPID: live.owningApplication?.processID ?? 0,
                frame: live.frame, scWindow: live)
            return true
        }
        guard accepted else {
            fputs("[capture] post-start acceptance rejected target=\(targetStillExists)\n", stderr)
            try? await stream.stopCapture(); throw CaptureError.windowNotFound
        }
        let driver = CapturePauseDriver { paused in
            if paused { try await stream.stopCapture() } else { try await stream.startCapture() }
        }
        lifecycle { activityDriver = driver }
        succeeded = true
        print("[capture] started")
    }

    /// Stop SCK entirely while the viewer is backgrounded or the Mac is locked; keep the selected target.
    func setPaused(_ paused: Bool) {
        let driver = lifecycle { () -> CapturePauseDriver? in
            guard !cancelled else { return nil }
            outputPaused = paused
            if !paused { configurationSince = mach_absolute_time() }
            return activityDriver
        }
        if paused, let binding { identity?.discardFrames(binding) }
        Task {
            do { try await driver?.setPaused(paused) }
            catch { invalidate() }
        }
    }

    /// Stream output pixels for a window of `points` at `scale`, long edge capped at 2560 by halving the scale.
    /// An arbitrary shrink factor made SCK's content rect fractional, so `contentCrop` rejected every frame.
    /// ponytail: below 1x an odd point size is still fractional; only windows over 2560 pt reach that.
    static func outputSize(points: CGSize, scale: CGFloat) -> CGSize {
        var s = scale
        while max(points.width, points.height) * s > 2560, s > 0.25 { s /= 2 }
        return CGSize(width: (points.width * s).rounded(), height: (points.height * s).rounded())
    }

    /// Live quality change: scale, frame interval and JPEG quality.
    /// Used by the viewer to trade pixels for bandwidth on slow links.
    func setQuality(scale: CGFloat, fps: Int, quality: Double) {
        lastScale = max(scale, 0.4); lastFPS = max(fps, 2)
        jpegQuality = min(max(quality, 0.3), 0.9)
        guard let stream, let previous = config, let window = currentWindow else { return }
        guard lifecycle({
            guard !cancelled, !configurationUpdating else { return false }
            configurationUpdating = true
            return true
        }) else { return }
        let cfg = SCStreamConfiguration()
        if #available(macOS 14.0, *) { cfg.ignoreShadowsSingleWindow = true }
        cfg.pixelFormat = previous.pixelFormat; cfg.queueDepth = previous.queueDepth
        cfg.showsCursor = previous.showsCursor; cfg.capturesAudio = previous.capturesAudio
        let output = Self.outputSize(points: sizeOverride ?? window.frame.size, scale: max(scale, 0.4))
        let w = output.width, h = output.height
        cfg.width = Int(w)
        cfg.height = Int(h)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 2)))
        Task {
            do {
                try await stream.updateConfiguration(cfg)
                lifecycle {
                    guard self.stream === stream, !cancelled else { return }
                    config = cfg; captureSize = [cfg.width, cfg.height]
                    configurationSince = mach_absolute_time(); configurationUpdating = false
                }
            } catch { invalidate() }
        }
        print("[capture] quality -> \(Int(w))x\(Int(h)) @ \(fps)fps q\(jpegQuality)")
    }

    // Matches startCapture, so a reapply after an external resize keeps the starting resolution and rate.
    private var maxEdge: Int? // Interact cap (M2-a2), applied by the JPEG encoder
    private var lastScale: CGFloat = 2
    static var viewFPS: Int { ProcessInfo.processInfo.environment["WINDOWSHARE_VIEW_FPS"].flatMap(Int.init).flatMap { (2...60).contains($0) ? $0 : nil } ?? 24 }
    private var lastFPS: Int = viewFPS

    /// M2-a: tune the stream while a lease is held, restore it after.
    /// ponytail: a change that lands while another updateConfiguration is in flight is dropped; retry if seen.
    func setInteract(_ on: Bool) {
        let fps = on && Tuning.fps ? 60 : Self.viewFPS
        let small = on && Tuning.small
        let scale: CGFloat = small ? 1 : 2
        let quality = on && Tuning.q4 ? 0.4 : small ? 0.5 : 0.65
        lifecycle { maxEdge = on && Tuning.cap ? Tuning.capEdge : nil }
        guard fps != lastFPS || scale != lastScale || quality != jpegQuality else { return }
        setQuality(scale: scale, fps: fps, quality: quality)
    }
    /// Set after a viewport.sync resize: SCK keeps reporting the pre-resize frame for a while.
    var sizeOverride: CGSize?
    var lastResizeAt = Date.distantPast
    /// Live geometry from the window server, used to follow external resizes.
    var liveFrameProvider: (() -> CGRect?)?
    private var frameWatcher: DispatchSourceTimer?

    func startFrameWatcher() {
        frameWatcher?.cancel()
        // dispatchMain() runs in headless mode, so a RunLoop Timer would never fire.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "windowshare.watch"))
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.syncToLiveFrame() }
        t.resume()
        frameWatcher = t
    }

    /// The user can drag the shared window at any time; the stream must follow it,
    /// otherwise the picture and the click mapping disagree.
    private var pendingFrame: CGRect?
    private var pendingCount = 0

    func syncToLiveFrame() {
        guard let live = liveFrameProvider?(), let w = currentWindow else { return }
        // Ignore geometry while a viewport.sync resize is still settling.
        if Date().timeIntervalSince(lastResizeAt) < 3 { return }
        if abs(live.width - w.frame.width) <= 2 && abs(live.height - w.frame.height) <= 2 {
            pendingFrame = nil; pendingCount = 0
            return
        }
        // Require two consecutive readings: window animations and window-server
        // shadow margins otherwise produce a flip-flop of reconfigurations.
        if let p = pendingFrame, abs(p.width - live.width) <= 2, abs(p.height - live.height) <= 2 {
            pendingCount += 1
        } else {
            pendingFrame = live; pendingCount = 1
        }
        guard pendingCount >= 2, live.width >= 120, live.height >= 120 else { return }
        pendingFrame = nil; pendingCount = 0
        let newFrame = CGRect(origin: live.origin, size: live.size)
        currentWindow = WindowInfo(id: w.id, title: w.title, ownerName: w.ownerName,
                                   ownerPID: w.ownerPID, frame: newFrame, scWindow: w.scWindow)
        if sizeOverride == nil { reapply() }
        print("[capture] window resized externally -> \(Int(live.width))x\(Int(live.height))")
    }

    func reapply() { setQuality(scale: lastScale, fps: lastFPS, quality: jpegQuality) }

    /// Re-resolve the window frame after a viewport.sync resize, then re-apply quality
    /// so the stream matches the new window size instead of the old one.
    func refreshWindowFrame() {
        guard let current = currentWindow else { return }
        Task {
            guard let content = try? await shareableContentWithTimeout(),
                  let w = content.windows.first(where: { $0.windowID == current.id }) else { return }
            self.currentWindow = WindowInfo(
                id: w.windowID,
                title: w.title,
                ownerName: w.owningApplication?.applicationName ?? current.ownerName,
                ownerPID: w.owningApplication?.processID ?? current.ownerPID,
                frame: w.frame,
                scWindow: w)
            // With an active size override the stream is already configured for the
            // requested size; re-applying here would just churn updateConfiguration.
            if self.sizeOverride == nil {
                self.setQuality(scale: self.lastScale, fps: self.lastFPS, quality: self.jpegQuality)
            }
            print("[capture] retargeted \(Int(w.frame.width))x\(Int(w.frame.height))")
        }
    }

    func stopCapture() async {
        if let binding { identity?.revokeWindow(binding) }
        let old = lifecycle { () -> SCStream? in
            cancelled = true
            targetWatcher?.cancel(); targetWatcher = nil
            frameWatcher?.cancel(); frameWatcher = nil
            let old = stream; stream = nil; currentWindow = nil; onFrame = nil
            onPixelBuffer = nil; config = nil
            return old
        }
        frameWatcher?.cancel(); frameWatcher = nil
        let driver = lifecycle { () -> CapturePauseDriver? in let value = activityDriver; activityDriver = nil; return value }
        do { if let driver { try await driver.finish() } else { try await old?.stopCapture() } }
        catch {
            // A failed pause transition must not skip the final best-effort native stop.
            try? await old?.stopCapture()
            if let binding { identity?.revokeWindow(binding) }; fputs("[capture] stop failed\n", stderr)
        }
        print("[capture] stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let callback = lifecycle { () -> ((Data) -> Void)? in
            guard self.stream === stream, !cancelled, !outputPaused else { return nil }; return onFrame
        }
        guard let callback else { recordSampleOutcome(.inactive); return }
        guard sampleBuffer.isValid else { recordSampleOutcome(.invalidSample); return }
        // Inspect status even for bufferless idle samples; they never reach the image gates.
        guard #available(macOS 13.1, *),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = info[.status] as? Int else { recordSampleOutcome(.metadata); return }
        guard status == SCFrameStatus.complete.rawValue else {
            recordSampleOutcome(status == SCFrameStatus.idle.rawValue ? .idle : .incomplete); return
        }
        guard let pb = sampleBuffer.imageBuffer else { recordSampleOutcome(.noImage); return }
        // Read immutable SCK sample metadata before conversion or crossing queues.
        guard let timestamp = info[.displayTime] as? NSNumber,
              let screenValue = info[.screenRect] as? [String: Any],
              let screen = CGRect(dictionaryRepresentation: screenValue as CFDictionary),
              let contentValue = info[.contentRect] as? [String: Any],
              let content = CGRect(dictionaryRepresentation: contentValue as CFDictionary),
              let scale = info[.scaleFactor] as? Double,
              let contentScale = info[.contentScale] as? Double,
              (1...4).contains(scale), contentScale.isFinite, contentScale > 0,
              screen.width > 0, screen.height > 0 else { recordSampleOutcome(.metadata); return }
        let size = [CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)]
        let time = timestamp.uint64Value
        let geometry = [Double(screen.minX), Double(screen.minY), Double(screen.width), Double(screen.height), scale]
        // SCK's surface may include padding. Publish only its explicit content rectangle.
        guard geometry.allSatisfy({ $0.isFinite }),
              let crop = JPEGEncoder.contentCrop(screen: screen, content: content, scale: scale,
                                                  contentScale: contentScale, surface: size) else {
            if recordSampleOutcome(.mapping) {
                // One numeric-only diagnostic per controller; never dump attachments or identity.
                let values = geometry + [Double(content.minX), Double(content.minY),
                    Double(content.width), Double(content.height), contentScale,
                    Double(size[0]), Double(size[1])]
                fputs("[capture] mapping geometry=\(values)\n", stderr)
            }
            return
        }
        let ready = lifecycle {
            !cancelled && !outputPaused && !configurationUpdating && self.stream === stream &&
                captureSize == size && time >= configurationSince
        }
        guard ready else { recordSampleOutcome(.configuration); return }
        guard let identity, let binding else { recordSampleOutcome(.authority); return }
        // This only rejects disagreement; live geometry never supplies a sample's provenance.
        let (reader, privacy) = lifecycle { (geometryReader, privacyReader) }
        let (measurement, sensitive) = DispatchQueue.main.sync { (reader?(), privacy?() ?? true) }
        identity.observeSensitiveFocus(sensitive, binding: binding)
        let reading = measurement ?? .failure(PairingSession.GeometryFailure(check: .noReader))
        let live = try? reading.get()
        guard identity.observeGeometry(reading, source: .capture, binding: binding) != nil else {
            recordSampleOutcome(live == nil ? .geometryUnavailable : .authority); return
        }
        guard live == geometry else { recordSampleOutcome(.geometryMismatch); return }
        let edge = lifecycle { maxEdge }
        let publishedSize = JPEGEncoder.scaled(crop.size, maxEdge: edge)
        guard let provenance = identity.frameProvenance(geometry: geometry, size: publishedSize, displayTime: time, binding: binding) else {
            recordSampleOutcome(.provenance); return
        }
        if let data = JPEGEncoder.encode(pb, crop: crop, quality: jpegQuality, maxEdge: edge) {
            lifecycle {
                guard !cancelled, !outputPaused, !configurationUpdating, self.stream === stream,
                      time >= configurationSince, captureSize == size else { recordSampleOutcome(.configuration); return }
                identity.publish(data, size: publishedSize, binding: binding, provenance: provenance)
                // publish is void and may reject a concurrent authority/epoch change.
                recordSampleOutcome(.publicationAttempt)
            }
            frameLock.lock(); frameCount += 1; frameLock.unlock()
            callback(data)
        } else { identity.discardFrames(binding); recordSampleOutcome(.encoding) }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        invalidate()
        fputs("[capture] stream failed\n", stderr)
    }

    var stats: [String: Any] {
        frameLock.lock(); let frames = frameCount; let outcomes = sampleOutcomes; frameLock.unlock()
        return [
            "sampleOutcomes": outcomes,
            "window": currentWindow?.title ?? "",
            "app": currentWindow?.ownerName ?? "",
            "pid": Int(currentWindow?.ownerPID ?? 0),
            "frames": Int(frames),
            "size": [sizeOverride?.width ?? currentWindow?.frame.width ?? 0,
                     sizeOverride?.height ?? currentWindow?.frame.height ?? 0],
        ]
    }
}

import os

enum JPEGEncoder {
    static func contentCrop(screen: CGRect, content: CGRect, scale: Double,
                            contentScale: Double, surface: [Int]) -> CGRect? {
        guard surface.count == 2, surface.allSatisfy({ $0 > 0 }),
              [screen.width, screen.height, content.minX, content.minY, content.width,
               content.height, scale, contentScale].allSatisfy({ $0.isFinite }),
              screen.width > 0, screen.height > 0, (1...4).contains(scale), contentScale > 0,
              abs(screen.width * contentScale - content.width) < 0.01,
              abs(screen.height * contentScale - content.height) < 0.01 else { return nil }
        let crop = CGRect(x: content.minX * scale, y: content.minY * scale,
                          width: content.width * scale, height: content.height * scale)
        // Fractional pixel crops would change the coordinate transform; reject rather than round.
        guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy({ $0.rounded() == $0 }),
              crop.width > 0, crop.height > 0, crop.minX >= 0, crop.minY >= 0,
              crop.maxX <= Double(surface[0]), crop.maxY <= Double(surface[1]) else { return nil }
        return crop
    }

    /// Pixel size of an encoded frame: the crop, shrunk to fit `maxEdge` the way ImageIO's max-pixel-size does.
    static func scaled(_ size: CGSize, maxEdge: Int?) -> [Int] {
        guard let maxEdge, max(size.width, size.height) > CGFloat(maxEdge) else { return [Int(size.width), Int(size.height)] }
        let k = CGFloat(maxEdge) / max(size.width, size.height)
        return [Int((size.width * k).rounded()), Int((size.height * k).rounded())]
    }

    static func encode(_ pixelBuffer: CVPixelBuffer, crop: CGRect, quality: Double = 0.65, maxEdge: Int? = nil) -> Data? {
        var cgImage: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage) == noErr,
              let image = cgImage?.cropping(to: crop) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        // Max pixel size only takes effect per image, not on the destination. Viewer clicks use normalized coordinates.
        CGImageDestinationAddImage(dest, image, maxEdge.map { [kCGImageDestinationImageMaxPixelSize: $0] as CFDictionary })
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

/// Serializes asynchronous SCK stop/start transitions, including teardown during a pending resume.
actor CapturePauseDriver {
    private let transition: (Bool) async throws -> Void
    private var desired = false, paused = false, busy = false, ended = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(transition: @escaping (Bool) async throws -> Void) { self.transition = transition }
    func setPaused(_ value: Bool) async throws {
        desired = ended || value
        if busy { return }
        if let failure { throw failure }
        busy = true
        defer { busy = false; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
        do {
            while paused != desired { let next = desired; try await transition(next); paused = next }
        } catch { failure = error; throw error }
    }
    func finish() async throws {
        ended = true
        try await setPaused(true)
        if busy { await withCheckedContinuation { waiters.append($0) } }
        if let failure { throw failure }
    }
}
