# Opus 复审：DESIGN.md + 001/002

- **审查模型**：Claude Opus 5.5（`claude_sub2api/claude-opus-5-5`），agent `OpusPlanReview`。
- **审查范围**：只做架构复审。基线为 `4adc120`，工作区内已修改 `DESIGN.md`、001、002，另有未跟踪的 `DEVELOPMENT_TASK.md`、`reviews/`。没有修改文件，没有构建或测试。
- **审查前提**：B1 按用户批准的取舍审查，即“暂用临时 ad-hoc 签名开发”，不再讨论证书问题。
- **引用缩写**：`D` = `DESIGN.md`，`001`/`002` = `cmux-translate-app/changes/00x-*.md`，`L` = 根目录 `cmux-translate` launcher。

## 结论：**PASS_WITH_NONBLOCKING**，可以开始开发

原来的 7 个阻塞项都已落实到方案和验收中，没有缩减范围：五种终端都保留，partial/unsupported 加 OCR 是如实标注的能力结果；001 的“至少两种缩放比例”保留，并且如实说明目前缺少 1x 设备证据（D:116）。

还剩 10 个非阻塞项：
- **R4、R9 要在 S0 第一笔提交之前处理。**
- **R1、R2、R3、R5 要在 S2 编码之前写进方案。**
- 其余项在对应切片里处理即可。

## 原 7 项逐条核对

| 项 | 结果 | 落点 |
|---|---|---|
| B1 签名、身份、开发隔离 | 已解决（按用户批准的取舍） | D:93、D:97、D:120；001:64-65；002 范围边界。release 保留 `local.cmux.translate` 和原配置；dev 使用 `local.cmux.translate.dev.<tag>`，数据、配置、构建目录放在 `.dev/`，通过 XDG 覆盖隔离；dev 默认快捷键另设；单实例改为从 `Bundle.main` 动态取 bundle id；配置新增键为单向迁移，并写入文档（D:120）。S0 门槛改为“每次重建后重新授权，并真实捕获成功”，不再要求两次重建后授权仍然保持。稳定签名列为正式发布前提，不阻塞开发。剩余问题见 R4、R5。 |
| B2 权限矩阵 | 已解决 | D:36-47 是完整矩阵：列出 SR、AX、AE、应用内设置和拒绝后的状态；needsPermission 与 error、unsupported 分开（D:20-22）。目标锁定不依赖 AX，用 CGWindowList 选窗口（D:26），也不使用私有的 AX→window SPI。窗口变化以轮询为基线；原生 revision 定义为重读文本后的哈希，不需要 SR（D:32）。Info.plist 加 AE usage 说明，AE 在进程内发送；SR 的周期确认也已覆盖（D:49）。剩余问题见 R1。 |
| B3 子进程继承 TCC | 已解决 | D:51：pi、认证助手和终端 CLI 都通过共享的 disclaim spawner 启动，不再用 Process；符号缺失时拒绝启动（fail closed）。D:112 的门槛要求：子进程的 SR 预检和 AX 检查都为 false，并记录 AE 不会被继承。 |
| B4 焦点与输入 | 已解决 | D:67：所有面板都是非激活 NSPanel，不调用 `activate`；DECSET-1004 只要求实测并如实记录，不承诺 focus-out 为 0。D:69：透明事件屏障必须存在，覆盖整个目标窗口，`ignoresMouseEvents=false`。D:30：重新定义了“目标仍在前台”的判定。HUD 承载可见的 `.translationTask` 宿主（D:69）。剩余问题见 R2、R3、R10。 |
| B5 选区语义 | 已解决（用户已决定） | D:28、D:30、001:13；002“插件职责”的倒数第三条：默认一键翻译；只有聚焦 pane 的身份和几何得到证明时才用 pane；区域选择由菜单显式进入；选区只在会话内记忆，变化即失效；状态机中的 selecting 变为可选；默认流程和区域流程都要验收（D:111、001:61）。剩余问题见 R1。 |
| B6 分段策略 | 已解决 | D:73：按区域来源和 kind 分别处理；UI 类区域只要含 1 个 ASCII 单词就翻译，不因分号、管道符或列表符号整行跳过；终端和代码继续用 TranslationPlan，由 SegmentsChecks 守住回归；ID 使用 region/piece 命名空间。001:62 有对应验收。剩余问题见 R7。 |
| B7 敏感区域排除 | 已解决 | D:53、D:112、001:56、001:63：截图只含选区，选区外像素不进入内存；AX 跳过 AXSecureTextField 及其子树；受保护或全黑窗口明确报“禁止捕获”；pi provider 在捕获前可见；每条都有对应证据要求。 |

