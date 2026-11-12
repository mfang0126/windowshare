import Foundation
import AppKit
import ScriptingBridge

/// Command-line share target. Each picks at most one window; the caller shares only on exactly one match,
/// so a missing window never falls back to another app (except the explicit `--fallback-default-browser`).
enum CLITarget {
    case title(String), app(String), windowID(CGWindowID), titleContains(String), url(String, fallback: Bool), defaultBrowser

    /// Title / ID / title substring: every matching window. App, URL, default browser: the frontmost match only.
    @MainActor func matches(in windows: [WindowInfo]) -> [WindowInfo] {
        switch self {
        case .title(let title): return windows.filter { $0.title == title }
        case .windowID(let id): return windows.filter { $0.id == id }
        case .titleContains(let part): return windows.filter { ($0.title ?? "").localizedCaseInsensitiveContains(part) }
        case .app(let name): return CLI.frontToBack(windows.filter { $0.ownerName == name }).prefix(1).map { $0 }
        case .url(let part, let fallback):
            let found = CLI.frontToBack(Browsers.windows(showing: part, in: windows)).prefix(1).map { $0 }
            return found.isEmpty && fallback ? CLITarget.defaultBrowser.matches(in: windows) : found
        case .defaultBrowser:
            guard let bundle = Browsers.defaultBrowser() else { return [] }
            return CLI.frontToBack(windows.filter { $0.scWindow.owningApplication?.bundleIdentifier == bundle }).prefix(1).map { $0 }
        }
    }
    var label: String {
        switch self {
        case .title(let title): return "window titled \"\(title)\""
        case .app(let name): return "window of app \"\(name)\""
        case .windowID(let id): return "window with id \(id)"
        case .titleContains(let part): return "window whose title contains \"\(part)\""
        case .url(let part, let fallback): return "browser window showing a URL containing \"\(part)\"" + (fallback ? " (or default browser window)" : "")
        case .defaultBrowser: return "window of the default browser"
        }
    }
}

/// Reads each running browser's window names and current-tab URLs over Apple events (first use asks for Automation
/// permission). Never launches a browser, never activates a window.
enum Browsers {
    static let urlPath: [String: String] = [
        "com.google.Chrome": "activeTab.URL", "company.thebrowser.Browser": "activeTab.URL", "com.microsoft.edgemac": "activeTab.URL",
        "com.brave.Browser": "activeTab.URL", "com.apple.Safari": "currentTab.URL"
    ]
    static func defaultBrowser() -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
    private final class Failures: NSObject, SBApplicationDelegate {
        var code: Int?
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? { code = code ?? (error as NSError).code; return nil }
    }
    @MainActor static func windows(showing part: String, in windows: [WindowInfo]) -> [WindowInfo] {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "org.mozilla.firefox").isEmpty {
            fputs("[cli] --url does not support Firefox; its windows are not checked\n", stderr)
        }
        var found: [WindowInfo] = []
        for (bundle, path) in urlPath.sorted(by: { $0.key < $1.key }) {
            // Each instance by pid: `tell application id` reaches only one of several same-bundle instances (e.g. a
            // second Chrome run with --user-data-dir), so the person's own browser could be missed.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                guard let browser = SBApplication(processIdentifier: app.processIdentifier) else { continue }
                let failures = Failures()
                browser.delegate = failures
                // A pending Automation prompt or a hung browser would otherwise block each event for the 2-minute
                // default, overrunning --wait; the prompt stays up and a later poll succeeds once it is allowed.
                browser.timeout = 300 // ticks: 5 s
                let rows = ((browser.value(forKey: "windows") as? SBElementArray) ?? []).compactMap { window -> (name: String, url: String)? in
                    guard failures.code == nil, let window = window as? SBObject,
                          let name = window.value(forKey: "name") as? String, let url = window.value(forKeyPath: path) as? String else { return nil }
                    return (name, url)
                }
                if let code = failures.code {
                    fputs("[cli] cannot read URLs from \(app.localizedName ?? bundle) pid \(app.processIdentifier) (Apple event error \(code)); allow it in System Settings → Privacy & Security → Automation\n", stderr)
                    continue
                }
                // Browser windows map to shareable windows by owner pid + exact title. A title shared by two browser
                // windows is ambiguous (a page can copy another's title), so such windows are never picked by URL.
                let owned = windows.filter { $0.ownerPID == app.processIdentifier }
                for row in rows where row.url.localizedCaseInsensitiveContains(part) {
                    let same = owned.filter { $0.title == row.name }
                    if rows.filter({ $0.name == row.name }).count == 1, same.count == 1 { found += same }
                    else if same.count > 1 || rows.filter({ $0.name == row.name }).count > 1 { fputs("[cli] skipped \(app.localizedName ?? bundle) windows with a duplicate title; use --window-id\n", stderr) }
                }
            }
        }
        return found
    }
}

