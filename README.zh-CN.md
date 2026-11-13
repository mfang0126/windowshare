# WindowShare

[English](README.md) | 中文

一条命令把 Mac 上某个 app 的窗口共享到同一 Tailscale 网络或同一局域网里的手机；手机上点「开启 Interact」就能点击、输入，比如自己输入用户名和密码。

> **发布状态：v1，只发源码**，[MIT 许可](LICENSE)。不提供预编译的 App，没有 Developer ID 签名或公证；按下文用自己的证书在本机构建。要求 macOS 13 以上（只在 macOS 26 上实测过），手机端用任意现代浏览器（实测 Android Chrome）。

## 安装

1. 在钥匙串里准备一个代码签名证书，取 SHA1：`security find-identity -v -p codesigning`。
2. 构建：`WINDOWSHARE_SIGNING_IDENTITY=<40 位 SHA1> ./Scripts/build-app.sh release`，产物是 `build/WindowShareHost.app`。
3. 拖进 `/Applications` 并打开。

必须用固定证书签名：macOS 的屏幕录制和辅助功能授权绑定代码签名。ad-hoc 签名每次重新构建都会失效，要重新授权。release 构建没有设置证书会直接报错，不会回退到 ad-hoc。

## 首次使用

1. 系统设置 → 隐私与安全性：给 WindowShare 开「屏幕录制」和「辅助功能」，然后重启 app。
2. Mac 和手机都登录同一个 Tailscale 网络（在家同一个 Wi-Fi 下也可以直接用局域网入口）。
3. 菜单栏点 WindowShare →「选择受控窗口…」，选要共享的窗口。
4. 手机浏览器打开菜单里显示的「手机入口：http://…」。
5. 默认只读。需要操作时点页面上的「开启 Interact」，再点击、滚动。
6. 输入文字（含中文）：点「键盘 / 中文输入」打开键盘面板。目标 App 必须在最前面。
7. 用完点菜单里的「完成（结束共享）」；手机上请求卡片的「完成」也会结束这次共享。

## Agent 用法

agent 卡在需要人的步骤时：

```
Scripts/windowshare-show --reason "需要登录 AWS" [--timeout 300]
```

命令打印「请在手机打开：<入口>」，等人在手机上点完成。退出码：

- `0` 人已完成
- `3` 人取消
- `4` 超时
- `5` 没有共享窗口（先在菜单栏选窗口）
- `2` 其他错误（app 未运行等）

skill 说明见 `skills/windowshare-show/SKILL.md`。

## 命令行启动

agent 或终端直接共享窗口，不弹确认框，运行命令就等于批准。`Scripts/windowshare` 会找到 `$WINDOWSHARE_APP`、仓库里的 `build/WindowShareHost.app` 或 `/Applications/WindowShareHost.app` 并直接运行，退出码原样返回：

```
Scripts/windowshare list [--json]                         # 列出可共享窗口，从最前到最后
Scripts/windowshare status [--json]                       # 是否在运行、在共享哪个窗口、手机入口
Scripts/windowshare --app "Google Chrome" --interact      # 共享该 app 最前面的窗口，允许手机操作
Scripts/windowshare --window "ws-h1-test.txt"             # 按精确标题共享，只看
Scripts/windowshare --url console.aws.amazon.com --wait 30 --interact   # 等浏览器打开这个网址再共享
```

选窗口的参数（只能用一个）：

| 参数 | 选哪个窗口 |
|---|---|
| `--window "<标题>"` | 标题精确匹配，必须正好一个 |
| `--title-contains <片段>` | 标题包含片段，必须正好一个 |
| `--window-id <id>` | `list` 里的窗口 ID |
| `--app "<App 名>"` | 该 app 最前面的窗口（App 名按 `list` 的写法） |
| `--url <片段>` | Chrome、Arc、Safari、Edge、Brave 当前标签页网址含该片段的窗口，取最前面的。第一次用会弹 macOS「自动化」权限框。Firefox 不支持。同名窗口有多个时拒绝。加 `--fallback-default-browser` 才会在找不到时退到默认浏览器 |
| `--default-browser` | 系统默认浏览器最前面的窗口 |

`--wait <秒>`（1–600）每秒重找一次，直到窗口出现或超时。找不到时退出码 3，stderr 里打印 `list --json` 的全部可共享窗口。

