# Desktop Translate 桌面中文阅读层

独立 macOS 菜单栏辅助工具。历史基线读取 cmux 可见屏幕快照；通用桌面、定位 OCR 和终端插件路径已部分实现，**未验收**。使用用户选择的 Apple 本机或 pi 无头模式翻译英文正文，在只读覆盖窗口中显示；pi 模式有两种输入：默认只发送本机 OCR 识别出的文字，或由用户显式选择把所选区域截图作为图像发送。设计不修改终端缓冲区或向 Shell 发送输入，真实输入屏障仍需验收。

项目根目录现为 `~/ai/desktop-translate`，本页中的 `cmux-translate-app/...` 检查命令均从该根目录执行。PATH 中原有 launcher 为安装符号链接，配置和已安装 app 路径不变。DEV 每个 worktree 使用 `.dev/data`、`.dev/config`、`.dev/build` 与 XDG 覆盖；默认快捷键为 **⌃⌥⇧T**，已有 DEV 配置优先，release 设置不改。见[项目说明](../README.md)及[实施方案](../DESIGN.md)。

## 启动与操作

要求 Apple Silicon、macOS 15 或更新版本和 Xcode Command Line Tools，不要求安装 cmux。可从普通终端执行：

```sh
cmux-translate
```

第一次会编译并签名本机 app 到 `~/.local/share/cmux-translate/CMux Translate.app`。源码变更后下次启动自动重新编译。菜单栏出现“译”表示已运行；DEV 与 release 的应用显示名同为 Desktop Translate，差异只在 bundle id（`local.cmux.translate.dev.<tag>`）与 `.dev/` 数据/构建路径，内部 `.dev` 构建目录名仍是 `Desktop Translate DEV.app`。

- 将要阅读的应用窗口置于前台，按已设置快捷键（release 初始为 **Control + Option + T**；DEV 初始为 **Control + Option + Shift + T**）：锁定活动窗口，默认处理完整 CG 窗口边界内的可见区域，通过插件或 ScreenCaptureKit/OCR 获取正文。
- 显式区域流程从菜单或 HUD 的区域入口选择，不要求额外的强制快捷键；它仍绑定同一锁定窗口，不扫描后台窗口。
- 再按同一快捷键或 **Esc** 撤除；翻译中也可取消，迟到结果不应重新展示。真实撤除与输入屏障仍未完成验收。
- 原位置遮罩是被动阅读层，不用于选中文字或滚动；需要选择/滚动时使用独立展开面板。真实点击/滚轮/按键隔离仍未验收，不能据旧 smoke 保证不穿透，关闭后再继续输入。
- 展示计数反映真实绘制结果：HUD 分开报告已绘制、空间不足（橙色标记）、与相邻文字冲突（不覆盖）、无可用原文位置四类，仅在未全部绘制时提示可展开全文；任何一类都不代表定位精度达标。若没有任何区域实际绘制，HUD 报失败而不是成功。
- 菜单栏“译” → “退出 Desktop Translate”（release 构建为“退出 CMux Translate”）停止工具。不自动配置登录启动。
- 更改快捷键：菜单栏“译” → **“设置快捷键…”**，按下想使用的组合，再保存。保存成功立即生效，重启后保留；取消不改设置。新快捷键被占用或保存失败时，原快捷键继续可用。
- 快捷键至少包含 Command、Control、Option 中的一种；Shift 可以附加。Esc 保留为关闭键。按物理按键位置记录，菜单与覆盖层显示当前组合。
- 选择翻译模式：菜单栏“译” → **“翻译模式、语言与模型…”**。本机模式为默认；pi 模式填写可执行文件，并从 pi 自身 `get_available_models` 的模型下拉中选择（显示 `provider/id`，可刷新，读取列表不发起模型请求）。输入方式为“OCR 文字 → pi”（默认）或“截图 → pi（图像输入）”，界面随选择显示对应的发送内容与风险说明；图像模式只列出 pi 声明支持图像输入的模型，所选模型不可用或非图像模型时拒绝保存。保存立即影响下一次翻译，正在运行的快照保持原模式；不会擅自切换或自动回退。
- 本机语言包未准备好时，在菜单栏“译” → **“翻译模式、语言与模型…”** 窗口的 **“语言包”** 一行查看当前语言对的状态，点 **“准备语言包…”** 在独立设置窗口完成下载，再重新触发翻译；状态随“从/译成”的选择即时更新，pi 模式不显示该行。下载不是已锁定目标捕获流程的一部分，也不会自动安装。
- 调试显示识别区域：菜单栏“译” → **“调试：显示识别区域”**（带勾选，默认关，配置 `debug.showRegions`，对新会话生效）。代码：**T** 已绘制（绿）、**E** 向右或向下扩展后绘制（青）、**O** 空间不足（橙）、**C** 文字冲突（红）、**N** 无位置（粉）、**P** 保护类型（蓝）、**K** 无需翻译（灰）、**R** 已规划无译文，或已绘制但译文仍含源语言字符（黄，后者子原因 `source-language-residue`，标签形如 `R8:source-language-residue`）、**X** 跨界省略（紫）、**D** 越界丢弃（棕）、**L** 低置信度忽略（靛）。仍只画框、代码和计数，不记录正文、像素或哈希，不改变安全判断，Esc 照常关闭。连续正文可按左缘/高度/行距合并为段落块，保留保护片段并允许译文在块内重排；12pt 仍溢出时只进入同一原图证明为空白且纳入基线的右/下条带。无法安全容纳仍保留 O 与展开全文。实窗捕获和实际翻译效果尚未测试。

