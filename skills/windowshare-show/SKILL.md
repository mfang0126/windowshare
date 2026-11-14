---
name: windowshare-show
description: Hand a step that needs a person (login, approval, tricky UI, a quick look) to them on their phone - share the right Mac window with WindowShare (find it by URL, app, title or window ID), then wait for them.
---

# windowshare-show

## 何时用
需要人亲自完成的一步：登录、授权、批准按钮、你做不好的操作，或想让人看一眼。

命令都在仓库里：`Scripts/windowshare`（共享、`list`、`status`）和 `Scripts/windowshare-show`（交给人）。找窗口全靠 WindowShare 自己，不需要 LCU 或 computer use。

## 一条龙（例：让人登录 AWS 控制台）

    Scripts/windowshare status --json                  # 第 1 步：看现在有没有在共享、共享的是哪个窗口
    log=$(mktemp)
    Scripts/windowshare --url console.aws.amazon.com --wait 30 --interact >"$log" 2>&1 & ws=$!
    for i in $(seq 1 40); do grep -q '^\[cli\] sharing' "$log" && break; kill -0 $ws 2>/dev/null || break; sleep 1; done
    if grep -q '^\[cli\] sharing' "$log"; then grep '^\[cli\] entry' "$log"; else kill $ws 2>/dev/null; wait $ws; echo "共享失败，退出码 $?"; cat "$log" >&2; fi
    Scripts/windowshare-show --reason "请在手机上登录 AWS 控制台，登录完点完成"
    kill $ws                                           # SIGTERM：松开按键、撤销窗口后退出

1. **先 `status`。** `running:false`：照上面启动共享。`running:true` 且 `window` 就是你要的窗口：跳过共享，直接 `windowshare-show`。共享的是别的窗口：同一时间只有一个共享（ADR 0003），不要停它、不要等；启动共享会立即退出码 `8` 并打印 `[share] busy: 正在被 X 使用（…已开 N 小时 M 分钟）`，把这行原样告诉老板，由老板决定。
2. **共享。** 浏览器里的页面用 `--url <域名或网址片段>`；`--wait 30` 等页面打开（比如你刚让浏览器打开登录页）。要让人输入必须加 `--interact`。加 `--owner "<你的名字>"`，别人撞上时看到的是你。共享随开启它的进程（默认是运行命令的 shell，可用 `--owner-pid <pid>` 指定）退出而结束；老板明确要求「持续分享」时才加 `--persistent`，它不随进程退出结束，做完后要告诉老板它还开着。任何共享 12 小时到点结束，提前 10 分钟打印 `[share] reminder`，结束时打印 `[share] ended reason=…`（`done` 老板点了「完成」、`boss` 老板在菜单栏点「完成（结束共享）」、`limit` 12 小时、`window_closed` 窗口关了、`unavailable` 睡眠/锁屏、`opener_exit` 开启进程退出），转告老板；共享结束后这个共享进程自己退出（`done` 时等约 10 秒，让 `windowshare-show` 读到结果）。
3. **交给人。** `windowshare-show` 打印 `请在手机打开：<共享链接>`（`…/w/<共享 id>`），把这行转告用户。链接只属于这次共享，结束即失效；下次共享是新链接，不要复用旧链接或根地址。
4. **停。** 老板点「完成」时共享已经结束、链接已失效；超时、取消或你自己做完时 `kill $ws`（进程已退出也无妨）。不要留着共享。

## 选窗口的参数（只能用一个）
- `--url <片段>`：Chrome、Arc、Safari、Edge、Brave 当前标签页网址包含该片段的窗口，取最前面那个。Firefox 不支持。第一次用会弹 macOS「自动化」权限框，需要用户点允许；用户不在时别用，改用 `--window-id`。加 `--fallback-default-browser` 才会在找不到时退到默认浏览器最前面的窗口。
- `--app "<App 名>"`：该 app 最前面的窗口。App 名用 `list` 里的写法，如 `Google Chrome`。
- `--default-browser`：系统默认浏览器最前面的窗口。
- `--window-id <id>`、`--window "<精确标题>"`、`--title-contains <片段>`：必须正好匹配一个窗口。
- `--wait <秒>`（1–600）：每秒重找一次，直到窗口出现或超时。

找不到时退出码 `3`，stderr 里有 `list --json` 的全部可共享窗口（`app`、`bundle_id`、`pid`、`window_id`、`title`、`frontmost`）。从里面挑一个，用 `--window-id` 重来；拿不准就问用户，不要随便共享别的窗口。也可以先 `Scripts/windowshare list --json` 自己看。

## 共享进程的退出码和输出
- 选好窗口后每行打印一个本次共享链接：`[cli] entry tailscale=…/w/<共享 id>`、`[cli] entry lan=…/w/<共享 id>`（Tailscale 和局域网默认都开）。没装或没连 Tailscale 时只警告，继续用局域网入口。
- `3`：没找到唯一匹配的窗口。`4`：窗口找到了但捕获失败。`6`：Tailscale 和局域网都不可用。`7`：端口被占（已有别的 WindowShare，或换 `--port`）。`2`：参数错误。
- `8`：已有共享（全机一把锁，换端口也一样），立即返回「正在被 X 使用」，不排队。不要停别人的共享，告诉老板。
- `7` 时先 `status`，不要停别人的实例。

## 交给人
一条命令，会阻塞到人处理完或超时：

    Scripts/windowshare-show --reason "请登录 AWS 控制台" [--timeout 300] [--events]

