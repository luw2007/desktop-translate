# Desktop Translate

独立 macOS 桌面翻译项目。当前交付包含 cmux 可见屏幕阅读层，以及已组装但仍需真实 UI 验收的通用桌面/定位 OCR/终端插件路径；Apple 本机或用户选择的 pi 翻译、可配置快捷键、可撤销的只读覆盖层保持不变。本文不把未完成的真实 UI 证据宣称为发布能力。
开发隔离：DEV 应用默认快捷键为 **Control + Option + Shift + T（⌃⌥⇧T）**；若 `.dev/config` 已有快捷键则配置优先，release 用户设置不被覆盖。每个 worktree 使用独立 `.dev/data`、`.dev/config`、`.dev/build` 和 XDG 覆盖路径；release 路径与日常配置保持不变。显示名不区分构建：DEV 与 release 的应用显示名同为 Desktop Translate，差异只在 bundle id 与 `.dev/` 数据/构建路径。


> 多窗口说明：同一 app 有多个重叠（含等 frame）普通窗口时，取 CGWindowList 前到后顺序最上层者为目标，不再一刀切拒绝；半透明顶层压住同 app 下层窗口或缺少顺序证据时仍拒绝。详见 DESIGN.md。

## 使用当前实现

要求 Apple Silicon、macOS 15+ 和 Xcode Command Line Tools；通用前台窗口的 ScreenCaptureKit/OCR 路径不依赖 cmux。终端插件能力与限制见下方支持说明。

```sh
cd ~/ai/desktop-translate
./cmux-translate help
./cmux-translate start
# 现有 PATH 入口仍可使用：
cmux-translate
```

`~/dotfile/bin/cmux-translate` 是指向本项目实际 launcher 的安装符号链接；launcher 解析链接后从本项目读取源码，与从独立根目录直接运行一致。没有复制第二套实现。源码目录暂保留 `cmux-translate-app/`，所有源文件、测试与产品变更记录随项目迁移。

配置继续使用 `$XDG_CONFIG_HOME/cmux-translate/config.json` 或 `~/.config/cmux-translate/config.json`，无需导入、重置或改名；快捷键和本机/pi选择保持兼容。安装 app 继续位于 `$XDG_DATA_HOME/cmux-translate/CMux Translate.app` 或 `~/.local/share/cmux-translate/CMux Translate.app`。迁移没有改动个人配置、已安装 app 或正在运行的实例；下次执行构建类命令可能按源码时间戳重新构建。

