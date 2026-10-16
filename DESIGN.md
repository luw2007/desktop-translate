# Desktop Translate 实施方案

状态：Opus 已批准开始开发，结论 **PASS_WITH_NONBLOCKING**；[完整复审报告](reviews/opus-plan-review.md) 已保留。实现部分落地，**未验收**；S0 第一笔 launcher-only 隔离提交为 `184fba2`。代码组装、提交或适配器注册不代表 S0–S7 门槛已全部完成。下文的设计要求不自动代表运行证据。用户明确选择“暂用临时签名开发”，接受每次重建重新授权，不创建证书或改钥匙串。

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
本机模式捕获前查询 `LanguageAvailability`。语言支持但未安装时不锁定/捕获目标，提示在“翻译模式、语言与模型…”窗口的“语言包”一行点“准备语言包…”打开独立设置窗口；该窗口允许激活本 app，不绑定目标或翻译操作，安装完成后由用户重新触发。首次下载的实际焦点与安装路径须记录，不依赖捕获 HUD 存活来完成下载；不可用状态明确提示。

CGWindowList 定时轮询为移动/resize/关闭/遮挡基线；NSWorkspace 激活、Space、显示器通知即时失效；AXObserver 仅作已授权增强。不同 window ID 即便 frame 相同也按重叠错误 fail closed，不假定属于 cmux。原生 revision 设计要求重新读取同一可见文本并结合布局/字体/身份；当前五适配器未证明此能力。OCR 使用区域分块签名及连续变化检测；光标闪烁误报尚未解决，当前没有启发式光标排除，不能将“排除已证明光标格”设计要求写成已实现。关闭取消工作、释放图片/签名；不回滚后台状态、不强行激活用户已切换的应用。

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

## 5. 坐标与证据

overlay 全部 window-local 点，截图边界才用 pixel。显式 `ignoreShadowsSingleWindow`、关闭 `scalesToFit`；输出宽高=sourceRect×pointPixelScale，CGImage 偏差>1px 拒绝，避免阴影/letterbox 偏移。跨屏窗口一个 backing scale，按实际图片尺寸分别计算 sx/sy，不猜固定 2x。

Vision (x,y,w,h) → pixel (xW,(1-y-h)H,wW,hH) → 除 sx/sy 加 crop Quartz 原点 → 减窗口原点得 local；AppKit 全局转换统一用主显示器桌面高度翻 y，保留负坐标，不逐屏翻转。框裁剪选区/父布局，字体边距均点。

独立公开 fixture 进程在已知 frame 绘制已知文字，不能由被排除的本 app 作截图基准；角点/round-trip 数学误差≤1pt，真实 OCR 框≤4pt，第三方应用人工标注独立报告。目前两台显示器均 2x（4608×2592、逻辑2304×1296），无实际 1x 证据；验收切非 HiDPI 或虚拟 1x，副屏摆左/上形成负坐标。跨屏与“显示器具有单独空间”开/关各记录真实裁剪行为；不能获得完整可见选区就明确拒绝而非通过。

## 6. 覆盖、输入、分段与溢出

选择/HUD/overlay/展开统一 non-activating NSPanel，可成为 key，不调用 NSApp.activate，保持 `fullScreenAuxiliary`。真实 FocusLost 与输入屏障仍未测；五终端必须用公开 DECSET-1004 记录程序测选择→展示→关闭 focus-out 并披露实际次数与限制，零不是验收要求，不能把未测写为零。当前不引入 speculative CGEventTap；任何新增输入监控/AX 权限路线须更新权限矩阵并重新提交 Opus 复审。

必须有透明全目标窗口 frame 事件屏障，ignoresMouseEvents=false，吞点击/滚轮/手势与非关闭键，不仅遮罩文字块；Esc/快捷键关闭。窗口外不拦截，用户点击外部导致前台变化撤除，不能承诺窗口外无操作。HUD 位于选区外侧/边缘同一屏，承载可见 `.translationTask` host、来源/provider/进度/警告/关闭提示；展开面板共用宿主。语言包准备使用独立可激活设置窗口而非捕获 HUD；已开始的捕获一旦目标失效不显示旧结果。

