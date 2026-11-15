<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# 安卓 → Mac 指定应用共享与控制：技术架构报告

本方案的定位是 **应用级远控**：安卓手机只显示、操作指定 Mac 应用的窗口；应用继续在 Mac 上运行。Mac 原生端负责窗口定位、捕获和输入执行，安卓端负责显示与交互，连接层负责认证、视频传输和控制消息。

本文区分两类内容：

- 平台能力：Apple SDK、浏览器 API、WebRTC 已提供的功能。
- 产品设计：需要我们自己实现的窗口匹配、坐标映射、权限边界、重连、布局恢复及控制权管理。

这是技术设计报告，不代表整套链路已完成编译、兼容性或性能验证。你的原始目标是“手机一点就进入现有桌面应用”，而不是重新开发手机版应用，也不是让用户运行几套远控软件拼接使用。

## 1. 系统组成与职责

| 组成 | 所在位置 | 技术名称 | 职责 | 不负责什么 |
| :-- | :-- | :-- | :-- | :-- |
| Mac Host | Mac | Swift、AppKit、ApplicationServices、ScreenCaptureKit | 管理应用窗口、获取画面、执行输入、维护会话 | 不重新实现目标 App |
| Android Viewer | 安卓浏览器，后续可原生化 | WebRTC Web API、HTML video、Pointer Events | 显示窗口画面，收集触控和文字输入 | 不在手机上运行 Mac 软件 |
| Session Coordinator | 主要位于 Mac，安卓保留对应状态 | 自定义会话状态机 | 串联认证、窗口准备、传输、控制和恢复 | 不替代编码器或网络协议 |
| Signaling Service | Mac 本机服务或独立服务器 | HTTPS／WSS、自定义信令协议 | 交换连接描述、网络候选和认证信息 | 默认不转发视频 |
| Media Transport | Mac 与安卓之间 | WebRTC、RTP／RTCP、SRTP | 实时传输视频，处理网络反馈 | 不决定用户可以操作哪个 App |
| Control Transport | Mac 与安卓之间 | RTCDataChannel | 传递输入、窗口状态、会话命令 | 不直接执行 macOS 输入 |
| Optional Relay | 公网服务器 | TURN | 直连失败时中继流量 | 不运行应用，也不负责窗口控制 |

WebRTC 提供连接和媒体能力，但不规定应用信令服务；`RTCDataChannel` 提供双向任意数据传输，具体消息格式需要自行设计。[^1][^2]

## 2. 完整使用流程：动作、执行者、技术和结果

以下以“安卓手机打开 Hermes Desktop”为例。


| 阶段 | 动作 | 执行者 | 使用技术 | 输出／用途 |
| :-- | :-- | :-- | :-- | :-- |
| 首次安装 | 启动 Mac Host | Mac 用户 | Swift 原生应用 | 建立可捕获、可控制的宿主进程 |
| 系统授权 | 授予捕获与辅助功能权限 | Mac 用户、macOS | 屏幕录制授权、Accessibility 授权 | 允许宿主获取画面和执行受支持的 UI 操作 |
| 首次配对 | 手机确认 Mac 身份，Mac 授权手机 | 两端配对模块 | 一次性配对凭据、设备凭据；具体协议自定义 | 建立长期信任关系 |
| 建立入口 | 保存“这台 Mac 的 Hermes” | 安卓入口管理 | 应用标识、窗口规则、显示配置 | 不再每次进入整个桌面找窗口 |
| 发起连接 | 手机点击 Hermes 入口 | 安卓端 | HTTPS／WSS 信令 | 请求建立指定应用会话 |
| 验证权限 | 判断该设备是否可访问、可控制 Hermes | Mac Host | 设备认证、应用访问策略 | 未授权设备不能进入控制流程 |
| 协商链路 | 交换媒体能力和网络地址 | 两端 WebRTC | SDP、ICE、STUN／TURN | 建立视频和控制通道 |
| 定位应用 | 找到 Hermes 进程和目标窗口 | App Resolver | NSWorkspace、SCShareableContent、Accessibility API | 形成当前有效的窗口绑定 |
| 准备布局 | 保存原布局，尝试手机适配 | Window Manager | AXUIElement 属性读取／修改 | 窗口尺寸适配，或进入缩放／平移回退模式 |
| 启动画面 | 捕获、编码、发送窗口内容 | Capture／Media 模块 | ScreenCaptureKit、WebRTC 编码器；可使用 VideoToolbox | 安卓出现可用画面 |
| 执行操作 | 手机点击、滑动、输入 | 安卓输入模块、Mac Input Executor | Pointer Events、RTCDataChannel、AX／CGEvent | Mac 上的真实应用发生变化 |
| 持续同步 | 更新画面、几何信息和网络配置 | 各模块 | 视频流、窗口通知、统计反馈 | 窗口移动、网络变化后保持一致 |
| 退出 | 停止输入、停止捕获、条件恢复布局 | Session Coordinator | 会话清理逻辑 | 无残留按键、无失效输入、避免覆盖用户改动 |