- 源语言残留：目标语言为英文（`en`/`en-*`，大小写不敏感）时，已绘制的译文若仍有超过 30% 的字母是 CJK（汉字/假名/谚文），且该区域捕获到的原文本身含 CJK 字母，则该区域不再记为 T/E/S/V，而记为 **R** 并带子原因 `source-language-residue`（导出 JSON 的 `subreason` 同值）。这是纯诊断：绘制、遮罩、保护、新鲜度与 HUD 四类计数都不变（该区域仍计入已绘制），只是不再把“仍是源语言”的译文显示为成功；判定只看捕获原文与呈现译文，不读配置的源语言（`auto` 与固定源语言一致），英文原文永不触发。无论调试开关是否打开，只要存在残留就向 `app.log` 追加一行仅含计数的「译文仍含源语言字符：N 个区域」，不写原文或译文。

捕获设计仅针对当前用户选中的活动窗口，不读取整个历史记录。当前桌面路径尝试以定位 OCR 提供区域覆盖，但真实位置精度仍未验收，不保证原 TUI 的精确布局。历史 cmux 整窗阅读层不是逐字逐行替换，也不能作为定位成功证据。

配置保存于 `~/.config/cmux-translate/config.json`；设置了 `XDG_CONFIG_HOME` 时使用该目录。菜单设置是推荐入口，也可在工具退出后手动编辑：

```json
{
  "shortcut": {"keyCode":17,"modifiers":["control","option"]},
  "translation": {"mode":"local","piExecutable":"pi","model":"deepseek/deepseek-flash","inputMode":"ocr-text","sourceLanguage":"auto","targetLanguage":"zh-Hans"}
}
```

