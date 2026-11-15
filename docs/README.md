# 文档索引

现行产品依据是 [分享页产品要求](product/share-page-ux-20261115.md)；项目范围与进度分别见 [INTENT](../INTENT.md)、[PLAN](../PLAN.md)。历史实测保留为历史证据，不表示新交互已经验收。

| 文档 | 用途 | 状态 |
|---|---|---|
| [README.md](README.md) | docs 全目录索引 | 现行 |
| [product/share-page-ux-20261115.md](product/share-page-ux-20261115.md) | 正常分享、手机操作、地址选择、AI 路径及以后验收的要求 | 现行，产品要求主文档 |
| [adr/0001-native-capture-route.md](adr/0001-native-capture-route.md) | 原生 ScreenCaptureKit 路线及拒绝 MirageKit 的决策 | 现行；传输协议以 ADR 0002 为准 |
| [adr/0002-mjpeg-and-websocket-for-v1.md](adr/0002-mjpeg-and-websocket-for-v1.md) | v1 使用 MJPEG 和 WebSocket | 现行；帧率优化暂缓，见产品要求 |
| [adr/0003-share-lifecycle.md](adr/0003-share-lifecycle.md) | 单共享、开启者归属、持续分享与结束规则 | 现行；老板结束方式已由产品要求改为关页，原完成按钮只在 debug |
| [research/air-pane-lessons.md](research/air-pane-lessons.md) | 旧项目经验及 ADR 0001 选型依据 | 待确认：许可拒绝依据仍被 ADR 引用，旧里程碑和帧率经验仅作历史参考，暂不移动 |
| [archive/m1-phone-test.md](archive/m1-phone-test.md) | M1 手机测试历史步骤 | 过时；原路径 docs/m1-phone-test.md；依赖 Interact/键盘按钮与旧端口及页面入口，现行体验见产品要求，历史结果见 PLAN |
| [archive/m2-phone-test.md](archive/m2-phone-test.md) | M2-a 延迟对比历史步骤 | 过时；原路径 docs/m2-phone-test.md；依赖旧按钮，当前不做帧率优化，现行要求见产品要求，历史结果见 PLAN |
| [archive/research/android-mac-app-share-architecture-report.md](archive/research/android-mac-app-share-architecture-report.md) | 初期架构方案及资料来源 | 过时；原路径 docs/research/android-mac-app-share-architecture-report.md；WebRTC、配对、公网 TURN 和系统选择器提案已被 INTENT、ADR 0001/0002 及产品要求替代 |

没有发现可整份判为重复的文档。局部历史内容重叠不另删文件；待确认文档维持原位置。