- `list`：文本格式每行 `窗口 ID、App、标题`；`--json` 每项有 `app`、`bundle_id`、`pid`、`window_id`、`title`、`frontmost`（该 app 最前面的窗口，也就是 `--app` 会选的那个）。只有元数据，不含画面。
- `status`：读 `agent.json` 找到正在运行的实例并询问它。退出码 `0` 在运行，`1` 没运行。`--json` 形如 `{"running":true,"pid":…,"port":8777,"entry":"http://100.x.y.z:8777/w/<共享 id>","entries":[…],"window":{"window_id":…,"app":…,"pid":…,"title":…,"interact":true}}`，没在共享时 `window` 为 `null`。
- 没匹配上就报错退出（退出码 3），不会改抓别的窗口或 app。窗口找到但捕获失败退出码 4，参数错误退出码 2。
- 共享链接：选好窗口后打印本次共享的全部手机链接，每行一个，例如 `[cli] entry tailscale=http://100.x.y.z:8777/w/<共享 id>` 和 `[cli] entry lan=http://192.168.x.y:8777/w/<共享 id>`。链接只属于这次共享，结束后立即失效（打开显示「共享链接已失效」），根地址 `http://…:8777/` 不会进入任何共享。Tailscale 和局域网默认都开。
- Tailscale 用 `tailscale ip -4` 检测（在 PATH、`/opt/homebrew/bin`、`/usr/local/bin`、`/Applications/Tailscale.app` 里找）。没装或没连上时只打印警告和安装 / 登录提示，继续用局域网入口。Tailscale 和局域网都不可用时，命令行共享报错退出（退出码 6）。端口被占时退出码 7。
- 局域网：新装默认允许。菜单里的「允许局域网访问」可以关掉；命令行 `--no-lan` 只关这一次，`--lan` 只开这一次。只接受私有网段（10/8、172.16/12、192.168/16、169.254/16、IPv6 fc00::/7、fe80::/10）的对端，公网地址一律拒绝。
- 默认只看；不加 `--interact` 时，手机上的点击和输入一律被拒绝。
- 收到 SIGTERM、SIGHUP 或 Ctrl-C 时，松开所有按键和拖动，撤销窗口后退出。SIGKILL 无法处理。
- 风险：本机任何程序（包括 agent）都能用这个命令共享任意窗口，Tailscale 网络里、同一局域网里能访问入口的设备都能看到画面。这是用户 2026-10-27 和 2026-10-29 的决定。
- 同一时间只有一个共享（ADR 0003）：全机一把锁 `~/Library/Application Support/WindowShare/share.lock`，与端口无关。已有共享时再申请，立即退出码 `8`，打印 `[share] busy: 正在被 <开启者> 使用（pid …，已开 N 小时 M 分钟）`，不排队。`--owner "<名字>"` 设开启者名称（默认是父进程名和 pid）。
- 菜单栏 app 一直开着、空闲时，CLI 共享会临时接管 `agent.json`，结束退出时交还给菜单栏 app，`status` 和 `windowshare-show` 随后又能找到它。被接管的登记记在 `agent.json` 里，不只在进程内存里：第一个共享还在退出前的 10 秒等待时就开始第二个共享，不管谁先退出，最后都会交还给菜单栏 app；这期间菜单栏 app 退出，也不会被写回。共享被 SIGKILL 时，它的旧登记会留在 `agent.json`；`status` 和 `windowshare-show` 会跳过它，改用它接管过的菜单栏 app，下一个共享结束时也会把文件交还给菜单栏 app。已知限制：只按 pid 判断进程是否还在，已退出 host 的 pid 被系统复用时识别不出来。
- 开启者生命周期：普通共享在开启进程（默认父进程，`--owner-pid <pid>` 指定）退出时结束，host 随之退出；`--persistent`（持续分享，用户要求时才用）不随它结束。所有共享 12 小时到点结束，提前 10 分钟打印 `[share] reminder ends_in_sec=600 reason=limit`，结束时打印 `[share] ended reason=limit|opener_exit`。

## 测试

都在仓库根目录运行，只用临时目录、临时端口和子进程，不抓真实窗口、不动鼠标键盘：