只在 TextRegion 遮罩/译文，不整窗铺白，不遮图标或邻居。字号≥12pt，测量换行并用父裁剪/占用图约束；空间不足明确标记，可展开完整可滚动译文与保护片段，共用 region ID，不静默截断或扩张。每个译文区域恰好产出一个条目并带一个如实结果：已绘制、空间不足（仅橙色标记，不覆盖原文）、与相邻文字冲突（不覆盖也不标记）、无可用原文位置（不绘制）；任何情况都不丢弃条目，全文始终可经展开面板读取。HUD 按这四类计数并只在未全部绘制时提示展开；没有任何区域实际绘制时 HUD 报失败而不是成功。

按 source/kind 分段：终端/代码沿用 TranslationPlan/Segments 保守保护，既有 SegmentsChecks 守回归；桌面 button/label/menu/heading/cell/OCR prose 含≥1 ASCII 单词即可翻译，不限大小写，不因分号、管道或列表符号整行跳过。仍用 isProtectedToken 保护 URL/路径等，纯数字/标识符跳过；此处标识符明确为含 `_`、camelCase 或数字字母混排的词，不把普通英文或全大写 UI 单词当标识符，Cancel、Settings、OK 必须翻译。软换行合并段落请求，保留各行矩形并集排版；不跨 pane/按钮/单元合并。ID 为 region/piece 命名空间，沿用结果完整性校验。终端非 ASCII 列宽必须终端报告或 OCR 对齐，否则转明确 OCR；不能自己按字符数推列宽。

## 7. 五终端证据与只读约束

以下是只读采集事实与当前实现状态，不是能力通过证据：

| 应用/精确 bundleID/版本 | 当前实现与诚实基线 |
|---|---|
| cmux `com.cmuxterm.app` 0.65.0 | CLI metadata-only identify；read-screen 为可见 viewport；未证明 CG 几何，partial + OCR |
| iTerm2 `com.googlecode.iterm2` 3.7.0 | 显式数值 ID、NSAppleScript visible-contents probe；无已证明 split/inset 几何，partial + OCR |
| Terminal.app `com.apple.Terminal` 2.15 | 选中 tab visible contents；不读 history；无已证明 content inset，partial + OCR |
| Ghostty `com.mitchellh.ghostty` 1.3.1 | 无文字接口，unsupported + OCR |
| Kaku `fun.tw93.kaku` 0.19.0 | 全局 list 未映射 CG；screen row 0 不等于 viewport，partial + OCR |

当前五终端均为 window-only partial/unsupported + OCR；OCR 本身仍未完成真实验收。没有已证明的 native positioned mapping、tab/pane 精确几何、原生 Unicode 列宽或字体缩放映射。插件注册/编译不等于五终端产品交付。插件按 bundle ID、PID、launch identity、window owner 匹配，保留 adapter 的 none/unsupported/partial/error/needsPermission，不对 error 或 needsPermission 隐式 OCR。CLI 通过 LaunchServices 找应用和 bundle 内固定路径，静态只读白名单排除写入/输入命令，清除 CMUX_*/WEZTERM_* 与 Kaku 目标变量，Kaku 使用 `--no-auto-start`。

已观察的开发证据：DEV host 公共 fixture ScreenCaptureKit 探针成功（1520×1040，无保存、无 OCR）；disclaim spawner 子进程报告 SR/AX=false。此证据不证明完整权限隔离或 TCC 授权来源，TCC=true 的确切责任归属和因果未证实，不归因于 Doubao 或其他应用。旧本机 smoke 的 ok 标志不是定位/输入隔离证明：未一一对应框的最小距离匹配曾报告最大 159.8pt，输入为合成事件；不能据此声称真实误差≤4pt、真实键鼠不穿透或 FocusLost=0。后续修正仍未完成真实验收。