## 非阻塞项

**R1（S2 编码前修改方案）：“内容边界”与“无 AX 基线”矛盾。**
- **来源**：D:26（“无法判定普通窗口或 content 边界时停止”）、D:28（“普通应用用窗口内容区……无可靠 content 边界停止而非猜 inset”），与 D:38 的无 AX 基线矛盾。
- **问题**：没有 AX 时，CGWindowList 只能给出包含标题栏的窗口 frame。照字面执行，所有没有插件的应用在无 AX 时都会停止，S2 的“无 AX 锁定 → OCR”路径无法完成。
- **改法**：无插件目标的默认区域定义为“锁定窗口的完整 CG bounds”（window-local `(0,0,w,h)`），这在没有 AX 时也可靠。只有插件的 pane/网格映射才需要 content inset；只有 CG bounds 本身无法唯一确定时才停止。

**R2（S2 编码前修改方案）：本机模式首次下载语言包可能永远无法完成。**
- **来源**：D:30（系统 UI 激活本 app 时操作停止）、D:69（下载系统 UI 的焦点行为待实测）、App.swift:79、App.swift:159-163（下载对话框挂在 `.translationTask` 的宿主视图上）。
- **问题**：如果下载对话框激活了本 app，操作随即停止，HUD 被拆除，宿主视图消失，下载对话框也一起消失（[INFERENCE]）。默认的本机模式在首次使用时可能永远装不上语言包。
- **改法**：捕获前先查询 `LanguageAvailability`；如果状态是已支持但未安装，就不捕获，引导用户打开菜单里的“准备本机语言包”。这个窗口可以激活本 app，也不绑定任何目标；安装完成后由用户重新触发。验收时如实记录首次下载路径的证据。

**R3（S2）：遮挡检测要排除本 app 自己的窗口，并明确哪些窗口层算遮挡。**
- **来源**：D:26（“上层无关窗口遮挡/变化使目标无效”）、D:32（轮询包含遮挡）。
- **问题**：事件屏障、HUD 和 overlay 都在目标窗口之上。如果不排除本 app 的 PID，展示后的第一次轮询就会把覆盖层撤掉；通知横幅、Dock 等系统层窗口也会反复触发撤除。
- **改法**：遮挡判定只统计其他 PID 的 layer 0 窗口，系统层单独列出。ScreenCaptureKit 按窗口截图本身不受遮挡影响（[INFERENCE]），所以遮挡只关系到“展示是否仍然有效”。

**R4（S0 第一笔提交前处理）：launcher 需要拒绝误建 release 路径，并补 .gitignore。**
- **来源**：L:11-13 当前总是构建到 release 路径；D:93 只写了“tag 由开发环境显式定义”，没写缺少 tag 时怎么办；`.gitignore` 只有 `.DS_Store` 和 `build/`，`.dev/` 没有被忽略（已用 `git check-ignore` 实测）。
- **问题**：worktree 里只要有人在 S0 落地前执行 `./cmux-translate build`，就会覆盖日常使用的 app。按 mtime 判断，日常 launcher 之后不会重建，于是会悄悄运行开发版。
- **改法**：
  - S0 的第一笔提交只做 launcher 隔离。
  - 在非主 worktree 中缺少 tag 时拒绝构建。
  - tag 必须匹配 `[A-Za-z0-9-]+`，保证 bundle id 合法。
  - 把 `.dev/` 加进 `.gitignore`。
  - 隔离落地之前，worktree 里不运行任何构建。

