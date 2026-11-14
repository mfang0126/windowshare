# Bot 交给人操作的场景（2026-11-14）

> **状态：Draft · 待 Ming 裁决 · 非授权实施。** 这是 Ming 15:07 口述场景的需求记录，不代表方向冲突已裁决，也不代表功能已实现。下文估时都是条件性的，前置条件未满足前不进入排期。方向依据：`INTENT.md:28-30`「不做」（main `d61104fb`；`git log -1 -- INTENT.md` 显示 INTENT 最近修改即该提交）。

## 需求

1. **后台**：平时 WindowShare 隐藏在 Android 手机后台，共享窗口偶尔发两张画面就够，刷新率不必高。
2. **需要人时**：Bot 需要 Ming 时（例如登录），把对应页面送到手机上，Ming 一看就知道该做什么。自动强行置前还是点击通知进入，待 Ming 决定。
3. **打开后**：手机端实时显示，24 或 30 帧均可，能看清即可。
4. **清晰度**：清晰主要取决于分辨率；压缩、网络和显示缩放也会影响效果。
5. **由人决定结束**：Ming 接手后自己决定何时关；**明确关闭**后，Bot 尽快收到提醒或回调，自己回收会话与资源。「明确关闭」的定义见下一节。

非目标（防止范围蔓延）：iOS、自动登录、逐次授权、模拟授权、远程解锁、绕过锁屏、公网开放、Bot 读取密码或验证码。这些仍按 `INTENT.md` 不做或必须守住处理。

## 「明确关闭」的定义与各动作现状

**定义**：明确关闭 = 手机请求卡上的「完成」（`/request/decision`，`decision=done`）。只有它表示交接完成。请求卡只在 Bot 发起请求后出现（`ViewerPage.swift:26,123-128`）；若 Ming 要在没有 Bot 请求时也能结束共享，需新增「结束共享」按钮，语义与「完成」相同，属于待裁决的新增入口。「停止观看」「取消」、关闭页面、切后台、断网都**不是**交接完成，Bot 不能把它们当作用户完成。

下表为 main `d61104fb` 的代码行为（静态阅读，未真机验证）：

| 手机端动作 | 代码路径 | 撤销输入 | 停止捕获 | 链接失效 | Bot 是否得知 |
|---|---|---|---|---|---|
| 请求卡「完成」 | `ViewerPage.swift:131-138` → `PairingSession.swift:485-498`：`clearWindow("done")`（`:153-161` 置 `active=false`、清 binding/pairs/sessions），再经 share observer 到 `MenuBarController.swift:209-224` `endShare` → `stopSharing`（`:200-206`） | 是：会话清空后，每次加锁及每秒定时器的 `pruneControl` 撤租约（`PairingSession.swift:111-124,294-307`） | 是：`stopSharing` 释放共享锁并异步 `stopCapture` | 是：binding 已清，`POST /session` 回 410（`PairingSession.swift:464`）；同一会话内页面显示「链接已失效」（`ViewerPage.swift:134`），全新访问者的页面文案未在依据中证实 | 是，靠轮询：`windowshare-show` 每 2 秒查一次，读到 `done` 退出 0（`Scripts/windowshare-show:75-84`）；CLI 共享进程等 10 秒供读取后退出（`MenuBarController.swift:216-223`）。无推送回调 |
| 请求卡「取消」 | 同一路由，`decision=cancel`（`PairingSession.swift:485-498`） | 否 | 否 | 否，共享继续 | 是：`cancelled`，CLI 退出 3。表示拒绝本次请求，不是交接完成 |
| 「停止观看」 | `ViewerPage.swift:272` → `/session/close`（`PairingSession.swift:499-503`）只删除本观看会话 | 是：连接的会话不存在后 `current()` 失败，下一次 `pruneControl`（≤约 1 秒）撤租约（`:277-281,299-307`） | 否：共享仍 active；若曾在 Interact，撤租约后回到 15 fps（`CaptureController.swift:298-305`） | 否：同一 `/w/<id>` 链接可再次 `POST /session` 加入（`PairingSession.swift:459-479`），页面「重试」即走此路（`ViewerPage.swift:271`） | 否：请求保持 pending，直至用户在别处决定或超时（CLI 退出 4） |
| 关闭页面 / 切后台 | `pagehide`、`visibilitychange` hidden 调 `clear()` 关 socket（`ViewerPage.swift:61-67,257,259`）；host 端 `disconnect` 删会话（`PairingSession.swift:331-336`） | 是，同上 | 否 | 否：回到前台 `recover()` 自动重新加入（`ViewerPage.swift:68-73,257`） | 否 |
| 断网（没有关闭帧） | host 端连接 15 秒无 pong 即判失效（`PairingSession.swift:279`） | 是：≤约 15 秒加 1 秒定时器撤租约 | 否 | 否：恢复联网后 `online` 事件重新加入（`ViewerPage.swift:258`）；观看会话 cookie 15 分钟、配对 8 小时到期（`PairingSession.swift:473,478`） | 否 |

