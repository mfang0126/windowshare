# 0002 - v1 传输层用 MJPEG + WebSocket，WebRTC 推迟到 v2

状态：accepted（2026-10-13）

v1 的视频传输采用 MJPEG over HTTP（控制走 WebSocket），不按架构报告 §17 直接上 WebRTC + H.264。考虑过直接 WebRTC——最终形态确实需要它（低延迟、带宽自适应）——但 v1 的目标是最快验证「手机看 + 控 Mac 窗口」这个体验本身：MJPEG 概念少、浏览器直接可看、调试直观，且对「文字窗口、内网、单 viewer」场景性能足够，它本身就是合法的 v1 产品形态（同类工具 shipped MJPEG），不是测试废件。WebRTC 的信令/编解码调试是最大的时间黑洞，与「快速验证、只做关键验证」冲突。

预留：信令/视频/控制三通道分离的接口边界（报告 §7），v2 升级 WebRTC 时替换传输层不动产品逻辑。视觉降级风险：MJPEG 帧率/码率上限低于 H.264，滚动流畅度以 StreamTuningPolicy 帧率策略兜底。
