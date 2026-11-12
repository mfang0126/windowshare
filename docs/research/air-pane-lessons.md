# air-pane 经验总结（保留参考，不删除）

> 来源项目：`~/Code/air-pane`（**保留不删**；回头汲取材料去那里找）
> 产出会话：Codex `019e17b9-036e-7510-b6c3-9dab2ae948e8`（2026-05-11，"air_pane_harness_and_first_swift_prototype"）
> 归档时间：2026-10-13。air-pane 目录自 2026-05-12 后未再改动，无 git 仓库。

## 1. MirageKit 证伪结论（最值钱的一条）

MirageKit（macOS→iOS 流传输库）功能高度匹配（Bonjour/AWDL、`AVSampleBufferDisplayLayer`、输入转发），但**不能绑死**：

- License 为 PolyForm Shield，禁止用于竞争性远程桌面/投屏产品。
- `Package.swift` 含作者本机绝对路径依赖 （指向其作者本机目录的 Loom 路径），直接接入无法编译。
- 远端 tags 已到 `1.0.8`（当时用户手上是 `1.0.5`）。

**结论**：走原生 ScreenCaptureKit + VideoToolbox/WebRTC 路线。已写入 [ADR-0001](../adr/0001-native-capture-route.md)。

## 2. 可编译 Swift 骨架（air-pane 内，可整段搬用）

`AirPaneShared`（窗口目标、stream profile、telemetry、input event）、`AirPaneHost`（cmux/terminal/browser preview 窗口筛选）、`AirPaneClientCore`、`AirPaneMirageBridge`（占位）+ `StreamTuningPolicy.swift`。2026-05-12 时 `swift test` / `swift build` / host+client CLI smoke 全绿。

## 3. 动态帧率策略（StreamTuningPolicy 实测值）

| 场景 | 帧率 |
|---|---|
| idle terminal | 12–15 fps |
| typing | 20–24 fps |
| scrolling | 30 fps |
| 视频/大面积变化 | ≤ 45 fps |

默认 terminal profile：HEVC、24 fps、text-optimized。client smoke 曾把 idle terminal 调到 `hevc, 12fps, 1200kbps, text=true`。

## 4. Level 1→5 分层验收（部分被取代）

原分层：L1 编译/CLI smoke → L2 本地 App + fake stream → L3 真单窗口捕获 → L4 真机收流+打字反控 → L5 开发工作流完成（手机看/控 cmux、browser preview、resize）。

**2026-10-13 决定**：L2 fake-stream 测试层被「真件优先、只做关键验证」取代——不做测试 MVP，M1 起就是真捕获。L3/L4/L5 的验收语义保留，映射进 `MILESTONES.md`。

## 5. 其他可复用点

- host smoke 按窗口名筛目标（`cmux - codex`、`localhost:3000 preview`）——窗口筛选思路可复用到「入口」匹配规则。
- harness 结构（短 AGENTS 入口 + 设计/验证文档 + 可执行脚本 + 进度跟踪）是 window-share 四文件 harness 的前身。
