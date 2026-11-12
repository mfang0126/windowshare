import Foundation
import AppKit
import CoreGraphics

// Local authenticated View/Interact development build; remote control remains disabled.
struct Options {
    var configuration: EntryConfiguration = try! EntryConfiguration()
    var target: CLITarget?
    var interact = false
    var listWindows = false
    var status = false
    var json = false
    var fallbackDefaultBrowser = false
    var wait = 0
    /// Opener (ADR 0003): label shown to others in 「正在被 X 使用」, the process whose exit ends a normal share,
    /// and `--persistent` (持续分享, only when the boss asks) which is not tied to that process.
    var owner: String?
    var ownerPID = getppid()
    var persistent = false
}
// LAN and Tailscale are both on by default (user decision 2026-10-29); the menu switch or --no-lan turns LAN off.
UserDefaults.standard.register(defaults: ["allowLAN": true])
func parseOptions() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    var port: UInt16 = 8777
    var externalOrigin: String?
    var seen = Set<String>()
    var allowLAN = UserDefaults.standard.bool(forKey: "allowLAN") // registered default: true
    func invalid() -> Never { fputs("invalid options\n", stderr); exit(2) }
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--port":
            guard seen.insert("port").inserted, let value = args.first, !value.isEmpty,
                  value.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = UInt16(value),
                  parsed > 0, parsed < UInt16.max else { invalid() }
            port = parsed; args.removeFirst()
        case "--external-origin":
            guard seen.insert("origin").inserted, let value = args.first,
                  EntryConfiguration.validExternalOrigin(value) else { invalid() }
            externalOrigin = value; args.removeFirst()
        case let flag where ["--window", "--app", "--window-id", "--title-contains", "--url"].contains(flag):
            guard seen.insert("target").inserted, let value = args.first, !value.isEmpty, !value.hasPrefix("--") else { invalid() }
            switch flag {
            case "--app": opts.target = .app(value)
            case "--window-id":
                guard value.utf8.allSatisfy({ (48...57).contains($0) }), let id = CGWindowID(value) else { invalid() }
                opts.target = .windowID(id)
            case "--title-contains": opts.target = .titleContains(value)
            case "--url": opts.target = .url(value, fallback: false)
            default: opts.target = .title(value)
            }
            args.removeFirst()
        case "--default-browser":
            guard seen.insert("target").inserted else { invalid() }
            opts.target = .defaultBrowser
        case "--fallback-default-browser": opts.fallbackDefaultBrowser = true
        case "--wait":
            guard seen.insert("wait").inserted, let value = args.first, (1...4).contains(value.count),
                  value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Int(value), (1...600).contains(seconds) else { invalid() }
            opts.wait = seconds; args.removeFirst()
        case "--owner":
            guard seen.insert("owner").inserted, let value = args.first, (1...80).contains(value.count), !value.hasPrefix("--"),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { invalid() }
            opts.owner = value; args.removeFirst()
        case "--owner-pid":
            guard seen.insert("ownerpid").inserted, let value = args.first, (1...10).contains(value.count),
                  value.utf8.allSatisfy({ (48...57).contains($0) }), let pid = Int32(value), pid > 1 else { invalid() }
            opts.ownerPID = pid; args.removeFirst()
        case "--persistent": opts.persistent = true
        case "--interact": opts.interact = true
        case "--list-windows": opts.listWindows = true
        case "list" where seen.isEmpty && !opts.listWindows && !opts.status: opts.listWindows = true
        case "status" where seen.isEmpty && !opts.listWindows && !opts.status: opts.status = true
        case "--json": opts.json = true
        case "--lan": guard seen.insert("lan").inserted else { invalid() }; allowLAN = true
        case "--no-lan": guard seen.insert("lan").inserted else { invalid() }; allowLAN = false
        default: invalid()
        }
    }
    // A share target: the person running it on this Mac is the approval; it listens like the menu flow (Tailscale, LAN unless off).
    if opts.fallbackDefaultBrowser {
        guard case .url(let part, _)? = opts.target else { invalid() }
        opts.target = .url(part, fallback: true)
    }
    guard (opts.owner == nil && !seen.contains("ownerpid") && !opts.persistent) || opts.target != nil,
          !opts.interact || opts.target != nil, opts.target == nil || externalOrigin == nil, opts.wait == 0 || opts.target != nil,
          !opts.json || opts.listWindows || opts.status, !(opts.listWindows || opts.status) || (opts.target == nil && !opts.interact) else { invalid() }
    do { opts.configuration = try EntryConfiguration(port: port, externalOrigin: externalOrigin, allowLAN: allowLAN) }
    catch { invalid() }
    return opts
}
// The share counts from the start command (ADR 0003 rule 2), not from when the window is found (--wait).
let commandStartedAt = ProcessInfo.processInfo.systemUptime
let opts = parseOptions()
if opts.status { CLI.status(json: opts.json) }
// One share per Mac: take the lock before anything slow (Tailscale probe, permissions, listeners), so a second
// request is answered at once with who holds it; no queueing.
if opts.target != nil {
    guard opts.persistent || AgentFile.alive(opts.ownerPID), opts.ownerPID > 1 else {
        fputs("[share] opener process \(opts.ownerPID) is not running; pass --owner-pid <pid> or --persistent\n", stderr); exit(2)
    }
    do { try ShareLock.acquire(owner: opts.owner ?? ShareOwner.label(pid: opts.ownerPID), persistent: opts.persistent) }
    catch let busy as ShareLock.Busy { print("[share] busy: \(busy.message())"); fflush(stdout); exit(ShareLock.busyExit) }
    catch { fputs("[share] lock unavailable\n", stderr); exit(2) }
    print("[share] opener=\(opts.persistent ? "persistent" : "pid \(opts.ownerPID)")"); fflush(stdout)
}
// Print every phone entry. No Tailscale is a warning while a LAN entry exists; with neither the CLI share exits 6.
if !opts.listWindows, !opts.configuration.proxied {
    if case .failure(let failure) = CLI.tailscaleAddress() { fputs("[cli] warning: \(failure.message)\n", stderr) }
    // The per-share links are printed once the share exists (MenuBarController); bare entries never join a share.
    let entries = opts.configuration.entries()
    if entries.isEmpty, opts.target != nil {
        fputs("[cli] no phone entry: neither Tailscale nor a LAN address is available\(opts.configuration.allowLAN ? "" : " (LAN is off)")\n", stderr); exit(6)
    }
}