其中，`NSWorkspace` 可枚举或启动应用；ScreenCaptureKit 可枚举捕获对象；Accessibility API 可读取和修改受支持的 UI 属性。配对、应用入口、访问策略和恢复规则属于本产品需要实现的逻辑。[^3][^4][^5][^6]

## 3. 应用定位与窗口身份

### 3.1 涉及的技术名称

| 技术／标识 | 角色 | 用途 |
| :-- | :-- | :-- |
| `NSWorkspace` | 应用发现与启动入口 | 枚举运行中的应用，必要时请求启动应用 |
| `NSRunningApplication` | 运行进程描述 | 获得当前运行实例的信息 |
| Bundle Identifier | 持久应用标识 | 保存“要进入哪个 App”，不单靠窗口标题 |
| PID | 当前进程标识 | 对接本次运行的 Accessibility 应用对象 |
| `SCShareableContent` | 可捕获内容清单 | 获得当前可共享的显示器、应用和窗口 |
| `SCWindow` | 捕获窗口描述 | 用于选择本次捕获窗口 |
| `AXUIElement` | 可访问性对象 | 表示应用、窗口或控件，供读取属性和执行动作 |

应用枚举由 AppKit 提供；捕获对象由 ScreenCaptureKit 提供；UI 对象由 Accessibility API 提供。这三套对象属于不同体系，需要产品自己建立关联。[^5][^7][^3]

### 3.2 必须建立的匹配规则

建议保存“匹配规则”，而不是永久保存某个窗口 ID：

1. 先按 Bundle Identifier 找应用。
2. 再定位当前运行实例。
3. 优先寻找上次绑定窗口。
4. 失效时，按窗口角色、标题、尺寸等条件重新匹配。
5. 多窗口无法确定时，要求用户明确选择，而不是任意控制一个。

PID、窗口 ID 和 AX 对象都应视为运行期绑定。应用重启或窗口重建后，重新发现并验证。

### 3.3 两个身份不能直接混为一谈

- `SCWindow`：回答“捕获哪个窗口”。
- AX 窗口对象：回答“读取或操作哪个 UI 对象”。

不能假设两者天然一一对应，也不能只凭相同标题确定它们是同一个窗口。产品需要处理关联失败、重名窗口及对象失效。

## 4. 窗口尺寸、布局与手机适配

### 4.1 技术名称及动作

| 技术名称 | 动作 | 用途 |
| :-- | :-- | :-- |
| `AXUIElementCopyAttributeValue` | 读取属性 | 获得窗口位置、尺寸和状态 |
| `AXUIElementIsAttributeSettable` | 检查属性是否可修改 | 判断是否允许调整窗口 |
| `AXUIElementSetAttributeValue` | 修改属性 | 尝试改变位置、尺寸等 |
| `kAXPositionAttribute` | 窗口位置属性 | 支持布局管理和输入坐标转换 |
| `kAXSizeAttribute` | 窗口尺寸属性 | 尝试适配手机视口 |
| `AXObserver`／`AXObserverCreate` | 订阅目标应用通知 | 感知受支持的窗口变化 |
| `AXUIElementPerformAction` | 请求语义动作 | 对支持该动作的 UI 对象执行操作 |

AX 属性修改可能返回“不支持属性”“对象失效”“无法完成”等错误，因此“所有 App 都能任意 resize”不能作为技术承诺。[^6][^8][^9]

### 4.2 必须分开的三个尺寸

| 尺寸 | 单位／含义 | 谁控制 |
| :-- | :-- | :-- |
| Mac 窗口逻辑尺寸 | macOS 布局使用的逻辑坐标 | Window Manager |
| 捕获输出尺寸 | 视频帧像素宽高 | Capture／Media 模块 |
| 安卓可用视口 | 页面实际可用于显示的区域 | Android Viewer |

手机物理分辨率不等于 Mac 窗口逻辑尺寸。Retina 缩放、浏览器缩放、视频缩放及黑边都会影响转换；ScreenCaptureKit 的输出宽高则是独立可配置的捕获参数。[^10][^11]

### 4.3 建议的适配策略

1. 以手机可用视口比例提出目标窗口尺寸。
2. 检查目标 App 的最小尺寸和可调整能力。
3. 请求 resize 后，读取实际结果。
4. 按实际窗口大小生成视频，而不是按请求值假设成功。
5. 不能适配时，使用等比缩放、局部放大或平移。
6. 断开时，仅在符合恢复条件时还原。

窗口变窄，只能促使 App 按自己的布局规则重新排布；它不会自动获得原生手机版 UI。

恢复也不能无条件覆盖：若 Mac 本地用户在会话期间主动移动或调整窗口，产品应避免把用户的新布局强行改回去。

## 5. 画面捕获：ScreenCaptureKit

### 5.1 核心对象

