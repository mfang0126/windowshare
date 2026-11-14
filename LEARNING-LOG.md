# LEARNING-LOG — 项目教训记录

每个 M 收官时追加。格式：日期 · 教训 · 为什么 · 证据去向。**只写会改变下次行为的教训**，不写流水账。

## 2026-10-13 · M1

1. **AppKit 图像编码（`NSBitmapImageRep`）在非完整 AppKit 初始化的进程里会 `CGS_REQUIRE_INIT` 崩溃 → 图像编码一律用 ImageIO（`CGImageDestination`）。** SwiftPM 可执行 + ScreenCaptureKit 组合下的必踩坑。证据：`evidence/2026-10-13-m1/VERIFICATION.md`。

2. **`SCStreamOutputType` 的视频输出类型是 `.screen`，不是 `.video`。** API 命名反直觉，直接搜文档确认再写。

3. **菜单栏 App 双击后「没反应」是必然的第一印象**（无窗口、无 Dock 图标）。启动必须给可见反馈：本次改为启动即开 HTTP 服务 + 自动弹浏览器 + 指引页。**验收清单必须包含「首次启动体验」，由真人过一遍**——这个坑是用户发现的，不是验证发现的。

4. **MJPEG `<img>` 流永不触发 `onload`**（无限流），页面状态切换要用 `/status.json` 轮询。

5. **`git rm --cached` 可能静默失败（stderr 被吞），`.gitignore` 不解除已追踪文件。** 修正后必须 `git ls-files | grep` 回读验证，不能只看 commit 输出。构建产物混入提交过一次。

6. **GUI 自动化验证不可靠时（LCU 被占用、osascript 无辅助权限），headless CLI 模式是唯一稳定验证通道。** 产品从设计上就要带 `--window`/`--list-windows` 这类可脚本化入口（本次救了验证）。

7. **验证一律用受控内容窗口**（如 TextEdit 测试文件），不抓随机窗口——既防敏感信息进证据，也让判读有确定答案。

8. **开工检查单里的「事实」会过期**：写的是 Swift 6.3.3 / Xcode 26.6 / Xcode app target，实际是 6.4 / 27.0 / SwiftPM+bundle。检查单放文档里、开工时复验，不能留在聊天记录里当真理。

9. **参考实现的坑要先吸收再动手**：SideScreen 的 `SCShareableContent` 超时兜底（FB12114396）提前内置，M1 全程未被此坑咬到。

## 2026-10-20 · M2

1. **锁屏和显示睡眠是两件独立的事，都会让 ScreenCaptureKit 输出 0 帧。** 症状一样：`/stream.mjpg` 返回 200 但 0 字节、`frames` 不再增长；静态文件仍 200。判断方法：读 `CGSSessionScreenIsLocked`，并看 frames 是否在增长。**app 必须自持 power assertion**，否则「人不在家看窗口」这条主用例会静默失效；文档里要写明「Mac 需解锁 + 显示唤醒」是硬边界，不绕过锁屏。

2. **HTTP 200 不等于有内容。** 交付任何观看链接前，必须现场验到「非零字节 + frames 增长」，否则就是给用户一个死链接（本次犯过两次：先 kill 了服务再发地址；后又把锁屏时的 0 帧页面当可用）。验收判据要写成「bytes > 0 且 frames 递增」，不是「curl 返回 200」。

3. **`open -na Chrome --args --window-size` 不可靠**：会话恢复会覆盖尺寸，三个窗口全变成 1179×1244。要精确宽度用 AppleScript 设 `bounds`，并用 `/status.json` 的 `size` 回读确认——不能只看页面里写的标签。

4. **Tailscale 自测 000 不等于网络不通**：同端口 python `http.server` 在 `0.0.0.0` 与 `::` 两种绑定下 TS IP 均 200，问题缩在「本 app 的 NWListener × 本机自环」。这类对照实验要用**已授过本地网络权限的 app**做，`/tmp` 下临时编译的二进制会被 macOS 权限拦住，不能当对照组。

## 2026-10-20 · M3

1. **一半输入能用、另一半不能用，先怀疑客户端 JS，不是服务端。** 本次 `let pressed` 在 `pointerdown` 里被重新赋值 → TypeError → click 永不发送，而文本走另一条路径完全正常。**判断法：看两条路径是否共享同一变量/函数**；共享的那一段就是嫌疑点。

2. **MJPEG over TCP 没有拥塞控制，蜂窝链路上必然积压。** 全尺寸帧 1.3 MB/s 时「越来越卡」不是网络慢，是队列越积越深。可用的降级顺序：先降分辨率（0.75x），再降帧率（8fps），最后降 JPEG 质量——分辨率对观感影响最大。实测低档 ≈135 KB/s。

3. **降带宽能救「卡」，救不了「延迟」。** 用户对比 UU 远程仍觉得迟钝：对方是硬件 H.264/HEVC + UDP + 自适应码率。要接近，只能换传输层（WebRTC），这是 ADR-0002 的 v2，不是调参能解决的。

4. **锁屏/睡眠期间不要向用户交付链接。** 两次都出现「200 但 0 字节」，判据是 `CGSSessionScreenIsLocked` + `frames` 是否增长；交付前先验 `snapshot.jpg` 返回 200。

## 2026-10-21 · 通宵（WebRTC / 输入 UX / handoff）

