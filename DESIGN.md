# Desktop Translate 实施方案

状态：Opus 已批准开始开发，结论 **PASS_WITH_NONBLOCKING**；[完整复审报告](reviews/opus-plan-review.md) 已保留。以下落实非阻塞项，不宣称未来能力已经实现；实现、构建、测试和真实 UI 门槛均未执行。需求依据是 [001](cmux-translate-app/changes/001-desktop-plugin-ocr.md) 与 [002](cmux-translate-app/changes/002-terminal-layout-plugins.md)，全部范围保持有效。B1身份已决定，用户明确选择“暂用临时签名开发”，接受每次重建重新授权，不创建证书或改钥匙串。允许开始隔离开发，但必须遵守 S0 第一笔提交的 launcher 隔离及隔离落地前禁止构建门槛。

## 1. 当前基线与完整范围

现有 `Capture.swift` 的 cmux 可见文本没有文字几何，`frontmostBounds` 与拿不到边界时退回主屏的行为不能进入桌面路径。现有整窗阅读器不是定位替换。保留操作 UUID、冻结设置、取消 pi/迟到结果隔离、后端 ID 完整性校验及设置存储惯例；cmux 插件切换同一变更删除旧捕获、旧目标判定和整窗阅读器，不长期保留两套入口。

交付任意前台应用活动窗口的区域翻译、插件优先、本机 OCR、原位置译文与完整撤除，以及 cmux、iTerm2、Ghostty、Terminal.app、Kaku 五个终端。不会把整窗重排称为定位成功，不改应用数据、不注入 Shell、不要求回显钩子、不扫描后台窗口、不实时翻译无限日志；partial/unsupported + 明示 OCR 是能力结果，不是删减应用范围。

## 2. 共享模型与插件边界

只加载编译进 app 的内建 Swift 插件，按精确 bundle ID 注册；不加载外部插件代码。未来外部插件另审签名、授权、隔离和版本。

- `CaptureTarget`：bundleID、PID、应用实例身份、CGWindowID、Quartz 桌面点窗口 frame、displayIDs、window-local selection、可选 tab/pane、revision。
- `CaptureSnapshot`：UUID、时间、target、source(native/plugin+OCR/OCR)、能力、变换 provenance、布局树、文字区域、revision。原始图片 OCR 后释放，失效检测仅保留区域降采样签名。
- `TextRegion`：snapshot 内稳定 ID、原文、source、kind(prose/code/command/prompt/path/diff/log/table/TUI/button/label/menu/heading/cell/unknown)、置信度、window-local 点矩形、readingOrder、父布局、可选字体/网格/底色证据。unknown 保守保护并提示。
- `LayoutRegion`：ID、parentID、kind、可见/裁剪矩形；文字属于选区且被父区域裁剪。
- 能力 visibleText/textGeometry/paneLayout/contentRevision/fontRevision 各标 verified/partial/unsupported，记录接口/应用版本；未知应用版本继续 probe，但标“未验证版本”，不能标 verified。
- 插件提供 probe 和 capture，不拥有后端/快捷键。返回 none/unsupported/partial/error/needsPermission；权限拒绝不是 error 或 unsupported。调度器验证 ID 唯一、文本长度与区域数上限、矩形在选区/父区域内、revision 一致，插件不能自证有效。

none/unsupported 可走 OCR；partial 用可靠布局裁剪 OCR。error 或 needsPermission 明确呈现，用户可显式选择一次 OCR，不能静默 fallback。无几何全文不能按行号硬拼 OCR；有可靠匹配证据才合并，否则标 OCR 来源。

## 3. 目标锁定、选择与一致性

快捷键先保存 NSWorkspace 前台应用 PID/实例，再创建 UI。基线不要求 AX：按 `CGWindowListCopyWindowInfo` 前到后排序，选该 PID 第一个 on-screen、layer 0、非空 frame 普通窗口；排除本 app 与非普通浮层。窗口 ID/PID/CG bounds 必须在列表中唯一，重复/模态遮挡/无法判定普通窗口或唯一 CG bounds 时停止，不猜另一窗口、不退回全屏；不以缺少 content inset 拒绝无 AX 基线。只有已有 AX 授权或插件确实需要时才用 focusedWindow 交叉核对；公开 AX frame 仅在唯一匹配时关联 CG ID，歧义停止，不使用私有 AX→window SPI。窗口标题不是键。选区必须可见；遮挡有效性只统计目标之上的其他 PID 的 layer 0 窗口，本 app 的屏障/HUD/overlay 全部排除；通知、Dock 等系统层不算此类遮挡、不因此误撤除。遮挡只用于展示有效性判断，不作为窗口截图受遮挡的推断。

