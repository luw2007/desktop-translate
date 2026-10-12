# 产品变更 002：常见终端布局与文本插件

状态：方案经 Opus 复审 **PASS_WITH_NONBLOCKING**，允许开始开发；[报告](../../reviews/opus-plan-review.md)。待实现，全部验收门槛未执行，不是已发布能力。依赖产品变更 001 的目标识别、插件加载与定位覆盖契约。

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

- 根据精确bundle id和唯一窗口匹配，内建插件只读，不输入命令、不改变tab/pane焦点；选择/HUD/overlay/展开是非激活NSPanel，保持fullScreenAuxiliary。五应用必须实测DECSET-1004 FocusLost次数，目标0，非0披露实际与限制；当前不引入event tap，任何新增输入监控/AX权限路线先更新权限矩阵并重新经Opus复审。
- 识别终端窗口内的 tab/分屏/侧边栏/可见内容矩形，保持区域层级与阅读顺序。
- 提取**可见 viewport**文本，不把历史 scrollback 当当前屏幕；可获得原生文字时优先使用，必要时与截图几何合并。
- 文字携带原文与几何映射。非ASCII列宽来自终端报告或OCR对齐，否则明示OCR，不自行按字符数推列宽；记录终端Unicode/模糊宽度设置，覆盖宽字符、emoji、组合字符、软换行和字体缩放。软换行合并段落请求，用各行矩形并集排版。
- 标记正文、代码/命令、提示符、日志、diff、TUI 边框/状态栏。保守分类；无法确定的区域不以翻译覆盖伪造状态。
- 输出产品变更 001 的共享快照/区域契约，复用已有本机/pi翻译与统一覆盖层；插件不绑定某个模型。
- 原生接口不支持的能力必须明示，不将整窗全文重排作为定位成功。
- 默认一键只在聚焦pane身份与几何、content inset可靠时取其内容矩形，否则使用锁定窗口完整CG bounds（window-local (0,0,w,h)，包含标题栏，无需AX/inset）；显式“区域翻译”拖选/Return/Esc，选区按(bundleID,windowID)会话记忆并于resize/pane变化失效。无pane证明时明确来源/限制，不能猜inset或把整窗称为聚焦pane。
- 原生revision为同一可见文本重读哈希+布局/字体/身份，不需要SR；无可靠revision不得展示，用户可明确另选OCR。OCR sourceRect仅含选区，AX安全角色排除；provider捕获前可见。error与needsPermission不能静默OCR。
- 终端/代码继续保守TranslationPlan，UI按钮/菜单/表头/单元使用≥1 ASCII单词策略；标识符明确为下划线、camelCase或数字字母混排的词，Cancel/Settings/OK必须翻译；未知区域保护，不伪造TUI状态。共享本机模式先检查LanguageAvailability，未安装时不捕获，通过独立可激活“准备本机语言包”窗口安装后由用户重新触发。

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

插件扩展点本轮仅编译进app的内建Swift插件，不加载外部可执行代码。外部插件信任/签名/隔离另审。AE进程内发送而非osascript；CLI与pi/认证助手用共享私有responsibility_spawnattrs_setdisclaim spawner，仅内部native用途，符号缺失fail closed。支持macOS15+本地工作站，不承诺App Store。B1已定：Desktop Translate/release local.cmux.translate保留原配置；DEV显示Desktop Translate DEV、bundle local.cmux.translate.dev.<tag>（tag匹配[A-Za-z0-9-]+）、独立worktree .dev/data/config/build与XDG覆盖、默认⌃⌥⇧T（配置优先，release用户设置不变）、Bundle.main动态单实例。S0第一笔实现提交仅launcher隔离，非主worktree缺合法tag拒绝构建，忽略.dev；隔离落地前禁止构建。用户明确接受ad-hoc开发每次重建重新授权；S0独立公共fixture SCK截图探针无OCR且不保存，S2完整捕获/OCR管线，拒绝停止；日常app/配置不变且两者并存，不要求两次重建TCC保持。签名identity可选、证书默认禁用，不创建证书/改钥匙串；稳定production签名是发布前提，不阻塞获豁免的开发，源码/launcher别名保留至产品迁移。
