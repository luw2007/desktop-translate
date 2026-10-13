# Desktop Translate 桌面中文阅读层

独立 macOS 菜单栏辅助工具。历史基线读取 cmux 可见屏幕快照；通用桌面、定位 OCR 和终端插件路径已部分实现，**未验收**。使用用户选择的 Apple 本机或 pi 无头模式翻译英文正文，在只读覆盖窗口中显示；设计不修改终端缓冲区或向 Shell 发送输入，真实输入屏障仍需验收。

项目根目录现为 `~/ai/desktop-translate`，本页中的 `cmux-translate-app/...` 检查命令均从该根目录执行。PATH 中原有 launcher 为安装符号链接，配置和已安装 app 路径不变。DEV 每个 worktree 使用 `.dev/data`、`.dev/config`、`.dev/build` 与 XDG 覆盖；默认快捷键为 **⌃⌥⇧T**，已有 DEV 配置优先，release 设置不改。见[项目说明](../README.md)及[实施方案](../DESIGN.md)。

## 启动与操作

要求 Apple Silicon、macOS 15 或更新版本和 Xcode Command Line Tools，不要求安装 cmux。可从普通终端执行：

```sh
cmux-translate
```

第一次会编译并签名本机 app 到 `~/.local/share/cmux-translate/CMux Translate.app`。源码变更后下次启动自动重新编译。菜单栏出现“译”表示已运行。

- 将要阅读的应用窗口置于前台，按已设置快捷键（release 初始为 **Control + Option + T**；DEV 初始为 **Control + Option + Shift + T**）：锁定活动窗口，默认处理完整 CG 窗口边界内的可见区域，通过插件或 ScreenCaptureKit/OCR 获取正文。
- 显式区域流程从菜单或 HUD 的区域入口选择，不要求额外的强制快捷键；它仍绑定同一锁定窗口，不扫描后台窗口。
- 再按同一快捷键或 **Esc** 撤除；翻译中也可取消，迟到结果不应重新展示。真实撤除与输入屏障仍未完成验收。
- 原位置遮罩是被动阅读层，不用于选中文字或滚动；需要选择/滚动时使用独立展开面板。真实点击/滚轮/按键隔离仍未验收，不能据旧 smoke 保证不穿透，关闭后再继续输入。
- 菜单栏“译” → “退出 CMux Translate”停止工具。不自动配置登录启动。
- 更改快捷键：菜单栏“译” → **“设置快捷键…”**，按下想使用的组合，再保存。保存成功立即生效，重启后保留；取消不改设置。新快捷键被占用或保存失败时，原快捷键继续可用。
- 快捷键至少包含 Command、Control、Option 中的一种；Shift 可以附加。Esc 保留为关闭键。按物理按键位置记录，菜单与覆盖层显示当前组合。
- 选择翻译模式：菜单栏“译” → **“翻译模式与模型…”**。本机模式为默认；pi 模式可填写可执行文件和 `provider/model`。保存立即影响下一次翻译，正在运行的快照保持原模式；不会擅自切换或自动回退。
- 本机语言包未准备好时，先通过菜单的“准备本机语言包”在独立设置窗口完成下载，再重新触发翻译；下载不是已锁定目标捕获流程的一部分。

捕获设计仅针对当前用户选中的活动窗口，不读取整个历史记录。当前桌面路径尝试以定位 OCR 提供区域覆盖，但真实位置精度仍未验收，不保证原 TUI 的精确布局。历史 cmux 整窗阅读层不是逐字逐行替换，也不能作为定位成功证据。

配置保存于 `~/.config/cmux-translate/config.json`；设置了 `XDG_CONFIG_HOME` 时使用该目录。菜单设置是推荐入口，也可在工具退出后手动编辑：

```json
{
  "shortcut": {"keyCode":17,"modifiers":["control","option"]},
  "translation": {"mode":"local","piExecutable":"pi","model":"deepseek/deepseek-flash"}
}
```

`keyCode` 是 macOS 物理按键编号，不是字符编码。上例为默认 ⌃⌥T；只支持字母、数字、F1–F12、方向键、Home/End/PageUp/PageDown 和 Space。修饰键为 `control`、`option`、`shift`、`command` 的不重复组合。配置缺失使用默认；格式或按键无效会明确报错，而不是静默替换成默认快捷键。

## 翻译和隐私

**本机模式（默认）**使用 Apple Translation 框架。Apple 的公开 API 不提供具体模型名称、版本或模型选择接口。不需要 API Key。首次使用系统可能要求下载英中语言包；安装后文字翻译在本机进行。

**pi 模式（主动选择）**使用已安装的 pi 无头进程。初始模型建议为 `deepseek/deepseek-flash`，用户可填写任意已在 pi 中配置的 `provider/model`。每屏正文一次批量调用，保留原有代码/路径边界。pi 的认证和 provider 配置由用户自己的 pi 管理，辅助工具不保存密钥。

pi 模式会把英文正文发送到所选模型服务；请不要翻译包含密钥或敏感信息的屏幕。可执行文件接受 PATH 中的名称或绝对路径，不接受 shell 命令/参数字符串；shell function/alias 不是可执行文件。PATH 发现会跳过 cmux 的 CLI shim，避免启动包装器；找不到时在设置中填写实际 pi 路径。

当前 pi 将 `--system-prompt ""` 视为“未指定”，因此工具额外加载自带的最小扩展，用 `before_agent_start` 强制覆盖为空；其余扩展、工具、MCP、技能、项目指令、提示模板全部关闭。翻译指令在 user prompt，不加载默认编程 system prompt。DeepSeek 的 OpenAI-completions 适配器会省略空的 system 消息，其他 provider 的空 system 编码由 pi 负责。没有工具调用或会话保存；辅助工具不做自动换模式或额外重试，pi 自身的 provider 重试/回退政策沿用用户配置。已配置的认证命令仍可能由 pi 执行。

