# Opus 架构审查：DESIGN.md + 变更 001/002

- **审查模型**：Claude Opus 5.5（`claude_sub2api/claude-opus-5-5`），agent `OpusPlanReview`。
- **范围**：只读审查 `~/ai/desktop-translate` @ `4adc120`（工作树干净）。没有修改文件，没有运行构建、测试或 smoke。只运行了只读事实探针：读取 bundle Info/sdef、CLI `--help`、显示器配置，以及一次符号存在性检查。
- **引用缩写**：`D` = `DESIGN.md`；`001` / `002` = `cmux-translate-app/changes/00x-*.md`；代码路径相对于 `cmux-translate-app/`；`launcher` = 根目录 `cmux-translate`。

## 结论：**BLOCKED**

共 7 个阻塞项。它们都是方案层面的矛盾或缺失决定，修改 DESIGN 的成本较低。**没有任何一项需要缩减五终端或桌面 OCR 的范围**，“原生部分能力 + 明示 OCR 补齐”的路线可以成立。其中 B1、B5 需要用户拍板，其余由负责人直接改方案即可。

### 已经站得住的部分（无需修改）
- 插件信任模型选择保守路线，并且写得明确：本轮只用编译进 app 的内建 Swift 插件，不加载外部代码，按 bundle ID 精确匹配，不靠标题猜测（D:15）。这满足“先用内建插件、外部插件另行审查”的要求。
- 插件错误和“无插件”分开处理；不会把没有几何信息的全文按行号硬拼到 OCR 结果上（D:24）。
- 坐标公式正确：Vision 左下角归一化框转为图片左上角像素框，再转 Quartz 桌面点，最后以主显示器高度统一翻转为 AppKit 坐标（D:48）。现有代码也用 `NSScreen.screens.first` 作为主屏（Capture.swift:103-107），与此一致。sx/sy 分开计算；数学误差 ≤1pt 与识别误差 ≤4pt 分开报告（D:46-50）。
- 不允许整窗铺白，最小字号 12pt，空间不足时提供展开面板，失效时不“跟随猜测”（D:54-58）。
- 五个终端都要交付；native / partial / unsupported+OCR 如实标注；不得用 mock 冒充交付（D:70、D:86-89）。
- 现有本机/pi 后端可直接复用：每次操作冻结一份设置（App.swift:31-57）；pi 与 Apple 两条路径都严格校验 ID 完整性（PiTranslation.swift:13-15、118-123；App.swift:107-119）。区域级 ID 可以直接沿用。

### 已采集的只读事实（可补进 D §7）
| 应用 | bundle id / 版本 | 脚本与 CLI 事实 |
|---|---|---|
| cmux | `com.cmuxterm.app` 0.65.0 | `read-screen` 默认读取可见 viewport（另有 `--scrollback`/`--lines`/`--selection`）；有 `tree --json`、`list-panes`。help 里**没有像素几何**参数。sdef 结构与 Ghostty 相近，没有文本属性 |
| iTerm2 | `com.googlecode.iterm2` 3.7.0 | sdef 中 session 的 `contents`/`text` 描述为 “currently visible contents”；有 `rows`/`columns` 和窗口 `bounds`；没有 split 几何 |
| Terminal.app | `com.apple.Terminal` 2.15 | tab 的 `contents` 描述为 “currently visible contents”，另有 `history`（整个滚动缓冲）；有 `number of rows/columns`、`font size` 和窗口 `bounds` |
| Ghostty | `com.mitchellh.ghostty` 1.3.1 | sdef 有 window/tab/terminal 的 id、`focused terminal`、`working directory`，**没有文本属性**；同时含有会产生副作用的 `input text`、`send key`、`perform action`、`split` |
| Kaku | `fun.tw93.kaku` 0.19.0 | sdef 只有 Standard Suite。`kaku cli list --format json`、`get-text` 来自 WezTerm 系：pane 默认取自 `WEZTERM_PANE` 环境变量；存在 `--no-auto-start`；`get-text` 第 0 行是“terminal screen”首行，用户回滚时**不一定等于可见 viewport**；也有 `send-text`/`kill-pane`/`activate-pane` 等变更命令 |
| ScreenTextGrab | `dev.screentextgrab.app` 1.1.1 | 只作为交互参考 |
| 显示器 | 两台，均为 4608×2592，按 2304×1296 渲染 | **两台都是 2x**；当前没有 1x 设备 |