`keyCode` 是 macOS 物理按键编号，不是字符编码。上例为默认 ⌃⌥T；只支持字母、数字、F1–F12、方向键、Home/End/PageUp/PageDown 和 Space。修饰键为 `control`、`option`、`shift`、`command` 的不重复组合。`translation.inputMode` 只允许 `ocr-text`（默认；旧配置没有该键时按此解释）或 `image`，未知字段仍然报错。`sourceLanguage` 为 `auto`（自动检测）或受支持语言代码，`targetLanguage` 为受支持语言代码（不含 `auto`），两者不能相同；语言列表即 Apple 翻译支持的 20 种（en、zh-Hans、zh-Hant、ja、ko、fr、de、es、it、pt、ru、uk、ar、hi、id、nl、pl、th、tr、vi）。无配置文件时默认 `auto`→`zh-Hans`；已有配置若 `translation` 缺失或两个语言键都缺失，则迁移为 `en`→`zh-Hans`（保持原有行为）。本机模式的 `auto` 在 OCR 之后用 `NLLanguageRecognizer` 对待译文字做真实检测（把握不足则报错，不猜），再按实际语言对检查语言包，不自动安装；pi 模式在提示词里写明目标语言与源语言（auto 时让模型自行判断）。Vision 在固定源语言时使用对应识别语言，auto 时使用 Vision 自动语言检测。配置缺失使用默认；格式或按键无效会明确报错，而不是静默替换成默认快捷键。

## 翻译和隐私

**本机模式（默认）**使用 Apple Translation 框架。Apple 的公开 API 不提供具体模型名称、版本或模型选择接口。不需要 API Key。首次使用系统可能要求下载英中语言包；安装后文字翻译在本机进行。

**pi 模式（主动选择）**使用已安装的 pi 无头进程。模型列表来自 pi 自身的 `get_available_models`（只读取该命令，不发起模型请求），每项显示 `provider/id` 以及是否声明图像输入；已保存但 pi 当前不再提供的模型保持可见并标注，不会被静默替换。OCR 文字模式沿用每屏正文一次批量调用，保留原有代码/路径边界；截图模式每次发送一张所选区域截图，由模型同时给出译文和它自报的位置。pi 的认证和 provider 配置由用户自己的 pi 管理，辅助工具不保存密钥。

pi 模式会把待翻译内容发送到所选模型服务：OCR 文字模式只发送本机识别出的文字；截图模式发送所选区域的完整截图（包含其中可见的一切）。请不要翻译包含密钥或敏感信息的屏幕。可执行文件接受 PATH 中的名称或绝对路径，不接受 shell 命令/参数字符串；shell function/alias 不是可执行文件。PATH 发现会跳过 cmux 的 CLI shim，避免启动包装器；找不到时在设置中填写实际 pi 路径。

2026-10-15 用户选择“批准修正契约并继续”：捕获保护只以系统实际SCK结果为准。捕获前检查屏幕录制权限，缺失/撤销单独提示；SCShareableContent没有同windowID+PID、onScreen、layer0、相同frame的锁定目标，SCK错误或全黑结果明确报“该窗口无法捕获（可能受系统或应用保护）”，不能报无文字，也不回退其他窗口或显示器；不把每个错误都称为保护。legacy CG sharing=0 / NSWindow.sharingType=.none既不证明保护也不证明安全，只可作非权威诊断，不作用户警告或捕获决策。精确窗口、选区sourceRect、身份重验证和捕获前provider边界不变：默认只上传待翻译正文，只有用户显式选择截图模式时才上传所选区域截图。没有公开安全像素检测接口；OCR不能检测/排除安全字段、敏感控件或应用防截图意图，AX secure排除仅适用于AX读取。局部黑块仍可能让其余像素进入OCR；请仅选择可分享内容。

当前 pi 将 `--system-prompt ""` 视为“未指定”，因此工具额外加载自带的最小扩展，用 `before_agent_start` 强制覆盖为空；其余扩展、工具、MCP、技能、项目指令、提示模板全部关闭。翻译指令在 user prompt，不加载默认编程 system prompt。DeepSeek 的 OpenAI-completions 适配器会省略空的 system 消息，其他 provider 的空 system 编码由 pi 负责。没有工具调用或会话保存；辅助工具不做自动换模式或额外重试，pi 自身的 provider 重试/回退政策沿用用户配置。已配置的认证命令仍可能由 pi 执行。

