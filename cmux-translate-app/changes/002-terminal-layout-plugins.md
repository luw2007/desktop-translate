# 产品变更 002：常见终端布局与文本插件

状态：方案经 Opus 复审 **PASS_WITH_NONBLOCKING**，允许开始开发；[报告](../../reviews/opus-plan-review.md)。已部分实现，**未验收**，不是已发布能力。依赖产品变更 001 的目标识别、插件加载与定位覆盖契约；五适配器注册或编译不等于五终端完整交付。

## 用户目标

为常见终端开发插件，识别窗口/分屏布局、可见文字内容及正文/代码区域，使终端翻译优先使用可靠的文字与几何数据，而非通用 OCR 猜测。

对应请求条目 3。不缩减成仅支持 cmux，也不把全屏纯文本输出称为布局插件。

## 首批终端范围

| 终端 | 已确认事实 | 实现前需验证的能力 |
|---|---|---|
| cmux | 当前工具已读取可见屏幕；本机安装 | pane/surface 的几何、网格/字形坐标、选中区域与可见 viewport |
| iTerm2 | 本机安装 `iTerm.app` | 原生/自动化接口或 AX 是否同时提供可见文本、分屏边界和可靠坐标 |
| Ghostty | 本机安装 | 原生/AX 可见文本与字形网格几何；不可假定与 cmux 共用公开 API |
| Terminal.app | 系统安装，bundle `com.apple.Terminal` | 可见 viewport 与历史区分，窗口/tab/文本几何可靠性 |
| Kaku | 本机安装 | 实际布局/文本捕获接口及支持范围 |

安装事实不是接口可用性证明。各插件开发前要记录接口证据和限制。没有可用文字/坐标接口时，插件应标明仅提供布局或“不支持”，由共享 OCR 流程补齐；禁止编造完整支持。

Opus只读证据的精确身份/版本：cmux com.cmuxterm.app 0.65.0；iTerm2 com.googlecode.iterm2 3.7.0；Ghostty com.mitchellh.ghostty 1.3.1；Terminal com.apple.Terminal 2.15；Kaku fun.tw93.kaku 0.19.0。iTerm2/Terminal sdef有可见contents但无content inset/split几何，先partial；Ghostty无文本属性；cmux CLI无像素几何；Kaku get-text在回滚时未证明等于viewport。完整接口事实、权限矩阵与P1–P5探针门槛见DESIGN §4/7/8，不将安装事实升级为支持。

## 插件职责

- 根据精确bundle id和唯一窗口匹配，内建插件只读，不输入命令、不改变tab/pane焦点；选择/HUD/overlay/展开是可成为key的非激活NSPanel，保持fullScreenAuxiliary。五应用必须实测DECSET-1004 FocusLost次数并披露实际与限制，零不是验收要求；当前不引入event tap，任何新增输入监控/AX权限路线先更新权限矩阵并重新经Opus复审。
- 识别终端窗口内的 tab/分屏/侧边栏/可见内容矩形，保持区域层级与阅读顺序。
- 提取**可见 viewport**文本，不把历史 scrollback 当当前屏幕；可获得原生文字时优先使用，必要时与截图几何合并。
- 文字携带原文与几何映射。非ASCII列宽来自终端报告或OCR对齐，否则明示OCR，不自行按字符数推列宽；记录终端Unicode/模糊宽度设置，覆盖宽字符、emoji、组合字符、软换行和字体缩放。软换行合并段落请求，用各行矩形并集排版。
- 标记正文、代码/命令、提示符、日志、diff、TUI 边框/状态栏。保守分类；无法确定的区域不以翻译覆盖伪造状态。
- 输出产品变更 001 的共享快照/区域契约，复用已有本机/pi翻译与统一覆盖层；插件不绑定某个模型。
- pi 后端有两种由用户显式选择的输入方式：默认 `ocr-text` 只发送本机识别出的正文，`image` 才发送所选区域的完整裁剪图像；模型由 pi 自身 `get_available_models` 提供，截图模式只允许声明支持图像输入的模型。截图模式的位置是模型自报几何，不是原生或 OCR 验证结果；该能力与终端插件能力互相独立，不改变上文的 native/OCR 优先级。详见文末 2026-10-16 源码修改说明。
- 原生接口不支持的能力必须明示，不将整窗全文重排作为定位成功。
- 绘制结果按四类如实计数（已绘制/空间不足/与相邻文字冲突/无可用原文位置）：无可用原文位置的区域不再丢弃全文，条目始终保留并可经展开面板读取全文，HUD 只在未全部绘制时提示展开、无任何区域绘制时报失败而非成功。此前“无占用即丢弃条目”的表述由本节取代，详见文末 2026-10-16 源码修改说明。
- 默认一键只在聚焦pane身份与几何、content inset可靠时取其内容矩形，否则使用锁定窗口完整CG bounds（window-local (0,0,w,h)，包含标题栏，无需AX/inset）；显式“区域翻译”拖选/Return/Esc，选区按(bundleID,windowID)会话记忆并于resize/pane变化失效。无pane证明时明确来源/限制，不能猜inset或把整窗称为聚焦pane。
- 原生revision为同一可见文本重读哈希+布局/字体/身份，不需要SR；无可靠revision不得展示，用户可明确另选OCR。OCR sourceRect仅含选区，AX安全角色排除；provider捕获前可见。error与needsPermission不能静默OCR。
- 2026-10-15用户批准“批准修正契约并继续”：共享OCR策略以实际SCK结果为准，SR缺失/撤销独立报告；精确锁定目标未列出、SCK错误、全黑明确报无法捕获（可能受系统或应用保护），不报无文字、不回退窗口/显示器。legacy sharing值不证明保护或安全，仅非权威诊断，不作捕获/用户警告条件。AX secure排除只适用于AX读取；OCR无法检测/排除安全控件、敏感像素、防截图意图，局部黑块的剩余像素仍可能OCR。provider捕获前可见与锁定窗口/选区边界不变。
- 终端/代码继续保守TranslationPlan，UI按钮/菜单/表头/单元使用≥1 ASCII单词策略；标识符明确为下划线、camelCase或数字字母混排的词，Cancel/Settings/OK必须翻译；未知区域保护，不伪造TUI状态。共享本机模式先检查LanguageAvailability，未安装时不捕获，在“翻译模式、语言与模型…”窗口的“语言包”一行点“准备语言包…”由独立可激活窗口安装后由用户重新触发。