enum CLI {
    /// On-screen windows front to back (CG lists them in z-order); windows CG does not list go last.
    static func frontToBack(_ windows: [WindowInfo]) -> [WindowInfo] {
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return windows.enumerated().sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }.map(\.element)
    }

    /// `list --json`: shareable windows front to back; `frontmost` marks each app's top window (what `--app` picks).
    /// Metadata only, never window content.
    static func listing(_ windows: [WindowInfo]) -> Data {
        var seen = Set<pid_t>()
        let rows: [[String: Any]] = frontToBack(windows).map { w in
            ["app": w.ownerName, "bundle_id": w.scWindow.owningApplication?.bundleIdentifier ?? "", "pid": Int(w.ownerPID),
             "window_id": Int(w.id), "title": w.title ?? "", "frontmost": seen.insert(w.ownerPID).inserted]
        }
        return (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
    }

    /// `status [--json]`: is a WindowShare running (per agent.json), what it shares, its entry. Exit 0 running, 1 not.
    static func status(json: Bool) -> Never {
        var out: [String: Any] = ["running": false]
        if let file = AgentFile.current(), let pid = file["pid"] as? Int, AgentFile.alive(pid_t(pid)),
           let port = file["port"] as? Int, let token = file["token"] as? String,
           let url = URL(string: "http://127.0.0.1:\(port)/agent/status") {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            var reply: [String: Any]?
            let done = DispatchSemaphore(value: 0)
            URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
                if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                    reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                done.signal()
            }.resume()
            done.wait()
            if let reply {
                // Share links (…/w/<share id>) only while a share is active; the bare host entry never joins one.
                out = ["running": true, "pid": pid, "port": port, "entry": reply["entry"] ?? NSNull(),
                       "entries": reply["entries"] ?? [], "window": reply["window"] ?? NSNull()]
                if let holder = ShareLock.holder() { out["share"] = ["owner": holder.owner, "pid": holder.pid, "started_at": holder.startedAt] }
            }
        }
        if json {
            print(String(decoding: (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self))
        } else if out["running"] as? Bool == true {
            print("running pid=\(out["pid"]!) entries=\((out["entries"] as? [String] ?? []).joined(separator: " "))")
            if let w = out["window"] as? [String: Any] {
                print("sharing window_id=\(w["window_id"] ?? "") app=\(w["app"] ?? "") title=\(w["title"] ?? "") interact=\(w["interact"] as? Bool == true)")
            } else { print("sharing none") }
        } else { print("not running") }
        exit(out["running"] as? Bool == true ? 0 : 1)
    }

    /// The Tailscale address from `tailscale ip -4`; on failure, a message telling the person how to fix it.
    static func tailscaleAddress(tools: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { $0 + "/tailscale" }
            + ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]) -> Result<String, CLIFailure> {
        guard let tool = tools.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failure(CLIFailure("Tailscale not found, so phones outside this LAN cannot connect: install it from https://tailscale.com/download/mac (or brew install --cask tailscale) and sign in."))
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = ["ip", "-4"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        // ponytail: no timeout; a hung tailscaled hangs startup. Add one if that is ever seen.
        guard (try? process.run()) != nil else { return .failure(CLIFailure("cannot run \(tool)")) }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let address = output.split(separator: "\n").map(String.init).first(where: EntryConfiguration.isTailscale) else {
            return .failure(CLIFailure("Tailscale is not connected (tailscale ip -4 failed): open Tailscale and sign in, or run `tailscale up`."))
        }
        return .success(address)
    }
}
struct CLIFailure: Error { let message: String; init(_ message: String) { self.message = message } }