---

## 阻塞项

### B1　构建签名、bundle 身份与开发隔离（需要用户决定）
**来源**：launcher:11-13（`BASE`/`APP` 路径固定），launcher:24-28（按 mtime 判断是否重建），launcher:44-46（ad-hoc 签名 `--sign -` 后整体替换 app）；Info.plist:4-6（`local.cmux.translate` / “CMux Translate”）；App.swift:324、366-370（单实例判断用硬编码 bundle id）；TranslationSettings.swift:93-95（配置中出现未知顶层键就拒绝启动）；D:93（“bundle身份、安装数据目录暂不改名”）；D:81（准备在新 worktree 开发）；D:38（“授权未生效”）。

**问题**：
1. ad-hoc 签名的指定要求就是 cdhash，因此每次源码变更或 pull 后重建，屏幕录制、辅助功能、自动化授权都会失效，而系统设置里仍显示“已开启”。（这是已知的 TCC 行为；需在 S0 用连续两次重建验证。）
2. worktree 里的 launcher 会构建到同一个 `~/.local/share/cmux-translate/CMux Translate.app`，覆盖用户日常使用的 app。之后日常 launcher 按 mtime 判断不需要重建，于是**悄悄运行开发版**。单实例检查和快捷键注册也会冲突，两个版本还共用同一条 TCC 记录。
3. 开发版只要写入新的配置键，日常版就会因为“配置包含未知字段”而无法启动。
4. 通用桌面工具的权限弹窗会显示“CMux Translate”。如果用户授权之后再改名，所有授权都要重新给一遍。

**用户可见风险**：开发期间日常工具被替换或启动失败；权限反复出现“已开启却失败”；权限相关验收证据无法复现。

**决议**（写入 D §8、§10）：
- 使用稳定的签名身份：本机自签代码签名证书，或已有的 Apple Development 证书，由 launcher 通过环境变量或参数选择。ad-hoc 只作为显式降级，并提示“每次构建都会重置授权”。如果开启 hardened runtime，需加 `com.apple.security.automation.apple-events` entitlement。
- 在第一个会触发 TCC 弹窗的切片之前，定下最终的 bundle id 和显示名：要么现在改名（文档说明需要一次性重新授权），要么明确永久保留现名。配置目录名可以继续保留。
- worktree 使用独立的 dev bundle id。launcher 已支持 `XDG_DATA_HOME`/`XDG_CONFIG_HOME`，dev 构建把它们指向 worktree 私有目录，并使用不同的默认快捷键。单实例判断改为运行时读取 `Bundle.main.bundleIdentifier`。
- 配置演进规则：新增键必须和 parse/encode 在同一个变更里落地；文档写明这是单向迁移，旧版本会拒绝新键。

**验证门槛**：dev 连续重建两次后屏幕录制预检仍为 true；dev 构建之后日常 app 与配置的指纹不变；dev 和日常版可以同时运行。

### B2　权限矩阵不完整，且前后矛盾
**来源**：D:28（用 AX `focusedWindow` 判定所有目标的身份）；D:34（订阅窗口移动/尺寸变化；用截图差异兜底；“无法检查就撤除”）；D:38（“纯原生捕获不额外要求屏幕录制…插件 AX 权限独立显示”）；002:53（额外的自动化授权需说明并由用户选择启用）；Info.plist 没有 `NSAppleEventsUsageDescription`；sdef 事实见上表。