对照：host 端结束路径。菜单结束走 `finishSharing` → `endShare`（`MenuBarController.swift:199`）；12 小时上限经 `expire` → `clearWindow("shareLimit")`（`PairingSession.swift:207-210`）；目标窗口关闭经 `identity.revokeWindow`（`CaptureController.swift:76,379`）。链接失效、捕获停止均由 `clearWindow`/`stopSharing` 完成（窗口关闭到 `endShare` 的调用链未逐行核实，按同一结束路径推定）；`clearWindow` 把 pending 请求置为 `cancelled`（`PairingSession.swift:155`），但 CLI 共享会立即退出（非 done 不等 10 秒），`windowshare-show` 可能只看到轮询失败（退出 2）。Bot 目前无法区分这几种原因。

PR #1（`9e9ae91`，未合并）在这些路径上的差异：共享结束时 host 向手机发 WebSocket 1001，手机据此停止重连并显示「共享已结束」（`ControlServer.swift` 的 `stop`/`goAway`/`close`，`ViewerPage.swift` 的 `ws.onclose`，`PairingSession.swift` 新增 `shareEnded`）。这是 **host→手机**的连接关闭语义变化，不让 Bot 得知手机关闭，也不改变上表撤输入、停捕获、链接失效的判定。

## 验收矩阵

阈值未经 Ming 约定的格子写「待约定」：该项**当前无通过/失败标准，不可验收**，只能记录数据。

| 场景 | 可观测断言 | 测量方法 | 通过阈值 |
|---|---|---|---|
| 1 后台低频 | 后台期间手机是否收到新帧；回到前台时显示的是最新帧而非旧帧 | 目标 Android，后台 10 分钟，记录 host 发帧日志、手机收帧数、电量变化；系统暂停须如实记录 | 待约定（建议形式：前台恢复后 ≤N 秒显示最新帧；后台 10 分钟电量下降 ≤X%） |
| 2 唤起页面 | 从 Bot 指定窗口和原因开始，手机看到对应任务原因并进入该共享页面 | 记录 Bot 发出到手机显示请求卡的时间；分别测通知权限关闭、离线、链接过期时的恢复路径 | 待约定（唤起方式未裁决） |
| 3 前台帧率 | 端到端实际显示帧率与延迟，不以捕获设置替代 | 目标 Android、实际网络、代表性窗口操作，记录窗口、网络、时长和掉帧 | 稳定 24–30 fps（Ming 原话）；持续时长和掉帧容忍度待约定 |
| 4 清晰度 | 代表性登录表单的文字、控件与操作位置清楚可用 | 记录源窗口、输出像素、手机尺寸与缩放；可沿用 `Scripts/readability-target.html` 加 OCR 方法（`PLAN.md:31`） | 待约定（最低字号与识别率）；PLAN 已有参考：cap 768 时 12 px 中英文 OCR 全对 |
| 5 明确关闭 | 「完成」后：旧链接回 410；输入撤销；捕获停止；共享锁、进程和登记按归属释放；Bot 收到 done | 记录「完成」到 Bot 读到 done 的时间；另测「停止观看」、关页、后台、断网均**不**产生 done | 现状轮询理论上限约 2 秒加请求时间；Bot 可接受的时限待约定 |

## 与现有方向的冲突

`INTENT.md`「不做」原文包括：“系统共享面板（`SCContentSharingPicker`，2026-10-29 删除）、agent 交接协议的扩展、逐次授权、模拟授权、自动登录、pattern 录制、推送通知、远程解锁、iOS 专项、发布门槛和真机验收清单。” 新场景需要 Bot 通知手机、手机结束后通知 Bot；推送通知和交接协议扩展可能触及现行禁止范围。Ming 需决定是否修改方向、允许哪些通知与协议机制，以及「弹到手机上」是否可由用户点击通知完成。现有方向保持原样，以下仅为条件性建议，不构成授权实施。

## 「通知」的几种机制

文中「通知」不混用，分四类：