## 状态变化

将文字和布局绑定同一目标与快照。捕获期间 tab/pane/窗口变化应丢弃快照或提示重试；翻译期间发生输出滚动、调整大小、pane分裂/关闭、终端字体缩放等会使坐标失效，需撤除或用户触发重新捕获，不静默把旧译文贴到新文本。

无需实时翻译无限滚动日志。按用户快捷键捕获快照，关闭后看到真实终端的当前状态。

## 验收矩阵

每个首批终端均需要真实应用证据，不只以单元测试或 mock 证明支持：

- [ ] 插件匹配正确，支持/部分支持/不支持能力可见；无法原生提取时可用 OCR且显示来源。
- [ ] 单窗口、多个 tab、分屏（终端支持时）下，捕获边界与文字位置正确；不读取无关 pane，不改变焦点。
- [ ] 提示符、代码块、命令、路径、diff保持原文；长英文段落翻译可读且不覆盖邻近区域。
- [ ] 宽字符、emoji、组合字符、软换行、Retina缩放、负屏幕坐标有定位证据。
- [ ] TUI与动态日志场景不误把历史文字当当前内容；不因旧快照覆盖新的状态。
- [ ] 翻译中取消、快捷键/Esc恢复、pane关闭/字体缩放/目标切换均安全。
- [ ] 本机和 pi 模式都复用同一插件结果；模型选择/快捷键持久化不受插件影响。
- [ ] 默认一键/显式区域两流程、会话记忆失效、非激活UI、各终端DECSET-1004 focus-out实数与限制有证据；全窗口屏障在遮罩/未遮罩区吞点击滚动，窗口外切换撤除；fullScreenAuxiliary与原生全屏终端Space真实验证；遮挡仅其他PID layer0，自身overlay与系统层不误撤除。
- [ ] 每插件权限矩阵逐格拒绝、AE逐应用请求/usage说明、AX安全角色、原生revision与展示前重读有证据；所有CLI/pi共享disclaim spawner，app有SR/AX时公开子进程预检false。
- [ ] 只读白名单静态检查，清理CMUX_*/WEZTERM_*/Kaku目标变量，固定bundle内CLI路径，Kaku --no-auto-start、cmux无--lines/--scrollback；回滚viewport不可靠明确布局+OCR。
- [ ] 未知应用版本标未验证，调度器验证ID/裁剪/父区域/上限/revision；OCR双语言与代码禁纠错、半透明背景、光标签名误报及连续两次变化有真实证据。

## 范围边界

不修改终端缓冲区、不注入 Shell、不要求用户安装改变终端行为的命令回显钩子。若某终端需要额外官方自动化权限/集成，必须说明、由用户选择启用。