历史公共验收门槛（早于下述 2026-10-16 最终集中 gate）：S2本机流程在捕获前缺Apple en→zh包，pi在捕获前缺普通CG窗口；newglyph首次sharing=None未通过guard且未OCR。owned PID/window、sharing1/2连续两tick readiness加入后重建exit0，newglyph-pi仍捕获前notFrontmost（该sharing条件已被下方2026-10-15批准取代）。没有模型请求或成功展示；S3真实显示/权限矩阵、S4≤4pt及输入隔离仍无证据。S6 owned PTY14项仅证明五canned场景、合成CSI计数、22byte丢弃与清理，不是真实应用；Ghostty/Kaku候选需safeguard token，其他三应用缺用户批准fixture。builder不activate，自然启动仍必须通过精确owned身份就绪与重验证；未改权限、未生成新私有截图。原任务未完成。
终端 fixture 设施（2026-10-16）：`fixtures/terminal_fixture_launcher.py` 新增 `handoff`/`attach-plan`/`attach`，`fixtures/terminal_public_producer.py` report schema 升到 2（`scenarioMode`/`revision`/`xpixel`/`ypixel`；`revision` 是每 tick 递增的计数器，不是内容变化证明，真实重绘看 `sceneChanges`/`renderCount`），`cmux-translate-app/TerminalSmoke.swift` 为新消费者（`terminal-fixture-smoke`/`terminal-fixture-pi-smoke`）。能力边界：只有 Ghostty/Kaku 有文档化隔离启动路径且均为未观察的 candidate；cmux/iTerm2/Terminal.app 只能由用户手工新建一次性进程后 `attach`，launcher 的机器校验只有 plan 时间早于 owner 启动、report 身份/新鲜度、producer 为 owner 后代，tty 与窗口由消费者侧再校验，其余（「非日常实例」、无其他 tab/pane、`--window-id`）是操作者声明。消费者重新对活体事实取证，失败不回退，且明确 `geometry.measured=false`（终端无字形 oracle）。最终源码已构建，集中 gate 中两个实际 PTY/CLI 测试与真实进程/TTY（合成 bundle 边界）fresh attach 检查通过；这不构成真实 emulator UI、物理 FocusLost 或五应用证据，S6 仍未验收。

字形 oracle fixture（2026-10-16）：`fixtures/GlyphSceneFixtureApp.swift` 让 oracle 与真实绘制共用同一 `CTLine` 与同一 `drawToken`（抗锯齿开/字体平滑关在共用路径内设置），`cjk` 场景新增 `cjk.combining.1` 组合字符样本，`caret` 阶段改为四 tick 后 `caret-stop`（`caretVisible=false`、计时器失效、`runRevision` 不变，caret 落在最后一个可见 token 的 ink 矩形内），mutation 仅在 token 实际文本变化时递增 `runRevision`，事件分区改为字形 ink 的 covered/uncovered 矩形（`keyDown` 只记事件类型），resize 重新生成场景规格，发布要求真实 `window.screen` 与非零 display id（无 `NSScreen.main`/零边界/默认缩放回退）。`GlyphSmoke.swift`/`GlyphMetric.measure` 只对实际 `paintRects` 评分，逐行以产品 `OccupiedGeometry` 重新裁剪并精确一一关联（无排序 zip/最近匹配回退），overflow/collision 计入 `maskCounts` 并判失败（故意不绘制的 overflow/受保护文本可以是正确产品行为，但不提供几何精度证据），OCR 未对齐区域计入 `ocrMisalignedRegions` 并判失败，重复 token/缺失 ink/oracle 不一致 fail-closed，另校验目标 PID/window/frame/display id/缩放前后一致。最终源码已构建：DEV app 与 fixture 构建 exit 0，GlyphMatcherChecks、DesktopChecks（实际 paint/clip/gap/overflow/collision 与 signatureChecks）通过，实际 `drawToken` 离屏 oracle 六场景 1x/2x 共 68 次绘制通过（向外像素对齐加一个设备像素的抗锯齿模型）；`GlyphMatcher` 容差未放宽（OCR/mask 4pt），这不是通用物理精度证明。产品相关行内 caret 仍 fail-closed，属开发未完成（非仅缺物理验收），产品非文字安全证明仍缺；真实 oracle 渲染几何、≤4pt 指标、模型请求、成功展示与输入隔离证据均不存在。

剩余门槛：真实文字框定位误差≤4pt；真实点击/滚轮/按键在遮罩及未遮罩区域的屏障隔离；原生全屏、负坐标、1x/2x 两种缩放、跨屏/Space；五应用的 tab/分屏/TUI/Unicode/字体缩放；逐应用 FocusLost 实际次数；本机/pi 真实端到端；逐格权限拒绝/撤销及隔离、复杂布局/溢出/失效与完整 001/002 验收。现有两台设备均为 2x，不可将数学 round-trip 替代真实 1x 证据；production 稳定签名仍是发布门槛。

