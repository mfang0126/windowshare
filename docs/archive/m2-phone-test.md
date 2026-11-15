# M2-a 手机对比测量（一次 session，约 20 分钟）

目的：在同一台手机、同一条 Tailscale 路径上，比较「基线」「M2-a 全开」「逐项关闭」各 30 次的点击→画面延迟，最后顺带跑一遍 M1-5 登录闭环。

**要知道的**
- 只用 M2-a 分支的构建：基线用 `WINDOWSHARE_M2A_OFF=all`，和 main 行为一致，不用换构建。
- 每轮都会真实点击 Mac 上的测试窗口，Mac 鼠标会跳；每段开始和结束都用 orca send 告诉协调者。
- 只共享 `ws-latency-target` 和 `ws-login-test`。

## 准备（约 3 分钟）

1. 手机：USB 连着，`adb devices` 能看到；Tailscale 已连接（打开 Tailscale app 能看到 `Connected`，`adb shell ip -4 addr` 里有 100.x）。
2. Mac：
   - 构建：`WINDOWSHARE_SIGNING_IDENTITY=<证书 SHA1> ./Scripts/build-app.sh release`
   - 确认 8777 空闲：`lsof -nP -iTCP:8777 -sTCP:LISTEN`
3. 打开测试窗口，并把它缩到 1000×800：各次测量的窗口大小一致，结果才能比。窗口要在 Mac 最前面，否则点击会被判定为被遮挡（日志里是 `stage=hit`）。
4. `adb forward tcp:9333 localabstract:chrome_devtools_remote`。Mac 的 9222 常被本机 Chrome 占用，所以用 9333。

## 每一轮（约 1.5 分钟 × 6）

| 轮 | `WINDOWSHARE_M2A_OFF` | 看什么 |
|---|---|---|
| 1 | `all` | 基线；应接近 M1-4 的 Tailscale p50 422 ms |
| 2 | 空 | M2-a 全开 |
| 3 | `push` | 关推画面 |
| 4 | `fps` | 关提帧率 |
| 5 | `small` | 关缩小帧 |
| 6 | `push,input` | 推画面和输入后出帧都关；和第 3 轮对比就是「输入后出帧」的效果（推画面开着时这项不起作用） |

每轮做法：

1. Mac：`WINDOWSHARE_M2A_OFF=<值> Scripts/windowshare --window "ws-latency-target" --interact &`，等日志出现 `[cli] sharing`。
2. JP：`session start`，intent 写「手机经 Tailscale 测 M2-a <轮次> 的点击延迟」。
   - `act launch_activity`：`component` 填 `com.android.chrome/com.google.android.apps.chrome.Main`，`data` 填 `http://<Mac Tailscale IP>:8777/#latency`。
   - 后置条件：`element_exists {"text_contains":"<IP>:8777/w/"}`。
3. 开启 Interact：JP 无法定位网页里的按钮，所以经 CDP 点 `document.getElementById('interact').click()`。状态变成「Interact · 可操作」再继续。
4. Mac：`CDP=9333 TAB=<IP>:8777 node Scripts/latency-run.mjs 30 m2a-<轮次>`，输出一行 JSON。
5. 把结果写进页面的 `#detail`，用 JP `observe source=pixels` 留证；然后 `session finish` 和 `trace`。
6. Mac：停掉共享进程。

## M1-5 登录闭环（约 3 分钟）

用 M2-a 全开再跑一遍 M1-5，步骤同 PLAN 的 M1-5：
- 共享 `ws-login-test`（同样缩到 1000×800）。
- 手机经 Tailscale 开 Interact，点用户名框，用 viewer 的「键盘 / 中文输入」发一个编造的用户名；点密码框，发一个编造的密码；点「登录」。
- 画面应显示「已提交：用户名「…」，密码 N 位」。
- 网页内的点击用 CDP 触摸（`Input.dispatchTouchEvent`），坐标取图片上的相对位置。
- 不用真实账号，密码不写进任何文件。

## 记录

每轮一行写进 `PLAN.md`「延迟记录」：日期、commit、路径、改动（`OFF=` 的值）、p50、p95、匹配数 / 30。逐项对比后，在 M2-a 状态里写一句结论：哪几项有效、目标 p50 ≤ 100 ms / p95 ≤ 200 ms 是否达到。