插件扩展点本轮仅编译进app的内建Swift插件，不加载外部可执行代码。外部插件信任/签名/隔离另审。AE进程内发送而非osascript；CLI与pi/认证助手用共享私有responsibility_spawnattrs_setdisclaim spawner，仅内部native用途，符号缺失fail closed。支持macOS15+本地工作站，不承诺App Store。B1已定：Desktop Translate/release local.cmux.translate保留原配置；DEV显示名同为Desktop Translate（内部 .dev 构建路径名不变）、bundle local.cmux.translate.dev.<tag>（tag匹配[A-Za-z0-9-]+）、独立worktree .dev/data/config/build与XDG覆盖、默认⌃⌥⇧T（配置优先，release用户设置不变）、Bundle.main动态单实例。S0第一笔实现提交仅launcher隔离，非主worktree缺合法tag拒绝构建，忽略.dev；隔离落地前禁止构建。用户明确接受ad-hoc开发每次重建重新授权；S0独立公共fixture SCK截图探针无OCR且不保存，S2完整捕获/OCR管线，拒绝停止；日常app/配置不变且两者并存，不要求两次重建TCC保持。签名identity可选、证书默认禁用，不创建证书/改钥匙串；稳定production签名是发布前提，不阻塞获豁免的开发，源码/launcher别名保留至产品迁移。

## 当前证据与限制

当前五终端均为 window-only partial/unsupported + OCR，OCR 本身未完成真实验收。cmux 0.65.0 为 metadata-only identify；iTerm2 3.7.0 有显式数值 ID 的只读 visible-contents probe；Terminal.app 2.15 有选中 tab visible contents、不读 history；Ghostty 1.3.1 无文字接口；Kaku 0.19.0 的全局 list 未映射 CG，screen row 0 不证明 viewport。没有已证明的 native positioned mapping、tab/pane 精确几何、原生 Unicode 列宽或字体缩放映射。

旧 smoke 的 ok 标志不证明定位或键盘隔离：未一一对应框的最小距离匹配曾报告最大 159.8pt，输入为合成事件。FocusLost 未测不能写为零。公共 host SCK 探针及子进程 SR/AX=false 不证明完整权限隔离；TCC=true 的确切来源及因果未证实，不归因于 Doubao 或其他应用。

当前合法 partial-empty 走共享 OCR，保留实际 OCR 能力、provenance 与 revision，不沿用未验证 native revision；不同window ID同frame仍重叠fail closed。最新待验证 `RegionSignature.swift` 按原始SCK译文实测行rect计算原始像素FNV哈希（最多4096），绑定crop/尺寸/格式/不可变rect set，替代整选区64×64分块签名。区域外/间隙/受保护内容变化不影响该签名，行内caret仍fail closed、未解决；不是运行验收证据。

最新公共流程无模型请求/展示/≤4pt/输入证明：本机缺Apple en→zh包，pi缺普通CG窗口；newglyph先sharing=None，readiness修正及build exit0后newglyph-pi仍捕获前notFrontmost。Glyph fixture构建/GlyphMatcher通过，真实oracle几何未验证。S6 owned PTY14项仅覆盖五canned场景、合成CSI计数、22byte丢弃与所有权清理，不是真实五应用；Ghostty/Kaku候选需safeguard token，其余三应用缺用户批准fixture。S2/S3/S4/S6仍阻塞，未改权限或产生新私有截图。

剩余门槛：五应用真实运行及 tab/分屏/TUI/Unicode/字体缩放、真实文字框≤4pt、真实点击/滚轮/按键隔离、逐应用 FocusLost 实际次数、原生全屏/负坐标/1x与2x/跨屏/Space、本机/pi 真实端到端、逐应用权限拒绝/撤销及隔离、复杂布局/溢出/失效，以及完整 001/002 验收。production 稳定签名仍是发布门槛。

最新实现：verified插件布局先于OCR分组，父区域完整包含/token完整切分，跨界省略并显示固定警告，pane/font仅复制verified能力。软换行按实际词间距、无容差判断下一词不能容纳verified容器，不按字体样式合并控件标签。OccupiedGeometry检查受保护/未译文字碰撞，不画任何正文或marker，由HUD展开；实际限制及skipped数经固定清洗显示。

最终集中证据：最终源码DEV构建exit0、24.90s、无warning输出；最终DesktopChecks通过。实际源码内存/offscreen检查通过pane/跨界/保护命令/换行、签名忽略外部/间隙/保护像素并检测内部1px/几何变化、精确选区与碰撞原文未涂绘。静态签名复审未报告P0–P2。HUD/Expansion未展示，无实际key，session start/live SCK/present和屏幕/UI/权限未新增验证。

相关行caret仍fail-closed，误报排除属于未完成开发，不只是物理验收缺证；图标/非文字占用无安全证明。五终端和S4真实门槛未验收。

caret边界：SCK像素不能安全区分caret/字形；周期掩码及debounce放宽未批准、未实现。优先验证native visible-text revision与cursor/cell几何（含attributes）两项；否则AX selected-range bounds+value须新范围/隐私审查、AXSecure排除和用户授权，本轮无新增代码。最终精确源码编译exit0、30.4s，仍不代表S2/S3/S4/S6验收。