最新实现：`RegionSignature.swift` 按原始SCK图片的译文实测行矩形生成原始像素FNV哈希（最多4096），绑定crop/尺寸/格式/不可变矩形集合；区域外、间隙、受保护内容变化不影响该签名。verified插件布局在OCR分组前传入，父区域须完整包含，token须完整切分，跨界项否则省略并显示固定清洗警告；pane/font仅复制verified能力。保守软换行按实际词间距、无容差判断下一词不能容纳verified容器，不按字体样式合并控件标签。签名与绘制共用精确选区/窗口/父区域OccupiedGeometry，比较全部受保护/未译文字占用；碰撞连marker也不画，由HUD展开。警告反映实际置信度、背景、透明、边界省略及skipped数。

最终集中证据：最终源码以 `DESKTOP_TRANSLATE_DEV_TAG=desktop-plugins-ocr ./cmux-translate build` 构建exit0，24.90s，无warning输出。最终DesktopChecks通过；实际源码内存/offscreen检查通过：签名忽略间隙/保护/区域外像素、检测内部1px与几何变化，pane/跨界/保护命令/软换行分组，精确选区与碰撞原文不涂绘、行间隙不填、只读展开保留完整溢出文字。静态ScopedSignatureReview未报告P0–P2，检查了索引/raw/fallback/不可变baseline fail-closed。HUD/Expansion只构建或非展示，未测实际key；session start/live SCK/present未覆盖，没有新增屏幕/UI/权限证据。

开发仍未完成：相关行内caret变化仍fail closed，光标误报没有排除，属于未完成开发而非仅缺物理验收；图标/非文字占用没有安全证明。真实S4/001/002门槛保持未验收。

caret决策边界：仅SCK像素无法可靠区分caret与真实字形变化；周期复现掩码或放宽debounce未获批准、未实现。下一步优先独立验证native可见文本revision与cursor/cell几何（含attributes），两者都可靠才可排除caret。否则AX focused selected-range bounds+value路线须另行范围/隐私审查、AXSecure排除与用户授权；本轮不新增该代码。最终精确源码编译再次exit0，30.4s；不新增运行验收证据。

以下原始探针事实仍适用：

 | 应用/精确 bundleID/版本 | 接口事实与诚实基线 |
 |---|---|
 | cmux `com.cmuxterm.app` 0.65.0 | read-screen 默认 viewport；tree --json/list-panes 无像素几何，sdef 无文本属性。禁 --lines/--scrollback；几何未证实前 partial+OCR |

## 8. 依赖安全切片

B1已定：产品显示名 Desktop Translate，release保留local.cmux.translate与现有配置身份；开发构建沿用同一显示名 Desktop Translate，隔离身份为bundle local.cmux.translate.dev.<tag>（内部 .dev 构建路径名不变）。tag由开发环境显式定义并匹配 `[A-Za-z0-9-]+`。S0 第一笔实现提交只做 launcher 隔离：非主 worktree 缺 tag 拒绝构建，dev 输出不得落 release 路径，并将 `.dev/` 加入 `.gitignore`；隔离落地前 worktree 内不运行任何构建。每worktree独立.dev/data、.dev/config、.dev/build，launcher设置XDG覆盖；dev 默认快捷键 Control+Option+Shift+T（⌃⌥⇧T），避免吞字符输入，已配置值优先且 release 用户设置不变，单实例键从Bundle.main动态取得。当前security find-identity结果0，用户明确接受ad-hoc开发及每次重建重新授权；不创建证书、不触碰钥匙串。签名identity为可选环境参数，证书默认禁用。稳定production签名仍是正式发布前提，不阻塞已获豁免的开发；不得将ad-hoc说成TCC稳定身份。复审报告已在 reviews/opus-plan-review.md，可开始创建隔离workspace/worktree，验证由负责人集中执行。