| 名称 | 角色 | 用途 |
| :-- | :-- | :-- |
| `ScreenCaptureKit` | 捕获框架 | 获取显示器、应用、窗口画面 |
| `SCShareableContent` | 内容发现 | 列出可用于捕获的对象 |
| `SCContentFilter` | 捕获范围定义 | 规定流中包含或排除什么 |
| `desktopIndependentWindow` | 单窗口过滤方式 | 指定某一个窗口作为捕获对象 |
| `SCStreamConfiguration` | 捕获配置 | 设置尺寸、帧率、裁剪、像素格式等 |
| `SCStream` | 捕获流 | 持续产出捕获内容 |
| `SCStreamOutput` | 帧接收接口 | 接收捕获输出 |
| `CMSampleBuffer` | 样本容器 | 携带视频样本及相关元数据 |
| `CVPixelBuffer` | 像素缓冲区 | 为后续编码提供图像数据 |

ScreenCaptureKit 的职责是获取与筛选画面，不是远程控制，也不是网络传输。[^12][^13][^10]

### 5.2 必须配置的参数

| 参数／名称 | 作用 | 设计注意事项 |
| :-- | :-- | :-- |
| `width`、`height` | 输出视频像素尺寸 | 与窗口逻辑尺寸分开管理 |
| `minimumFrameInterval` | 限制最大更新频率 | 30 fps 对应最小间隔 $1/30$ 秒；不是固定产出承诺 |
| `sourceRect` | 选择捕获源区域 | 用于局部捕获，需按该捕获模式解释坐标 |
| `destinationRect` | 指定内容在输出中的区域 | 影响缩放、留白及输入映射 |
| `pixelFormat` | 像素格式 | 应匹配编码链路，减少转换 |
| `showsCursor` | 是否捕获鼠标指针 | 避免捕获指针与安卓绘制指针重复 |
| `queueDepth` | 捕获缓冲容量 | 容量影响内存与处理余量，不应当成长视频缓存 |
| `pointPixelScale`／帧几何元数据 | 逻辑坐标与像素关系 | 支持尺寸和坐标转换；检查 API 可用性 |

Apple 明确将输出尺寸、源／目标矩形、像素格式、指针、帧率及队列深度作为捕获控制项；帧率限制的是更新上限，实际更新还受内容和处理能力影响。[^11][^14][^15][^10]

### 5.3 三种捕获模式

| 模式 | 适用场景 | 边界 |
| :-- | :-- | :-- |
| 单窗口 | Hermes、终端、单个浏览器窗口 | 独立弹窗、菜单或其他窗口可能需要额外处理 |
| 应用窗口集合 | 同一 App 的多个窗口 | 手机端需明确展示和输入目标 |
| 显示器区域 | 共享桌面上的一个矩形 | 更容易包含无关内容，窗口移动时需要重新定义区域 |

你的主路径应是单窗口；区域捕获是补充，不应在窗口捕获失败时静默切换到整个桌面。

## 6. 视频编码：VideoToolbox 与 WebRTC 编码器

### 6.1 各层职责

| 技术 | 角色 | 用途 |
| :-- | :-- | :-- |
| `VideoToolbox` | Apple 编解码框架 | 提供底层视频压缩和硬件编解码访问 |
| `VTCompressionSession` | 编码会话 | 将像素帧压缩成指定编码格式 |
| H.264／AVC | 视频编码格式 | 作为 Mac → 安卓浏览器的优先兼容选项 |
| WebRTC 编码器接口 | 编码与实时网络的衔接层 | 接收码率反馈、生成适合媒体链路的编码输出 |
| RTP Packetization | 媒体封包 | 将编码视频组织成实时传输包 |

VideoToolbox 不是 WebRTC 的替代品：前者处理压缩，后者处理媒体协商、封包、传输和反馈。WebRTC 兼容实现要求支持 VP8 和 H.264 Constrained Baseline；实际会话仍须协商编码能力。[^16][^17]

### 6.2 两条实现路径

| 路径 | 描述 | 判断 |
| :-- | :-- | :-- |
| WebRTC 管理编码 | 把捕获帧交给 WebRTC 视频源，由其编码器路径处理 | 优先评估，减少编码与网络反馈脱节 |
| 自定义 VideoToolbox 编码器 | 在 WebRTC 编码器接口内接入 `VTCompressionSession` | 控制更细，但需要正确接入码率、关键帧和格式协商 |

不应“先用 VideoToolbox 编码，再把它当原始画面交给另一套编码器”，造成重复编码。也不应把 H.264 数据直接塞进普通数据通道，就认为完成了 WebRTC 视频链路。

### 6.3 低延迟配置名称

