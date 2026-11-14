# WindowShare

English | [中文](README.zh-CN.md)

Share one app window from your Mac to a phone on the same Tailscale network or the same LAN with one command. Tap **开启 Interact** (Enable Interact) on the phone to click and type in that window, for example to enter a username and password yourself.

> **Release status: v1, source only**, under the [MIT License](LICENSE). No prebuilt app is published, and the app is not Developer ID signed or notarized. Build it locally with your own certificate as described below. Requires macOS 13 or later (tested only on macOS 26). The phone side is any modern browser (tested on Android Chrome).

The phone viewer and menu are in Chinese; English labels are given in parentheses below.

## Install

1. Have a code-signing certificate in your keychain and get its SHA-1: `security find-identity -v -p codesigning`.
2. Build: `WINDOWSHARE_SIGNING_IDENTITY=<40-character SHA-1> ./Scripts/build-app.sh release`. The result is `build/WindowShareHost.app`.
3. Drag it into `/Applications` and open it.

Always sign with the same certificate: macOS ties Screen Recording and Accessibility permissions to the code signature. An ad-hoc signature changes on every build, so you would have to grant the permissions again. A release build without a certificate fails; it never falls back to ad-hoc.

## First use

1. System Settings → Privacy & Security: allow WindowShare under **Screen Recording** and **Accessibility**, then restart the app.
2. Sign the Mac and the phone in to the same Tailscale network (at home on the same Wi-Fi you can also use the LAN entry).
3. Menu bar → WindowShare → **选择受控窗口…** (choose window) and pick the window to share.
4. On the phone, open the **手机入口：http://…** (phone entry) link shown in the menu.
5. The viewer is read-only by default. To operate the window, tap **开启 Interact**, then tap and scroll.
6. To type text (Chinese included), tap **键盘 / 中文输入** (keyboard / Chinese input). The target app must be frontmost.
7. When done, choose **完成（结束共享）** (done, end share) in the menu. **完成** on the phone's request card also ends the share.

## Agent usage

When an agent is stuck on a step that needs a person:

```
Scripts/windowshare-show --reason "Need to sign in to AWS" [--timeout 300]
```

It prints the phone link and waits until the person taps **完成** (done) on the phone. Exit codes:

- `0` the person finished
- `3` the person cancelled
- `4` timed out
- `5` no window is shared (choose one in the menu bar first)
- `2` other error (app not running, and so on)

See `skills/windowshare-show/SKILL.md` for the agent skill.

## Command line

An agent or a terminal can share a window directly. There is no confirmation dialog: running the command is the approval. `Scripts/windowshare` finds `$WINDOWSHARE_APP`, the repo's `build/WindowShareHost.app` or `/Applications/WindowShareHost.app`, runs it and returns its exit code:

```
Scripts/windowshare list [--json]                         # shareable windows, front to back
Scripts/windowshare status [--json]                       # running? which window? phone links
Scripts/windowshare --app "Google Chrome" --interact      # share the app's frontmost window, allow phone input
Scripts/windowshare --window "ws-h1-test.txt"             # share by exact title, view only
Scripts/windowshare --url console.aws.amazon.com --wait 30 --interact   # wait until a browser shows this URL, then share
```

Window selection (use exactly one):

| Option | Window |
|---|---|
| `--window "<title>"` | Exact title; must match exactly one window |
| `--title-contains <text>` | Title contains the text; must match exactly one window |
| `--window-id <id>` | Window ID from `list` |
| `--app "<app name>"` | The app's frontmost window (app name as `list` prints it) |
| `--url <text>` | Frontmost Chrome, Arc, Safari, Edge or Brave window whose current tab URL contains the text. The first use shows the macOS Automation permission prompt. Firefox is not supported. Refused when several windows share the title. Falls back to the default browser only with `--fallback-default-browser` |
| `--default-browser` | The default browser's frontmost window |

`--wait <seconds>` (1–600) retries once a second until the window appears or time runs out. When nothing matches, the exit code is 3 and stderr lists every shareable window as `list --json`.