默认一键：终端只在聚焦 pane 身份与几何已证明时使用该 pane 内容矩形，否则与无插件普通应用一样使用锁定窗口完整 CG bounds，即 window-local `(0,0,w,h)`，包含标题栏，不要求 AX/content inset。只有插件 pane/网格映射需要可靠 content inset，无法证明时不得猜 inset 或称为 pane 成功。菜单“区域翻译”进入用户拖选，Return 确认、Esc 取消，不改变目标。选区只按 (bundleID,windowID) 在当前会话记忆，resize、pane 身份/布局变化立即清除；裁剪到锁定窗口，有可靠 pane 时再裁剪到 pane。默认流程与显式区域流程都验收。

状态机 idle → [selecting] → capturing → translating → presented → dismissing → idle，selecting 可选。每次 UUID，所有异步提交检查 UUID/取消/目标。捕获前后及翻译完成展示前再次核对实例/PID/windowID/前台/选区/layout/font/content revision。目标 PID 必须仍是前台；本 app 的非激活 panel 不作为新目标，其他应用激活立即撤除。若系统 UI 意外激活本 app，操作停止，不把本 app 激活视为保持目标的证据。
本机模式捕获前查询 `LanguageAvailability`。语言支持但未安装时不锁定/捕获目标，提示从菜单打开“准备本机语言包”；该独立设置窗口允许激活本 app，不绑定目标或翻译操作，安装完成后由用户重新触发。首次下载的实际焦点与安装路径须记录，不依赖捕获 HUD 存活来完成下载；不可用状态明确提示。

CGWindowList 定时轮询为移动/resize/关闭/遮挡基线；NSWorkspace 激活、Space、显示器通知即时失效；AXObserver 仅作已授权增强。原生 revision 是重新读取同一可见文本的哈希加布局/字体/身份，不需截图。不能可靠重读 revision 的能力不能无权限展示，显示需授权或明确 unsupported，并由用户另选 OCR。OCR 差异仅比较遮罩区域和布局，排除已证明的光标格/插入点，连续两次采样变化才失效；不能可靠排除动态区域时拒绝稳定展示而非忽略变化。关闭取消工作、释放图片/签名；不回滚后台状态、不强行激活用户已切换的应用。

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

ScreenCaptureKit 过滤已锁定 windowID、排除本 app，`sourceRect` 精确等于选区（窗口本地左上点）；选区外像素不进入图片内存。AX 跳过 AXSecureTextField 等安全角色及其文本子树。sharingState=none 或全黑受保护结果明确“该窗口禁止捕获”，不能报无文字或转另一窗口；全黑普通窗口也不臆测可识别内容，提示捕获不可用。用户排除即选区外。pi provider/模式在捕获前 HUD/选择 UI 显示；只发送待翻译正文，不上传截图。截图/原文/译文不落临时文件、不入日志/错误，公共 fixture 证据可明确保存。

Vision accurate，recognitionLanguages=[en-US,zh-Hans]；终端/代码关闭 usesLanguageCorrection，避免改写标识符。置信度、背景复杂和半透明效果有可见警告；无文字独立状态。

## 5. 坐标与证据

overlay 全部 window-local 点，截图边界才用 pixel。显式 `ignoreShadowsSingleWindow`、关闭 `scalesToFit`；输出宽高=sourceRect×pointPixelScale，CGImage 偏差>1px 拒绝，避免阴影/letterbox 偏移。跨屏窗口一个 backing scale，按实际图片尺寸分别计算 sx/sy，不猜固定 2x。

Vision (x,y,w,h) → pixel (xW,(1-y-h)H,wW,hH) → 除 sx/sy 加 crop Quartz 原点 → 减窗口原点得 local；AppKit 全局转换统一用主显示器桌面高度翻 y，保留负坐标，不逐屏翻转。框裁剪选区/父布局，字体边距均点。