| 名称 | 用途 |
| :-- | :-- |
| `kVTCompressionPropertyKey_RealTime` | 标记实时编码用途 |
| `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` | 请求低延迟码率控制模式，须检查支持情况 |
| `kVTCompressionPropertyKey_AllowFrameReordering` | 控制帧重排序，避免不必要的等待 |
| `kVTCompressionPropertyKey_AverageBitRate` | 目标平均码率 |
| `kVTCompressionPropertyKey_ExpectedFrameRate` | 预期输入帧率 |
| `kVTCompressionPropertyKey_MaxKeyFrameInterval` | 关键帧间隔控制 |

Apple 的低延迟编码路径强调实时配置、低延迟码率控制及减少帧重排序；这些是优化手段，不是端到端延迟保证。[^18][^19][^20][^21]

## 7. 网络连接、视频通道与控制通道

### 7.1 建立连接的技术

| 名称 | 角色 | 用途 |
| :-- | :-- | :-- |
| HTTPS | 页面与接口保护 | 安全加载安卓页面、访问服务 |
| WSS | 实时信令连接 | 交换会话消息 |
| SDP Offer／Answer | 能力协商 | 描述媒体编码、连接参数等 |
| ICE | 路径发现与连通性检查 | 选择两端可用连接路径 |
| STUN | 地址发现 | 获得 NAT 外部地址等信息 |
| TURN | 中继 | 直连失败时转发数据 |
| `RTCPeerConnection` | 浏览器连接对象 | 管理 WebRTC 会话 |

STUN 不保证打洞成功，TURN 不等于应用服务器。信令服务器也不必位于视频数据路径中。[^22][^23][^1]

### 7.2 数据路径必须分开

| 路径 | 内容 | 使用技术 |
| :-- | :-- | :-- |
| 信令路径 | 认证、入口请求、SDP、ICE 候选 | HTTPS／WSS |
| 视频路径 | 编码后的窗口画面 | RTP／RTCP、SRTP、WebRTC |
| 控制路径 | 点击、滚动、文字、窗口几何、控制权 | RTCDataChannel |
| 可选中继路径 | 视频和控制流量中继 | TURN |

媒体通道使用 SRTP，数据通道使用 SCTP over DTLS；不能把所有 WebRTC 流量笼统称为“TLS 视频流”。[^24]

### 7.3 控制消息的传输策略

以下属于建议设计：

- 按下／抬起、文字提交、会话命令：可靠、有序传递。
- 高频指针位置：允许丢弃过时状态，避免排队后连续执行旧移动。
- 拖拽：移动可合并，但按下、抬起和取消必须有完整生命周期。
- 窗口几何更新：携带版本号，防止旧坐标作用于新布局。
- 所有动作：携带会话标识，拒绝上一段会话遗留的动作。

`RTCDataChannel` 提供传输能力；可靠性选择、消息协议和动作验证由产品定义。[^2]

## 8. 安卓显示、触控与文字输入

### 8.1 浏览器端技术

| 技术 | 角色 | 用途 |
| :-- | :-- | :-- |
| HTML `video` | 视频显示 | 播放收到的窗口视频 |
| `RTCPeerConnection` | 媒体连接 | 接收视频轨道 |
| `RTCDataChannel` | 控制通信 | 发送操作、接收状态 |
| `PointerEvent`／Pointer Events | 统一指针事件 | 收集触摸、鼠标、触控笔输入 |
| 手机端文字输入区域 | 输入法承载 | 让安卓输入法生成已提交文本 |
| 视口与视频布局管理 | 展示适配 | 处理横竖屏、键盘、缩放、黑边 |

Pointer Events 统一表达鼠标、触摸和触控笔，但“单指拖动”“双指滚动”等含义仍需产品定义，不能假设它们天然对应 Mac 鼠标行为。[^25][^26]

### 8.2 建议的手势协议

| 安卓动作 | 产品解释 | Mac 端动作 |
| :-- | :-- | :-- |
| 单击 | 点击目标 | 鼠标按下并抬起，或 AX 语义点击 |
| 拖动 | 拖拽目标 | 按下 → 移动 → 抬起 |
| 双指滑动 | 滚动内容 | 发送滚动增量 |
| 双指缩放 | 手机本地放大 | 默认不改变 Mac App 内容 |
| 长按 | 右键或操作菜单 | 产品可配置，不默认为任意系统动作 |
| 工具栏快捷键 | 显式键盘组合 | 执行允许的按键序列 |
| 文本提交 | 输入确定文本 | 文本输入通路 |

需要区分“移动鼠标指针”“拖动 App 内容”和“平移手机视口”，否则同一个滑动动作会产生歧义。

### 8.3 中文输入的技术边界

文字输入不能只依赖安卓键盘的逐键事件。

建议分为两个协议：

- Text Commit：发送输入法已经确定的文本。
- Key Action：发送 Enter、Backspace、方向键、快捷键等动作。

候选词组合期间，不把每一次未完成文本变化重复注入 Mac。Mac 侧的文本实现可使用支持写入的 AX 控件、应用适配接口或经兼容性验证的输入注入方案；没有一种路径能保证对所有 App 都完全一致。

