# Desktop Translate：实施切片、验收与契约修正

[设计总览与当前契约摘要](design.md) · [文档索引](README.md)

本文保留原设计的章节编号与历史记录；当前契约以[总览摘要](design.md#当前契约摘要2026-10-21-文档整理)为准，历史要求不代表已通过验收。

## 8. 依赖安全切片

B1已定：产品显示名 Desktop Translate，release保留local.cmux.translate与现有配置身份；开发构建沿用同一显示名 Desktop Translate，隔离身份为bundle local.cmux.translate.dev.<tag>（内部 .dev 构建路径名不变）。tag由开发环境显式定义并匹配 `[A-Za-z0-9-]+`。S0 第一笔实现提交只做 launcher 隔离：非主 worktree 缺 tag 拒绝构建，dev 输出不得落 release 路径，并将 `.dev/` 加入 `.gitignore`；隔离落地前 worktree 内不运行任何构建。每worktree独立.dev/data、.dev/config、.dev/build，launcher设置XDG覆盖；dev 默认快捷键 Control+Option+Shift+T（⌃⌥⇧T），避免吞字符输入，已配置值优先且 release 用户设置不变，单实例键从Bundle.main动态取得。当前security find-identity结果0，用户明确接受ad-hoc开发及每次重建重新授权；不创建证书、不触碰钥匙串。签名identity为可选环境参数，证书默认禁用。稳定production签名仍是正式发布前提，不阻塞已获豁免的开发；不得将ad-hoc说成TCC稳定身份。复审报告已在 reviews/opus-plan-review.md，可开始创建隔离workspace/worktree，验证由负责人集中执行。


| 切片 | 依赖 | 内容与门槛 |
|---|---|---|
| S0 基座 | B1已定及用户临时签名豁免 | 第一笔实现提交仅 launcher 隔离（非主worktree缺合法tag fail closed、dev输出隔离、.dev忽略），落地前禁止构建；随后 ad-hoc开发/可选sign identity、独立dev bundle/XDG数据配置构建目录/⌃⌥⇧T、Bundle.main动态单实例、usage说明/共享disclaim spawner、权限矩阵。每次重建后重新请求/授权，以独立公共fixture窗口做一次SCK截图探针（仅截图、不做OCR、不保存）证明授权真实有效，拒绝停止；子进程预检false，日常app/配置指纹不变、dev与日常并存。不要求两次重建TCC保持；完整捕获/OCR管线门槛属于S2，稳定production签名为发布前提 |
| S1 纯逻辑 | S0 | 不依赖 AppKit 的模型、裁剪/变换、合成Vision分组、kind分段、路由和UUID状态机；负原点/非均匀缩放round-trip≤1pt、路由/UI单词fixture、保留四套既有检查 |
| S2 首个完整端到端 | S0,S1 | 无插件 fixture进程+TextEdit，默认完整CG bounds/区域流程→无AX锁定→crop/OCR→本机/pi→非激活overlay/屏障/HUD/展开→取消/撤除/展示前核对；捕获前LanguageAvailability及独立语言包准备/安装后重触发、其他PID layer0遮挡排除自身UI；主屏2x真实误差≤4pt，不穿透，迟到不复活；实际完整捕获/OCR管线在此验收 |
| S3 显示与隐私 | S2 | 1x/负坐标/跨屏/移除/独立Space开关、原生全屏终端Space及fullScreenAuxiliary面板、选区排除/secure AX、SCK目标缺失/错误/全黑各拒绝路径、周期授权；001对应真实证据；legacy sharing-none只记录实际结果 |
| S4 复杂布局/失效 | S2；与S3同负责人顺序进行 | 按钮/表格/代码/段落/溢出、光标签名误报控制；分组不越界，闪烁不误撤除 |
| P1–P5 只读探针 | S0；FocusLost测量需S2窗口模型 | 五应用接口/版本/viewport/回滚/几何/权限探针，可与S1–S4并行；安装事实不能升级能力 |
| S5 注册表/cmux切换 | S2,S4,P-cmux | 冻结API、注册表、cmux可靠native+OCR、删除旧CmuxCapture/frontmostBounds/整窗路径；capture改目标元数据探针，smoke改独立fixture定位，README迁移；真实插件+无插件验收 |
| S6 四适配器 | S5及各自探针 | Terminal/iTerm2/Ghostty/Kaku独立文件并行，注册表由集成负责人独占；各应用002全适用场景 |
| S7 集中验收 | 全部 | 001全部+002×5、支持表、用户文档/变更记录、清理旧契约；全部门槛才能完成 |

S2 是首个完整 E2E：OCR是所有partial回退关键路径，不依赖未证实终端API，独立fixture使坐标/权限/焦点证据可复现。

## 9. 最终门槛与证据

- 001：精确身份、默认/区域流程、真实插件与无插件、error/unsupported/needsPermission区分、1x/2x/跨屏/负坐标、按钮/表格/代码/软换行/UI单词、溢出、关闭/取消/迟到/目标变化、本机/pi与设置兼容。
- 001 pi 截图模式（2026-10-16 新增，未验证）：模型下拉来自 pi 自身 `get_available_models` 且只允许声明图像输入的模型；截图经内存 PNG/stdin 发送、不落盘/日志/错误/进程参数；模型自报位置不冒充原生或 OCR 几何，受保护片段与裁剪边界严格校验否则整批拒绝；展示前以同一张已持有原图基线核对；四类绘制计数与真实结果一致。当前只有逐文件 `swiftc -parse` 证据。
- 权限矩阵每个拒绝格真实UI验证，SR撤销/周期确认、AE逐目标拒绝、AX拒绝、不可靠revision不展示；无错窗。子进程disclaim符号缺失fail closed、已有SR/AX时子进程预检false。选区外像素不进入图片、secure AX读取排除、SCK目标未列出/错误/全黑各自明确报捕获不可用、provider捕获前可见，各自有公开fixture证据。`--sharing-none` 只记录实际拒绝/全黑/仍可捕获，不是保护窗口拒绝的验收证据。
- 002对五应用：单窗/多tab/支持时split、viewport非history、不读无关pane、两流程、DECSET-1004次数与真实限制、遮罩/未遮罩区点击滚动不穿透、窗口外切换撤除、Esc/快捷键有效；代码/命令/path/diff、Unicode/软换行/字体、动态输出/旧快照、pane关闭与两后端全部验证。
- N1–N7落实：截图尺寸/阴影/空间矩阵；只读白名单/环境清理/Kaku不自动启动；未知版本标记/调度器校验/固定路径；展示前重读及两次签名变化/光标；OCR双语言及终端禁纠错/半透明探针；新capture/smoke且同变更切除旧路径；非ASCII列映射和软换行并集。每项在对应切片记录实际结果。
- 公共单元fixture含坐标/裁剪/分组/overflow/路由/分段/配置/generation；保留 Segments/Shortcut/TranslationSettings/PiResponse。真实UI不可由mock替代。证据含OS/app版本、显示布局缩放、source/接口/步骤/实际误差、公共截图，不含私人内容。
- 当前只有两台2x设备事实，无1x/FocusLost/权限/新能力完整通过证据；本机/pi 真实端到端未验收，旧 smoke 的匹配误差及合成输入不能证明定位或输入隔离。无法取得1x真实设备或虚拟模式则验收缺证，不把模拟数学结果称硬件通过。任何缺应用/错窗/输入穿透/权限继承/失效贴旧坐标/迟到复活都阻塞交付。

## 10. 迁移与本次边界

根目录为用户的 Git 检出，源码为 `app/`，launcher 为 `desktop-translate`，无重复实现。产品名 Desktop Translate，release 保留 local.cmux.translate 与现有配置，无身份迁移；现有 release ad-hoc 可继续用于开发，但稳定 production 签名是正式发布前提。开发构建显示名同为 Desktop Translate，隔离身份为 local.cmux.translate.dev.<tag> 与独立 worktree .dev/data/config/build 和 XDG 覆盖、默认 ⌃⌥⇧T（release 用户设置不变）、动态 bundle 单实例。用户已明确接受临时签名每次重建重新授权，禁止新增证书或钥匙串更改，不要求用户再命名。配置新键与 parse/encode 同变更单向迁移，旧版拒绝新键应文档化。S0–S7 实现已组装，但本文件列出的真实 UI、权限、显示器和五终端证据仍是发布前提；不得将 fixture、一次旧 smoke 或已编译 build 当作完成证明。

### 2026-10-15 用户批准的契约修正

用户明确选择“批准修正契约并继续”：legacy sharing=0 不提供保护或安全保证，以系统实际 SCK 结果为准，产品与 harness 共用单一路径，无 fixture 特例、OS 版本猜测或替代捕获。上文历史 sharing guard/readiness 记录仅代表当时失败；sharing1/2 条件已被此决定取代，保留精确 owned PID/window、frame/layer/alpha、单普通窗口连续两 tick 与重验证。公开 fixture 激活仅可每次显式 opt-in，对本次新建且身份完全核实的 owned PID 至多一次；不得激活用户现有应用、注入输入或放宽目标边界。本次批准不授权 TCC/钥匙串/日常配置更改、新权限或其他应用操作。S2/S3/S4/S6 与原始 001/002 验收仍未通过；契约变更不是新增运行证据。

### 2026-10-16 源码修改（未构建未运行）

本轮源码修改（2026-10-16，未构建未运行）新增：pi 显式截图输入模式与 `translation.inputMode` 配置键（旧配置无该键时按 `ocr-text` 解释）、模型下拉改由 pi 自身 `get_available_models` 提供并标注图像能力、RPC 传输与严格图像区域响应、HUD 四类真实绘制计数，以及按实际可绘制字形几何修正的原位置渲染。除逐文件 `swiftc -parse` 外未构建、未类型检查、未运行；S0–S7 门槛与 §9 证据要求均未因此改变，真实 UI/模型请求/精度证据仍全部缺失。

语言对（2026-10-16）：`translation.sourceLanguage`（`auto` 或语言代码）与 `targetLanguage`；旧配置缺失两者时迁移为 `en`→`zh-Hans`，无配置文件默认 `auto`→`zh-Hans`。本机 auto 由 `NLLanguageRecognizer` 检测（≥0.6 才采用，否则明确失败）并按实际语言对检查语言包，源=目标时固定提示不翻译；非英文源（含 auto）使用 Unicode 版分段启发式，英文源保持原 ASCII 行为。pi 提示词（文字与截图）写明目标与源语言。

产品决定（2026-10-16 验收）：展示之前的新鲜度门槛（基线 + 两次采样）保持；译文一旦展示，内容像素变化（含光标/小型动态元素）不再撤除覆盖——展示后的 `TargetMonitor` 不带基线，只因窗口身份/移动/resize/关闭/Space/屏幕参数/遮挡/前台变化（几何而非内容）撤除，用户以 Esc/快捷键退出。展示成功后 HUD 约 1.5 秒动画收起为 40pt 可拖动小图标（提示屏幕正被覆盖），点击展开回完整面板。HUD 面板始终非 key、非激活；屏障仍是 key 窗口，故收起/拖动/点击后 Esc 仍由屏障关闭，键盘不泄漏到目标。