辅助工具不持久保存原文或译文，日志不记录屏幕内容，位于 `~/.local/share/cmux-translate/app.log`。pi 模式使用 stdin 传递翻译请求，不将私有文字放入进程参数；关闭覆盖层时取消进程。系统和所选 provider 自身可能记录运行/请求信息，按其政策处理。

**截图模式（显式选择）**每次翻译捕获与 OCR 路径相同的精确锁定窗口/选区裁剪，只编码为内存 PNG 经 stdin 发送给所选模型：不写临时文件、不入日志或错误、随会话丢弃，也不放进进程参数。pi 子进程沿用与文字模式完全相同的隔离参数（空 system prompt、`--no-tools`、`--no-extensions` 且只加载自带最小扩展、`--no-mcp`、`--no-skills`、`--no-prompt-templates`、`--no-context-files`、`--no-approve`、`--offline`、私有临时工作目录与超时/进程组终止），图像只作为该次 prompt 的一条内容，不启用任何新工具或会话保存；HUD 与菜单把来源标为“模型图像理解（pi · 模型名；无 OCR）”，与 OCR 文字模式的来源区分。模型返回的译文位置是模型自报的几何（相对该裁剪的比例），会映射回窗口本地坐标，但不是原生或 OCR 验证过的位置，且未经 OCR 校准；因此对模型没有正确识别的图标、非文字内容或它没有报出的文字没有任何保证，也不会替它们生成译文或位置。模型返回的区域同样受既有严格校验：必须落在裁剪内，受保护片段必须在译文中逐字出现，否则整批拒绝显示，不做修复或部分显示。展示前仍以同一张已持有的原图基线核对目标/内容是否变化（不重新截图），变化即撤除；没有模型回退或模式回退。pi 声明支持图像输入不等于远端部署一定遵守该声明。

保守规则保留代码围栏、常见命令和提示符、diff、明显的源码行、内联反引号、路径及 URL。终端纯文本没有完整的语义信息，不能保证识别所有代码/命令；裸露的代码或陌生命令可能被视为正文。译文仅供阅读，不应当作可执行命令复制。保护的片段会打断上下文，短语翻译可能不准确。已有中文不单独翻译。

## 命令与诊断

```sh
cmux-translate build    # 编译，不启动
cmux-translate run      # 前台运行，启动错误显示在当前终端
cmux-translate smoke    # 使用独立公共fixture做本机端到端尝试，不读取私有终端屏幕
cmux-translate capture  # 仅报告前台目标元数据，不捕获屏幕文字、不输出正文
cmux-translate pi-smoke # 调用 pi 实际翻译公共示例（会发送到模型服务）
cmux-translate terminal-fixture-smoke # 消费 terminal_fixture_launcher.py handoff：对已证明归属的公共终端 fixture 窗口做一次真实会话（不激活/输入/启动/终止）
cmux-translate terminal-fixture-pi-smoke # 同上，显式使用 pi
cmux-translate shortcut-smoke # 用隔离的临时配置验证快捷键设置界面，不修改个人设置
cmux-translate help
```

`DESKTOP_TRANSLATE_DEV_TAG=desktop-plugins-ocr ./cmux-translate request-screen-recording`（app 参数 `--request-screen-recording`）只针对该 DEV bundle 经 LaunchServices 做一次屏幕录制预检，未授权时只调用一次系统请求，由用户处理系统对话框；不捕获、不创建 fixture/覆盖层，不读写应用配置，不调用语言包、AX、Apple Events、pi 或终端读取，也不轮询、自动打开系统设置或修改 TCC。JSON 的 `bundleIdentifier`、`preflight`、`requestInvoked`、`requestReturn`（未调用时为 null）与 `screenRecordingMayRequireUserAction` 如实报告即时结果；`commandCompleted: true` 和退出码 0 仅表示请求命令已完成，不代表权限已授予，`requestReturn: false` 也不表示命令未能显示系统请求。未通过预检时，即使请求返回 true，仍可能需要用户操作或重启；此命令不会再次预检确认。launcher 会在需要时构建当前 DEV app；不要把它当成捕获或权限验收。