剪贴板粘贴可以作为可选回退，但它会改变 Mac 剪贴板，并涉及额外隐私和恢复规则，不应成为隐含行为。

## 9. 坐标映射与 Mac 输入执行

### 9.1 需要管理的坐标空间

| 坐标空间 | 描述 |
| :-- | :-- |
| 安卓页面坐标 | 触控事件所在位置 |
| 视频显示内容坐标 | 排除黑边、工具栏，考虑缩放和平移 |
| 视频帧像素坐标 | 编码画面的实际像素位置 |
| 捕获内容坐标 | 考虑裁剪、目标矩形及帧元数据 |
| Mac 窗口／桌面坐标 | 最终输入执行位置 |

如果视频等比显示并带有留白，应先扣除内容偏移，再除以显示缩放比例；若手机进行了局部放大和平移，还要应用其逆变换。

不能简单按“手机宽度／Mac 屏幕宽度”计算，因为你共享的是窗口，而不是整个桌面。

### 9.2 输入执行技术

| 技术名称 | 角色 | 用途 | 边界 |
| :-- | :-- | :-- | :-- |
| `AXUIElementPerformAction` | 语义操作 | 请求控件执行受支持的动作 | 依赖应用可访问性支持 |
| `AXUIElementSetAttributeValue` | 属性操作 | 修改支持写入的属性 | 不是通用文本输入保证 |
| `CGEvent` | 事件表示 | 创建鼠标、键盘、滚动事件 | 需要系统权限及正确上下文 |
| `CGEventPost`／`CGEvent.post(tap:)` | 事件注入 | 将事件送入系统事件流 | 不是指定 App 的隔离输入通道 |

Apple 将 AX 动作定义为对可访问性对象的请求；Quartz 事件发送则进入系统事件流，因此捕获窗口范围并不会自动约束输入影响范围。[^9][^27][^6]

### 9.3 每次执行动作前的验证

建议按以下顺序处理：

1. 验证设备授权与当前会话。
2. 验证该会话是否持有控制权。
3. 验证目标应用和窗口仍然存在。
4. 验证几何版本，拒绝过期坐标。
5. 验证点击位于允许的共享区域。
6. 验证焦点、遮挡、模态窗口及输入目标。
7. 执行动作；条件不满足时暂停，不盲目投递。

“坐标落在目标窗口矩形内”仍不足以证明输入一定落入目标 App：窗口遮挡、焦点改变及系统快捷键都可能改变结果。

### 9.4 弹窗与菜单

单窗口捕获需要独立定义：

- 同一 App 的 sheet 如何展示。
- 独立弹窗如何纳入共享范围。
- 菜单是否可见、是否可以控制。
- 文件选择器和系统权限窗口是否暂停。
- 新增捕获窗口是否需要用户授权。

正确的回退是明确提示或授权扩展范围，而不是静默共享整个桌面。

## 10. 配对、身份、加密与授权

### 10.1 四层安全职责

| 层次 | 回答的问题 | 建议机制 |
| :-- | :-- | :-- |
| 页面与信令安全 | 请求是否被篡改？ | HTTPS／WSS |
| 传输安全 | 视频与输入是否被窃听？ | WebRTC 的 SRTP／DTLS |
| 设备身份 | 对端是不是已配对手机？ | 设备凭据、挑战验证或受控会话凭据 |
| 操作授权 | 这个设备能控制什么？ | 应用白名单、查看／控制权限、撤销机制 |

WebRTC 强制保护媒体与数据传输，但应用仍需保护信令和身份绑定。加密连接成立，不等于该设备已经获得控制授权。[^24]

### 10.2 证书不能混为一谈

- HTTPS 证书：证明网页／信令服务端身份。
- WebRTC DTLS 证书：参与媒体连接的安全建立。
- 配对凭据：表达“用户授权了这台设备”。
- 会话权限：表达“本次允许查看或控制哪些应用”。

自建证书只是其中一个环节，不会自动完成持久配对或应用级授权。浏览器方案还要解决证书信任和页面来源安全，不能用“忽略证书告警”替代安全设计。[^24]

### 10.3 建议配对流程

1. Mac 创建一次性、短期配对邀请。
2. 安卓读取邀请，连接正确服务。
3. 两端确认目标设备。
4. Mac 发放长期设备凭据。
5. 保存该设备允许访问的应用与权限。
6. 后续连接验证设备身份，再签发当前会话权限。
7. Mac 端提供立即撤销设备授权的入口。

二维码用于携带邀请，不应长期包含可重复使用的高权限控制密钥。

### 10.4 macOS 权限

| 权限／机制 | 作用 |
| :-- | :-- |
| 屏幕捕获相关授权 | 允许程序化获取屏幕内容 |
| Accessibility 授权 | 允许宿主作为可信辅助功能客户端 |
| `AXIsProcessTrustedWithOptions` | 检查辅助功能信任状态 |
| `SCContentSharingPicker` | 用户主动选择共享内容的系统入口 |

