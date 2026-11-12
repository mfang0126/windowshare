# v1 真机验证

环境：macOS 26.6.2 · `build/WindowShareHost.app`（release，固定本地签名证书）· 手机 Android 测试机（Chrome）· 受控窗口 = TextEdit `ws-h1-test.txt`

**路径：USB `adb reverse tcp:8777 tcp:8778` → 手机访问 `127.0.0.1:8777`。不是 Tailscale**（该手机不在 tailnet）。Tailscale 入口与 LAN 开关仍待验证。

## H1 真机冒烟（2026-10-27 22:42–23:57）

| # | 检查 | 结果 | 证据 |
|---|---|---|---|
| 1 | 未共享时手机显示「无共享窗口」 | 通过 | `nowin.png`；`POST /session` 返回 503 |
| 2 | 共享后手机只显示受控窗口 | 通过 | `view.png`：只有 `ws-h1-test.txt`，没有桌面或其他窗口 |
| 3 | 点击 | 通过（23:43）：按下和抬起同一点，无拖选 | `down at 1100,617` / `up at 1100,617`；此前失败见下文 |
| 4 | 滚动、中英文输入、⌘ 组合键 | 通过：中英文、滚动（23:43–23:44）；⌘A/⌘C/⌘V（23:55，`eb38071` 构建） | 「Hello WS 你好」落在点击处；⌘A 全选、⌘C 后剪贴板等于选区、⌘V 粘贴在光标处；每步后 `flagsState=0x20000000`、修饰键全部未按下 |
| 5 | Mac 改窗口尺寸，手机跟随 | 通过（23:36） | 用 AX 把窗口移到 600,250、改为 760×480；capture 重新映射，共享未撤销，`resize.png` 显示更多行 |
| 6 | 手机切后台后恢复观看，不恢复操作 | 通过（23:22、23:37） | 回到前台后显示「View · 只读」 |
| 7 | Tailscale 入口 | 未测（手机不在 tailnet） | |
| 8 | 结束 host 后无卡键 | 通过（23:57） | SIGTERM 后鼠标左右键、全部修饰键均未按下 |
| 9 | 共享中途关闭受控窗口 | 通过（10-28 00:05） | 第二个 fixture `ws-h1-close.txt` 开启 Interact 后经 AX 关闭；host 日志 `window revoked reason=revokeWindow`；手机显示「无共享窗口：请在 Mac 菜单栏选择窗口」，没有改抓其他窗口（`closed.png`）；关闭后鼠标键、修饰键均未按下 |

## H4 视口变化后坐标（2026-10-27 23:56）

折叠无法测：Android 测试机不可折叠（`device_state` 只有 DEFAULT），以横竖屏旋转代替（MILESTONES 允许通用 viewport 验证）。

| # | 检查 | 结果 | 证据 |
|---|---|---|---|
| 1 | 竖屏 → 横屏 → 竖屏，点击画面上同一位置 | 通过 | host 日志落点：竖屏 `842,330`、横屏 `841,330`、竖屏 `842,330`（1 像素取整差） |

旋转经 adb 锁定执行（`accelerometer_rotation 0` + `user_rotation 1/0`），结束后恢复原设置（`1` / `0`）。

## Apps 覆盖层与 Dock 规则（10-28 00:00–00:05，未能复现）

`hit()` 放行 Dock 拥有的、layer 20、屏幕大小的透明窗口。若 macOS 26 的 Apps（原 Launchpad）覆盖层也是这样的窗口，点击会落进覆盖层。用 `open -a /System/Applications/Apps.app` 和对 Dock「Apps」项的 AXPress 都没能打开覆盖层（窗口列表、Dock AX、窗口 9 单独截图均无变化），需要人手动打开一次再探测。

## 未完成（需要人）