**R5（S2 前）：S0 门槛依赖了 S2 才有的能力。**
- **来源**：D:97 的 S0 门槛要求“真实捕获成功”，但截图管线在 S2 才实现。
- **改法**：S0 只做 SR 预检/授权请求，加一次对 fixture 窗口的 SCK 截图探针（不做 OCR，不保存）；或者把这条门槛移到 S2。

**R6（S3）：原生全屏 Space 里的目标没有进入测试矩阵。**
- **来源**：D:100。
- **改法**：所有面板保持 `fullScreenAuxiliary`（与 App.swift:201 一致），并把全屏终端加入 S3 的测试矩阵。

**R7（S4）：需要定义 UI 分段里的“标识符”。**
- **来源**：D:73 写了“纯数字/标识符跳过”。
- **改法**：标识符明确为包含 `_`、camelCase 或数字字母混排的词，确保 Cancel、Settings、OK 这类单词会被翻译。001:62 的 fixture 会覆盖这一点。

**R8（偏好）：dev 默认快捷键会吞掉字符输入。**
- **来源**：D:93。
- **问题**：Option+Shift+D 注册为全局 Carbon 热键后，dev 运行期间会吞掉 “Î” 字符的输入。
- **建议**：可考虑改用 ⌃⌥⇧T。

**R9（S0 前）：开发任务引用的审查报告路径不存在。**
- **来源**：DEVELOPMENT_TASK.md:7 读取 `reviews/opus-plan-review.md`，但实际保存的是 `opus-plan-review-initial.md`。
- **改法**：把本复审保存到被引用的路径，或者修改引用；否则开发 session 的启动门槛会读不到文件。

**R10（P 探针/S6）：focus-out 实测不为 0 时的修正路线。**
- **来源**：D:67。
- **说明**：如果 DECSET-1004 实测有 focus-out，“修正”很可能需要 CGEventTap：目标保持 key，由本 app 吞掉按键。这会新增输入监控或 AX 权限，必须先加进权限矩阵，不能临时引入。

## 切片与第一个端到端切片
维持 D:95-107 的切片顺序：S0 → S1 → **S2（第一个完整端到端：无插件 OCR）** → S3/S4 → P1–P5 与 S1–S4 并行 → S5 → S6 → S7。所有切片都不改变最终范围。开发顺序为：先在 S0 第一笔提交处理 R4、R9；在开始写 S2 代码之前，把 R1、R2、R3、R5 写进 D。这几项都不需要再次请 Opus 复审，除非修改时改变了权限矩阵（例如 R10 引入 event tap），那时需要复审。

## 2026-10-15 追加：B7 历史结论的替代契约

以上原始 verdict 与 B7“已解决”表格保持历史原文，不代表当前保护保证。用户明确选择“批准修正契约并继续”，取代初审B7第3项及本复审对legacy sharing保护的认可。Apple NSWindow.SharingType.none 文档写明：“A legacy constant that macOS no longer uses.”，且“Don't use this value to hide or omit content from being captured. Instead, use FairPlay Streaming.”（https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none）。sharing=0既非保护也非安全依据，只能作非权威诊断，不能作用户警告或捕获条件，不猜OS版本。

以实际SCK结果为准：SR缺失/撤销单独报告；精确锁定windowID/PID、onScreen/layer0/相同frame目标未列出、SCK错误或全黑明确报无法捕获（可能受系统或应用保护），不报无文字或回退窗口/显示器，不把所有错误叫保护。窗口/选区sourceRect、重验证、捕获前provider边界不变。AX secure排除仅AX读取有效，OCR不能识别/排除安全控件、敏感像素、防截图意图；局部黑块剩余像素仍可能OCR。sharing-none fixture只记录实际拒绝/黑/仍捕获，不保证拒绝。产品/harness单一路径，无fixture豁免。激活只在显式opt-in下对本次新建且核实身份的公共fixture owned PID至多一次，不激活既有应用或注入输入；不改TCC/钥匙串/日常配置、不增权限。此追加不升级原始阶段：S2/S3/S4/S6与001/002仍未验收，无新增运行证据。