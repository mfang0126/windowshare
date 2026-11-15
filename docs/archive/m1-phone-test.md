# M1 手机测试步骤（M1-4 延迟基线、M1-5 闭环实测）

你只需要拿手机按「你做」操作；「Mac 上」的命令由 agent 在你确认后执行，也可以自己在仓库根目录运行。每段开始前 agent 会先告诉你，等你说「开始」再动。

## 会发生什么

- M1-4 每次点击都会真实点到 Mac 上的测试窗口，**Mac 的鼠标指针会跳过去**，跑测量的约 1 分钟里别碰 Mac 的鼠标。
- M1-5 只用本地测试登录页 `Scripts/login-test.html`，不用真实账号。随便编一个用户名和密码；页面只显示用户名和密码位数，不发送到任何地方。
- 全程只共享测试窗口（`ws-latency-target`、`ws-login-test`），不共享别的窗口。

## 开始前（一次）

你做：

1. Mac 解锁，屏幕亮着（锁屏或显示睡眠时没有画面）。
2. 手机和 Mac 都连上 Tailscale；手机装好 Chrome。
3. 手机用 USB 连 Mac，开着「USB 调试」（开发者选项里）。第一次连会弹「允许 USB 调试吗」，点允许。

Mac 上（agent 执行）：

```sh
adb devices                                   # 应列出一台 device
lsof -nP -iTCP:8777 -sTCP:LISTEN              # 8777 必须空闲
WINDOWSHARE_SIGNING_IDENTITY=<证书 SHA1> ./Scripts/build-app.sh release
WS=build/WindowShareHost.app/Contents/MacOS/WindowShareHost
TS=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4); echo "Tailscale 入口 http://$TS:8777/"
```

8777 被占用时（例如另一个 worktree 的 WindowShare），agent 会先问你能不能停掉它，不会自己去关。

## M1-4 延迟基线：USB 和 Tailscale 各 30 次

### 准备测试窗口（两条路径共用）

Mac 上：

```sh
open -na "Google Chrome" --args --new-window "file://$PWD/Scripts/latency-target.html"
$WS --window "ws-latency-target" --interact > /tmp/ws-m1.log 2>&1 & echo $! > /tmp/ws-m1.pid
sleep 3; grep '^\[cli\] sharing' /tmp/ws-m1.log    # 必须看到这一行
adb forward tcp:9222 localabstract:chrome_devtools_remote
```

### A. USB 路径

Mac 上：

```sh
adb reverse tcp:8777 tcp:8777 && adb reverse tcp:8778 tcp:8778
```

你做：

1. 手机 Chrome 打开 `http://127.0.0.1:8777/#latency`。
2. 看到黑色画面后，点「开启 Interact」。
3. 把手机放下，别再碰屏幕，告诉 agent「好了」。

Mac 上（约 45 秒，鼠标会跳）：

```sh
node Scripts/latency-run.mjs 30 usb
```

输出一行 JSON。`matched` 应接近 30；明显偏少说明画面没翻转，告诉 agent 后重跑。

### B. Tailscale 路径

Mac 上：

```sh
adb reverse --remove-all
```

你做：

1. 关掉上一个标签页，手机 Chrome 打开 `http://<Tailscale 入口>/#latency`（agent 会把完整地址发给你，形如 `http://100.x.y.z:8777/#latency`）。
2. 能看到画面，就说明命令行共享经 Tailscale 可以打开（这也是 M1-1 的手机验收）。
3. 点「开启 Interact」，放下手机，告诉 agent「好了」。

Mac 上：

```sh
node Scripts/latency-run.mjs 30 tailscale
```

USB 线只用来让 Mac 驱动手机上的点击（CDP）；画面和输入走的是 Tailscale。

### 收尾和记录

Mac 上：

```sh
kill $(cat /tmp/ws-m1.pid); adb forward --remove-all
```

agent 把两行结果写进 `PLAN.md`「延迟记录」（日期、commit、路径、p50、p95、matched/30），M1-4 标完成。你可以关掉 Chrome 里的 `ws-latency-target` 窗口。

## M1-5 闭环：手机经 Tailscale 在测试登录页输入

这一步验证 M1 的完整用法：一条 `--app` 命令共享 Chrome，手机经 Tailscale 输入。

Mac 上：

```sh
open -na "Google Chrome" --args --new-window "file://$PWD/Scripts/login-test.html"
sleep 2
$WS --app "Google Chrome" --interact > /tmp/ws-m1.log 2>&1 & echo $! > /tmp/ws-m1.pid
sleep 3; grep '^\[cli\] sharing' /tmp/ws-m1.log    # owner=Google Chrome，title=ws-login-test
```

`title` 不是 `ws-login-test`，说明登录页窗口不在 Chrome 最前面：agent 会停掉共享，请你在 Mac 上点一下登录页窗口后重来。

你做（不需要 USB）：

1. 手机 Chrome 打开 `http://<Tailscale 入口>/`。
2. 点「开启 Interact」。
3. 点用户名输入框，用「键盘 / 中文输入」输入一个编的用户名（中英文都可以）。
4. 点密码框，输入一个编的密码。
5. 点「登录」。页面下方应显示「已提交：用户名「…」，密码 N 位」。
6. 告诉 agent 你看到的那行字，以及中途有没有卡顿或点偏。

Mac 上：

```sh
kill $(cat /tmp/ws-m1.pid)
```

agent 把一句结果写进 `PLAN.md` 的 M1-5 状态。密码本身不写进任何文件。

## 出问题时

- 没画面：Mac 是否锁屏或显示睡眠；`/tmp/ws-m1.log` 里有没有 `[cli] sharing`。
- 共享进程退出码 3：没找到窗口（标题不对或 app 没开）；退出码 4：捕获失败。
- Tailscale 入口打不开：两端 Tailscale 都要在线；Mac 本机 curl 自己的 Tailscale 地址超时是已知现象（LEARNING-LOG M2-4），以手机为准。
- 点了没反应：确认已点「开启 Interact」；打字时 Chrome 必须在 Mac 最前面。