辅助工具不持久保存原文或译文，日志不记录屏幕内容，位于 `~/.local/share/cmux-translate/app.log`。pi 模式使用 stdin 传递翻译请求，不将私有文字放入进程参数；关闭覆盖层时取消进程。系统和所选 provider 自身可能记录运行/请求信息，按其政策处理。

保守规则保留代码围栏、常见命令和提示符、diff、明显的源码行、内联反引号、路径及 URL。终端纯文本没有完整的语义信息，不能保证识别所有代码/命令；裸露的代码或陌生命令可能被视为正文。译文仅供阅读，不应当作可执行命令复制。保护的片段会打断上下文，短语翻译可能不准确。已有中文不单独翻译。

## 命令与诊断

```sh
cmux-translate build    # 编译，不启动
cmux-translate run      # 前台运行，启动错误显示在当前终端
cmux-translate capture  # 仅报告前台目标元数据，不捕获屏幕文字、不输出正文
cmux-translate smoke    # 使用独立公共fixture做本机端到端尝试，不读取私有终端屏幕
cmux-translate pi-smoke # 调用 pi 实际翻译公共示例（会发送到模型服务）
cmux-translate shortcut-smoke # 用隔离的临时配置验证快捷键设置界面，不修改个人设置
cmux-translate help
```

`smoke` 使用独立公共 fixture 窗口经真实捕获/OCR/本机翻译路径做端到端尝试，不读取私有终端正文。其结果不等于任意应用、五终端、精度或输入隔离通过；当前观察与失败限制见下方证据段落。不要把历史 `smoke-overlay.png` 或旧公共文本冒烟结果当作当前展示证据。

`pi-smoke` 同样使用独立公共 fixture；会把捕获的公共正文发送至所选模型服务，不写用户模式选择。可用 `CMUX_TRANSLATE_PI_MODEL` 和 `CMUX_TRANSLATE_PI_EXECUTABLE` 指定目标；真实端到端仍未验收。

字形定位公共工作流使用独立 `fixtures/build-glyph-fixture.sh` 构建，再以同一DEV tag执行 `glyph-smoke`（只读加载已选后端设置，不写日常配置；文件缺失默认本机，配置无效失败、不回退）或 `glyph-pi-smoke`（显式覆盖为pi）。`CMUX_TRANSLATE_GLYPH_SCENE` 选择 `boundary|collision|icon|code|cjk|prose`，`DESKTOP_TRANSLATE_GLYPH_FIXTURE_APP` 指定独立bundle；必须自然前台并通过owned PID/window/sharing就绪条件，不注入激活或按键、不重试。oracle/安全终端生产者协议与未验收限制见[fixture说明](../fixtures/README.md)。这些入口不代表≤4pt或五终端已通过。

保存原文边界的回归检查：

```sh
swiftc cmux-translate-app/Segments.swift cmux-translate-app/tests/SegmentsChecks.swift -o /tmp/cmux-segments-checks
/tmp/cmux-segments-checks
```

- **菜单栏没有“译”**：用 `cmux-translate run` 查看启动错误。重复实例会退出；快捷键已被占用也会明确报错。
- **读取失败**：确认目标窗口仍在前台、屏幕录制权限可用且未撤销，目标没有移动、关闭或被其他窗口遮挡；按实际失效/权限提示处理，不开放终端 Socket 或额外权限来绕过失败。
- **翻译失败**：本机模式先通过菜单准备语言包；pi 模式确认 executable、模型和认证可用。不会用原文冒充翻译或静默换模式，响应不完整或协议错误明确失败。

## 桌面与五终端当前状态

通用桌面/OCR代码部分实现，未验收。DEV host 公共 fixture ScreenCaptureKit 探针曾成功（1520×1040，无保存、无 OCR）；disclaim spawner 子进程 SR/AX 预检为 false。此证据不证明完整权限隔离，TCC=true 的确切来源和因果未证实，不归因于 Doubao 或其他应用。

旧本机 smoke 的 ok 标志不是定位或输入隔离证明：未一一对应框的最小距离匹配曾报告最大 159.8pt，输入为合成事件。不能声称真实文字框≤4pt、真实键鼠不穿透或 FocusLost=0；修正后的本机/pi 真实端到端仍未验收。

最新公共工作流观察：本机public smoke捕获前缺Apple en→zh包，pi捕获前无普通CG窗口；newglyph首次sharing=None未通过guard、未OCR。共享readiness要求owned PID/window及sharing1/2连续两tick；重建exit0后newglyph-pi仍捕获前notFrontmost。无模型请求、展示、≤4pt指标或输入证据。Glyph fixture构建/GlyphMatcher检查通过，真实oracle渲染几何未运行验证。owned PTY14项仅证明五canned场景/合成CSI计数/22byte丢弃/清理，不是真实五终端；Ghostty/Kaku候选需safeguard token，其余三应用缺批准fixture。未改权限、未产生新私有截图文件。

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

- 1.2.0：保留本机默认翻译，新增用户可选 pi 无头模式、可执行文件/模型设置、空 system prompt 隔离和每屏批量翻译；配置保存互相保留快捷键及模式。

- 1.1.0：菜单栏快捷键录制、立即生效、持久化设置；注册或保存失败保留原快捷键；所有快捷键提示随配置更新。

- 1.0.0：历史基线包括可见终端快照、本机英中翻译、⌃⌥T/Esc 可撤销阅读层、取消隔离和受保护文本边界；旧真实应用冒烟记录不证明当前桌面定位、输入隔离或五终端验收。
