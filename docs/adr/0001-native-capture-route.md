# 0001 - Mac 端捕获走原生 ScreenCaptureKit 路线，拒绝绑定 MirageKit

状态：accepted（2026-10-13 确认，结论源自 2026-05-11 air-pane 调研）

Mac 端窗口捕获采用 Apple 原生 ScreenCaptureKit（编码链路 VideoToolbox / WebRTC），不依赖 MirageKit 等第三方流传输库。考虑过 MirageKit——macOS→iOS、Bonjour/AWDL、`AVSampleBufferDisplayLayer`、输入转发，功能高度匹配——拒绝原因：其 license 为 PolyForm Shield，禁止用于竞争性远程桌面/投屏产品；且 `Package.swift` 写死作者本机绝对路径依赖（指向其作者本机目录的 Loom 路径），直接接入无法编译。证据与调研过程见 [../research/air-pane-lessons.md](../research/air-pane-lessons.md)。

被拒选项保留记录，防止未来有人再次提议「直接用 MirageKit 不就完了」。
