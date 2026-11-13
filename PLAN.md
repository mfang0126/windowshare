# PLAN — 里程碑

做什么见 `INTENT.md`。本文件只记里程碑顺序、每步做什么、怎么算做完、当前状态。一次只做一步；做完在「状态」里写一句结果，和代码放在同一个 commit。

**当前：v1.0.0 已发布**（M1 + M2 + M4 完成；M2-b、M2-c 不做；后续新想法先记进本文件）

## M1 核心闭环：一条命令共享，Tailscale 上的手机能操作

做完以后：`--app "Google Chrome" --interact` 一条命令，Tailscale 上的手机打开入口，点 Interact，能在测试登录页里输入用户名和密码。

| 步 | 做什么 | 做完的判据 | 状态 |
|---|---|---|---|
| M1-1 | 命令行共享也监听 Tailscale：`host/Sources/main.swift:42` 不再对 `--window` 设 `loopbackOnly`；局域网仍按菜单开关；README「命令行启动」同步 | 命令行共享后，手机经 Tailscale 能打开入口看到画面 | done（PR #2）。`--window` 两个端口都监听 `*:8790/8791`，loopback 带 Tailscale Host 返回 200；本机 curl 自身 Tailscale IP 超时（同端口 python 对照 200，已知自环问题，见 LEARNING-LOG M2-4），手机经 Tailscale 打开在 M1-4 B 一并确认 |
| M1-2 | `--app "<App 名>"`：共享该 app 最前面的窗口（匹配逻辑在 `host/Sources/MenuBarController.swift:69` 附近）；没有窗口时报错退出，不改抓别的 app | `--app "Google Chrome"` 共享到 Chrome 窗口；app 没开时退出码 3 | done（PR #2）。`--app "Google Chrome"` 共享到 Chrome 窗口，`--app Finder` 选中 CG 前后序第一个窗口，`--app "No Such App"` 退出码 3 |
| M1-3 | skill 和 `Scripts/windowshare-show` 说明里补上「先用 `--app` 共享」 | `skills/windowshare-show/SKILL.md` 写清从共享到交给人的一条龙用法 | done（PR #2）。按 SKILL「一条龙」跑 `--app TextEdit --interact` + `windowshare-show --timeout 30`，打印 Tailscale 入口，超时退出 4，host 正常退出 0 |
| M1-4 | 延迟基线：USB 和 Tailscale 两条路径各 30 次（方法见下文） | 两行数字写进「延迟记录」 | done：USB p50 211 / p95 358 ms，Tailscale p50 422 / p95 677 ms（见「延迟记录」）；JP 控手机 r_10d9e065、r_32ccd334 |
| M1-5 | 闭环实测：Chrome 打开一个本地测试登录页（不用真实账号），手机经 Tailscale 输入用户名和密码 | 状态里写一句结果 | done：2026-10-30 手机经 Tailscale 共享 ws-login-test，Interact 下点用户名框、用 viewer 键盘发 `demo-user`、点密码框发 8 位编造密码、点登录，画面显示「已提交：用户名「demo-user」，密码 8 位」（JP r_6c7eb01f；网页内点击经 CDP 触摸，JP 不能定位网页元素）。同日 Tailscale 只看（r_3bf01e80）、局域网只看（r_1428389a，修了控制通道 PR #6）也在手机上确认 |
| M1-6 | `windowshare list [--json]`：用 SCShareableContent 列出可共享窗口：app 名、bundle id、pid、窗口 ID、标题、是否最前 | `list --json` 输出可被 agent 解析，不含窗口画面 | done：`list --json` 实测 13 行，字段 app / bundle_id / pid / window_id / title / frontmost，按前后序；入口 `Scripts/windowshare` |
| M1-7 | Tailscale 和局域网默认都开 + `windowshare status [--json]`：启动时打印所有入口（Tailscale、局域网各一行）；检测 `tailscale` CLI、`tailscale ip -4`，检测不到只警告并给安装提示，继续用局域网；两者都没有时命令行共享退出码 6。新装默认允许局域网，菜单开关或 `--no-lan` 关掉。`status` 报服务是否在跑、在共享哪个窗口、全部入口。skill 第一步调 `status` | 启动打印全部入口；`status --json` 在运行和未运行时都给出可解析结果 | done：默认启动打印 `entry tailscale=http://<tailscale-ip>:8790/` 和 `entry lan=http://<lan-ip>:8790/`，局域网入口 curl 200；`--no-lan` 只剩 Tailscale；`status --json` 的 `entries` 列出两个入口；没装 / 没连 Tailscale 的提示由 verify-direct-entry 用假 `tailscale` 覆盖；局域网只接受私有网段对端（verify 覆盖公网地址被拒） |
| M1-8 | 选窗口：`--window-id <id>`、`--title-contains <s>`、`--url <子串>`、`--default-browser`、`--wait <秒>`。`--url` 用 Apple 事件（ScriptingBridge，按 pid 逐个实例，每个事件 5 秒超时）读 Chrome / Arc / Safari / Edge / Brave 每个窗口当前标签页网址，按标题 + pid 对齐到 SC 窗口；Firefox 明确报不支持。`--default-browser` 用 LaunchServices 查 https 默认浏览器，取最前窗口。`--url` 找不到时只有显式 `--fallback-default-browser` 才退到默认浏览器。全失败退出码 3，并把 `list --json` 打到 stderr。`--wait N` 轮询到窗口出现或超时 | 每个参数各实测一次；第一次 AppleScript 会弹「自动化」权限框，触发前先问用户 | done：`--window-id`、`--title-contains`、`--default-browser`（LaunchServices → Chrome）、`--wait`（窗口 4 秒后出现，5 秒内共享；超时退出 3）、找不到时 stderr 打 `list --json` 已实测；`--url`（用户允许 Chrome「自动化」后）匹配到受控页 `latency-target.html` 并只看共享，`status` 窗口一致，不匹配时 5.9 秒退出 3。Arc 每次 -1712 超时（未获授权或 Arc 不响应），只报 stderr 不影响 Chrome。`--fallback-default-browser` 未实测（会共享非受控窗口） |
| M1-9 | 共享文件归属：`agent.json` 记录 pid，进程退出时只删 pid 是自己的那份。按 ADR 0003 改为同一时间只允许一个共享：`share.lock` 全机一把 flock（与端口无关），第二个共享立即退出码 8 并回「正在被 X 使用」（开启者、已开时长），不排队 | 两个实例先后申请共享，后者被拒并带开启者信息；前者退出后锁释放 | done（2026-11-13）：`Scripts/verify-share-lifecycle.swift` 用子进程持锁验证被拒、开启者/时长、进程退出释放。原「两个不同端口实例并存」的行为作废 |
| M1-10 | skill 补 AWS 类场景：`status` → `--url <域名> --wait 30 --interact` → 把入口发给人 → 完成后停 | `skills/windowshare-show/SKILL.md` 写清 | done：按 SKILL 一条龙（用 `--title-contains` 代替 `--url`）实测：`status` 未运行 → 共享打印两个入口 → `status` 报窗口 64470 和 2 个入口 → `windowshare-show` 超时退出 4 → 停止退出 0。端口被占时共享进程退出码 7（原来是 0） |