- `list`: text output is `window ID, app, title` per line; `--json` items have `app`, `bundle_id`, `pid`, `window_id`, `title`, `frontmost` (the app's frontmost window, the one `--app` picks). Metadata only, no pixels.
- `status`: reads `agent.json` to find the running instance and asks it. Exit code `0` running, `1` not running. `--json` looks like `{"running":true,"pid":…,"port":8777,"entry":"http://100.x.y.z:8777/w/<share id>","entries":[…],"window":{"window_id":…,"app":…,"pid":…,"title":…,"interact":true}}`; `window` is `null` when nothing is shared.
- No match exits with code 3; it never falls back to another window or app. Window found but capture failed: exit code 4. Bad arguments: exit code 2.
- Share links: once the window is chosen, every phone link of this share is printed, one per line, for example `[cli] entry tailscale=http://100.x.y.z:8777/w/<share id>` and `[cli] entry lan=http://192.168.x.y:8777/w/<share id>`. A link belongs to one share and stops working as soon as the share ends (the page shows 共享链接已失效, "share link expired"). The bare root `http://…:8777/` never joins a share. Tailscale and LAN are both on by default.
- Tailscale is detected with `tailscale ip -4` (looked up in PATH, `/opt/homebrew/bin`, `/usr/local/bin` and `/Applications/Tailscale.app`). When it is missing or not connected, a warning with install or sign-in hints is printed and the LAN entry is used. With neither Tailscale nor LAN available, a command-line share exits with code 6. Port in use: exit code 7.
- LAN: allowed by default on a new install. Turn it off in the menu (**允许局域网访问**, allow LAN access); `--no-lan` turns it off and `--lan` turns it on for one run. Only private-range peers are accepted (10/8, 172.16/12, 192.168/16, 169.254/16, IPv6 fc00::/7, fe80::/10); public addresses are always refused.
- View only by default: without `--interact`, every click and keystroke from the phone is refused.
- On SIGTERM, SIGHUP or Ctrl-C it releases all held keys and drags, revokes the window and exits. SIGKILL cannot be handled.
- Risk: any program on the Mac, agents included, can share any window with this command, and any device that can reach the entry on the Tailscale network or the same LAN can see it. This was an explicit user decision (2026-10-27 and 2026-10-29).
- One share at a time ([ADR 0003](docs/adr/0003-share-lifecycle.md)): one Mac-wide lock, `~/Library/Application Support/WindowShare/share.lock`, whatever the port. A second request exits at once with code `8` and prints `[share] busy: 正在被 <opener> 使用（pid …，已开 N 小时 M 分钟）` ("in use by <opener>, pid …, open for N h M min"). There is no queue. `--owner "<name>"` sets the opener name (default: parent process name and pid).
- While the menu bar app is running idle, a command-line share takes over `agent.json` for its duration and hands it back when it exits, so `status` and `windowshare-show` find the menu bar app again. The taken-over registration is kept in `agent.json` itself, so this also holds when a second share starts while the first is still in its 10-second exit wait (whichever exits first), and a menu bar app that quits meanwhile is not written back. If a share is killed with SIGKILL, its stale registration stays in `agent.json`; `status` and `windowshare-show` skip it and use the menu bar app it took over, and the next share hands the file back to it. Known limit: a process is treated as alive by pid only, so a reused pid of an exited host is not detected.
- Opener lifetime: a normal share ends when its opener process exits (the parent process by default, or `--owner-pid <pid>`), and the host exits with it. `--persistent` (only when the user asks for it) does not end with the opener. Every share ends after 12 hours; 10 minutes before, it prints `[share] reminder ends_in_sec=600 reason=limit`, and at the end `[share] ended reason=limit|opener_exit`.

## Tests

Run from the repo root. They use temporary directories, temporary ports and child processes only; no real window is captured and no mouse or keyboard input is sent:

```
swiftc -parse-as-library host/Sources/{CaptureController,InputController,PairingSession,ViewerPage,EntryConfiguration,AgentRequest}.swift Scripts/verify-share-lifecycle.swift -o /tmp/verify-share-lifecycle && /tmp/verify-share-lifecycle
swiftc -parse-as-library host/Sources/{CaptureController,InputController,PairingSession,ViewerPage,EntryConfiguration,AgentRequest}.swift Scripts/verify-lifecycle.swift -o /tmp/verify-lifecycle && /tmp/verify-lifecycle
python3 Scripts/verify-share-ending.py
python3 Scripts/verify-direct-entry.py
python3 Scripts/verify-cleanup-lifetime.py
python3 Scripts/verify-view-recovery.py
python3 Scripts/verify-windowshare-show.py
python3 Scripts/verify-host-close.py
python3 Scripts/verify-geometry-diagnostics.py
```

The old `Scripts/verify-morning.sh` checked `/status.json` and `/snapshot.jpg`, which no longer exist; it was removed on 2026-11-13. To check whether the host is running and what it shares, use `Scripts/windowshare status --json`.

## Latency

Phone tap to visible change (`Scripts/latency-run.mjs`, same Wi-Fi over Tailscale, 1000×800 window, 2026-10-30): v1 p50 about 93 ms, p95 about 185 ms; before M2 it was p50 422 ms, p95 677 ms.

How: in Interact mode the viewer long-polls for the next frame instead of waiting 250 ms after each snapshot; capture runs at 60 fps; frames are sent at 1x size, long edge at most 768 px, JPEG quality 0.4. 12 px text is still readable on the phone. These apply only in Interact mode; view-only mode keeps 2x detail at 15 fps.

Each change can be switched off for comparison: `WINDOWSHARE_M2A_OFF=push,fps,input,small,q4,cap`; `all` restores the pre-M2 behavior. Measurement method: `PLAN.md` (延迟测量方法) and `docs/m2-phone-test.md`.

## Known behavior

- After a window is shared from the menu bar, tapping **开启 Interact** on the phone is enough; the Mac does not ask for each action.
- Command-line shares show no confirmation dialog (see Command line).
- If WindowShare is force-killed (crash, `kill -9`) it cannot release input; a mouse button held from the phone at that moment stays down until the next real click. Normal quit, Ctrl-C, SIGTERM and SIGHUP release everything first.
- Revoking control clears modifier key state once; if you are holding ⌘ or another key on the Mac at that moment, press it again.
- With the Dock set to auto-hide, a phone tap at the screen edge can land on the Dock as it slides out.
- After a network drop or a frame timeout the viewer reconnects and shows 重连中 (reconnecting). A drop ends control; after recovery the viewer is read-only again until you tap **开启 Interact**.
- Window identification uses the private macOS call `_AXUIElementGetWindow`. If a future macOS breaks it, keyboard and text input are refused rather than sent to another window.

## LAN access risk

**允许局域网访问（重启后生效）** (allow LAN access, applies after restart) is on by default (user decision 2026-10-29). While it is on, anyone on the same network can see the shared window and ask for control, and LAN input is not encrypted. The Tailscale path is encrypted. On untrusted networks (cafés, hotel Wi-Fi), turn it off in the menu or pass `--no-lan`.

## Troubleshooting

- No picture: check the Screen Recording permission; check that the shared window is still open; choose the window again.
- Taps do nothing: check the Accessibility permission; check that Interact is on; for typing, the target app must be frontmost. Taps on a spot covered by another window are refused (log `stage=hit`); bring the shared window to the front.
- `--url` finds no window: System Settings → Privacy & Security → Automation, allow WindowShare to control that browser.
- Tailscale link fails but LAN works: the phone's Tailscale app may have been stopped by battery saving; open it so it reconnects.
- Phone cannot open the link: for the Tailscale entry, both the Mac and the phone must be connected to Tailscale; for the LAN entry, the phone must be on the same Wi-Fi. The menu line 未找到 Tailscale 或局域网地址：仅本机可访问 means neither path is available.

## License

[MIT](LICENSE)