独立公开 fixture 进程在已知 frame 绘制已知文字，不能由被排除的本 app 作截图基准；角点/round-trip 数学误差≤1pt，真实 OCR 框≤4pt，第三方应用人工标注独立报告。目前两台显示器均 2x（4608×2592、逻辑2304×1296），无实际 1x 证据；验收切非 HiDPI 或虚拟 1x，副屏摆左/上形成负坐标。跨屏与“显示器具有单独空间”开/关各记录真实裁剪行为；不能获得完整可见选区就明确拒绝而非通过。

## 6. 覆盖、输入、分段与溢出

选择/HUD/overlay/展开统一 non-activating NSPanel，可成为 key，不调用 NSApp.activate，全部保持 `fullScreenAuxiliary`；目标保持前台。不能保证无 FocusLost：每个终端用公开 DECSET-1004 记录程序测选择→展示→关闭 focus-out，目标0，实际非0必须披露实际次数与明确限制，不把未测写成功。当前方案不引入 speculative CGEventTap；任何拟引入 event tap 的修正及新增输入监控/AX 权限必须先更新权限矩阵并重新提交 Opus 复审，不能临时加入。

必须有透明全目标窗口 frame 事件屏障，ignoresMouseEvents=false，吞点击/滚轮/手势与非关闭键，不仅遮罩文字块；Esc/快捷键关闭。窗口外不拦截，用户点击外部导致前台变化撤除，不能承诺窗口外无操作。HUD 位于选区外侧/边缘同一屏，承载可见 `.translationTask` host、来源/provider/进度/警告/关闭提示；展开面板共用宿主。语言包准备使用独立可激活设置窗口而非捕获 HUD；已开始的捕获一旦目标失效不显示旧结果。

只在 TextRegion 遮罩/译文，不整窗铺白，不遮图标或邻居。字号≥12pt，测量换行并用父裁剪/占用图约束；空间不足明确标记，可展开完整可滚动译文与保护片段，共用 region ID，不静默截断或扩张。

按 source/kind 分段：终端/代码沿用 TranslationPlan/Segments 保守保护，既有 SegmentsChecks 守回归；桌面 button/label/menu/heading/cell/OCR prose 含≥1 ASCII 单词即可翻译，不限大小写，不因分号、管道或列表符号整行跳过。仍用 isProtectedToken 保护 URL/路径等，纯数字/标识符跳过；此处标识符明确为含 `_`、camelCase 或数字字母混排的词，不把普通英文或全大写 UI 单词当标识符，Cancel、Settings、OK 必须翻译。软换行合并段落请求，保留各行矩形并集排版；不跨 pane/按钮/单元合并。ID 为 region/piece 命名空间，沿用结果完整性校验。终端非 ASCII 列宽必须终端报告或 OCR 对齐，否则转明确 OCR；不能自己按字符数推列宽。

## 7. 五终端证据与只读约束

以下是 Opus 只读采集事实，不是能力通过证据：

| 应用/精确 bundleID/版本 | 接口事实与诚实基线 |
|---|---|
| cmux `com.cmuxterm.app` 0.65.0 | read-screen 默认 viewport；tree --json/list-panes 无像素几何，sdef 无文本属性。禁 --lines/--scrollback；几何未证实前 partial+OCR |
| iTerm2 `com.googlecode.iterm2` 3.7.0 | sdef session contents/text 描述 currently visible contents，rows/columns、window bounds；无 split 几何/content inset，AX 实证前 partial |
| Terminal.app `com.apple.Terminal` 2.15 | tab contents 为 currently visible contents，history 是全缓冲；rows/columns/font size/window bounds；content inset 未证实，partial |
| Ghostty `com.mitchellh.ghostty` 1.3.1 | sdef 有 window/tab/terminal id、focused terminal，无文本属性；输入类命令禁止，文字/几何靠只读探针或 OCR |
| Kaku `fun.tw93.kaku` 0.19.0 | sdef 只有 Standard Suite；WezTerm 系 cli list --format json/get-text，默认 pane 受 WEZTERM_PANE 影响；get-text 第0行 terminal screen 未必回滚 viewport；未证实时 layout+OCR |