```
swiftc -parse-as-library host/Sources/{CaptureController,InputController,PairingSession,ViewerPage,EntryConfiguration,AgentRequest}.swift Scripts/verify-share-lifecycle.swift -o /tmp/verify-share-lifecycle && /tmp/verify-share-lifecycle
swiftc -parse-as-library host/Sources/{CaptureController,InputController,PairingSession,ViewerPage,EntryConfiguration,AgentRequest}.swift Scripts/verify-lifecycle.swift -o /tmp/verify-lifecycle && /tmp/verify-lifecycle
python3 Scripts/verify-share-ending.py
python3 Scripts/verify-direct-entry.py
python3 Scripts/verify-cleanup-lifetime.py
python3 Scripts/verify-view-recovery.py
python3 Scripts/verify-windowshare-show.py
python3 Scripts/verify-host-close.py
```

旧的 `Scripts/verify-morning.sh` 查的是早已删除的 `/status.json`、`/snapshot.jpg`，已在 2026-11-13 删除；检查 host 是否在跑、在共享什么，用 `Scripts/windowshare status --json`。

## 延迟

手机点一下到画面变化（`Scripts/latency-run.mjs`，同一 Wi-Fi 经 Tailscale，窗口 1000×800，2026-10-30）：v1 p50 约 93 ms，p95 约 185 ms；M2 之前是 p50 422 ms，p95 677 ms。

做法：Interact 时 viewer 长轮询下一帧，不再每张快照后等 250 ms；捕获 60fps；画面按 1x 尺寸、长边最多 768 px、JPEG 质量 0.4。手机上 12 px 文字仍可识别。这些只在 Interact 时生效，只看时仍是 2 倍清晰度、15fps。

每项都可以用环境变量关掉，方便对比：`WINDOWSHARE_M2A_OFF=push,fps,input,small,q4,cap`，填 `all` 回到 M2 之前的行为。测量方法见 `PLAN.md`「延迟测量方法」和 `docs/m2-phone-test.md`。

## 已知行为

- 从菜单栏共享窗口后，手机端点「开启 Interact」即可操作，Mac 上不再逐次确认。
- 命令行共享不弹确认框，见上文「命令行启动」。
- WindowShare 被强制结束（崩溃、`kill -9`）时来不及松开按键；若此时手机正按着鼠标，按键会保持按下，直到下一次实际点击。正常退出、Ctrl-C、SIGTERM、SIGHUP 都会先松开。
- 撤销操作时会清一次修饰键状态；如果你恰好在 Mac 上按着 ⌘ 等键，需要重新按一下。
- Dock 设为自动隐藏时，手机点击在屏幕边缘可能落到滑出的 Dock 上。
- 网络断开或取帧超时后会自动重连，页面显示「重连中」。断网时控制权会结束，恢复后回到只读，要重新点「开启 Interact」。
- 窗口识别用到 macOS 私有接口 `_AXUIElementGetWindow`；将来系统更新若使其失效，键盘和文字输入会被拒绝，不会打到别的窗口。

## 局域网开关的风险

菜单里的「允许局域网访问（重启后生效）」默认打开（2026-10-29 用户决定）。打开时，同一网络里的任何人都能看到共享窗口并申请操作，局域网上的输入不加密。Tailscale 链路是加密的。在不信任的网络（咖啡馆、酒店 Wi-Fi）请在菜单里关掉，或命令行加 `--no-lan`。

## 故障排查

- 没有画面：检查「屏幕录制」权限；被共享的窗口是否已关闭；重新选择窗口。
- 点了没反应：检查「辅助功能」权限；是否已点「开启 Interact」；打字时目标 App 必须在最前面。被别的窗口挡住的位置点击会被拒绝（日志 `stage=hit`），把共享窗口拉到前面。
- `--url` 找不到窗口：系统设置 → 隐私与安全性 → 自动化，允许 WindowShare 控制该浏览器。
- 手机经 Tailscale 打不开但局域网可以：手机上的 Tailscale 可能被系统省电杀掉了，打开 Tailscale app 让它重连。
- 手机打不开：用 Tailscale 入口时，Mac 和手机都要连上 Tailscale；用局域网入口时，手机要在同一个 Wi-Fi。菜单显示「未找到 Tailscale 或局域网地址：仅本机可访问」说明两条路都不通。

## 许可

[MIT](LICENSE)
