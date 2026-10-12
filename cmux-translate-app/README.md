# cmux 终端中文阅读层

独立 macOS 菜单栏辅助工具。当前稳定基线读取 cmux 可见屏幕快照；通用桌面、定位 OCR 和终端插件路径已组装，仍需真实 UI 验收。使用用户选择的 Apple 本机或 pi 无头模式翻译英文正文，在不透明、只读覆盖窗口中显示；不会修改终端缓冲区或向 Shell 发送输入。

项目根目录现为 `~/ai/desktop-translate`，本页中的 `cmux-translate-app/...` 检查命令均从该根目录执行。PATH 中原有 launcher 为安装符号链接，配置和已安装 app 路径不变。DEV 每个 worktree 使用 `.dev/data`、`.dev/config`、`.dev/build` 与 XDG 覆盖；默认快捷键为 **⌃⌥⇧T**，已有 DEV 配置优先，release 设置不改。见[项目说明](../README.md)及[实施方案](../DESIGN.md)。

## 启动与操作

要求 Apple Silicon、macOS 15 或更新版本、Xcode Command Line Tools，以及 `/Applications/cmux.app`。在 cmux 终端执行：

```sh
cmux-translate
```

第一次会编译并签名本机 app 到 `~/.local/share/cmux-translate/CMux Translate.app`。源码变更后下次启动自动重新编译。菜单栏出现“译”表示已运行。

- 在 cmux 终端中按已设置的快捷键（release 初始为 **Control + Option + T**；DEV 初始为 **Control + Option + Shift + T**）：读取当时可见内容并显示中文覆盖层。
- 再按同一快捷键或 **Esc**：关闭覆盖层，返回原终端。
- 翻译或语言包下载期间也可关闭。迟到的翻译结果不会重新打开窗口。
- 覆盖层支持鼠标滚动、选中文字；键盘不会穿透到终端。关闭后才能继续输入。
- 菜单栏“译” → “退出 CMux Translate”停止工具。不自动配置登录启动。
- 更改快捷键：菜单栏“译” → **“设置快捷键…”**，按下想使用的组合，再保存。保存成功立即生效，重启后保留；取消不改设置。新快捷键被占用或保存失败时，原快捷键继续可用。
- 快捷键至少包含 Command、Control、Option 中的一种；Shift 可以附加。Esc 保留为关闭键。按物理按键位置记录，菜单与覆盖层显示当前组合。
- 选择翻译模式：菜单栏“译” → **“翻译模式与模型…”**。本机模式为默认；pi 模式可填写可执行文件和 `provider/model`。保存立即影响下一次翻译，正在运行的快照保持原模式；不会擅自切换或自动回退。