`--reason` 写给人看，说清要做什么（最多 200 字）；`--timeout` 为 30–1800 秒，默认 300。`--events`（可选，草稿，待 Ming 拍板）：不每 2 秒轮询，改等下面的事件接口，结果一出约 0.1 秒内退出；退出码不变；手机离开或连接丢失时 stderr 打一行 `手机端 left|disconnected（reason=…）；请求仍在等待`，请求继续等。host 没有事件接口时自动退回轮询。

退出码：
- `0` done：人说做完了。这只是人的自述，不代表一定成功；继续前自己检查结果。
- `3` cancelled：人取消，或共享窗口被关。不要重试，问用户怎么办。
- `4` timeout：人没在时限内处理。告诉用户，由用户决定是否再发一次。
- `5` no_window：WindowShare 在运行但没有共享窗口。按上面先共享，或请用户在菜单栏选择窗口。
- `2` 其他错误（WindowShare 未运行、token 失效、已有进行中的请求等）：读 stderr，告诉用户。

## 事件接口（草稿，待 Ming 拍板）
只给本机 Bot：`GET http://127.0.0.1:<port>/agent/events/<after>`，`Authorization: Bearer <token>`（`agent.json` 里的 port、token），和 `/agent/request` 同一道鉴权：只认 loopback、不认 Origin / Cookie / 代理头，token 错 401。长轮询：有比 `<after>` 新的事件立即回 200，否则最多挂 3 秒回 204，再用同一个游标重发。读事件不消费，多个读者拿到的一样；同时挂着的最多 4 个，第 5 个 429。

回 `{"events":[…], "next":<游标>}`；下次用 `next`。host 只留最近 64 条，落后太多时带 `"truncated":true`；游标比 host 当前的还大（host 重启过，token 也会变）时带 `"reset":true`，从头给。每条事件只有这些字段，不含窗口标题、画面、链接、共享 id、token、`--reason` 原文：

| 字段 | 说明 |
|---|---|
| `seq` | 递增序号，本 host 进程内唯一 |
| `kind` | `done`、`cancelled`、`timeout`、`left`、`disconnected`、`share_ended` |
| `request_id` | `done`、`cancelled`、`timeout`、`share_ended`：当前（或刚结束的）请求 id；`left`、`disconnected`：最后一个观看端离开那一刻还在等待的请求 id（不是 N 秒到点时的）。没有时为 `null` |
| `at` | Unix 秒（Mac 时钟） |
| `reason` | 固定词，见下表 |
| `hint` | 只有 `disconnected` 有，可选，不可当真 |

| kind | 什么时候 | reason | 资源 |
|---|---|---|---|
| `done` | 手机点「完成」（明确） | `phone_done` | 共享立即结束，链接失效，紧接一条 `share_ended` |
| `cancelled` | 手机点「取消」（明确），或共享因别的原因结束时请求还没完 | `phone_cancel` / `share_ended` | 前者共享继续 |
| `timeout` | 请求到了 `--timeout` | `request_timeout` | 共享继续 |
| `left` | 手机明确上报离开：「停止观看」或页面卸载时发的离开信号，之后 N 秒内没有观看端连回来 | `stop_watching` / `page_unload` | **不回收**，共享和链接都还在 |
| `disconnected` | 没收到离开信号，最后一个观看端的连接消失（心跳 15 秒超时或连接被关）后 N 秒仍没有连回来。关页、切后台、断网、休眠、App 被杀都是这一种，host 分不清 | `connection_lost`；`hint`：`heartbeat_timeout` / `connection_closed` | **不回收** |
| `share_ended` | 共享结束（完成、菜单停止、12 小时、窗口关闭、睡眠锁屏、几何失败、换窗口……） | host 内部的结束原因词，如 `done`、`shareLimit`、`revokeWindow`、`geometryUnavailable`、`select` | 已结束 |

有多个观看端时只看最后一个离开的：它发了离开信号记 `left`，否则记 `disconnected`；还有观看端连着就什么都不记；从没连上过的页面关掉也不记。N 默认 45 秒，环境变量 `WINDOWSHARE_LEAVE_SEC`（1–3600）可改，**待 Ming 定**。离开信号是手机页面在自己的控制连接关闭前发的一条 `leave` 消息（「停止观看」另有 HTTP 关闭会话作同一信号，谁先到都算），尽力而为。手机上关标签页通常先进后台：进后台那一刻页面就关了连接（后台不算离开），之后的卸载已发不出信号，所以多半记 `disconnected`；`page_unload` 主要见于前台直接卸载（桌面关标签、页面跳转）。另外，App 被杀、断网时发不出，这时只会有 `disconnected`；刷新页面会在 N 内连回来，不记事件。心跳超时要先等 15 秒才算连接消失，所以断网到 `disconnected` 约 15 + N 秒。

收到事件只当「状态可能变了」：回收前再 `GET /agent/request/<id>` 确认，并核对 `request_id` 是自己的。`left`、`disconnected` 不代表人做完了，也不代表失败，由你决定重发链接、继续等还是结束共享。原来的 `GET /agent/request/<id>` 和 2 秒轮询不变。

## 规则
- 绝不索要或转述密码、验证码；让人在手机上的窗口里自己输入。
- 你拿不到窗口画面，也看不到人的输入；`list` 和 `status` 只有窗口元数据。
- 只共享这一步需要的那个窗口，用完就停。
