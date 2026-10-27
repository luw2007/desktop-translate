# Opus 初审：阻塞项 B1–B3

[返回历史入口](opus-plan-review-initial.md)。保留历史判定及其当时证据范围，不代表当前实现验收；行号引用对应原始快照。

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