**问题**：
- (a) 身份判定对每个目标都要用 AX，实际上把 AX 变成了 OCR 路径的必需权限，与“只在需要的插件路径上请求 AX”矛盾。另外，从 AX 窗口拿到 CGWindowID 没有公开 API，只能用私有的 `_AXUIElementGetWindow` 或按 frame 匹配，方案没有说明选哪种。
- (b) 观察窗口移动、尺寸、关闭：用 `AXObserver` 需要 AX，轮询 `CGWindowList` 则不需要任何权限。方案没有指定。
- (c) **方案完全没有提到 Automation（Apple Events）权限。** Terminal.app 和 iTerm2 最直接的原生文本来源就是 AppleScript，Ghostty 的焦点识别也要用它。每个目标应用都要单独同意，且 Info.plist 必须有 usage 说明；缺少时 Apple Events 会直接被拒绝。（[INFERENCE] 自 10.14 起的行为，需在 S0 验证。）
- (d) 原生插件如果拿不到 revision，就退回截图差异，而截图需要屏幕录制。再加上“无法检查就撤除”，纯原生路径在没有屏幕录制时实际上无法使用，与 D:38 矛盾。
- (e) macOS 15 起会周期性要求重新确认屏幕录制（[INFERENCE]），方案没有设计对应的用户体验。

**用户可见风险**：权限弹窗出乎用户意料；终端插件因为拿不到 Apple Events 而静默失败；纯原生路径在没有屏幕录制时立即被撤除。

**决议**：在 D §4 加一张权限矩阵。
- **行**：目标锁定、OCR 截图、失效检测、五个插件各自的原生路径、cmux socket 和 Kaku CLI。
- **列**：屏幕录制 / AX / 按目标应用的 Automation / 应用内设置（iTerm2 Python API 开关、cmux socket 模式）、何时请求、拒绝后的状态（例如“需授权”，与 error 和 unsupported 区分），以及是否允许用户另选 OCR。
- **建议的具体决定**：
  - 目标锁定基线不依赖 AX：取前台应用 PID，在 `CGWindowListCopyWindowInfo` 的前到后顺序中找该 PID 第一个 on-screen、layer 0 的窗口，并写明唯一性规则。只有在 AX 已授权或插件需要时，才用 AX 交叉核对。若采用 `_AXUIElementGetWindow`，要标注为私有 SPI 并给出回退方案。
  - 窗口变化以 CGWindowList 轮询为基线，AXObserver 只作增强。
  - 原生插件的 revision 定义为重新读取可见文本后的哈希，不需要屏幕录制。截图差异只用于 OCR 快照。两种检查都不可用时，明确拒绝展示并提示授权。
  - Info.plist 加上 `NSAppleEventsUsageDescription`；Automation 按插件在首次使用时申请。

**验证门槛**：矩阵中每个“拒绝”格都在真实 UI 下得到文档规定的状态，并且不会捕获错误的窗口。

### B3　子进程继承 TCC 授权（安全）
**来源**：PiTranslation.swift:140、157-170（可执行文件由用户配置并按 PATH 解析）、223-232（`posix_spawn` 只设置了 pgroup，没有放弃 TCC 责任）；Capture.swift:23-37（用 `Process` 启动 cmux CLI）；app README:47（pi 可能执行认证命令）；D:38-40。

**问题**：TCC 按“负责进程”判定授权。app 拿到屏幕录制、AX、Automation 后，它启动的子进程会在不弹窗的情况下继承这些授权。这些子进程包括 pi 及其 provider 认证助手，以及 cmux/kaku CLI。而配置文件对当前用户可写，`piExecutable` 可以是 PATH 里任意二进制，`/Applications` 下的 bundle 通常也对用户可写。结果是这个辅助工具变成绕过 TCC 的跳板。现在的 app 还没有任何 TCC 授权，**所以这个风险是本方案新引入的**。

**决议**：D §4 写明子进程策略。所有子进程（pi 和终端 CLI）统一通过一个共享的 spawner 启动，并放弃 TCC 责任（`responsibility_spawnattrs_setdisclaim`）。这是私有 SPI；本机 libSystem 已确认存在该符号。（[INFERENCE] 终端模拟器用它解决同类问题。）插件 CLI 改用这个 spawner，不再用 `Process`。Apple Events 在进程内发送（NSAppleScript/AE），不调用 `osascript` 子进程，这样授权归属于本 app。如果不接受私有 SPI，必须写明替代隔离方式，不能留空。