- [当前功能、隐私、设置及诊断](cmux-translate-app/README.md)
- [实施方案（部分实现，未验收）](DESIGN.md)
- [001：通用桌面插件与定位 OCR](cmux-translate-app/changes/001-desktop-plugin-ocr.md)
- [002：五种终端布局与文本插件](cmux-translate-app/changes/002-terminal-layout-plugins.md)
- [2026-10-16 源码修改（未构建未运行）](#2026-10-16-源码修改未构建未运行)

## 迁移记录

- 2026-10-12：从 dotfile/bin 分离为独立 Git 项目；保留历史命令、配置目录与源码名称，PATH 入口改为符号链接。DEV 隔离与插件/OCR代码已组装；真实 UI 验收仍有明确阻塞项，未宣称通用桌面/OCR能力完成。

## 当前实现状态与剩余门槛

DEV host 的独立公共 fixture ScreenCaptureKit 探针曾成功（1520×1040，无保存、无 OCR）；disclaim spawner 子进程报告 SR/AX=false。这只证明该次探针及预检结果，不证明完整权限隔离或 TCC 授权来源。TCC=true 的确切责任归属与因果未证实，不归因于 Doubao 或其他应用。

旧本机 smoke 的 ok 标志不是定位或键盘隔离证明：其框匹配采用未一一对应的最小距离，曾报告最大 159.8pt，输入使用合成事件。不能据此声称精度达标、真实点击/滚轮/按键不穿透或 FocusLost=0；后续修正仍待真实 UI 验收。本机与 pi 的真实端到端流程均未验收。

历史公共工作流观察（早于下述集中 gate）：本机public smoke在捕获前因缺Apple en→zh语言包失败；pi尝试在捕获前找不到普通CG窗口。新glyph场景首次sharing=None未通过guard，未OCR；当时新增的owned PID/window、sharing1/2连续两tick就绪条件（该sharing条件已被下文2026-10-15批准取代）加入后重建exit0，刻意newglyph-pi正文仍在捕获前因notFrontmost失败。没有模型请求、成功展示、≤4pt指标或输入隔离证据。owned PTY生产者14项检查仅覆盖五种canned场景、合成CSI计数、22byte丢弃与所有权清理，不是真实五应用；Ghostty/Kaku候选要求safeguard token，其他三应用缺用户批准fixture。没有权限变更或新私有截图文件，原任务未完成。

五种终端适配器已注册，但注册或编译不等于五终端产品交付。当前来源是 window-only partial/unsupported + OCR：cmux 0.65.0（CLI metadata-only identify）；iTerm2 3.7.0（显式数值 ID、只读 visible-contents probe）；Terminal.app 2.15（选中 tab、无 history）；Ghostty 1.3.1（无文字接口）；Kaku 0.19.0（全局 list 未映射 CG，screen row 0 不证明 viewport）。没有已证明的 native positioned mapping、tab/pane 精确几何或原生 Unicode 列宽映射；OCR 路径本身也未完成真实验收。

剩余门槛：真实文字框定位误差≤4pt；真实点击/滚轮/按键在遮罩及未遮罩区域的屏障隔离；原生全屏、负坐标、1x/2x 两种缩放、跨屏/Space；五应用的 tab/分屏/TUI/Unicode/字体缩放；逐应用 FocusLost 实际次数；本机/pi 真实端到端；权限拒绝/撤销及隔离、复杂布局/溢出/失效与完整 001/002 验收。production 稳定签名仍是发布门槛，临时开发签名不是 TCC 稳定性证明。
***

## 2026-10-16 源码修改（未构建未运行）

本轮源码修改已写入工作区但**未构建、未类型检查、未运行**：pi 新增显式截图输入模式（默认仍是 OCR 文字；只有用户显式选择才发送所选区域截图，内存 PNG 经 stdin，不落盘、不入日志或错误、不进进程参数，随会话丢弃）、模型下拉改由 pi 自身 `get_available_models` 提供并带图像能力标注（截图模式只允许声明支持图像输入的模型）、HUD 改为四类真实绘制计数、原位置渲染按实际可绘制字形几何修正，且无可用原文位置的区域不再丢弃全文。截图模式沿用与文字模式相同的隔离 pi 调用参数（无工具、无额外扩展、无 MCP 等，只加载自带最小扩展），位置为模型自报的裁剪比例映射、不是原生或 OCR 验证几何，对模型未报出的图标/非文字没有保证。改动者只对每个改动文件执行过 `swiftc -parse`（无语法错误），类型错误仍可能在构建时出现。相关描述已同步到 [应用说明](cmux-translate-app/README.md)、[实施方案](DESIGN.md)、[001](cmux-translate-app/changes/001-desktop-plugin-ocr.md) 与 [002](cmux-translate-app/changes/002-terminal-layout-plugins.md)。本节不是验收证据，不改变下述任何未通过门槛；最终集中验证由集成负责人另行执行并报告。

## 集中验证

最终集中 gate（2026-10-16，由集成负责人执行并报告）：当前 DEV app 与 glyph fixture 构建 exit 0（fixture 未启动）；GlyphMatcherChecks、DesktopChecks（实际 paint/source clipping、gap、overflow、collision 与已接入的 signatureChecks）通过；两个实际 PTY/CLI Python 测试通过。实际 `drawToken` 离屏 oracle 覆盖六场景、1x/2x 共 68 次绘制，对比 alpha 与最终 `oracleConsistent`（向外像素对齐加一个设备像素的抗锯齿模型），不是通用物理精度证明，OCR/mask 4pt 阈值未改。fresh attach 的真实进程/TTY 与合成 bundle 边界检查通过，不是 emulator UI。未新增 GUI、捕获、权限预检/请求或网络。真实显示 oracle 渲染几何、≤4pt、模型请求、成功展示与输入隔离证据仍不存在；产品行内 caret 与产品非文字安全证明仍未完成，用户权限/本机语言包与真实终端/显示硬件门槛仍阻塞。`pi-smoke` 会把公共示例发送给已配置模型服务，`smoke` 可能要求下载 Apple 语言包。该 gate 早于上方 2026-10-16 源码修改，不覆盖 pi 截图模式、模型下拉、绘制计数与渲染修正；这些修改只有逐文件 `swiftc -parse` 证据。

段落与溢出内联延伸（2026-10-18）：连续正文在左缘、高度、行距一致且没有受保护/遗漏观察穿过间隙时可合并为段落块，整块翻译并保留保护片段。12pt 仍放不下时，可向右和向下进入“无识别矩形且同一张原图像素与背景一致”的已证明空白处；源块（含行间隙）与扩展条带并入同一不可变新鲜度基线，绘制时再次夹紧边界。不安全或仍放不下者保留空间不足（橙色标记，可展开全文）。调试 E 包含任一方向的安全扩展，HUD/log 分别计数。详见 DESIGN §6；实窗捕获与实际翻译效果尚未测试。

溢出兜底（2026-10-19）：空间不足时先用窄体并把字号自 12pt 降到最低 9pt（调试 S），仍只画在源区域和已证明空白处；仍放不下才按用户明确接受的最后手段画半透明背景覆盖（约 85% 不透明、带细边框，调试 V），它会盖住邻近的未翻译/受保护内容，但不与其他译文重叠，且限制在窗口/选区内，不计入新鲜度基线。仍无法显示的行保留橙色标记与展开面板。

重叠项与短标签（2026-10-19）：两条译文的原文框互相重叠时不再两个都拒绝——阅读序靠前者保留整框，靠后者把自身绘制区裁掉前者的原文框（剩余片段两边均 ≥6pt）后走常规链（常规→窄体/9pt→半透明覆盖→溢出），绝不叠画两条译文；与受保护/未翻译文字或延伸障碍重叠、被完全吞没、身份重复仍为冲突（C），但现在同样画橙色可展开标记。终端行规则放宽：单个首字母大写词（Complete）、全大写短语、带装饰符号的状态行（✓ Complete）、`## 标题`、状态分隔符 ` | `、含 `;` 的正文句、以 for/if/from/go/make 等开头的普通句均可翻译；路径、URL、哈希、数字/时间、命令（含装饰提示符后）、代码、选项、标识符、主机/IP 仍跳过。K 保持代码 K，调试标签附子原因（如 K7:short），日志新增“无需翻译原因计数”（仅计数，无文本）。真实窗口效果尚未验证。

## 2026-10-15 批准的捕获边界

用户已选择“批准修正契约并继续”。legacy CG sharing=0 / NSWindow.sharingType=.none既不证明保护也不证明捕获安全，仅可作非权威诊断，不产生用户警告或允许/拒绝决策。屏幕录制权限缺失/撤销独立报告；实际SCK未列出精确锁定目标、SCK错误或全黑结果明确报无法捕获（可能受系统或应用保护），不报无文字、不回退其他窗口/显示器。窗口身份/选区sourceRect与重验证仍保留，provider在捕获前可见；默认只发送待翻译正文，只有用户显式选择 pi 截图模式时才把所选区域截图（内存 PNG、不落盘、不入日志）发送给所选模型。OCR不能检测或排除像素中的安全字段、敏感控件或应用防截图意图；AX secure排除只适用于AX读取，局部黑块剩余像素仍可能OCR。不要选择含敏感信息的区域。

历史sharing1/2 readiness被取代，仍要求精确owned窗口/frame/layer/alpha/单普通窗口连续两tick。公开fixture激活仅每次显式opt-in、对新建且身份核实的owned PID至多一次，不能激活既有用户应用或注入输入。此修正不授权新权限或改TCC/钥匙串/日常配置，不新增运行证据；原始S2/S3/S4/S6及001/002验收仍未通过。