## M2 低延迟

目标（暂定，M1-4 出基线后用户可改）：同一 Wi-Fi 经 Tailscale，**p50 ≤ 100ms，p95 ≤ 200ms**。达到目标，或用户说「够了」，就结束。每段做完在 Tailscale 路径重测，写一行记录。NAT 穿透由 Tailscale 承担，不做。

| 步 | 做什么 | 状态 |
|---|---|---|
| M2-a | **MJPEG 管线提速**，每次只改一项、各测一次：Interact 时服务端推画面（现在手机每张快照加载完再等 250ms，`ViewerPage.swift` 的 `snapshot()`）；Interact 期间提帧率（`CaptureController.swift` 的 `minimumFrameInterval` 现为 15fps）；收到输入后立即出帧；缩小单帧（分辨率 / JPEG 质量） | done（PR #8，四项默认全开）：每项可用 `WINDOWSHARE_M2A_OFF=push,fps,input,small` 关闭，`all` 即基线）：① 推画面：Interact 时 viewer 长轮询 `/snapshot/<seq>`，有新帧就返回、最多等 2 秒，取完立刻再取；本机 loopback 同 seq 0.04 秒拿到下一帧；② 提帧率：拿到控制权时捕获改 60fps，放开回 15fps（日志 `quality -> … @ 60fps` / `@ 15fps`），只关这项 loopback p50 25→45 ms；③ 输入后立即出帧：输入确认后马上取帧，不等 250 ms 轮询（推画面开着时长轮询本来就在等，不起作用）；推画面关时 loopback p50 208→22 ms；④ 缩小帧：Interact 时按 1x 点尺寸、JPEG 质量 0.5（1000×800 窗口从 2000×1600 q0.65 降到 1000×800 q0.5），只关这项 loopback p50 25→36 ms。本机 loopback 全开 p50 25 / p95 41 ms，基线（all）212 / 310 ms，只作参考。**手机（2026-10-30，Tailscale，见「延迟记录」）**：全开 p50 143–153 / p95 260–270 ms，基线 411 / 792 ms；单关缩小帧 p50 涨到 254，单关提帧率涨到 176，单关推画面 p50 114 但 p95 499，推画面和输入后出帧都关 293 / 443。四项默认全开；目标 p50 ≤ 100 / p95 ≤ 200 未达到，是否做 M2-b 由用户定。M1-5 登录闭环全开下再跑一遍通过（JP r_a2ff86d3）。OFF=fps 第一轮只送出 10 次输入（7/30 匹配），作废重跑 |
| M2-a2 | **再压单帧**（2026-10-30 监工决定，M2-b 等这组数据再定）：Interact 时 JPEG 质量 0.4（开关 `q4`）；Interact 时长边上限 768 px，在 JPEG 编码时缩小，不改 SCK 输出尺寸（开关 `cap`）。两项默认开，同样用 `WINDOWSHARE_M2A_OFF` 关 | done（PR #10）：手机对比（2026-10-30，见「延迟记录」）：全开 p50 93–108 / p95 182–387（后两轮 94/189、93/182，达到 ≤100/≤200），M2-a 水平（`OFF=q4,cap`）145–188 / 276–292。`cap` 是主要收益（只开 cap 第 2 轮 99/276），`q4` 单独约省 10 ms。第 1 轮网络抖动大（只开 cap 391/1466，25/30），以第 2、3 轮为准。可读性（`Scripts/readability-target.html`，12/13/14/16 px 中英文加登录表单，手机截图做 Vision OCR）：cap 768 平均 0.991，cap 关 1.000，12 px 全部识别正确，只有一行 13 px 中文错了两个字 |
| M2-b | **H.264**：M2-a 不达标才做。VideoToolbox 硬编 H.264，经 WebSocket 发帧，手机用 WebCodecs 解码 | 不做（2026-10-30：M2-a + M2-a2 已达到目标）|
| M2-c | **完整 WebRTC**：最后兜底，多半不做；参考 `spike/webrtc-v2`，转正前写 ADR | 不做（2026-10-30：M2-a + M2-a2 已达到目标）|