系统选择器与程序化捕获的授权路径不同；“用户当前选择了窗口”不能直接当成“以后可以无人交互自动共享”。具体授权行为需按目标 macOS 版本验证。[^28][^29]

第一版不绕过锁屏，不设计无人值守解锁；电脑锁定、休眠或权限撤销时，明确暂停或失败。

## 11. 动态画质与低延迟策略

“动态压缩”应拆为多个独立控制项：


| 控制项 | 调整内容 | 用途 |
| :-- | :-- | :-- |
| Capture Resolution | 捕获像素数 | 降低源头处理负担 |
| Capture Frame Rate | 最大更新频率 | 降低持续捕获与编码负担 |
| Encoder Bitrate | 编码目标码率 | 适配可用带宽 |
| Frame Dropping | 丢弃过时帧 | 防止画面越积越旧 |
| Keyframe Control | 关键帧请求与间隔 | 支持解码恢复、重新加入 |
| Display Scale | 手机显示比例 | 改善可读性，不等于节省网络流量 |

ScreenCaptureKit 提供尺寸和帧率控制；VideoToolbox 提供编码配置。实际自适应策略需要媒体反馈与产品控制逻辑配合。[^19][^10]

建议默认策略：

- 文字清晰优先。
- 30 fps 作为初始上限，不承诺固定 30 fps。
- 网络不足时，优先降低不必要的帧率，再按可读性调整尺寸。
- 避免无限编码、发送或解码队列。
- 重连和编码尺寸变化后确认解码恢复。

30 fps 的帧间隔约为 33.3 ms，不等于操作反馈延迟。总延迟包括输入上行、系统执行、App 重绘、捕获、编码、下行、解码和显示；必须实际测量。

## 12. 会话状态、断线重连与清理

### 12.1 建议状态机

| 状态 | 含义 |
| :-- | :-- |
| Unpaired | 尚未建立设备信任 |
| Paired／Disconnected | 已配对，当前未连接 |
| Authenticating | 验证设备与会话权限 |
| Connecting | 建立媒体和数据通道 |
| Resolving App | 定位应用与窗口 |
| Preparing Window | 验证或调整布局 |
| Streaming／View Only | 可看，不可控制 |
| Streaming／Controllable | 可看且持有控制权 |
| Suspended | 锁屏、权限变化、窗口失效等原因导致暂停 |
| Reconnecting | 恢复连接并重新验证运行期状态 |
| Closing | 释放输入、停止流、执行恢复 |

重连保留配对和应用入口，但重新验证进程、窗口、权限、焦点及几何状态，不把断线前的运行期对象直接当成仍有效。

### 12.2 清理要求

- 停止接受新的输入。
- 对已按下的按钮和修饰键执行释放／取消。
- 丢弃未执行的旧动作。
- 停止捕获与编码。
- 关闭或回收媒体、数据通道。
- 条件性恢复窗口布局。
- 保留设备配对，除非用户要求撤销。

尤其需要覆盖“拖拽期间断网”和“快捷键按下后连接中断”，避免 Mac 留在错误输入状态。

## 13. AI 接入与人机控制权

AI 是可选动作来源，不应侵入捕获或传输模块。


| 模块 | 角色 | 用途 |
| :-- | :-- | :-- |
| Observation Adapter | 观察入口 | 提供截图、窗口信息或可选 AX 状态 |
| Action Adapter | 动作入口 | 将 AI 动作转为统一输入命令 |
| Control Arbiter | 控制权仲裁 | 保证当前只有允许的执行者发出动作 |
| Approval Policy | 操作审批 | 对敏感动作增加确认 |
| Application Adapter | 应用专用接口 | 在有可验证接口时执行结构化操作 |

你之前的目标是让人和 computer-use agent 共用底座，并能够随时接管；具体 Hermes 接口必须独立核对，不能假设插件天然能控制所有 UI。

建议接管规则：

1. 人接管时立即暂停 AI。
2. 撤销 AI 的执行权限。
3. 清空待执行动作。
4. 拒绝携带旧控制权版本的动作。
5. 用户明确恢复后，AI 才重新获得控制权。

AI 云端截图属于另一条数据路径，必须单独授权。手机与 Mac 的自建加密连接，并不会阻止被主动发送给云端模型的画面离开设备。

## 14. 模块接口与工程边界

以下名称是建议的内部模块，不是 Apple 或 WebRTC 的现成 SDK 名称。