CLI 经 LaunchServices bundleID 找应用，再用 bundle 内固定相对 executable 路径；不从 PATH 猜插件。每插件版本证据、超时/输出上限/不含原文错误与静态只读白名单；排除 cmux send/new-split、Ghostty input text/send key/perform action/split、Kaku send-text/kill-pane/activate-pane。清除全部 CMUX_*、WEZTERM_* 及 Kaku 目标变量，显式目标；Kaku 一律 --no-auto-start。回滚 viewport/滚动位置未知不能把 get-text 当可见屏幕，走布局+OCR或可靠交叉验证。

每应用记录只读步骤、权限、tab/pane/布局、字体/Unicode 宽度设置、FocusLost 和失效事实。完整 native 需文本+几何+viewport+revision，无法映射宽字符/emoji/组合字符区域明示 OCR。五应用都真实触发可读定位与撤除，unsupported+OCR 也须跑全适用矩阵，不能 mock 或漏交。

## 8. 依赖安全切片

B1已定：产品显示名 Desktop Translate，release保留local.cmux.translate与现有配置身份；开发显示名Desktop Translate DEV，bundle为local.cmux.translate.dev.<tag>。tag由开发环境显式定义并匹配 `[A-Za-z0-9-]+`。S0 第一笔实现提交只做 launcher 隔离：非主 worktree 缺 tag 拒绝构建，dev 输出不得落 release 路径，并将 `.dev/` 加入 `.gitignore`；隔离落地前 worktree 内不运行任何构建。每worktree独立.dev/data、.dev/config、.dev/build，launcher设置XDG覆盖；dev 默认快捷键 Control+Option+Shift+T（⌃⌥⇧T），避免吞字符输入，已配置值优先且 release 用户设置不变，单实例键从Bundle.main动态取得。当前security find-identity结果0，用户明确接受ad-hoc开发及每次重建重新授权；不创建证书、不触碰钥匙串。签名identity为可选环境参数，证书默认禁用。稳定production签名仍是正式发布前提，不阻塞已获豁免的开发；不得将ad-hoc说成TCC稳定身份。复审报告已在 reviews/opus-plan-review.md，可开始创建隔离workspace/worktree，验证由负责人集中执行。

| 切片 | 依赖 | 内容与门槛 |
|---|---|---|
| S0 基座 | B1已定及用户临时签名豁免 | 第一笔实现提交仅 launcher 隔离（非主worktree缺合法tag fail closed、dev输出隔离、.dev忽略），落地前禁止构建；随后 ad-hoc开发/可选sign identity、独立dev bundle/XDG数据配置构建目录/⌃⌥⇧T、Bundle.main动态单实例、usage说明/共享disclaim spawner、权限矩阵。每次重建后重新请求/授权，以独立公共fixture窗口做一次SCK截图探针（仅截图、不做OCR、不保存）证明授权真实有效，拒绝停止；子进程预检false，日常app/配置指纹不变、dev与日常并存。不要求两次重建TCC保持；完整捕获/OCR管线门槛属于S2，稳定production签名为发布前提 |
| S1 纯逻辑 | S0 | 不依赖 AppKit 的模型、裁剪/变换、合成Vision分组、kind分段、路由和UUID状态机；负原点/非均匀缩放round-trip≤1pt、路由/UI单词fixture、保留四套既有检查 |
| S2 首个完整端到端 | S0,S1 | 无插件 fixture进程+TextEdit，默认完整CG bounds/区域流程→无AX锁定→crop/OCR→本机/pi→非激活overlay/屏障/HUD/展开→取消/撤除/展示前核对；捕获前LanguageAvailability及独立语言包准备/安装后重触发、其他PID layer0遮挡排除自身UI；主屏2x真实误差≤4pt，不穿透，迟到不复活；实际完整捕获/OCR管线在此验收 |
| S3 显示与隐私 | S2 | 1x/负坐标/跨屏/移除/独立Space开关、原生全屏终端Space及fullScreenAuxiliary面板、敏感区域/secure AX/保护窗口、周期授权；001对应真实证据 |
| S4 复杂布局/失效 | S2；与S3同负责人顺序进行 | 按钮/表格/代码/段落/溢出、光标签名误报控制；分组不越界，闪烁不误撤除 |
| P1–P5 只读探针 | S0；FocusLost测量需S2窗口模型 | 五应用接口/版本/viewport/回滚/几何/权限探针，可与S1–S4并行；安装事实不能升级能力 |
| S5 注册表/cmux切换 | S2,S4,P-cmux | 冻结API、注册表、cmux可靠native+OCR、删除旧CmuxCapture/frontmostBounds/整窗路径；capture改目标元数据探针，smoke改独立fixture定位，README迁移；真实插件+无插件验收 |
| S6 四适配器 | S5及各自探针 | Terminal/iTerm2/Ghostty/Kaku独立文件并行，注册表由集成负责人独占；各应用002全适用场景 |
| S7 集中验收 | 全部 | 001全部+002×5、支持表、用户文档/变更记录、清理旧契约；全部门槛才能完成 |