## M4 收尾（用户要发版时）

v1 = M1（含 M1-6..10）+ M2 + M4。

更新 README，打 tag `v1.0.0`。

状态：done（2026-10-30）：README 补上 M1-8 的选窗口参数、M2 的延迟数字和开关、断网重连和排查条目；tag `v1.0.0`。

收尾修复（2026-10-30）：`Scripts/verify-lifecycle.swift` 能编译并通过（PASS）；编译命令补上 `EntryConfiguration`、`AgentRequest`，已删除的 `localInvite` 改为断言 `POST /session` 的状态码（失效时 503，重新选择后 200）。

交还登记修复（2026-11-13）：空闲菜单 host 运行时，CLI 共享接管 `agent.json`（R2），退出时原来直接删掉，菜单 host 还活着但 `status` 报 `running:false`、`windowshare-show` 找不到它。改为退出时把被接管的原登记写回（原 owner 还活着才写回）。`verify-share-lifecycle` 新增 `handBack`：ad03a67 上 FAIL、修复后 PASS。真机（Android 经 Tailscale，原生假数据窗口 `ws-v1-mock`，release 签名包）：开始共享、手机 Interact 点两次（Mac 计数 2）、第二个 agent 立即退出码 8 并回「正在被 test-agent-A 使用」、手机点「完成」后 `windowshare-show` 退出 0 且页面显示「链接已失效」、杀掉开启进程即 `ended reason=opener_exit`，每次结束后 `status` 都回到菜单 host（8777）；手机锁屏 15 秒解锁后重连，能再点。Mac 锁屏 / 睡眠、菜单选窗口流程未实测。