**验证门槛**：在 app 已有屏幕录制和 AX 授权时，经共享 spawner 启动的公开测试子进程报告 `CGPreflightScreenCaptureAccess()==false` 且 `AXIsProcessTrusted()==false`。

### B4　选区/覆盖窗口的焦点与输入模型未定
**来源**：001:40（禁止输入穿透；关闭后恢复合理焦点）；002:25、002:44（不改变焦点）；D:28（先记录前台应用，再显示选择 UI）；D:30（捕获前后核对“前台应用”）；D:58（“区域外**如需**拦截可用透明事件屏障”）；App.swift:196-201、263-267（现有覆盖层调用 `NSApp.activate` 抢占前台）；App.swift:159-163（Apple 翻译的 `.translationTask` 宿主必须是可见视图，首次语言包下载对话框要挂在上面）。

**问题**：
- (a) 如果选择 UI 或覆盖层激活本 app（现有做法），“捕获后核对前台应用”必然失败，除非特判本 app。更严重的是终端失焦后，会向开启了 DECSET 1004 的程序发送 focus-out（`CSI O`）。vim/neovim 的 FocusLost 自动命令（例如自动保存）、tmux focus-events、各类 TUI 失焦重绘都会被触发。这等于在捕获的那一刻向 PTY 写入输入并改变屏幕内容。**现有已发布行为就存在这个问题。**
- (b) “如需”把屏障写成了可选项。AppKit 窗口的透明像素默认会把鼠标事件传给下层窗口（[INFERENCE] 需显式设置 `ignoresMouseEvents=false`）。在未遮罩区域滚动滚轮会滚动下面的终端，既违反 001:40，又会让覆盖内容立即过期。
- (c) 定位模式下，状态、来源、模式/provider、进度、警告、关闭提示，以及 `.translationTask` 宿主放在哪里，方案没有说明。

**决议**（写入 D §3、§6）：
- 选择 UI、覆盖层、HUD、展开面板统一使用 non-activating `NSPanel`（可成为 key），目标应用保持前台。是否仍会产生 focus-out 必须实测（[INFERENCE]），按实测结果在支持表中如实记录。
- 事件屏障**必须存在**：至少覆盖整个已锁定窗口的 frame，并吞掉点击、滚动和手势。点击窗口外部会因前台应用变化而撤除覆盖层，这一点要写进文档。
- “前台应用”核对定义为：目标 PID 仍在前台，且除本 app 外没有其他应用被激活。
- HUD 用一个独立的小 panel，放在选区外侧或边缘、同一显示器上。它承载 `.translationTask` 以及来源、模式标签和关闭提示；展开面板共用这个宿主。

**验证门槛**：在每个终端里运行公开的 DECSET-1004 记录程序，记录“选择 → 展示 → 关闭”整个过程中的 focus-out 次数（目标为 0，否则如实记录）；在遮罩区、未遮罩区和窗口外分别点击、滚动，目标状态都不变；目标保持前台时 Esc 和快捷键仍然有效。

### B5　选区语义未定（需要用户决定）
**来源**：001:13（“首次提供区域选择以避开不需翻译的内容”）；D:30 原样照搬了这句；D:32 的状态机必经 selecting；002:37（按快捷键捕获快照）；002:44（不读取无关 pane）；app README:17（现在是按一次快捷键直接出结果）。

**问题**：“首次”既可以理解为“每次触发都先选区”，也可以理解为“第一次或第一版提供选区”。这决定了：是否每次都要拖选，从而让现有 cmux 的一键体验退化；选区是否记忆、记多久；插件目标默认选什么（聚焦的 pane 还是整个窗口）；选区与 pane 边界怎样相交。

**决议**（推荐方案，交用户确认）：按快捷键后锁定目标，立即使用默认区域：终端插件取聚焦 pane 的内容矩形，无插件目标取窗口内容区。可选进入调整（拖拽细化、Return 确认、Esc 取消），或另设一个“区域翻译”快捷键。按 (bundleID, windowID) 只在本次会话内记忆选区，窗口尺寸变化即失效。选区始终裁剪到已锁定窗口内；有插件布局时再裁剪到 pane。相应更新 D:32 状态机（selecting 变为可选步骤）和 001/002 验收（两种流程都要验证）。