`smoke` 使用独立公共 fixture 窗口经真实捕获/OCR/本机翻译路径做端到端尝试，不读取私有终端正文。其结果不等于任意应用、五终端、精度或输入隔离通过；当前观察与失败限制见下方证据段落。不要把历史 `smoke-overlay.png` 或旧公共文本冒烟结果当作当前展示证据。

`pi-smoke` 同样使用独立公共 fixture；会把捕获的公共正文发送至所选模型服务，不写用户模式选择。可用 `CMUX_TRANSLATE_PI_MODEL` 和 `CMUX_TRANSLATE_PI_EXECUTABLE` 指定目标；真实端到端仍未验收。

字形定位公共工作流：以同一 DEV tag 构建独立 `fixtures/build-glyph-fixture.sh` 后运行 `glyph-smoke`（只读已选后端）或 `glyph-pi-smoke`（显式 pi）；`CMUX_TRANSLATE_GLYPH_SCENE` 选择 `boundary|collision|icon|code|cjk|prose`，`DESKTOP_TRANSLATE_GLYPH_FIXTURE_APP` 指定独立 bundle。精确 owned 窗口两 tick 就绪、前台与重验证保持；sharing 仅非权威诊断，显式 opt-in 仅允许本次新建且身份核实的 fixture 至多一次激活。fixture 共用 `CTLine`/`drawToken`，含组合字符、有限 `caret-stop` 与 count-only ink 分区观察器。最终源码已构建并通过下述离屏检查；这不代表真实 OCR/mask ≤4pt、展示或输入隔离通过。协议和限制见 [fixture 说明](../fixtures/README.md)。

终端 fixture 公共工作流：`fixtures/terminal_fixture_launcher.py` 先以 `capabilities`/`plan` 只读确认哪些应用有隔离启动路径，`launch`（需 `DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=<token>`）才新建独立进程，`handoff --token T` 输出 schema `terminal-fixture-handoff/1`；对无隔离启动路径的 cmux/iTerm2/Terminal.app 走 `attach-plan` + `attach`（用户手工新建一次性进程；launcher 机器只校验 plan 时间早于 owner 启动、report 身份/新鲜度与 producer 为 owner 后代，tty 与窗口由消费者侧再校验）。随后 `cmux-translate terminal-fixture-smoke`（或 `terminal-fixture-pi-smoke`；这两个是 app 模式，不是 launcher 子命令）消费该 handoff，用 `DESKTOP_TRANSLATE_TERMINAL_TOKEN`/`HANDOFF`/`STATE_ROOT`/`FIXTURE_AUTHORIZED` 重新对活体事实取证：sysctl 启动时间、后代关系、控制 tty、bundle 与「唯一普通窗口」；不激活、不输入、不启动、不终止，失败不回退到其他窗口。它只做一次真实会话（插件→OCR→翻译→覆盖→快捷键撤除）并输出公共计数，明确 `geometry.measured=false`（终端文字没有字形几何 oracle）。这些入口不代表五终端、FocusLost 或精度已通过，细节与未验收限制见 [fixture 说明](../fixtures/README.md)。

保存原文边界的回归检查：

```sh
swiftc cmux-translate-app/Segments.swift cmux-translate-app/tests/SegmentsChecks.swift -o /tmp/cmux-segments-checks
/tmp/cmux-segments-checks
```

