# 产品变更 002：终端范围与职责

[返回概览](002-terminal-layout-plugins.md) · [源码修改说明](002-terminal-layout-plugins-implementation.md)

本分册中的“本文开头链接”指 [当前契约摘要](../design.md#当前契约摘要2026-10-21-文档整理)；“文末 2026-10-16 源码修改说明”现见 [终端翻译输入与绘制结果](002-terminal-layout-plugins-implementation.md)。

## 首批终端范围

| 终端 | 已确认事实 | 实现前需验证的能力 |
|---|---|---|
| cmux | 当前工具已读取可见屏幕；本机安装 | pane/surface 的几何、网格/字形坐标、选中区域与可见 viewport |
| iTerm2 | 本机安装 `iTerm.app` | 原生/自动化接口或 AX 是否同时提供可见文本、分屏边界和可靠坐标 |
| Ghostty | 本机安装 | 原生/AX 可见文本与字形网格几何；不可假定与 cmux 共用公开 API |
| Terminal.app | 系统安装，bundle `com.apple.Terminal` | 可见 viewport 与历史区分，窗口/tab/文本几何可靠性 |
| Kaku | 本机安装 | 实际布局/文本捕获接口及支持范围 |

安装事实不是接口可用性证明。各插件开发前要记录接口证据和限制。没有可用文字/坐标接口时，插件应标明仅提供布局或“不支持”，由共享 OCR 流程补齐；禁止编造完整支持。

Opus只读证据的精确身份/版本：cmux com.cmuxterm.app 0.65.0；iTerm2 com.googlecode.iterm2 3.7.0；Ghostty com.mitchellh.ghostty 1.3.1；Terminal com.apple.Terminal 2.15；Kaku fun.tw93.kaku 0.19.0。iTerm2/Terminal sdef有可见contents但无content inset/split几何，先partial；Ghostty无文本属性；cmux CLI无像素几何；Kaku get-text在回滚时未证明等于viewport。完整接口事实、权限矩阵与P1–P5探针门槛见[设计方案 §4/7/8](../design.md)，不将安装事实升级为支持。

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
- 历史分段策略：终端/代码继续保守 TranslationPlan，UI 按钮/菜单/表头/单元使用 ≥1 ASCII 单词策略；标识符明确为下划线、camelCase或数字字母混排的词，Cancel/Settings/OK必须翻译；未知区域保护，不伪造TUI状态。该 ASCII 限制已由本文开头链接的当前契约摘要取代。共享本机模式先检查 LanguageAvailability，未安装时不捕获，在“设置…”窗口的“语言包”一行点“准备语言包…”由独立可激活窗口安装后由用户重新触发。

## 状态变化

将文字和布局绑定同一目标与快照。捕获期间 tab/pane/窗口变化应丢弃快照或提示重试；翻译期间发生输出滚动、调整大小、pane分裂/关闭、终端字体缩放等会使坐标失效，需撤除或用户触发重新捕获，不静默把旧译文贴到新文本。

无需实时翻译无限滚动日志。按用户快捷键捕获快照，关闭后看到真实终端的当前状态。