| 切片 | 依赖 | 内容与门槛 |
|---|---|---|
| S0 基座 | B1已定及用户临时签名豁免 | 第一笔实现提交仅 launcher 隔离（非主worktree缺合法tag fail closed、dev输出隔离、.dev忽略），落地前禁止构建；随后 ad-hoc开发/可选sign identity、独立dev bundle/XDG数据配置构建目录/⌃⌥⇧T、Bundle.main动态单实例、usage说明/共享disclaim spawner、权限矩阵。每次重建后重新请求/授权，以独立公共fixture窗口做一次SCK截图探针（仅截图、不做OCR、不保存）证明授权真实有效，拒绝停止；子进程预检false，日常app/配置指纹不变、dev与日常并存。不要求两次重建TCC保持；完整捕获/OCR管线门槛属于S2，稳定production签名为发布前提 |
| S1 纯逻辑 | S0 | 不依赖 AppKit 的模型、裁剪/变换、合成Vision分组、kind分段、路由和UUID状态机；负原点/非均匀缩放round-trip≤1pt、路由/UI单词fixture、保留四套既有检查 |
| S2 首个完整端到端 | S0,S1 | 无插件 fixture进程+TextEdit，默认完整CG bounds/区域流程→无AX锁定→crop/OCR→本机/pi→非激活overlay/屏障/HUD/展开→取消/撤除/展示前核对；捕获前LanguageAvailability及独立语言包准备/安装后重触发、其他PID layer0遮挡排除自身UI；主屏2x真实误差≤4pt，不穿透，迟到不复活；实际完整捕获/OCR管线在此验收 |
| S3 显示与隐私 | S2 | 1x/负坐标/跨屏/移除/独立Space开关、原生全屏终端Space及fullScreenAuxiliary面板、选区排除/secure AX、SCK目标缺失/错误/全黑各拒绝路径、周期授权；001对应真实证据；legacy sharing-none只记录实际结果 |
| S4 复杂布局/失效 | S2；与S3同负责人顺序进行 | 按钮/表格/代码/段落/溢出、光标签名误报控制；分组不越界，闪烁不误撤除 |
| P1–P5 只读探针 | S0；FocusLost测量需S2窗口模型 | 五应用接口/版本/viewport/回滚/几何/权限探针，可与S1–S4并行；安装事实不能升级能力 |
| S5 注册表/cmux切换 | S2,S4,P-cmux | 冻结API、注册表、cmux可靠native+OCR、删除旧CmuxCapture/frontmostBounds/整窗路径；capture改目标元数据探针，smoke改独立fixture定位，README迁移；真实插件+无插件验收 |
| S6 四适配器 | S5及各自探针 | Terminal/iTerm2/Ghostty/Kaku独立文件并行，注册表由集成负责人独占；各应用002全适用场景 |
| S7 集中验收 | 全部 | 001全部+002×5、支持表、用户文档/变更记录、清理旧契约；全部门槛才能完成 |

S2 是首个完整 E2E：OCR是所有partial回退关键路径，不依赖未证实终端API，独立fixture使坐标/权限/焦点证据可复现。

## 9. 最终门槛与证据

- 001：精确身份、默认/区域流程、真实插件与无插件、error/unsupported/needsPermission区分、1x/2x/跨屏/负坐标、按钮/表格/代码/软换行/UI单词、溢出、关闭/取消/迟到/目标变化、本机/pi与设置兼容。
- 001 pi 截图模式（2026-10-16 新增，未验证）：模型下拉来自 pi 自身 `get_available_models` 且只允许声明图像输入的模型；截图经内存 PNG/stdin 发送、不落盘/日志/错误/进程参数；模型自报位置不冒充原生或 OCR 几何，受保护片段与裁剪边界严格校验否则整批拒绝；展示前以同一张已持有原图基线核对；四类绘制计数与真实结果一致。当前只有逐文件 `swiftc -parse` 证据。
- 权限矩阵每个拒绝格真实UI验证，SR撤销/周期确认、AE逐目标拒绝、AX拒绝、不可靠revision不展示；无错窗。子进程disclaim符号缺失fail closed、已有SR/AX时子进程预检false。选区外像素不进入图片、secure AX读取排除、SCK目标未列出/错误/全黑各自明确报捕获不可用、provider捕获前可见，各自有公开fixture证据。`--sharing-none` 只记录实际拒绝/全黑/仍可捕获，不是保护窗口拒绝的验收证据。
- 002对五应用：单窗/多tab/支持时split、viewport非history、不读无关pane、两流程、DECSET-1004次数与真实限制、遮罩/未遮罩区点击滚动不穿透、窗口外切换撤除、Esc/快捷键有效；代码/命令/path/diff、Unicode/软换行/字体、动态输出/旧快照、pane关闭与两后端全部验证。
- N1–N7落实：截图尺寸/阴影/空间矩阵；只读白名单/环境清理/Kaku不自动启动；未知版本标记/调度器校验/固定路径；展示前重读及两次签名变化/光标；OCR双语言及终端禁纠错/半透明探针；新capture/smoke且同变更切除旧路径；非ASCII列映射和软换行并集。每项在对应切片记录实际结果。
- 公共单元fixture含坐标/裁剪/分组/overflow/路由/分段/配置/generation；保留 Segments/Shortcut/TranslationSettings/PiResponse。真实UI不可由mock替代。证据含OS/app版本、显示布局缩放、source/接口/步骤/实际误差、公共截图，不含私人内容。
- 当前只有两台2x设备事实，无1x/FocusLost/权限/新能力完整通过证据；本机/pi 真实端到端未验收，旧 smoke 的匹配误差及合成输入不能证明定位或输入隔离。无法取得1x真实设备或虚拟模式则验收缺证，不把模拟数学结果称硬件通过。任何缺应用/错窗/输入穿透/权限继承/失效贴旧坐标/迟到复活都阻塞交付。