### B6　分段策略：终端行启发式不能直接套用到桌面 UI 区域
**来源**：D:56（“原有 Segments 保护规则复用到每个区域”）；Segments.swift:175-209：`isProse` 要求至少 2 个含小写字母的单词（续行除外）；整行包含 `;`、` | `、` = ` 或以 `+`/`-`/`#`/`$`/`%`/`>` 或常见命令词开头时，一律不翻译；001:54（按钮、表格的验收）。

**问题**：单词按钮、菜单、表头和表格单元（如 “Cancel”、“Settings”、“Download”）永远不会进入翻译请求；带 ` | ` 或 `;` 的 UI 文案原样保留；`- item` 列表不翻译。按方案原文实现，无法完成 001 关于按钮、表格分组与不越界的验收。OCR 如果逐行请求，段落上下文也会被打断。

**决议**（改 D §6）：按区域来源和 kind 选择策略。终端、代码类上下文继续原样使用 `TranslationPlan`，由 SegmentsChecks 守住回归。桌面 UI 类区域（button/label/menu/heading/cell/OCR 段落）使用 UI 策略：只要含 ASCII 单词就翻译（≥1 个词，不限大小写）；继续用 `isProtectedToken` 保护路径、URL 等；纯数字和标识符跳过。段落区域把软换行合并成一个请求。ID 采用 `region/piece` 命名空间，沿用现有完整性校验。补充相应 fixture。

### B7　静默缩减：001 的“敏感区域排除”没有进入方案和验收
**来源**：001:47（需测试拒绝授权、撤销授权**及敏感区域排除**）；D:38-40、D:85 只覆盖了拒绝和撤销。

**问题**：方案没有定义“敏感区域排除”，也没有对应测试，属于范围静默缩减。

**决议**（写入 D §4、§9）：
1. ScreenCaptureKit 用 `sourceRect` 等于选区，选区外的像素从不进入内存。
2. 任何基于 AX 的读取都跳过 `AXSecureTextField` 等安全角色。
3. 受捕获保护的窗口（`kCGWindowSharingState` 为 none，或截图结果全黑）直接报“该窗口禁止捕获”，不能报成“没有文字”。
4. 用户排除的内容就是选区之外的部分。
5. pi 模式在确定捕获之前，就在选择 UI 上显示 provider 标识。

以上每条都要有测试。

---

## 非阻塞项（在对应切片内解决）

**N1 坐标管线的实现陷阱（高）。** ScreenCaptureKit 单窗口截图需要显式设置 `ignoreShadowsSingleWindow`，并核对图片尺寸等于 frame×scale；否则阴影边距会让所有框整体偏移。输出宽高必须等于 `sourceRect` × `pointPixelScale`，并关闭 `scalesToFit`；返回的 CGImage 尺寸偏差超过 1px 就拒绝，因为 letterbox 偏移无法用 sx/sy 表达。`sourceRect` 是窗口本地、左上角为原点的点坐标。跨屏窗口只有一个 backing scale。默认开启的“显示器具有单独的空间”会裁掉跨屏窗口，两种设置都要定义验收结果或记录实际情况（D:46-50）。真实框的基准建议改为：**由一个独立的公开 fixture 进程**在已知 frame 上绘制已知文字（必须是独立进程，因为本 app 会把自己排除在截图之外），从而得到精确基准；人工标注只用于第三方应用。硬件方面，本机两台显示器都是 2x，1x 证据要靠切换到非 HiDPI 模式或虚拟显示器；负坐标需要把副屏摆在主屏左侧或上方。这些步骤要写进证据文档。