交还登记修复 2（2026-11-13，第四轮复审 HB1–HB3）：被接管的登记原来只存在接管进程内存里，接力共享（A 退出宽限内开 B）后丢失、菜单退出交错时被写回死登记。改为存进 `agent.json` 的 `displaced` 列表：退出时交还给最新的仍在运行的 host；不是自己的文件只把自己从列表里删掉；新共享接管时继承已死 owner 的列表；`status`/`windowshare-show` 在 owner 已死（SIGKILL）时改用列表里活着的 host。`verify-share-lifecycle` 新增 `relay`（4 个场景）与 `verify-windowshare-show` 新增 killed 场景：4c45f48 上 FAIL、修复后 PASS；全部 verify 脚本 exit 0；第四轮复审探针 network_ownership 四项（正常、接力、SIGKILL、菜单退出交错）父 1 过 3 败、新 4 过。真机未复测。

公开发布准备（2026-11-13）：README 改成英文 `README.md` + 中文 `README.zh-CN.md`（互相链接，加「测试」一节），加 MIT `LICENSE`；删除过时的 `Scripts/verify-morning.sh`（查的 `/status.json`、`/snapshot.jpg` 早已删除，改用 `windowshare status --json`）。打 tag、建 Release、仓库改 public 等用户定版本号后再做。

两个真机 bug 修复（2026-11-13）：① host 进程退出（开启进程退出、SIGTERM、Quit、CLI 的限时/窗口关闭等立即退出路径）后手机停在「连接 View」：撤销窗口会立刻断开控制 WebSocket，手机只能当成网络中断一直重试死掉的 host。改为退出前先用 WebSocket close 1001 通知 viewer（`ControlServer.stop()`，最多等 0.5 秒，在 `revokeWindow` 之前调用），viewer 收到 1001 就停止重试并显示「共享已结束：Mac 已停止共享，链接已失效」；其它关闭码仍自动恢复。② Interact 已生效时状态行仍是「正在申请控制权」：拿到 lease 时改为「已获得控制权」。`verify-view-recovery` 新增两项：v1.0.0 上各自 FAIL、修复后 PASS；全部 verify 脚本 exit 0。真机（Android 经 Tailscale，假数据窗口 `ws-v1-mock`，release 签名包）：v1.0.0 拿到控制权后仍显示「正在申请控制权」、杀掉开启进程 8 秒和 14 秒后都是「连接 View」；修复后显示「已获得控制权」，开启进程退出后显示「共享已结束」。SIGTERM / Quit 路径走同一处代码，真机未单独测。更正（2026-11-13 复审 P2-1）：上句原写「限时、窗口关闭路径走同一处代码」不对。12 小时到期和窗口关闭由 `PairingSession.clearWindow` 先撤掉会话，`pruneControl` 当场取消 WebSocket，等 `endShare` 里的 `control.stop()` 执行时连接已断，手机收到的是无 close 帧的断线，仍会重试。改为：会话里的取消一律经 `ControlServer.close`，它用 `PairingSession.shareEnded` 判断该 viewer 所在的共享已结束（窗口清掉或换掉）时先发 close 1001 再断开（最多等 0.5 秒），`stop()` 退出前也等这些 1001 发完；画面和输入仍在 `clearWindow` 里当场停止。新增 `Scripts/verify-host-close.py`（真实 loopback WebSocket，四条路径 terminate / unavailable / limit / window_closed）：b084aaa 上 limit、window_closed 两项 FAIL（无 close 帧），修复后四项 PASS；全部 8 个 verify 脚本 exit 0，release 构建 exit 0。

## 延迟测量方法

起点：手机上松手发出点击（`pointerup`）。终点：手机 viewer 里画面黑白翻转的那张快照解码完成（`image.onload`）。不含触摸采样和屏幕刷新（大约多 20–40ms）；每次测量方法相同，前后可比。

1. Chrome 打开 `Scripts/latency-target.html`（每点一下整页黑白翻转，窗口标题 `ws-latency-target`）。
2. 用 `--window "ws-latency-target" --interact` 共享。M1-1 完成前只能走 USB：`adb reverse tcp:8777 tcp:8777` 和 `tcp:8778`，入口是 `http://127.0.0.1:8777/`。
3. 手机 Chrome 打开 `<入口>#latency`，点「开启 Interact」。
4. `adb forward tcp:9333 localabstract:chrome_devtools_remote`（Mac 的 9222 常被本机 Chrome 占用），然后 `CDP=9333 TAB=<入口 host:port> node Scripts/latency-run.mjs 30 <标签>`，输出一行 JSON。`TAB` 用来在多个 viewer 标签页里选对那个。