1. **动态 framework 必须内嵌，rpath 不是可选项。** `stasel/WebRTC` 是 dynamic framework：只加 SPM 依赖能编译，但 `.app` 启动即 `Library not loaded`。修法是 `cp -R WebRTC.framework Contents/Frameworks` + `install_tool -add_rpath @executable_path/../Frameworks`，然后重签。判断法：**`--rtc-probe` 能在 `.build/` 下跑、`.app` 里不能跑**，就是打包问题。

2. **`RTCVideoSource` 不接受裸 buffer。** 必须自定义 `RTCVideoCapturer` 子类，用 `source.capturer(self, didCapture: frame)` 送入；传 `nil` 编译能过、运行会静默丢帧。

3. **SCK 在窗口 resize 后仍报旧 frame。** `currentWindow.frame` 是捕获时的快照，`AX` 改完窗口尺寸后不会自动更新，流会按旧尺寸继续编码（实测窗口已 390×844，流仍是 520×760 的 0.75x）。正确做法：resize 成功后立即用已知的 `sizeOverride` 重配流（`setQuality` 里优先读 override），再异步 `refreshWindowFrame()` 校正。

4. **协议里的数值要做范围说明。** `handoff.request` 的 ttl 被 clamp 到 30–3600s，测试传 8 会得到 30，容易误判为「参数没生效」。写测试时用边界值，或先在文档里写清 clamp 区间。

5. **headless Chrome 可以做交互回归。** CDP `Input.dispatchMouseEvent` 能驱动 pointer 事件，配合 `Runtime.evaluate` 读 DOM 状态，足以验证「模式切换 / 光标位移 / 放大镜出现」这类不依赖真机的手势逻辑；**但两指手势和真实触摸精度只能真机验**。

6. **点击坐标偏移的根因是「缓存的窗口 frame」，不是页面换算。** `WindowInfo.frame` 在启动时取一次，之后窗口被移动/缩放都不会更新；`point()` 一直用它算屏幕坐标，于是所有点击按旧矩形落点。修法：每次点击从 `CGWindowListCopyWindowInfo(.optionIncludingWindow)` 按 windowID 读实时 bounds（AX 作为 fallback，Chrome 常拒绝 AX 窗口属性）。判据：`probe` 返回的 rect 与 `System Events` 的 position/size 不一致即为命中此 bug。

7. **点击精度可以用 CDP 闭环验证，不需要人。** 一个自带 `click` 监听、把 `clientX/clientY` 写进 DOM 的页面 + `Scripts/click-calib.mjs`，就能量出「归一化坐标 → 页面坐标」的真实误差。本次结果：0.25→(125,88)、0.5→(250,263)、0.75→(375,438)，x 误差 0，y 差 87px 是 Chrome 自己的标签栏/工具栏高度（属于被捕获窗口的一部分，不是偏移）。

## 2026-10-29 · M1-8 `--url`

1. **同 bundle id 的浏览器可能有多个实例，`tell application id` 只到其中一个。** 本机有用户的 Chrome 和一个 `--user-data-dir` 启动的自动化 Chrome，AppleScript 只到后者，用户的标签页永远匹配不到。按 pid 发 Apple 事件（`SBApplication(processIdentifier:)`）逐个读。
2. **Apple 事件默认 2 分钟超时。** 授权框没点或浏览器不响应时，每次轮询卡 120 秒，`--wait` 失效；设 `timeout`（5 秒）。
3. **`open -g -a Chrome file://...?q` 会丢掉查询串。** 测试用的网址片段要取路径里的部分。

## 2026-11-13 · 真机端到端（共享生命周期）

1. **测试窗口要做成 `.app` 包。** 裸可执行文件打开的窗口没有 `NSRunningApplication.launchDate`，捕获来源校验拒绝（`[capture] initial application missing`，退出码 4），和 Finder 同一个原因。最小 `Info.plist` + ad-hoc 签名的 `.app` 就够。
2. **测试窗口被挡住时点击一律 `stage=hit` 被拒。** 不激活 app 也能把窗口提到普通层最上面：窗口自己调 `orderFrontRegardless()`。设成 `.floating` 层级不行，`list` 只收普通层窗口，会找不到它。
3. **ego lite 的所有 Space 共用一个窗口**，共享它会把别的 Space 的内容一起给出去；受控测试页不要放在 ego lite 里。命令行小 app 里的 `WKWebView` 实测只画黑底，改用原生 AppKit 控件。
4. **`$(脚本)` 里后台启动 host 和 `sleep` 时**，子进程继承管道，命令替换会一直等到 `sleep` 结束；后台子进程要重定向 `>/dev/null 2>&1 </dev/null`。

## 2026-11-13 · agent.json 交还

1. **跨进程交接的状态不要只放在接管进程的内存里。** 被接管的登记只存在 CLI 进程内存时，接力共享或进程被杀后就丢。放进共享文件本身（`displaced`），在同一把文件锁下读改写，任何后退出的进程都能接着交还。

## 2026-11-13 · 共享结束的 close 1001

1. **要让手机收到 close 帧，不能发完就断开或退出进程。** 浏览器还在发轮询，host 不读就退出，内核回 RST，已发出的 close 帧可能被丢；本机 loopback 探针测不出来，经 Tailscale 的手机 3 次里败 1 次。发 close 后继续读，等浏览器回 close（限时）再断开。
2. **结束信号要从最早撤销会话的地方发，同一时刻的 HTTP 轮询失败也会抢先。** viewer 收到 401 就重连并关掉控制通道，后到的 1001 被忽略；控制通道还开着时先给它一点时间。