| 模块 | 输入 | 输出 | 边界 |
| :-- | :-- | :-- | :-- |
| Device Trust | 配对请求、设备凭据 | 身份与权限 | 不执行 UI 操作 |
| App Resolver | 应用标识、窗口规则 | 当前应用／窗口绑定 | 不负责视频 |
| Window Manager | 窗口绑定、目标视口 | 实际布局、几何版本 | 不负责网络 |
| Capture Source | 捕获范围、输出配置 | 帧与元数据 | 不负责认证 |
| Media Session | 帧、媒体配置 | 视频发送、连接统计 | 不决定应用授权 |
| Input Executor | 动作、窗口绑定、几何版本 | 执行结果或拒绝原因 | 不接受绕过策略的裸命令 |
| Session Coordinator | 用户意图、各模块状态 | 状态转换、取消与清理 | 统一生命周期 |
| Control Arbiter | 人／AI 控制请求 | 当前控制权 | 不捕获和编码 |
| App Adapter | 特定应用请求 | 结构化状态或动作结果 | 不改变通用底座 |

共享数据契约至少包含：

- 设备身份和授权范围。
- 应用入口及窗口匹配规则。
- 当前窗口绑定。
- 捕获范围与实际输出尺寸。
- 坐标转换信息及几何版本。
- 会话 ID、控制权版本。
- 动作序号、取消状态、错误原因。

这对应你之前强调的工程目标：把组件整理成一个产品，而不是让几个完整项目碰巧一起运行。

## 15. 可复用项目与验证范围

历史讨论中收敛过这些候选：


| 候选 | 当时讨论的用途 | 当前处理原则 |
| :-- | :-- | :-- |
| `mac-screen-cast` | 单窗口捕获、编码和浏览器串流参考 | 先验证版本、窗口选择与媒体接口 |
| `SideScreen` | Mac 捕获与交互实现参考 | 只提取边界明确的部分 |
| `agent-desktop` | 窗口／Accessibility 操作及 FFI 候选 | 检查导出能力与宿主集成成本 |
| WebRTC 原生库 | 媒体与数据传输 | 作为库接入，而非再包装一个完整远控产品 |
| Hermes 应用接口／插件 | 结构化能力扩展 | 放在可选适配层 |

这些是之前搜索的候选记录，不是本次重新验证过的依赖、许可或性能结论；历史记录本身也注明未完成逐行审计及编译验证。

选用前必须检查许可证、依赖许可证、固定版本、维护状态、二进制分发要求和对 UI／网络／虚拟屏模块的耦合。

## 16. 性能指标与验收测试

### 16.1 必须记录的指标

| 指标 | 用途 |
| :-- | :-- |
| 点击入口 → 首个可用画面时间 | 衡量应用接续体验 |
| 点击入口 → 首次成功输入时间 | 判断是否真的消除了操作步骤 |
| 输入 → 可见反馈延迟 | 衡量远控响应，中位数与尾部都要记录 |
| 实际捕获／编码／解码帧率 | 定位处理瓶颈 |
| 码率、丢包、RTT、连接类型 | 判断直连、中继和网络状态 |
| 编码／解码耗时及队列积压 | 判断延迟来自哪里 |
| 窗口重定位与重连成功率 | 衡量稳定性 |
| 输入拒绝原因与越界事件 | 验证安全边界 |

浏览器可通过 `RTCPeerConnection.getStats()` 获得连接及部分通道统计；应用启动到首帧、输入到可见反馈等产品指标仍需自行埋点，不能只靠 WebRTC 统计推导。[^30]

### 16.2 必测场景

- Hermes 已打开、未打开、多窗口、窗口重建。
- 窗口移动、resize、跨显示器和不同缩放配置。
- 目标窗口被其他应用遮挡。
- 弹窗、菜单、文件选择器和权限窗口出现。
- 安卓横竖屏切换、键盘弹出、浏览器进入后台。
- 中文输入、快捷键、长文本、拖拽中断。
- Wi-Fi 与移动网络切换、弱网、TURN 中继。
- Mac 锁屏、休眠、权限撤销。
- 本地用户操作与远程操作冲突。
- 人接管 AI 后是否仍执行旧动作。


## 17. 第一版建议定稿

| 项目 | 第一版选择 |
| :-- | :-- |
| Mac 主体 | Swift 原生 Host |
| 安卓入口 | 浏览器 Viewer，原生客户端后置 |
| 捕获单位 | 单窗口，区域捕获作为显式补充 |
| 捕获框架 | ScreenCaptureKit |
| 窗口管理 | Accessibility API |
| 通用输入 | AX 语义动作优先；CGEvent 作为受约束回退 |
| 视频协议 | WebRTC |
| 编码格式 | 优先验证 H.264 |
| 编码集成 | 优先由 WebRTC 编码路径管理，必要时接 VideoToolbox |
| 控制协议 | RTCDataChannel 上的自定义动作协议 |
| 认证 | 一次配对、后续验证、可撤销授权 |
| 网络 | 先跑通局域网；公网采用现成 STUN／TURN 能力 |
| 适配 | 尝试窗口 resize，失败时缩放／平移 |
| 初始画面策略 | 文字优先、30 fps 上限、限制积压 |
| AI | 可选适配层，严格控制权仲裁 |
| 暂不纳入 | 绕过锁屏、文件传输、全桌面自动回退、自研公网穿透 |

