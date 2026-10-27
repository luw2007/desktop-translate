# Opus 架构审查：设计方案 + 变更 001/002

> 历史审查原始结论保留；不代表当前实现或发布验收。历史行号引用对应当时版本，当前文件见[设计方案](../design.md)、[001](../changes/001-desktop-plugin-ocr.md)、[002](../changes/002-terminal-layout-plugins.md)。后续替代条款见[当前契约摘要](../design.md#当前契约摘要2026-10-21-文档整理)。

- **审查模型**：Claude Opus 5.5（`claude_sub2api/claude-opus-5-5`），agent `OpusPlanReview`。
- **范围**：只读审查 `<历史项目检出目录>` @ `4adc120`（工作树干净）。没有修改文件，没有运行构建、测试或 smoke。只运行了只读事实探针：读取 bundle Info/sdef、CLI `--help`、显示器配置，以及一次符号存在性检查。
- **引用缩写**：`D` = [设计方案](../design.md)；`001` / `002` = `docs/changes/00x-*.md`（仓库根相对路径）；代码路径相对于 `app/`；`launcher` = 根目录 `desktop-translate`。

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

## 审查正文导航

- [阻塞项 B1–B3：身份、权限与子进程安全](opus-plan-review-initial-blockers-identity.md)
- [阻塞项 B4–B7：输入焦点、选区、分段与敏感区域](opus-plan-review-initial-blockers-interaction.md)
- [非阻塞项 N1–N7、推荐切片与复审触发条件](opus-plan-review-initial-recommendations.md)

所有原始问题、决议、验证门槛与推荐切片完整保存在分册中。上述 BLOCKED 是原始 verdict；下面的追加决定只替代明确指定的历史条款，不追改当时判定。

## 2026-10-15 追加：用户批准替代 B7 第 3 项

保留以上原始审查与判定作为历史记录，不把后来的事实改写为当时已知。用户已明确选择“批准修正契约并继续”。Apple 对 NSWindow.SharingType.none 的说明为：“A legacy constant that macOS no longer uses.”，并明确：“Don't use this value to hide or omit content from being captured. Instead, use FairPlay Streaming.”（https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none）。因此 B7 第 3 项将 sharing=none 视为保护的前提已由本次用户决定取代，不再有效；其余选区、AX读取排除、provider边界保留。

新契约：SR缺失/撤销独立报告；精确windowID/PID、onScreen/layer0/相同frame目标不在SCShareableContent、SCK错误或全黑明确报无法捕获（可能受系统或应用保护），不能报无文字或回退窗口/显示器，不将所有错误归因保护。legacy sharing只可非权威诊断，不能用于允许/拒绝或用户警告；不猜OS版本。OCR不能检测/排除防截图意图、安全字段或敏感像素，AX secure排除只适用于AX读取，局部黑块剩余像素仍可OCR；`--sharing-none`只记录实际结果，不保证拒绝。产品与harness共享策略，无fixture例外。显式opt-in仅允许新建、身份完全核实的公共fixture owned PID至多一次激活，不激活既有用户应用或注入输入，不新增权限或更改TCC/钥匙串/日常配置。此追加不是新验收或复审通过证据；S2/S3/S4/S6和原始001/002门槛保持未验收。