**N2 终端适配器约束（中）。** 根据上表的事实：
- 每个插件维护只读命令白名单，并用静态检查强制执行。Ghostty 的 `input text`/`send key`/`perform action`、cmux 的 `send`/`new-split`、Kaku 的 `send-text`/`kill-pane` 都必须排除。
- 环境变量清理从 cmux 推广到所有插件（参照 Capture.swift:29-31）：`CMUX_*`、`WEZTERM_*`/Kaku 相关变量，确保启动工具的终端不会被当成目标。
- Kaku 调用一律加 `--no-auto-start`。
- cmux 禁止使用 `--scrollback`/`--lines`。
- Kaku `get-text` 在用户回滚时是否等于可见 viewport 需要实测；如果拿不到滚动位置，就降级为布局 + OCR，或用 OCR 交叉验证。
- Terminal.app/iTerm2 的 sdef 不提供内容区 inset（tab 栏、滚动条、内边距），因此在 AX 探针确认之前按 partial 处理。

**N3 插件版本与输出校验（中）。** 每个插件记录已验证的应用版本。遇到未知版本时照常运行 probe，但能力标为“未验证版本”，不能静默标成 verified。快照校验由**调度器**完成，不交给 D:22 里的插件 `validate`：ID 唯一、矩形落在选区和父区域内、文本长度和区域数有上限、revision 一致。外部可执行文件通过 LaunchServices 按 bundle ID 定位，再取 bundle 内的固定相对路径；保留超时、输出上限和“错误信息不含原文”的规则（参照 pi runner）。

**N4 内容失效检测（高）。** 要求如下：
- 翻译**完成后、展示前**再核对一次。pi 最长可运行 180s（PiTranslation.swift:250），002:35 规定翻译期间内容变化就要失效。
- 截图差异必须控制误报：排除光标格或插入点、只比较遮罩区域与布局哈希、连续两次采样都有差异才判定变化。否则闪烁的光标会让覆盖层一出现就被撤除。
- D:18 写的是图片“短暂持有”，而差异检测需要一个基线：OCR 完成后只保留每个区域的降采样签名，不保留原图。

**N5 OCR 配置（中）。** `recognitionLanguages` 设为 en-US + zh-Hans，避免已有中文被识别成拉丁乱码后又被拿去翻译。终端和代码类目标关闭 `usesLanguageCorrection`，否则它会改写标识符并影响分类。半透明终端背景下的识别效果需要探针验证。

**N6 切换与诊断命令（中）。** App.swift:503-504 在拿不到边界时会静默退回 `NSScreen.main.visibleFrame`，Capture.swift:88-108 只取同 PID 的第一个窗口，这两处都不能进入桌面路径。launcher 的 `capture`/`smoke`（launcher:17、53-56；App.swift:541-600）是 cmux 专用的，需要重新定义为“目标元数据探针”和“基于 fixture 的定位 smoke”。旧的整窗阅读器只在 cmux 插件落地之前保留，cmux 插件落地的同一个变更里删除，不让两套目标判定长期并存（D:9）。坐标变换、分组、路由、分段策略等纯逻辑放在不依赖 AppKit 的文件中，以便沿用单文件 swiftc 检查（app README:72）。

**N7 终端文字到网格的映射（中）。** 各终端的字符宽度表不同：Ghostty 的 grapheme 聚类、iTerm2 的 Unicode 版本与模糊宽度设置、Terminal.app 的模糊宽度选项都会影响（[INFERENCE]，需探针确认）。一旦知道内容区矩形，行的几何是可靠的；含非 ASCII 的行，列范围要来自终端报告或 OCR 对齐，否则按 D:70 改为 OCR 来源。软换行合并为一个段落请求，按各行矩形的并集排版。

**偏好项（不阻塞）**：P1 pi 模式每次触发都弹确认，属于可选项，显示 provider 标识已满足要求。P2 源码目录和配置路径改名，没有必要。

---

## 推荐切片（依赖安全，保留全部最终范围；以下都是开发增量，不是缩小交付）

