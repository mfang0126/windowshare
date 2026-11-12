# M1 验证记录（2026-10-13 17:14 AEDT）

环境：macOS 26.6.2，Swift 6.4 / Xcode 27.0，build/WindowShareHost.app（release，ad-hoc 签名）
方法：`WindowShareHost --window ws-test --port 8777` 捕获 TextEdit 测试文件窗口（受控内容），curl `/stream.mjpg` 3 秒得 2.6MB/89 帧，提取中间帧 72KB（`frame-middle.jpg`），视觉判读。

## 结果

- [x] **验证①单窗口捕获无桌面泄漏**：画面边界契合窗口边缘，无壁纸、无菜单栏、无 Dock、无其他窗口。
- [x] **验证②文字可读**：中文「中文测试：在手机上这段中文必须清晰可读。」、英文、数字符号全部逐字转录命中，抗锯齿锐利。
- 流参数实测：≈15fps 上限（3s 内 89 帧 ≈ 11fps 含连接建立），2x 缩放输出。

## 过程坑（已修）

- `NSBitmapImageRep` 编码在无完整 AppKit 初始化的进程里触发 `CGS_REQUIRE_INIT` 断言崩溃 → 换 ImageIO（`CGImageDestination`）编码 + `NSApplication.shared` 显式初始化。
- `SCStreamOutputType` 视频输出是 `.screen` 不是 `.video`。
- SCShareableContent 超时+重试兜底（SideScreen 的 FB12114396 坑）已内置，本次未触发。
