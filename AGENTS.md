# AGENTS.md — WindowShare

开工前读两个文件：

1. `INTENT.md`：做什么、必须守住什么、不做什么。
2. `PLAN.md`：当前做到哪一步、下一步是什么、怎么判断做完。

其余文件按需查：`README.md`（安装和用法）、`LEARNING-LOG.md`（踩过的坑，改捕获、输入、网络前先看）、`docs/adr/`（难逆决策）、`docs/research/`（背景资料）、`evidence/`（截图等实测证据）。旧文档全部在 tag `archive/2026-10-29-pre-refocus`，需要时用 `git show archive/2026-10-29-pre-refocus:<路径>` 查看，不要恢复回主线。

## 规则

- **方向和文档冲突时**，先停下来指出冲突；改完 `INTENT.md` 或 `PLAN.md` 再继续。口头结论不生效。
- **只做 `PLAN.md` 里的当前步。** 新想法记进 `PLAN.md`，不顺手做。
- **完成 = 代码能跑 + 实测一次**：一句话结果或一行数字写进 `PLAN.md`，然后 commit。不写 review 文档、验收清单或阶段报告。
- **小步 commit**，代码和对应的 `PLAN.md` 更新放在同一个 commit。push 要先问用户。
- **会动 Mac 鼠标、键盘或切换前台窗口的测试**，跑之前先告诉用户。
- 测试只用受控窗口（`Scripts/latency-target.html`、TextEdit 测试文件），不抓随机窗口。
- 不代输密码和验证码，不绕过锁屏。
- 一个功能一份说明，写进已有文件，不新建同类文档。
- 新的踩坑经验，只有会改变下次做法的，才追加到 `LEARNING-LOG.md`。