每次点击都会真实点到 Mac 上的目标窗口，鼠标指针会跳过去。跑之前先告诉用户。

## 延迟记录

| 日期 | commit | 路径 | 改动 | p50 | p95 | 匹配 / 次数 |
|---|---|---|---|---|---|---|
| 2026-10-30 | 7f445db | USB（adb reverse） | 基线，窗口 1000×800 | 211 | 358 | 29 / 30 |
| 2026-10-30 | 7f445db | Tailscale（同一 Wi-Fi，direct） | 基线，窗口 1000×800 | 422 | 677 | 30 / 30 |
| 2026-10-30 | c89b8ef | Tailscale（同一 Wi-Fi，direct） | M2-a OFF=all（基线） | 411 | 792 | 30 / 30 |
| 2026-10-30 | c89b8ef | Tailscale（同一 Wi-Fi，direct） | M2-a 全开 | 153 | 260 | 28 / 30 |
| 2026-10-30 | c89b8ef | Tailscale（同一 Wi-Fi，direct） | M2-a 全开（重跑） | 143 | 270 | 30 / 30 |
| 2026-10-30 | c89b8ef | Tailscale（同一 Wi-Fi，direct） | M2-a OFF=push | 114 | 499 | 30 / 30 |
| 2026-10-30 | c89b8ef | Tailscale（同一 Wi-Fi，direct） | M2-a OFF=fps | 176 | 302 | 30 / 30 |
| 2026-10-30 | c89b8ef | Tailscale（同一 Wi-Fi，direct） | M2-a OFF=small | 254 | 358 | 30 / 30 |
| 2026-10-30 | c89b8ef | Tailscale（同一 Wi-Fi，direct） | M2-a OFF=push,input | 293 | 443 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 OFF=q4,cap（=M2-a 全开） | 188 | 292 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 全开 | 108 | 387 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 OFF=cap（只开 q4） | 133 | 246 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 OFF=q4（只开 cap） | 391 | 1466 | 25 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 全开（第 2 轮） | 94 | 189 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 OFF=q4（第 2 轮） | 99 | 276 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 OFF=q4,cap（第 2 轮） | 152 | 276 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 OFF=cap（第 2 轮） | 143 | 261 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 OFF=q4,cap（第 3 轮） | 145 | 279 | 30 / 30 |
| 2026-10-30 | 7b2d3ac | Tailscale（同一 Wi-Fi，direct） | M2-a2 全开（第 3 轮） | 93 | 182 | 30 / 30 |

## 已定决定

- 2026-10-29：删除 M3 系统共享面板。CLI + skill 就是完整入口，agent 自己能找到窗口，不需要人在系统面板里点选。
- 2026-10-29：Tailscale 和局域网默认都开，启动打印全部入口；没有 Tailscale 只警告，两者都没有才报错（推翻同日早些时候「检测不到 Tailscale 就报错」）。局域网只接受私有网段对端，不对公网开放。找窗口不依赖 LCU 或 computer use。
- 2026-10-29：命令行共享开放给 Tailscale 和局域网。Tailscale 网络里能访问入口的设备都能看到命令行共享的窗口，用户接受。
- 2026-10-29：共享单元只是一个 app 窗口，不做框选任意区域。
- 2026-10-27：`--window` / `--app` 不弹确认框，运行命令即视为批准。

## 已知问题

- 断网或取帧超时（2026-10-30 手机上见过一次「Failed to fetch」）：会自动恢复。长轮询超过 5 秒会自动重试，约 3 秒内回到「可操作」；断网 2 秒时整个页面自动重连，回到 View，要重新开 Interact（显式 Interact，设计如此）。状态文字已改成「重连中」，恢复后显示「画面已恢复」。复现脚本：`Scripts/viewer-netdrop.mjs`。
- Finder 窗口共享不了：`NSRunningApplication.launchDate` 为空，捕获来源校验拒绝，命令行退出码 4（2026-10-29 `--app Finder` 实测）。不改安全门。
- 开启进程退出后 host 立即退出，手机页面停在「连接 View」空白画面，不显示「共享已结束」（「完成」结束时会显示）。2026-11-13 真机见到。
- 手机拿到控制权、点击已生效后，状态行仍显示「正在申请控制权；最多 5 分钟」。2026-11-13 真机见到。
- Dock 自动隐藏时，贴屏幕边缘的点击可能落到滑出的 Dock 上（`InputController.swift` 中 `occludes` 的 ponytail 注释）。
