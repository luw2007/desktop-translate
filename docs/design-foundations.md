# Desktop Translate：目标、插件与隐私

[设计总览与当前契约摘要](design.md) · [文档索引](README.md)

本文保留原设计的章节编号与历史记录；当前契约以[总览摘要](design.md#当前契约摘要2026-10-21-文档整理)为准，历史要求不代表已通过验收。

## 1. 当前基线与完整范围

历史基线的 cmux 纯文本捕获没有文字几何，整窗阅读器不是定位替换；这是设计动机，不是当前全部源码状态。当前桌面/插件/OCR 路径已部分落地，未验收。操作 UUID、冻结设置、取消 pi/迟到结果隔离、后端 ID 完整性校验及设置存储惯例应继续保留；切换时应删除旧捕获、旧目标判定和整窗阅读器，不长期保留两套入口。

交付任意前台应用活动窗口的区域翻译、插件优先、本机 OCR、原位置译文与完整撤除，以及 cmux、iTerm2、Ghostty、Terminal.app、Kaku 五个终端。不会把整窗重排称为定位成功，不改应用数据、不注入 Shell、不要求回显钩子、不扫描后台窗口、不实时翻译无限日志；partial/unsupported + 明示 OCR 是能力结果，不是删减应用范围。

pi 模式有两种输入方式，由用户显式选择并随配置冻结：默认 `ocr-text` 只发送本机 OCR 识别出的文字；`image` 发送所选区域的精确裁剪截图，由模型同时给出译文与它自报的位置。截图模式不是 OCR 的自动回退或改进，也不会在 OCR 失败时自动启用；它发送像素，因此隐私与几何证据边界都按本节与 §4 的显式选择描述，而不是“只发送正文”。可选模型由 pi 自身的 `get_available_models` 列出（`provider/id`，只读该命令、不发起模型请求），截图模式只允许声明支持图像输入的模型；已保存但当前不可用的模型保持可见并标注，不被静默替换。截图模式的位置是模型自报的裁剪比例映射，不是原生或 OCR 验证几何。

## 2. 共享模型与插件边界

只加载编译进 app 的内建 Swift 插件，按精确 bundle ID 注册；不加载外部插件代码。未来外部插件另审签名、授权、隔离和版本。

- `CaptureTarget`：bundleID、PID、应用实例身份、CGWindowID、Quartz 桌面点窗口 frame、displayIDs、window-local selection、可选 tab/pane、revision。
- `CaptureSnapshot`：UUID、时间、target、source(native/plugin+OCR/OCR)、能力、变换 provenance、布局树、文字区域、revision。最新待验证源码的 `RegionSignature.swift` 从原始 SCK 图片按译文实测行矩形计算原始像素 FNV 哈希（最多4096），绑定 crop/尺寸/格式和不可变矩形集合，替代整选区64×64分块签名。
- `TextRegion`：snapshot 内稳定 ID、原文、source、kind(prose/code/command/prompt/path/diff/log/table/TUI/button/label/menu/heading/cell/unknown)、置信度、window-local 点矩形、readingOrder、父布局、可选字体/网格/底色证据。unknown 保守保护并提示。
- `LayoutRegion`：ID、parentID、kind、可见/裁剪矩形；文字属于选区且被父区域裁剪。
- 能力 visibleText/textGeometry/paneLayout/contentRevision/fontRevision 各标 verified/partial/unsupported，记录接口/应用版本；未知应用版本继续 probe，但标“未验证版本”，不能标 verified。
- 插件提供 probe 和 capture，不拥有后端/快捷键。返回 none/unsupported/partial/error/needsPermission；权限拒绝不是 error 或 unsupported。调度器验证 ID 唯一、文本长度与区域数上限、矩形在选区/父区域内、revision 一致，插件不能自证有效。

none/unsupported 可走 OCR；partial 用可靠布局裁剪 OCR，合法 partial-empty 也走共享 OCR。plugin+OCR 保留实际 OCR 能力、provenance 与 revision，不将未验证的 native revision 冒充 OCR 有效性依据。error 或 needsPermission 明确呈现，用户可显式选择一次 OCR，不能静默 fallback。无几何全文不能按行号硬拼 OCR；有可靠匹配证据才合并，否则标 OCR 来源。

## 3. 目标锁定、选择与一致性

快捷键先保存 NSWorkspace 前台应用 PID/实例，再创建 UI。基线不要求 AX：按 `CGWindowListCopyWindowInfo` 前到后排序，选该 PID 第一个 on-screen、layer 0、非空 frame 普通窗口；排除本 app 与非普通浮层。窗口 ID/PID/CG bounds 必须在列表中唯一，重复/模态遮挡/无法判定普通窗口或唯一 CG bounds 时停止，不猜另一窗口、不退回全屏；不以缺少 content inset 拒绝无 AX 基线。只有已有 AX 授权或插件确实需要时才用 focusedWindow 交叉核对；公开 AX frame 仅在唯一匹配时关联 CG ID，歧义停止，不使用私有 AX→window SPI。窗口标题不是键。选区必须可见；遮挡有效性只统计目标之上的其他 PID 的 layer 0 窗口，本 app 的屏障/HUD/overlay 全部排除；通知、Dock 等系统层不算此类遮挡、不因此误撤除。遮挡只用于展示有效性判断，不作为窗口截图受遮挡的推断。

默认一键：终端只在聚焦 pane 身份与几何已证明时使用该 pane 内容矩形，否则与无插件普通应用一样使用锁定窗口完整 CG bounds，即 window-local `(0,0,w,h)`，包含标题栏，不要求 AX/content inset。只有插件 pane/网格映射需要可靠 content inset，无法证明时不得猜 inset 或称为 pane 成功。菜单“区域翻译”进入用户拖选，Return 确认、Esc 取消，不改变目标。选区只按 (bundleID,windowID) 在当前会话记忆，resize、pane 身份/布局变化立即清除；裁剪到锁定窗口，有可靠 pane 时再裁剪到 pane。默认流程与显式区域流程都验收。

状态机 idle → [selecting] → capturing → translating → presented → dismissing → idle，selecting 可选。每次 UUID，所有异步提交检查 UUID/取消/目标。捕获前后及翻译完成展示前再次核对实例/PID/windowID/前台/选区/layout/font/content revision。目标 PID 必须仍是前台；本 app 的非激活 panel 不作为新目标，其他应用激活立即撤除。若系统 UI 意外激活本 app，操作停止，不把本 app 激活视为保持目标的证据。
本机模式捕获前查询 `LanguageAvailability`。语言支持但未安装时不锁定/捕获目标，提示在“设置…”窗口的“语言包”一行点“准备语言包…”打开独立设置窗口；该窗口允许激活本 app，不绑定目标或翻译操作，安装完成后由用户重新触发。首次下载的实际焦点与安装路径须记录，不依赖捕获 HUD 存活来完成下载；不可用状态明确提示。

CGWindowList 定时轮询为移动/resize/关闭/遮挡基线；NSWorkspace 激活、Space、显示器通知即时失效；AXObserver 仅作已授权增强。同一 app 多个重叠/等 frame 普通窗口：以 CGWindowList 前到后顺序取该 app 最上层普通窗口为目标（取代此前的一刀切拒绝；tmux 在 cmux 中是单窗口内 pane，真实触发是 cmux 的两个等 frame 窗口 188642/70904），仍锁定精确 windowID/PID/frame，捕获只用 desktopIndependentWindow 单窗口，下层同级窗口不进入像素；目标上层若有其他 app 普通窗口与选区相交则 obscured 拒绝；最上层半透明且其下有重叠同 app 窗口、窗口 ID 重复/无顺序证据则 fail closed。顺序变化（windowID 改变）使会话失效。不假定属于 cmux。原生 revision 设计要求重新读取同一可见文本并结合布局/字体/身份；当前五适配器未证明此能力。OCR 使用区域分块签名及连续变化检测；光标闪烁误报尚未解决，当前没有启发式光标排除，不能将“排除已证明光标格”设计要求写成已实现。关闭取消工作、释放图片/签名；不回滚后台状态、不强行激活用户已切换的应用。

## 4. 权限、子进程与隐私

支持 macOS 15+ 本地单工作站，不作 App Store 或私有 SPI 长期稳定承诺。所有权限按实际需要请求，不改 TCC。矩阵中 SR=屏幕录制，AX=辅助功能，AE=针对目标应用的 Automation：

| 路径 | SR | AX | AE | 应用内设置 | 请求时机、拒绝状态与 OCR 选择 |
|---|---|---|---|---|---|
| 锁定目标/CGWindowList 轮询 | 无 | 无；交叉核对可选 | 无 | 无 | 无权限基线；身份歧义停止，不能用 OCR 绕过身份错误 |
| OCR 截图/截图签名检测 | 必需 | 无 | 无 | 无 | 确认捕获前预检；拒绝/撤销/周期重新确认均 needsPermission，说明系统设置与重新触发；不换窗 |
| 原生文本 revision | 无 | 按原生接口 | 按原生接口 | 同插件 | 使用前/重读失败显示对应 needsPermission；无可靠 revision 不展示，可明确另选 OCR |
| cmux 原生文本/socket | 无 | 仅几何 AX 探针需要 | 无 | 现有 socket 权限模式；不要求全局开放 | 首次插件 probe 解释；不可访问是 needsPermission/error，用户另选 OCR |
| Terminal.app 原生文本 | 无 | 仅几何增强需要 | com.apple.Terminal 必需 | 无 | 首次使用 app 内 AE 请求；拒绝 needsPermission，可另选 OCR |
| iTerm2 原生文本 | 无 | 仅几何增强需要 | com.googlecode.iterm2 必需 | 当前路线用 AE；Python API 不启用，若证据需它须显式选择 | 首次使用请求 AE；拒绝 needsPermission，可另选 OCR |
| Ghostty 焦点识别/原生探针 | 无 | AX 文本/几何路径需要 | com.mitchellh.ghostty 的脚本焦点路线需要 | 无 | 各接口首次用时解释；无文本接口是 unsupported 而非授权错误，可选 OCR |
| Kaku CLI 文本/布局 | 无 | 仅 AX 增强需要 | 无 | CLI/socket 自有访问条件 | 首次 probe；访问拒绝 needsPermission、执行失败 error；用户另选 OCR |

Info.plist 加 `NSAppleEventsUsageDescription`；AE 在进程内通过 NSAppleScript/AE 发送，不启动 osascript；每个目标单独授权。若 hardened runtime 启用，配 automation.apple-events entitlement。SR 已开启但预检失败明确“授权未生效”，不宣称复选框证明有效。macOS 周期确认和撤销使操作停止，HUD 说明重新授权后重新触发。

所有 pi、认证助手入口及终端 CLI 统一共享 posix_spawn spawner，设置 `responsibility_spawnattrs_setdisclaim` 放弃 TCC 责任，不再用 Process。接受该私有 SPI 仅用于内部 native app；运行前动态符号检查，缺失 fail closed 禁止启动，不回退继承授权。只允许内建插件调用白名单 CLI，不接受外部插件代码。公开子进程在 app 已获 SR/AX 时必须报告 SR preflight=false、AX trusted=false；并记录 AE 不继承的实证。

ScreenCaptureKit 过滤已锁定 windowID、排除本 app，`sourceRect` 精确等于选区（窗口本地左上点）；选区外像素不进入图片内存。捕获前检查屏幕录制权限，权限缺失/撤销单独报告。系统实际结果是唯一捕获依据：SCShareableContent 中找不到同 windowID+PID、onScreen、layer 0、相同 frame 的目标，ScreenCaptureKit 返回错误，或结果全黑，都明确提示“该窗口无法捕获（可能受系统或应用保护）”，不能报无文字，也不能回退其他窗口或显示器；不把所有错误臆称为保护。`kCGWindowSharingState` / `NSWindow.sharingType=.none` 是 legacy 常量，既不证明保护也不证明安全，不用于允许/拒绝捕获或用户警告，仅可作标明非权威的诊断。AX 跳过 AXSecureTextField 等安全角色及其文本子树，但这仅适用于 AX 读取路径；没有公开接口可检测捕获保护或像素中的安全控件。OCR 无法识别/排除应用的防截图意图、安全字段或其他敏感像素，局部黑块不等于全黑，剩余像素仍可能进入 OCR。唯一排除边界是用户锁定的窗口与选区。pi provider/模式在捕获前 HUD/选择 UI 显示：默认 OCR 文字模式只发送待翻译正文；只有用户显式选择截图模式时，才把所选区域的完整裁剪编码为内存 PNG 经 stdin 发送给所选模型，该 PNG 不写临时文件、不入日志/错误、不放进进程参数、随会话丢弃。截图模式下的位置是模型自报几何（相对该裁剪的比例，映射回窗口本地坐标），不是原生或 OCR 验证过的几何，也没有 OCR 校准；模型未报出的图标/非文字内容不获得译文或位置保证。截图/原文/译文不落临时文件、不入日志/错误，公共 fixture 证据可明确保存。

Vision accurate，recognitionLanguages=[en-US,zh-Hans]；终端/代码关闭 usesLanguageCorrection，避免改写标识符。置信度、背景复杂和半透明效果有可见警告；无文字独立状态。
