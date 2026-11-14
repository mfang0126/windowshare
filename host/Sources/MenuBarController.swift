import Foundation
import AppKit

/// Local window selection and sharing lifecycle.
final class MenuBarController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let configuration: EntryConfiguration
    private let identity = PairingSession()
    private lazy var server = HTTPServer(identity: identity)
    private var capture: CaptureController?
    private var control: ControlServer?
    private func stopControl() {
        // Detach synchronously cleans the old attachment before replacing its handler.
        control?.setInput(nil)
    }
    private var selection: PairingSession.Binding?
    private var lastEnded: PairingSession.Binding? // the share whose CLI exit is pending (N2)
    private var targetLabel = ""
    private var workspaceObservers: [NSObjectProtocol] = []
    private var unavailable = Set<Notification.Name>()

    private func observeAvailability() {
        let center = NSWorkspace.shared.notificationCenter
        let transitions: [(Notification.Name, Notification.Name)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
        ]
        for (off, on) in transitions {
            workspaceObservers.append(center.addObserver(forName: off, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.unavailable.insert(off)
                self.endShare(self.selection, reason: "unavailable")
            })
            workspaceObservers.append(center.addObserver(forName: on, object: nil, queue: .main) { [weak self] _ in
                self?.unavailable.remove(off)
                self?.rebuildMenu()
            })
        }
    }
    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// `--window <exact title>` / `--app <name>` [`--interact`]: share that one window at launch; nil for the menu flow.
    /// `startedAt`: when the start command ran (systemUptime), so the 12-hour limit counts from it (ADR 0003 rule 2).
    private let autoShare: (target: CLITarget, interact: Bool, wait: Int, startedAt: TimeInterval)?
    init(configuration: EntryConfiguration, autoShare: (target: CLITarget, interact: Bool, wait: Int, startedAt: TimeInterval)? = nil) {
        self.configuration = configuration
        self.autoShare = autoShare
        super.init()
        observeAvailability() // Before NSApplication launch delivers inactive-session notifications.
        observeShare()
        statusItem.button?.title = "WS Dev"
        statusItem.button?.toolTip = "WindowShare · 本机 View / Interact 开发验证"
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let nextControl = ControlServer(configuration: configuration, input: nil, identity: identity)
        do {
            try nextControl.start()
            try server.start(configuration: configuration)
            control = nextControl
        } catch {
            nextControl.stop()
            fputs("[menu] listener bind failed (port \(configuration.port) or \(configuration.controlPort) in use?)\n", stderr)
            if autoShare != nil { exit(7) } // the CLI caller needs a failure code, not a clean exit
            NSApp.terminate(nil); return
        }
        publishAgentFile()
        rebuildMenu()
        guard let autoShare else { openBrowser(); return }
        Task { @MainActor in
            // Running the command is the approval (user decision 2026-10-27, INTENT.md): any local process can
            // share any window to the Tailscale network this way. Exactly one match; --wait polls once a second.
            let deadline = Date().addingTimeInterval(TimeInterval(autoShare.wait))
            var windows: [WindowInfo] = [], matches: [WindowInfo] = []
            while true {
                windows = (try? await CaptureController().listWindows()) ?? []
                matches = autoShare.target.matches(in: windows)
                if matches.count == 1 || Date() >= deadline { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard matches.count == 1, let target = matches.first else {
                fputs("[cli] need exactly one \(autoShare.target.label), found \(matches.count); shareable windows (list --json):\n", stderr)
                fputs(String(decoding: CLI.listing(windows), as: UTF8.self) + "\n", stderr)
                AgentFile.remove(); control?.stop(); exit(3)
            }
            guard let binding = share(target, input: autoShare.interact, startedAt: autoShare.startedAt) else { AgentFile.remove(); control?.stop(); exit(4) }
            for entry in configuration.entries() {
                print("[cli] entry \(EntryConfiguration.isTailscale(URL(string: entry)?.host ?? "") ? "tailscale" : "lan")=\(PairingSession.shareLink(entry, binding))")
            }
            print("[cli] sharing window id=\(target.id) owner=\(target.ownerName) title=\(target.title ?? "") interact=\(autoShare.interact) entry=\(PairingSession.shareLink(phoneEntry, binding))")
            fflush(stdout)
        }
    }
    private var phoneEntry: String { configuration.entries().first ?? "http://localhost:\(configuration.port)/" }
    private func publishAgentFile() {
        let entry = phoneEntry
        do {
            guard let token = AgentFile.newToken() else { throw NSError(domain: "WindowShare.Agent", code: 2) }
            try AgentFile.write(port: configuration.port, token: token, entry: entry, entries: configuration.entries())
            identity.configureAgent(token: token, entry: entry, entries: configuration.entries())
        } catch AgentFile.Failure.ownedByOther(let pid) {
            fputs("[agent] agent.json belongs to running instance pid=\(pid); windowshare-show and status will not see this instance\n", stderr)
        } catch { fputs("[agent] config unavailable\n", stderr) }
    }
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }
    private func rebuildMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        if !unavailable.isEmpty {
            menu.addItem(NSMenuItem(title: "本机会话暂不可用，请恢复后重新选择窗口", action: nil, keyEquivalent: ""))
        } else if selection != nil {
            add("完成（结束共享）", #selector(finishSharing), to: menu)
        } else {
            add("选择受控窗口…", #selector(loadWindows), to: menu)
        }
        add("打开开发观看页", #selector(openBrowser), to: menu)
        menu.addItem(.separator())
        let entries = configuration.entries()
        let link = { (entry: String) in self.selection.map { PairingSession.shareLink(entry, $0) } ?? entry }
        var lines = configuration.proxied ? ["入口：\(link(configuration.origin))"]
            : entries.isEmpty ? ["未找到 Tailscale 或局域网地址：仅本机可访问"] : entries.map { "手机入口：\(link($0))" }
        if configuration.allowLAN && !configuration.proxied { lines.append("⚠ 局域网开放：同网络的人都能看到并申请操作，输入不加密") }
        for line in lines { let item = NSMenuItem(title: line, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        if !configuration.proxied {
            let lan = NSMenuItem(title: "允许局域网访问（重启后生效）", action: #selector(toggleLAN), keyEquivalent: "")
            lan.target = self; lan.state = UserDefaults.standard.bool(forKey: "allowLAN") ? .on : .off; menu.addItem(lan)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    @objc private func loadWindows() {
        Task { @MainActor in
            let windows = (try? await CaptureController().listWindows()) ?? []
            guard selection == nil, unavailable.isEmpty else { return }
            let menu = NSMenu(); menu.autoenablesItems = false
            for window in windows.prefix(30) {
                let item = NSMenuItem(title: "\(window.ownerName) — \(window.title ?? "")", action: #selector(shareWindow(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = window; menu.addItem(item)
            }
            add("返回", #selector(resetMenu), to: menu)
            statusItem.menu = menu; statusItem.button?.performClick(nil)
        }
    }
    @objc private func resetMenu() { rebuildMenu() }
    @objc private func toggleLAN() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "allowLAN"), forKey: "allowLAN"); rebuildMenu()
    }
    @objc private func shareWindow(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? WindowInfo else { return }
        if share(target, input: true) != nil { dropOpenerWatch() } // the menu share is the boss's, not the CLI opener's
    }
    /// Starts a new share (new link). nil when unavailable or another share holds the Mac-wide lock.
    @discardableResult private func share(_ target: WindowInfo, input: Bool, startedAt: TimeInterval? = nil) -> PairingSession.Binding? {
        guard unavailable.isEmpty else { return nil }
        do { try ShareLock.acquire(owner: "Mac 菜单栏（老板）") } // no-op when this process already holds it (CLI start)
        catch let busy as ShareLock.Busy { print("[share] busy: \(busy.message())"); show("WindowShare", busy.message()); return nil }
        catch { show("WindowShare", "共享锁不可用"); return nil }
        // An idle instance may still own agent.json; the share that holds the lock takes it over (R2).
        if AgentFile.read()?["pid"] as? Int != Int(getpid()) { publishAgentFile() }
        identity.revokeWindow()
        stopControl()
        let old = capture
        let binding = identity.selectWindow(startedAt: startedAt)
        selection = binding
        targetLabel = "\(target.ownerName) — \(target.title ?? "")"
        identity.configureAgentWindow(["window_id": Int(target.id), "app": target.ownerName, "pid": Int(target.ownerPID), "title": target.title ?? "", "interact": input])
        let next = CaptureController(identity: identity, binding: binding)
        next.onInvalidated = { [weak self] in
            DispatchQueue.main.async { self?.endShare(binding, reason: "window_closed") }
        }
        capture = next; rebuildMenu()
        Task { @MainActor in
            await old?.stopCapture()
            do {
                try await next.startCapture(target) { _ in }
                guard identity.isCurrent(binding) else { await next.stopCapture(); return }
                let nextInput = InputController(window: target)
                next.liveFrameProvider = { nextInput.liveRect() }
                next.startFrameWatcher()
                if input { control?.setInput(nextInput) }
                identity.observeInteract { [weak next] on in next?.setInteract(on) }
                rebuildMenu()
            } catch {
                let failure = error as NSError
                fputs("[menu] capture failed domain=\(failure.domain) code=\(failure.code)\n", stderr)
                identity.revokeWindow(binding)
                if selection == binding { stopSharing() }
                fputs("[menu] capture failed\n", stderr)
                if autoShare != nil { AgentFile.remove(); control?.stop(); exit(4) }
            }
        }
        return binding
    }
    @objc private func finishSharing() { endShare(selection, reason: "boss") }
    private func stopSharing() {
        identity.revokeWindow() // stop accepting output synchronously, before asynchronous SCK stop
        stopControl()
        let old = capture; capture = nil; selection = nil; targetLabel = ""; rebuildMenu()
        ShareLock.release() // ended: the link is already dead (revokeWindow) and the next share is a new one
        Task { await old?.stopCapture() }
    }
    /// The one end path (ADR 0003 rule 2/4/5) for 「完成」, the limit, a closed window, sleep/lock and the menu:
    /// acts only on the share that produced the event, never a newer one (R1); prints the event for the opener.
    private func endShare(_ binding: PairingSession.Binding?, reason: String) {
        guard let binding, selection == binding else { return }
        print("[share] ended reason=\(reason)"); fflush(stdout)
        dropOpenerWatch() // the opener's share is over: its exit must not end a later one (N3)
        // Revoke frames and input first (P2-2): the close-1001 wait below may only delay transport cleanup, never the share.
        stopSharing()
        // A CLI share exits at once (except 「完成」, whose 10 s grace answers 410): wait for the viewers' 1001 handshakes,
        // which revokeWindow already started through ControlServer.close.
        if autoShare != nil, reason != "done" { control?.stop() }
        guard autoShare != nil else { return }
        // One CLI process is one share: exit so it keeps neither the port nor agent.json (R2). After 「完成」 wait
        // so windowshare-show (polls every 2 s) can still read `done`.
        // ponytail: fixed 10 s grace; hand off on the agent's read if polling ever gets slower.
        lastEnded = binding
        DispatchQueue.main.asyncAfter(deadline: .now() + (reason == "done" ? 10 : 0)) { [weak self] in
            // Only while no share started after this one (N2): a share opened from the menu in the grace owns the process.
            guard let self, self.selection == nil, self.lastEnded == binding else { return }
            NSApp.terminate(nil)
        }
    }
    /// CLI share (ADR 0003): the opener's exit ends the process, but only while that opener's share is still the one
    /// running (or still being started); dropped when it ends or a menu share takes over.
    private var openerWatch: DispatchSourceProcess?
    func watchOpener(pid: pid_t, persistent: Bool) {
        openerWatch = ShareOwner.watch(pid: pid, persistent: persistent) { [weak self] in
            guard self?.openerWatch != nil else { return } // dropped: an exit event already queued must not end a later share
            print("[share] ended reason=opener_exit pid=\(pid)"); fflush(stdout)
            NSApp.terminate(nil)
        }
    }
    private func dropOpenerWatch() { openerWatch?.cancel(); openerWatch = nil }
    /// 12-hour limit: remind 10 minutes ahead, then end; 「完成」 in the viewer ends too. Only for the share they belong to.
    private func observeShare() {
        identity.observeShare { [weak self] event, binding in
            DispatchQueue.main.async {
                guard let self, self.selection == binding else { return }
                if event == "reminder" {
                    print("[share] reminder ends_in_sec=\(Int(PairingSession.shareWarning)) reason=limit"); fflush(stdout); return
                }
                self.endShare(binding, reason: event)
            }
        }
    }
    private func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "好"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc private func openBrowser() {
        NSWorkspace.shared.open(selection.flatMap { URL(string: PairingSession.shareLink(configuration.origin, $0)) } ?? configuration.entryURL)
    }
    func applicationWillTerminate(_ notification: Notification) { AgentFile.remove(); stopControl(); identity.revokeWindow(); control?.stop() }
}