- **H2 真实登录**：手机上完成一次真实 AWS 或 Vercel 登录（密码 + 二次验证），凭据不进入 agent。待用户。
- **Apps 覆盖层探测**：用户打开一次 Apps，Opus 同时读取窗口列表；若覆盖层被 Dock 规则放行，发版前必须收紧。
- Tailscale 入口、局域网开关：测试机不在 tailnet，未测。
- 断网后恢复观看、同一时刻只有一个操作者、agent 超时（exit 4）：未在真机上单独测。

被拒绝的点击未注入任何事件，控制权随即自动释放（页面显示「控制已停止」）。这是预期的安全行为。

### #3 点击失败的原因

macOS 26 上，Dock 拥有一个透明的全屏窗口（窗口 9，2368×1332，layer 20）。`hit()` 把它当作每个点上最上层的窗口，于是所有点击都被拒绝。M3 时的 `ownerAt` 会跳过非 0 层，注释里写明了 Dock 的问题；`3fd9e3f` 重写 `hit()` 时丢掉了这个过滤。

修复 `beae9e4`：只跳过 Dock 拥有的窗口，而且只在屏幕 visibleFrame 之内跳过；Dock 栏、菜单栏和其他悬浮窗仍然算作遮挡。用本机实时窗口列表验证：原点击位置命中 TextEdit，Dock 栏位置命中 Dock，菜单栏位置命中控制中心。

## H3 agent 交给人（2026-10-27 22:44–22:45）

| # | 检查 | 结果 | 证据 |
|---|---|---|---|
| 1 | `Scripts/windowshare-show --reason "H3 测试：请点完成"`，手机显示原因和倒计时 | 通过 | `h3-card.png`：「Agent 请求：H3 测试：请点完成 · 剩余 118 秒 · 完成 / 取消」 |
| 2 | 手机点「完成」，CLI 退出码 0 | 通过 | CLI 输出 `exit=0` |
| 3 | 手机点「取消」，CLI 退出码 3 | 通过 | CLI 输出 `exit=3` |

CLI 打印的入口是 `http://<tailscale-ip>:8777/`（Tailscale 地址）；本次手机实际经 adb reverse 访问。

### 23:35 复测：抬起落点和文字被拒

鼠标光标本身是一个屏幕上的窗口：属主 WindowServer，layer 2147483630（光标层），23×22，位于光标所在处。`hit()` 把它当作遮挡：

- 按下后光标停在按下点，抬起时按下点的命中检查失败，回退到窗口中心，单击变成拖选（第 11–14、15–20 行被选中）。
- `target()` 检查窗口中心点；光标停在中心后 `focused()` 失败，所有文字和按键都在 `submit_authority` 被拒。

另：TextEdit 窗口没有 `AXWindowNumber`，`f956706` 改用 `_AXUIElementGetWindow` 取窗口 id（探针确认焦点窗口 = 58459）。

修复 `e05f613`：只放行属主可执行文件为 WindowServer 的光标层窗口，其他 App 抬到光标层的窗口仍算遮挡；抬起点不再回退到窗口中心。

### 23:45 ⌘ 组合键后 Command 残留

⌘A/⌘C/⌘V 之后，即使 host 已退出，`CGEventSource.flagsState` 仍为 `0x20100000`，`keyState(55)` = true。按停止规则结束 host，并发一个不带 flags 的 flagsChanged 清除，之后读数恢复 `0x20000000`。

原因：host 只在 A/C/V 的按键事件上设 `.maskCommand`，系统会话的 flags 状态沿用最后一个事件的 flags。修复 `f8fd76e`：组合键前后发真实的修饰键按下/松开（flagsChanged），最后一个不带 flags；cleanup 释放修饰键，并且总是以一个不带 flags 的 flagsChanged 收尾。

同一轮测试驱动出错：页面 ⌘ 是切换键，第二次点 ⌘ 把它关掉了，「C」被当作普通字符输入并覆盖了全选内容；TextEdit 自动保存了这个改动。fixture 已重新生成，剪贴板未被改动。