## 10. 迁移与本次边界

根目录`~/ai/desktop-translate`，源码仍`cmux-translate-app`，现有源码/launcher别名保留至产品正式迁移，无重复实现。产品名Desktop Translate，release保留local.cmux.translate与现有配置，无身份迁移；现有release ad-hoc可继续使用，但稳定production签名是正式发布前提。开发构建显示名同为Desktop Translate，隔离身份为local.cmux.translate.dev.<tag>与独立worktree .dev/data/config/build和XDG覆盖、默认⌃⌥⇧T（release用户设置不变）、动态bundle单实例。用户已明确接受临时签名每次重建重新授权，禁止新增证书或钥匙串更改，不要求用户再命名。配置新键与parse/encode同变更单向迁移，旧版拒绝新键应文档化。S0–S7实现已组装，但本文件列出的真实 UI、权限、显示器和五终端证据仍是发布前提；不得将 fixture、一次旧 smoke 或已编译 build 当作完成证明。

### 2026-10-15 用户批准的契约修正

用户明确选择“批准修正契约并继续”：legacy sharing=0 不提供保护或安全保证，以系统实际 SCK 结果为准，产品与 harness 共用单一路径，无 fixture 特例、OS 版本猜测或替代捕获。上文历史 sharing guard/readiness 记录仅代表当时失败；sharing1/2 条件已被此决定取代，保留精确 owned PID/window、frame/layer/alpha、单普通窗口连续两 tick 与重验证。公开 fixture 激活仅可每次显式 opt-in，对本次新建且身份完全核实的 owned PID 至多一次；不得激活用户现有应用、注入输入或放宽目标边界。本次批准不授权 TCC/钥匙串/日常配置更改、新权限或其他应用操作。S2/S3/S4/S6 与原始 001/002 验收仍未通过；契约变更不是新增运行证据。

### 2026-10-16 源码修改（未构建未运行）

本轮源码修改（2026-10-16，未构建未运行）新增：pi 显式截图输入模式与 `translation.inputMode` 配置键（旧配置无该键时按 `ocr-text` 解释）、模型下拉改由 pi 自身 `get_available_models` 提供并标注图像能力、RPC 传输与严格图像区域响应、HUD 四类真实绘制计数，以及按实际可绘制字形几何修正的原位置渲染。除逐文件 `swiftc -parse` 外未构建、未类型检查、未运行；S0–S7 门槛与 §9 证据要求均未因此改变，真实 UI/模型请求/精度证据仍全部缺失。

语言对（2026-10-16）：`translation.sourceLanguage`（`auto` 或语言代码）与 `targetLanguage`；旧配置缺失两者时迁移为 `en`→`zh-Hans`，无配置文件默认 `auto`→`zh-Hans`。本机 auto 由 `NLLanguageRecognizer` 检测（≥0.6 才采用，否则明确失败）并按实际语言对检查语言包，源=目标时固定提示不翻译；非英文源（含 auto）使用 Unicode 版分段启发式，英文源保持原 ASCII 行为。pi 提示词（文字与截图）写明目标与源语言。

产品决定（2026-10-16 验收）：展示之前的新鲜度门槛（基线 + 两次采样）保持；译文一旦展示，内容像素变化（含光标/小型动态元素）不再撤除覆盖——展示后的 `TargetMonitor` 不带基线，只因窗口身份/移动/resize/关闭/Space/屏幕参数/遮挡/前台变化（几何而非内容）撤除，用户以 Esc/快捷键退出。展示成功后 HUD 约 1.5 秒动画收起为 40pt 可拖动小图标（提示屏幕正被覆盖），点击展开回完整面板。HUD 面板始终非 key、非激活；屏障仍是 key 窗口，故收起/拖动/点击后 Esc 仍由屏障关闭，键盘不泄漏到目标。
