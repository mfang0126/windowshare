# M2 验证记录（2026-10-20 19:20–21:10 AEDT）

环境：macOS 26.6.2 · `build/WindowShareHost.app`（release，ad-hoc）· 手机与 Mac 同一 Wi-Fi（LAN `<lan-ip>`）· 捕获窗口 = TextEdit `ws-test.txt`（656×422，受控内容）

## 结果

- [x] **验证②：手机上文字可读**
  - 手机打开 `http://<lan-ip>:8777/` → 页面加载、画面出现
  - 用户判读：**「很清晰」**（2026-10-20 19:29）
  - 帧率侧观测：解锁后 2 秒内 frames 从 28114 → 28142（≈14fps，符合 idle 12–15 档）；3 秒取流 3.88 MB
  - 证据级：**用户口头确认**；本目录无手机截图

- [x] **验证②b：三断点 contact sheet 可一眼判读**
  - 三个受控响应式页面，Chrome 窗口用 AppleScript 设为 390×844 / 768×1024 / 1280×800
  - 每个窗口单独经 WindowShare 取流一帧；`/status.json` 确认尺寸分别为 390、768、1280（非同一图重采样）
  - `sheet.jpg`（2604×924）由 ffmpeg `hstack` 合成；`sheet.html` 提供并排查看与单张放大
  - 用户判读：**「看到了，没问题」**（2026-10-20 21:07）
  - 证据级：**用户口头确认**；三张原图与本目录文件字节一致

## 证据文件

- 截图（`cap-390.jpg`、`cap-768.jpg`、`cap-1280.jpg`、`sheet.jpg`）在公开仓库中已删除：画面里带有测试者浏览器的个人书签栏。
- 生成脚本与页面：`/tmp/ws-responsive/`（临时目录，24h 清理；本目录保留成品）

## 过程中确认的边界（不是 bug）

1. **Mac 锁屏 → 0 帧**：`CGSSessionScreenIsLocked = 1` 时 `/stream.mjpg` 返回 200 但 0 字节、frames 停止增长；静态文件仍 200。
2. **显示睡眠 → 0 帧**：display asleep 时同样 0 帧；`caffeinate -u -d` 唤醒后立刻恢复。
3. 两者都要求 **Mac 已解锁 + 显示唤醒** 才能捕获，与 INTENT 不变量 5（不绕过锁屏）一致。app 目前**不自持 power assertion**，测试靠外部 `caffeinate -u -d -t 7200` 兜底。
4. **无鉴权 + 监听所有网卡**：同一 Wi-Fi 下任何设备可访问 `/` 与 `/stream.mjpg`。M4 的配对/token 之前，服务只应临时开启。

## 未验证 / open

- Tailscale 路径：本机自测 `<tailscale-ip>:8777` 返回 000（连接超时），同端口 python `http.server` 两种绑定均 200；未做真机验证，不阻塞 M2。
- 手机在展开/折叠两种形态下的可读性未分别记录（本次为单一形态确认）。
- 输入交互（点击/滚动/中文输入）属 M3，本记录不涉及。