- **菜单栏没有“译”**：用 `cmux-translate run` 查看启动错误。重复实例会退出；快捷键已被占用也会明确报错。
- **读取失败**：确认目标窗口仍在前台、屏幕录制权限可用且未撤销，目标没有移动、关闭或被其他窗口遮挡；按实际失效/权限提示处理，不开放终端 Socket 或额外权限来绕过失败。
- **翻译失败**：本机模式先在“翻译模式、语言与模型…”窗口准备语言包；pi 模式确认 executable、模型和认证可用。不会用原文冒充翻译或静默换模式，响应不完整或协议错误明确失败。

## 桌面与五终端当前状态

通用桌面/OCR代码部分实现，未验收。DEV host 公共 fixture ScreenCaptureKit 探针曾成功（1520×1040，无保存、无 OCR）；disclaim spawner 子进程 SR/AX 预检为 false。此证据不证明完整权限隔离，TCC=true 的确切来源和因果未证实，不归因于 Doubao 或其他应用。

旧本机 smoke 的 ok 标志不是定位或输入隔离证明：未一一对应框的最小距离匹配曾报告最大 159.8pt，输入为合成事件。不能声称真实文字框≤4pt、真实键鼠不穿透或 FocusLost=0；修正后的本机/pi 真实端到端仍未验收。

2026-10-16 最终集中 gate（Main 报告）：当前 DEV app 与 glyph fixture 构建 exit 0（fixture 未启动）；GlyphMatcherChecks、DesktopChecks（实际 paint/source clipping、gap、overflow、collision 与已接入的 signatureChecks）通过；两个实际 PTY/CLI Python 测试通过。实际 `drawToken` 离屏检查覆盖六场景、1x/2x 共 68 次绘制，对比 alpha 与最终 `oracleConsistent`（向外像素对齐加一个设备像素的抗锯齿模型）；OCR/mask 4pt 阈值未改，不是通用物理精度证明。fresh attach 的真实进程/TTY 与合成 bundle 边界检查通过，不是 emulator UI。初始 enum/空白/oracle 1x/真实 ps 日期问题已修复，仅恢复失败步骤。没有新增 GUI、捕获、权限预检/请求或网络。caret、产品非文字安全证明、用户权限/本机语言包与真实终端/显示硬件门槛仍阻塞，原始 S2/S3/S4/S6/S7 及 001/002 未验收。该 gate 早于下述 2026-10-16 源码修改（pi 截图模式、模型下拉、绘制计数与渲染修正），不覆盖它们；这些修改只做过逐文件 `swiftc -parse`，仍未被构建、类型检查或运行。

历史公共工作流观察（早于上述最终 gate）：本机public smoke捕获前缺Apple en→zh包，pi捕获前无普通CG窗口；newglyph首次sharing=None未通过guard、未OCR。当时的共享readiness仍含sharing1/2连续两tick（该条件已被2026-10-15契约修正取代，见下文）；重建exit0后newglyph-pi仍捕获前notFrontmost。无模型请求、展示、≤4pt指标或输入证据。当时Glyph fixture构建与GlyphMatcher检查通过，但真实显示 oracle 渲染几何未验证（离屏 oracle 见上述最终 gate）。owned PTY14项仅证明五canned场景/合成CSI计数/22byte丢弃/清理，不是真实五终端；Ghostty/Kaku候选需safeguard token，其余三应用缺批准fixture。未改权限、未产生新私有截图文件。

五终端来源矩阵（均为 window-only partial/unsupported + OCR，OCR 亦未完成真实验收）：

| 终端 | 版本/精确 bundle ID | 当前只读能力与限制 | 结论 |
|---|---|---|---|
| cmux | 0.65.0 / `com.cmuxterm.app` | CLI metadata-only identify；不提供已证明的 CG 几何 | partial + OCR |
| iTerm2 | 3.7.0 / `com.googlecode.iterm2` | 显式数值 ID 的 NSAppleScript visible-contents probe；无已证明 split/inset 几何 | partial + OCR |
| Terminal.app | 2.15 / `com.apple.Terminal` | 选中 tab visible contents；不读 history；无已证明 content inset | partial + OCR |
| Ghostty | 1.3.1 / `com.mitchellh.ghostty` | 当前无文字接口 | unsupported + OCR |
| Kaku | 0.19.0 / `fun.tw93.kaku` | 全局 list 未映射 CG；screen row 0 不等于已证明 viewport | partial + OCR |