捕获的是当前用户选中的终端，而不是启动工具的终端。仅翻译可见屏幕，不读取整个历史记录。终端后台输出继续运行；再次开启才获取新快照。覆盖窗口覆盖当前 cmux 窗口，不是逐字逐行替换，不保留原 TUI 的精确布局。

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
cmux-translate capture  # 输出当前快照的字符数、行数和目标引用，不输出内容
cmux-translate smoke    # 真实本机翻译公共示例，截图并验证关闭路径
cmux-translate pi-smoke # 调用 pi 实际翻译公共示例（会发送到模型服务）
cmux-translate shortcut-smoke # 用隔离的临时配置验证快捷键设置界面，不修改个人设置
cmux-translate help
```

`smoke` 同时读取实际终端快照（仅报告计数），但翻译和截图使用固定的公共示例，不保存私有终端内容。截图在 `~/.local/share/cmux-translate/smoke-overlay.png`。语言包首次下载可能等待用户操作，最长等待 300 秒。它不验证任意终端文本的翻译质量。

`pi-smoke` 同样只翻译固定公共示例，默认使用 `deepseek/deepseek-flash`，不写用户模式选择；可用 `CMUX_TRANSLATE_PI_MODEL` 和 `CMUX_TRANSLATE_PI_EXECUTABLE` 环境变量指定验证目标。

保存原文边界的回归检查：

```sh
swiftc cmux-translate-app/Segments.swift cmux-translate-app/tests/SegmentsChecks.swift -o /tmp/cmux-segments-checks
/tmp/cmux-segments-checks
```

- **菜单栏没有“译”**：用 `cmux-translate run` 查看启动错误。重复实例会退出；快捷键已被占用也会明确报错。
- **读取失败**：确认 cmux 在运行、选中的是终端而非浏览器，且设置中的 Socket API 未关闭。限制为 cmux 子进程的模式下，应从 cmux 终端启动，不要改成全局开放来绕过限制。
- **翻译失败**：本机模式先确认语言包；pi 模式先确认 executable、模型和认证可用。不会用原文冒充翻译，也不会静默换模式。pi 响应不完整或协议错误会明确失败。

## 桌面与五终端当前状态

通用桌面/OCR代码已组装，但以下证据不等于完整 UI 验收：DEV host ScreenCaptureKit 探针记录 1520×1040，无保存、无 OCR；disclaim spawner 的子进程 SR/AX 预检为 false。一次本机 smoke 验证 9 个区域、区域裁剪、快捷键/Esc 撤除和无输入穿透，但发生在词级切分修复前，160pt 坐标误差修复后尚未对前台目标复测。`pi-smoke` 因前台窗口被占用而阻塞。

五终端支持矩阵（当前均为 window-only partial/unsupported + OCR；没有 native positioned mapping 已证明）：

| 终端 | 版本/精确 bundle ID | 当前只读能力与限制 | 结论 |
|---|---|---|---|
| cmux | 0.65.0 / `com.cmuxterm.app` | CLI metadata-only identify；不提供已证明的 CG 几何 | partial + OCR |
| iTerm2 | 3.7.0 / `com.googlecode.iterm2` | 显式数值 ID 的 NSAppleScript visible-contents probe；无已证明 split/inset 几何 | partial + OCR |
| Terminal.app | 2.15 / `com.apple.Terminal` | 选中 tab visible contents；不读 history；无已证明 content inset | partial + OCR |
| Ghostty | 1.3.1 / `com.mitchellh.ghostty` | 当前无文字接口 | unsupported + OCR |
| Kaku | 0.19.0 / `fun.tw93.kaku` | 全局 list 未映射 CG；screen row 0 不等于已证明 viewport | partial + OCR |

插件严格按 bundle ID、PID、launch identity 和 window owner 匹配，保留 adapter 的 `none`、`unsupported`、`partial`、`error`、`needsPermission` 结果；error 或 needsPermission 不会隐式切换 OCR，用户必须显式选择一次 OCR。内建 CLI 通过 LaunchServices 找应用和 bundle 内固定路径；只读白名单排除 cmux send/new-split、Ghostty 输入/分裂命令、Kaku send-text/kill-pane/activate-pane，并清除 CMUX_*/WEZTERM_* 与 Kaku 目标变量，Kaku 使用 `--no-auto-start`。

## 剩余验收门槛

仍需坐标精度修复后的前台复测、pi-smoke、S3 显示器/Space/隐私权限矩阵、S4 复杂布局与溢出、S6 五终端真实运行、FocusLost 次数、production 签名及完整真实 UI 验收。不得将 fixture、数学 round-trip 或一次旧 smoke 运行称为这些门槛的通过证据。
***

## 变更记录

- 1.2.0：保留本机默认翻译，新增用户可选 pi 无头模式、可执行文件/模型设置、空 system prompt 隔离和每屏批量翻译；配置保存互相保留快捷键及模式。

- 1.1.0：菜单栏快捷键录制、立即生效、持久化设置；注册或保存失败保留原快捷键；所有快捷键提示随配置更新。

- 1.0.0：可见终端快照、本机英中翻译、⌃⌥T/Esc 可撤销阅读层、取消隔离、受保护文本边界和真实应用冒烟验证。