- **Bot 经现有聊天转发链接**：`windowshare-show` 已打印本次共享链接（`Scripts/windowshare-show:70-73`），由 Bot 在它已有的聊天渠道发给 Ming。WindowShare 不改，不属于产品内推送。
- **产品内推送**：WindowShare 自己向手机推消息。`INTENT.md:30` 列为不做。
- **PWA Web Push**：需 HTTPS 安全上下文、service worker、推送订阅及通知授权；现有入口是私网 HTTP，需处理安全来源。属于产品内推送。
- **Android 原生通知 / Intent**：需安装原生应用、通知权限和接收通道；Android 限制后台直接启动界面，不能承诺自动强制置前。属于产品内推送。

参考（2026-11-14 访问）：[Android 后台启动 Activity 限制](https://developer.android.com/guide/components/activities/background-starts)（现重定向到 Activity security / BAL 页）、[Android 通知导航](https://developer.android.com/develop/ui/views/notifications/navigation)、[Push notifications overview（web.dev）](https://web.dev/articles/push-notifications-overview)、[Push API（MDN）](https://developer.mozilla.org/en-US/docs/Web/API/Push_API)。

## 差距与排期

基线 main `d61104fb0529c6b6451ef34e8ea1e657e9ec0129`；对照 PR #1 `9e9ae91f1520ff2d66a85ad1dbf14c659c80cae8`，未合并。结论来自静态代码与既有报告，没有本轮手机、host 或性能实测。估时为单人理想工程小时，含开发与基本测试，**不含真机排障**、平台账号和审批；规模 S ≤8h、M 9–24h、L >24h。置信度均为「低」（静态估计、无实测）。各项可能重叠，不应简单相加。

**代码能力与默认配置**：捕获参数可在运行中任意改（`CaptureController.swift:260-292` `setQuality`：scale、fps、JPEG 质量）。默认配置由 `Tuning` 开关决定，`WINDOWSHARE_M2A_OFF` 未设置时 `push/fps/input/small/q4/cap` **全部开启**（`EntryConfiguration.swift:134-153`；`README.md:107`；`PLAN.md:30-31` 记为默认全开）。下文「默认」均指此状态。Interact 参数只在手机取得控制租约后生效，放开后恢复（`MenuBarController.swift:186` → `CaptureController.swift:298-305`；租约授予/撤销见 `PairingSession.swift:286-291,388`），打开页面本身不会切换。

**PR #1 范围**（`git diff --stat d61104f 9e9ae91`）：11 个文件，+283/−11。代码改动只在 `ControlServer.swift`（+46/−3）、`MenuBarController.swift`（+5/−1）、`PairingSession.swift`（+3）、`ViewerPage.swift`（+8/−4）；其余为 `Scripts/verify-*.py` 与 `LEARNING-LOG.md`、`PLAN.md`、`README*.md`。`CaptureController.swift`、`HTTPServer.swift`、`EntryConfiguration.swift` 未改，因此 PR #1 不改捕获参数和帧传输；它改的是共享结束时的连接关闭语义（1001）和手机提示文案。

| 项目 | 现状与代码依据（main；PR #1 差异） | 推荐做法、工作量和风险 | 前置条件 | 顺序与依赖 |
|---|---|---|---|---|
| 后台低频 | **缺失**。代码能力：可设任意低 fps（`setQuality` 下限 2 fps，`CaptureController.swift:261`）。默认配置：View 15 fps（`:216,298-299`），Interact 60 fps（`Tuning.fps` 默认开），都是捕获上限，不是空闲偶发模式。手机端 hidden 时清流、关 socket、清画面并暂停重连，前台再恢复（`ViewerPage.swift:61-73,257`），后台不继续接收。PR #1 未改（见上方范围）。 | 先明确后台是否真的需要手机接收；若只需恢复后看到新图，host 低频捕获并保留最新帧，前台恢复取图；若要求后台可靠接收，需原生后台方案及系统限制验证。M 12–24h；原生可靠后台另估 L 40–80h。风险：电量、系统杀后台、旧帧隐私。 | host 低频：无方向冲突。原生后台：需 Ming 允许原生应用。 | F-4 定位修复及回归后测；与前后台模式和回收共设计。 |
| 唤起具体页面 | **部分支持**。`Scripts/windowshare-show:51-73` 创建请求并打印本次共享链接，靠 Bot 转交；`ViewerPage.swift:120-128` 显示请求原因。没有把页面推到前台。PR #1 未改此路径（见上方范围）。 | 分机制：① Bot 经现有聊天转发链接：现状已可用，WindowShare 侧 0h；Bot 侧投递不在本仓库，未估。② PWA Web Push：L 40–80h。③ Android 原生通知：L 60–120h。风险：能力链接泄漏、锁屏内容泄密、权限和系统版本差异。 | ①：无，但「弹到手机上」能否接受由 Ming 判断。②③：需 Ming 修改 `INTENT.md` 允许推送通知；③ 另需允许原生应用。 | 先等 Ming 裁决方向及唤起方式；依赖手机联网。 |
| 前台 24–30 fps | **部分支持，未验证达标**。View：HTTP MJPEG `/stream`（`ViewerPage.swift:85-91`，`HTTPServer.swift:161-176`），捕获 15 fps，流泵每 33ms 检查（`HTTPServer.swift:170`）。Interact：逐张 JPEG 快照，`Tuning.push` 开（默认）时长轮询 `/snapshot/<seq>`，最多等 2 秒，取完立即再取（`ViewerPage.swift:92-113`，`HTTPServer.swift:178`，`PairingSession.swift:531`）；push 关时为每 250ms 轮询（`ViewerPage.swift:113`）。捕获 60 fps 依赖 `Tuning.fps`（默认开）。都不是端到端帧率保证。PR #1 不改传输。 | 先测端到端实显帧率、CPU、带宽、解码与延迟，优化 JPEG 编码、串行请求、网络和浏览器解码；不达标再评估 H.264/WebRTC，须另行审视 ADR 0002。M 16–24h 测量及调优；换传输 L 80–160h。风险：电量、带宽、编解码兼容、画质。 | 测量与调优：无方向冲突。换传输：需 Ming 同意重开 ADR 0002。 | F-4 稳定后先测现方案；PR #1 经独立门禁再纳入基线；与分辨率联测。 |
| 清晰度与分辨率 | **部分支持**。代码能力：输出尺寸 = 窗口点尺寸 × scale，长边超过 2560 时逐次减半（`CaptureController.swift:249-257`）；编码时可按长边上限缩小（`:517-527`）。默认配置：View 2x（`:212-215`）、q0.65（`:40,302`）；Interact 在 `Tuning.small` 开（默认）时 1x，`Tuning.q4` 开（默认）时 q0.4，`Tuning.cap` 开（默认）时编码长边最多 768（`EntryConfiguration.swift:145-151`，`CaptureController.swift:298-303`）。2x 是固定值，不检测设备实际 scale；没有按手机屏幕、DPR 或网络协商的代码。PR #1 不改。 | 增加可配置/协商的分辨率与质量，按手机视口、DPR、带宽上限及文字清晰度选择，保留安全几何映射；手机实测文字和输入定位。M 16–32h（32h 属 L）。风险：分辨率上升增加带宽、延迟、电量；几何错误影响输入安全；与 M2-a2 已达成的延迟目标（`PLAN.md:31`）取舍。 | 无方向冲突；与 F6「操作响应优先于画面清晰度」（`INTENT.md:17`）取舍需 Ming 确认。 | 依赖 F-4 几何问题关闭，和帧率一起权衡。 |
| 关闭、通知与回收 | **部分支持**。明确关闭（「完成」）已能结束共享、使链接失效、停止捕获，Bot 靠 2 秒轮询读到 done；其余动作不产生 done。详见上方「明确关闭」一节。没有 webhook 或 Bot 事件流。PR #1 的 1001 是 host→手机，不能通知 Bot。 | 现状轮询已满足「Bot 得知完成」的基本语义。若要即时回调：提供带共享 ID、原因和确认的本机事件流/回调，支持断线后状态查询和幂等回收；若要无 Bot 请求时也能结束，新增「结束共享」入口。M 16–32h（32h 属 L）。风险：误把后台当结束、事件丢失或重复、旧共享误回收新共享。 | 回调/事件流和新增入口属于 agent 交接协议扩展，需 Ming 修改 `INTENT.md:30`。 | 先在 PR #1 与 F-4 的最终基线上实现；保留绑定/归属保护和 fail-closed，验证 done、断网、后台、进程退出、重复事件及资源释放。 |

建议顺序：先由 Ming 决定冲突与关闭语义，同时独立完成 F-4 诊断、修复和原故障回归；PR #1 仍需按其发布门独立复审，不能因为本文档或 1001 假定已通过。随后先做明确结束与 Bot 事件、低频策略和通知投递，再测前台帧率与清晰度，数据不足时再决定传输升级。F-4 曾出现 `geometryUnavailable`，根因未明；已有报告的单次只读成功不能证明问题关闭。估时与排期是建议，不是承诺。