_ = NSApplication.shared
fputs("[startup] accessibility_trusted=\(AXIsProcessTrusted()) post_event_access=\(CGPreflightPostEventAccess())\n", stderr)
fputs("[startup] screen_capture_preflight=\(CGPreflightScreenCaptureAccess())\n", stderr)
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
fputs("[startup] screen_capture_after_request=\(CGPreflightScreenCaptureAccess())\n", stderr)
fputs("[startup] m2a_off=\(Tuning.off.sorted().joined(separator: ","))\n", stderr)
if opts.listWindows {
    Task {
        do {
            let windows = try await CaptureController().listWindows()
            if opts.json { print(String(decoding: CLI.listing(windows), as: UTF8.self)) }
            else { for window in windows { print("\(window.id)\t\(window.ownerName)\t\(window.title ?? "")") } }
            exit(0)
        } catch { fputs("window listing failed\n", stderr); exit(1) }
    }
    dispatchMain()
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menu = MenuBarController(configuration: opts.configuration, autoShare: opts.target.map { ($0, opts.interact, opts.wait, commandStartedAt) })
app.delegate = menu
// The opener's exit ends only the share it started; a share opened from the menu afterwards is not tied to it (N3).
if opts.target != nil { menu.watchOpener(pid: opts.ownerPID, persistent: opts.persistent) }
// SIGTERM/SIGINT/SIGHUP go through applicationWillTerminate, which detaches input (releasing held buttons) and revokes the window.
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN)
let terminators = [SIGTERM, SIGINT, SIGHUP].map { sig -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }; source.resume(); return source
}
withExtendedLifetime(terminators) { app.run() }