平台提供的是捕获、UI 访问、事件和实时传输能力；需要我们完成的产品核心，是把它们连接成可验证的“已授权设备 → 正确应用窗口 → 一致坐标 → 受控输入 → 可恢复会话”。

<span style="display:none">[^31][^32][^33][^34][^35][^36][^37][^38][^39][^40][^41][^42][^43][^44][^45][^46][^47][^48][^49][^50][^51][^52][^53][^54][^55][^56][^57][^58][^59][^60][^61][^62][^63]</span>

<div align="center">⁂</div>

[^1]: https://webrtc.org/getting-started/peer-connections

[^2]: https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel

[^3]: https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications

[^4]: https://developer.apple.com/documentation/appkit/nsworkspace

[^5]: https://developer.apple.com/la/videos/play/wwdc2022/10156/

[^6]: https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue

[^7]: https://developer.apple.com/documentation/applicationservices/axuielement

[^8]: https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate

[^9]: https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction

[^10]: https://developer.apple.com/videos/play/wwdc2022/10155/

[^11]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration

[^12]: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos.md

[^13]: https://developer.apple.com/documentation/screencapturekit/sccontentfilter.md

[^14]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval

[^15]: https://github.com/xamarin/xamarin-macios/wiki/ScreenCaptureKit-macOS-xcode16.0-b1/b0496539039139e6bfde9e4eeaba45d7eef97636

[^16]: https://developer.apple.com/documentation/videotoolbox

[^17]: https://developer.mozilla.org/en-US/docs/Web/Media/Guides/Formats/WebRTC_codecs

[^18]: https://developer.apple.com/documentation/videotoolbox/encoding-video-for-live-streaming

[^19]: https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing

[^20]: https://developer.apple.com/videos/play/wwdc2014/513/

[^21]: https://developer.apple.com/videos/play/wwdc2021/10158/

[^22]: https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Protocols

[^23]: https://webrtc.org/getting-started/peer-connections-advanced

[^24]: https://www.rfc-editor.org/info/rfc8827/

[^25]: https://developer.mozilla.org/en-US/docs/Web/API/Pointer_events

[^26]: https://developer.mozilla.org/en-US/docs/Web/API/Pointer_events/Using_Pointer_Events

[^27]: https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)

[^28]: https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions

[^29]: https://nonstrict.eu/blog/2023/a-look-at-screencapturekit-on-macos-sonoma

[^30]: https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannelStats

[^31]: https://developer.apple.com/documentation/accessibility

[^32]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/captureresolution

[^33]: https://developer.apple.com/forums/tags/screencapturekit?page=2

[^34]: https://developer.apple.com/videos/play/wwdc2022/10156/

[^35]: https://developer.apple.com/library/archive/navigation/

[^36]: https://developer.apple.com/videos/play/wwdc2022/10153/

[^37]: https://developer.apple.com/forums/tags/accessibility?page=4

[^38]: https://developer.apple.com/documentation/videotoolbox/compression-properties

[^39]: https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel/protocol

[^40]: https://support.mozilla.org/en-US/questions/1448532

[^41]: https://webrtc.link/en/articles/webrtc-workflow/

[^42]: https://developer.apple.com/documentation/applicationservices/axobserver

[^43]: https://developer.apple.com/

[^44]: https://developer.apple.com/forums/thread/131322

[^45]: https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_data_channels

[^46]: https://developer.mozilla.org/en-US/docs/Glossary/DTLS

[^47]: https://developer.mozilla.org/en-US/docs/Glossary/RTP

[^48]: https://arxiv.org/pdf/1601.00184.pdf

[^49]: https://www.red5.net/blog/webrtc-security-cors-dtls-srtp-omg/

[^50]: https://www.forasoft.com/learn/video-streaming/articles-streaming/webrtc-security-dtls-srtp

[^51]: https://www.ismypeers.com/Welcome/DownloadDocument/250/1787743316/A+Study+of+WebRTC+Security+·+A+Study+of+WebRTC+Security.pdf

[^52]: https://rtcleague.com/blogs/webrtc-security-encryption-srtp-dtls

[^53]: https://developer.apple.com/forums/thread/761641

[^54]: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios

[^55]: https://developer.apple.com/forums/tags/screencapturekit

[^56]: https://devdoc.net/web/developer.mozilla.org/en-US/docs/DOM/DOM_event_reference/compositionend.html

[^57]: projects.open_source_modular_access

[^58]: preferences.remote_access.quick_control

[^59]: https://www.perplexity.ai/search/e092f723-f7f0-429c-b291-559bcbcddf72

[^60]: https://www.perplexity.ai/search/c036202b-66bc-4dca-a661-3cd47e3fece3

[^61]: projects.screen_sharing.apple_sdk

[^62]: https://developer.apple.com/documentation/screencapturekit

[^63]: https://developer.apple.com/documentation/applicationservices/axuielement_h