S2 是首个完整 E2E：OCR是所有partial回退关键路径，不依赖未证实终端API，独立fixture使坐标/权限/焦点证据可复现。

## 9. 最终门槛与证据

- 001：精确身份、默认/区域流程、真实插件与无插件、error/unsupported/needsPermission区分、1x/2x/跨屏/负坐标、按钮/表格/代码/软换行/UI单词、溢出、关闭/取消/迟到/目标变化、本机/pi与设置兼容。
- 权限矩阵每个拒绝格真实UI验证，SR撤销/周期确认、AE逐目标拒绝、AX拒绝、不可靠revision不展示；无错窗。子进程disclaim符号缺失fail closed、已有SR/AX时子进程预检false。敏感选区外像素不进入图片、secure AX排除、保护窗口明确报错、provider捕获前可见，各自有公开fixture证据。
- 002对五应用：单窗/多tab/支持时split、viewport非history、不读无关pane、两流程、DECSET-1004次数与真实限制、遮罩/未遮罩区点击滚动不穿透、窗口外切换撤除、Esc/快捷键有效；代码/命令/path/diff、Unicode/软换行/字体、动态输出/旧快照、pane关闭与两后端全部验证。
- N1–N7落实：截图尺寸/阴影/空间矩阵；只读白名单/环境清理/Kaku不自动启动；未知版本标记/调度器校验/固定路径；展示前重读及两次签名变化/光标；OCR双语言及终端禁纠错/半透明探针；新capture/smoke且同变更切除旧路径；非ASCII列映射和软换行并集。每项在对应切片记录实际结果。
- 公共单元fixture含坐标/裁剪/分组/overflow/路由/分段/配置/generation；保留 Segments/Shortcut/TranslationSettings/PiResponse。真实UI不可由mock替代。证据含OS/app版本、显示布局缩放、source/接口/步骤/实际误差、公共截图，不含私人内容。
- 当前只有两台2x设备事实，无1x/FocusLost/权限/新能力通过证据。无法取得1x真实设备或虚拟模式则验收缺证，不把模拟数学结果称硬件通过。任何缺应用/错窗/输入穿透/权限继承/失效贴旧坐标/迟到复活都阻塞交付。

## 10. 迁移与本次边界

根目录`~/ai/desktop-translate`，源码仍`cmux-translate-app`，现有源码/launcher别名保留至产品正式迁移，无重复实现。产品名Desktop Translate，release保留local.cmux.translate与现有配置，无身份迁移；现有release ad-hoc可继续使用，但稳定production签名是正式发布前提。开发名Desktop Translate DEV与local.cmux.translate.dev.<tag>，独立worktree .dev/data/config/build和XDG覆盖、默认⌃⌥⇧T（release用户设置不变）、动态bundle单实例。用户已明确接受临时签名每次重建重新授权，禁止新增证书或钥匙串更改，不要求用户再命名。配置新键与parse/encode同变更单向迁移，旧版拒绝新键应文档化。此轮仅修方案、001/002与开发任务，不运行构建/测试/smoke，不启动未来能力；Opus复审PASS_WITH_NONBLOCKING允许开始开发，报告见 reviews/opus-plan-review.md，所有实现与验收门槛尚未执行。