| 切片 | 依赖 | 内容 | 门槛 |
|---|---|---|---|
| **S0 基座** | B1–B3 决议 | 稳定签名与 dev 隔离（独立 bundle id、XDG 目录、快捷键）；Info.plist 加入 usage 说明；共享 spawner 放弃 TCC 责任（pi 和 CLI 都走它）；单实例按运行时 bundle id；配置演进规则；权限矩阵文档 | 连续两次重建授权仍有效；子进程预检为 false；日常 app 与配置指纹不变；dev 与日常版可同时运行 |
| **S1 纯逻辑核心** | S0 | 共享类型、坐标变换与裁剪、基于合成 Vision 观测的分组、按 kind 的分段策略、能力路由（none / unsupported / partial / error / 需授权）、UUID 状态机。全部不依赖 AppKit | 角点与 round-trip ≤1pt（含负原点、非均匀缩放）；路由与分段 fixture 通过；现有四套检查保留 |
| **S2 首个完整端到端（无插件 OCR）** | S0、S1、B4、B5 | 快捷键 → 无需 AX 的目标锁定 → 默认或调整后的选区 → ScreenCaptureKit 窗口截图（`sourceRect`、去阴影）→ Vision → 分组 → 本机与 pi 两种后端 → non-activating 定位覆盖层、事件屏障、HUD 和翻译宿主、溢出标记与展开面板 → Esc/快捷键关闭、翻译中取消、迟到结果隔离、移动/尺寸/关闭/激活/Space 变化撤除、展示前再核对。目标为公开 fixture 进程加 TextEdit，在主屏 2x 下运行。日常 cmux 不受影响 | 数学误差 ≤1pt，真实 OCR ≤4pt；点击和滚动都不穿透；权限拒绝与撤销提示明确；迟到结果不重建 UI |
| **S3 显示矩阵与隐私** | S2 | 1x 模式、负坐标、跨屏、显示器移除、两种“单独空间”设置、受保护窗口、敏感区域排除（B7）、屏幕录制周期确认 | 001 的坐标、权限、隐私各项都有真实证据 |
| **S4 复杂布局与失效检测** | S2（与 S3 同一个负责人，按顺序做） | 按钮、表格、代码、多行段落 fixture；UI 分段策略；溢出处理；带误报控制的差异检测 | 001 分组、溢出各项通过；光标闪烁不误撤除 |
| **P1–P5 五终端只读探针** | 只依赖 S0 的权限矩阵，可与 S1–S4 并行 | 每个终端一份证据记录，只用公开内容：接口与版本、只读步骤、viewport 与回滚行为、几何来源、权限、DECSET-1004 focus-out 实测（在 S2 的窗口模型下测量） | 安装事实不被升级为能力事实 |
| **S5 注册表 + cmux 插件 + 旧路径切除** | S2、S4、P-cmux | 注册表、能力与需授权状态、unsupported 与 error 区分；cmux 原生文本与 OCR 几何在有证据时合并；删除 CmuxCapture、frontmostBounds 和整窗阅读器；迁移 `capture`/`smoke` 命令与 README | 001 的“一个插件目标 + 一个无插件目标”真实运行 |
| **S6 其余四个终端适配器** | S5 冻结 API 后，加上各自的探针 | Terminal.app、iTerm2、Ghostty、Kaku 四个独立文件并行开发；注册表只由集成负责人修改 | 每个应用都跑完 002 全部适用场景 |
| **S7 集中验收** | 全部 | 001 全部条目 + 002 × 5 矩阵；支持表；文档；变更记录 | D §9 全部满足 |

**首个完整端到端切片 = S2。** 选它的理由有三点：
1. OCR 是所有插件都可能落到的通用回退，任何终端都可能是 partial+OCR，所以它在关键路径上。
2. 它不依赖任何尚未证实的终端 API，却覆盖了全部共享风险：目标身份、权限、坐标变换、覆盖层、输入与焦点、两种后端、失效与迟到隔离。
3. 用独立 fixture 进程可以拿到精确基准，证据可复现。

## 复审触发条件
B1–B7 写进 D、001、002 之后申请复审。其中 B1（最终 bundle id、显示名、是否创建本地签名证书）和 B5（选区交互语义）需要先由用户拍板；B2、B3、B4、B6、B7 可以由负责人直接改方案。复审时会特别核对：权限矩阵每一格都有拒绝路径；子进程放弃授权有验证门槛；屏障是必选项；001:47 已经回到验收清单中。