适配器注册或编译不等于完成五终端交付。没有已证明的 native positioned mapping、tab/pane 精确几何、原生 Unicode 列宽或字体缩放映射；上述文本探针也不是对应窗口内 pane 布局的证明。

插件严格按 bundle ID、PID、launch identity 和 window owner 匹配，保留 adapter 的 `none`、`unsupported`、`partial`、`error`、`needsPermission` 结果；error 或 needsPermission 不会隐式切换 OCR，用户必须显式选择一次 OCR。内建 CLI 通过 LaunchServices 找应用和 bundle 内固定路径；只读白名单排除 cmux send/new-split、Ghostty 输入/分裂命令、Kaku send-text/kill-pane/activate-pane，并清除 CMUX_*/WEZTERM_* 与 Kaku 目标变量，Kaku 使用 `--no-auto-start`。

## 剩余验收门槛

剩余门槛：真实文字框定位误差≤4pt；真实点击/滚轮/按键在遮罩及未遮罩区域的屏障隔离；原生全屏、负坐标、1x/2x 两种缩放、跨屏/Space；五应用的 tab/分屏/TUI/Unicode/字体缩放；逐应用 FocusLost 实际次数；本机/pi 真实端到端；权限拒绝/撤销及隔离、复杂布局/溢出/失效和完整 001/002 验收。production 稳定签名仍是发布门槛。fixture、数学 round-trip、插件注册或旧 smoke 均不可替代这些证据。
***

## 变更记录

- 2026-10-20（源码修改，未构建未运行）：新增源语言残留标记——英文目标下，已绘制但译文仍以 CJK 为主的区域由 T/E/S/V 改判为 R（子原因 `source-language-residue`），并新增仅含计数的日志行；计划/绘制/遮罩/保护/新鲜度与 HUD 计数不变。除逐文件 `swiftc -parse` 外未构建、未类型检查、未运行；本条不构成验收证据。

- 1.2.0：保留本机默认翻译，新增用户可选 pi 无头模式、可执行文件/模型设置、空 system prompt 隔离和每屏批量翻译；配置保存互相保留快捷键及模式。

- 1.1.0：菜单栏快捷键录制、立即生效、持久化设置；注册或保存失败保留原快捷键；所有快捷键提示随配置更新。

- 1.0.0：历史基线包括可见终端快照、本机英中翻译、⌃⌥T/Esc 可撤销阅读层、取消隔离和受保护文本边界；旧真实应用冒烟记录不证明当前桌面定位、输入隔离或五终端验收。

- 2026-10-15（契约修正，非验收）：用户批准以实际SCK目标缺失/错误/全黑fail-closed取代legacy sharing guard，产品与harness共享策略，不设fixture例外或OS版本猜测。上文历史sharing1/2 readiness/自然前台说明已被取代：保留精确owned PID/window/frame/layer/alpha/单普通窗口连续两tick及重验证，允许每次显式opt-in对新建且核实身份的公共fixture owned PID至多一次激活，绝不激活既有用户应用或注入输入。不新增权限，不改TCC/钥匙串/日常配置；S2/S3/S4/S6及001/002仍未验收，无新增运行证据。
- 2026-10-16（验收反馈，已实现）：展示后内容像素变化不再撤除译文覆盖（展示前新鲜度门槛不变；展示后监视器只看窗口身份/几何/Space/屏幕/遮挡/前台），Esc/快捷键退出。展示成功后 HUD 动画收起为可拖动小图标，点击展开；HUD 不激活也不成为 key，屏障保持 key，Esc 仍有效。