### 2026-10-16 终端 fixture 设施

新增源码：`fixtures/terminal_public_producer.py` report schema 升到 **2**（新增 `scenarioMode` cycle/fixed、`revision`、`xpixel`/`ypixel` 取 `TIOCGWINSZ`，0 表示 emulator 不上报像素；`SIGWINCH` 只置 dirty 让下一 tick 重读尺寸）。`revision` 是 tick 计数器而非内容变化证明：每次场景渲染和每个 0.5s tick 都递增，静止场景同样递增；区分真实重绘要看 `sceneChanges`（场景切换）与 `renderCount`（完整场景渲染）。`fixtures/terminal_fixture_launcher.py` 新增 `handoff`/`attach-plan`/`attach` 子命令；`cmux-translate-app/TerminalSmoke.swift` 是新的 handoff 消费者。

能力边界按实际源码写死：`launch` 只对「已安装 bundle 有文档化隔离独立启动路径」的应用新建进程（当前仅 Ghostty/Kaku 为 candidate，且两者都未被观察过），其余三应用必须走 `attach-plan` + `attach` 的用户手工路径；`attach` 的机器校验只有四项——plan 文件存在且未被改写、owner 进程 `ps lstart` 严格晚于 plan 时间、report 为 running 且新鲜且其 pid 是本 token 的活 `terminal_public_producer.py`、该 pid 是 owner 的后代。「全新一次性进程、非日常实例」是 `--attest-new-disposable-process` 的操作者声明，`state.json` 里也如实记成 `operator-asserted; machine-checked only: …`；该路径**不证明**附加进程没有其他 tab/pane，`--window-id` 由操作者提供。

消费者侧不信任 launcher 的派生数据：`TerminalSmoke.swift` 用 `sysctl` 重取 owner/producer 启动时间与 `lstart` 字符串比对、重算后代链、用 `stat` 校验控制 tty 的 `st_rdev`、要求 owner 是预期 bundle 的活进程、要求锁定的目标是 owner **唯一**普通窗口且非空标题包含 `DT-Fixture-<token>`；就绪要求 owner 自然前台且该唯一窗口连续两 tick 稳定（10s 上限），全程不激活、不输入、不启动、不终止，失败不回退到其他窗口。输出刻意声明 `geometry.measured = false`：终端文字没有字形几何 oracle，因此它只报公共计数/来源，不报 ≤4pt。

最终集中 gate（Main 报告，2026-10-16）：DEV app 与 glyph fixture 构建 exit 0（fixture 未启动），两个实际 PTY/CLI Python 测试通过，fresh attach 的真实进程/TTY 与合成 bundle 边界检查通过。这仍不是 emulator UI、物理 FocusLost 或五应用证据，`geometry.measured = false` 不变，S6 与原始 S2/S3/S4 仍未验收。

2026-10-15批准不新增运行证据：历史sharing readiness被取代，精确owned PID/window/frame/layer/alpha/单普通窗口两tick与重验证保留。激活只允许显式opt-in对本次新建、身份核实的公共fixture owned PID至多一次，不适用于五个既有用户终端，不注入输入；无新权限或TCC/钥匙串/日常配置更改。原始S2/S3/S4/S6及001/002仍未验收。

### 2026-10-16 终端翻译输入与绘制结果（源码已改，未构建未运行）

本节记录 2026-10-16 的源码修改，只完成源码写入与逐文件 `swiftc -parse`，**未构建、未类型检查、未运行**，不是验收证据，也不改变上文五终端能力事实、验收矩阵或任何未通过门槛：

- **输入方式**：pi 模式新增显式 `translation.inputMode`（`ocr-text` 默认 / `image`），旧配置无该键按 `ocr-text` 解释；截图模式只在用户显式选择时把与 OCR 路径相同的精确锁定窗口/选区裁剪编码为内存 PNG 经 stdin 发送（不落盘、不入日志或错误、不放进进程参数），且不回退。模型列表改由 pi 自身 `get_available_models` 提供，显示 `provider/id` 与图像能力，已保存但不可用的模型保持可见并标注。截图模式的位置是模型自报的裁剪比例映射，不是原生或 OCR 验证几何，对模型未识别/未报出的图标、非文字与文字没有保证；区域必须落在裁剪内且受保护片段逐字出现，否则整批拒绝显示；展示前仍以同一张已持有的原图基线核对变化，不重新截图。
- **绘制计数**：HUD 使用四类真实结果计数（已绘制/空间不足/与相邻文字冲突/无可用原文位置），四类之和等于条目总数；无可用原文位置不再丢弃全文。计数只描述本次绘制结果，不构成定位精度或覆盖率证据，也不改变本变更的验收矩阵。

