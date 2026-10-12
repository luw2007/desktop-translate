# Desktop Translate 实施方案

状态：待 Opus 审查；本文件不宣称未来能力已经实现。需求依据是 [001](cmux-translate-app/changes/001-desktop-plugin-ocr.md) 与 [002](cmux-translate-app/changes/002-terminal-layout-plugins.md)，两份记录的全部范围和验收条件保持有效。审查无阻塞后，负责人另建 cmux workspace 与 Git worktree 开始开发；迁移阶段不创建它们。

## 1. 当前基线与完整交付范围

现有 `Capture.swift` 的 `TerminalSnapshot` 只有 cmux text/workspace/surface/window；`CmuxCapture` 清除继承的 CMUX 目标变量，通过 identify --no-caller 和显式 read-screen 目标读取可见屏幕，并在读取后再次核对焦点。它没有文字几何。`frontmostBounds` 选择 PID 的首个合适窗口，不是可靠的活动窗口身份解析，不能直接复用于桌面定位。

`App.swift` 的 TranslationOperation 已按单次操作持有设置、取消 pi 进程并隔离迟到结果；现有 OverlayController 是整窗阅读器，不是定位替换。`Segments.swift` 保护代码/命令边界；`TranslationSettings.swift` 与 ShortcutStore 共享配置。保留这些后端、保护规则和设置存储惯例，但桌面捕获必须替换 cmux 专用入口，不能维护两套目标判定逻辑。

交付包括：任意前台应用活动窗口的区域选择、应用插件优先捕获、无插件/明确不支持时本机 OCR、原位置译文与完整撤除，以及 cmux、iTerm2、Ghostty、Terminal.app、Kaku 五个首批终端插件。不会把整窗重排称为定位成功，不承诺中文等长或底图完全重建，不改应用数据、不注入 Shell、不要求回显钩子、不扫描后台窗口、不实时翻译无限日志。

## 2. 共享模型与插件边界

在现有 Swift 源码目录加入共享捕获类型与内建注册表，首先使用编译进 app 的 Swift 插件；本轮不加载外部可执行文件、动态库或用户提供代码。注册表用已验证 bundle ID 精确匹配，不通过窗口标题猜测。未来外部插件若引入，须另行审查签名、显式授权、隔离、协议版本和输出校验；当前配置不得成为任意代码执行入口。

- `CaptureTarget`：bundleID、PID、CGWindowID、应用实例身份、窗口 Quartz 桌面点矩形、displayIDs、选择区域、可选 tab/pane 身份及捕获前 revision。
- `CaptureSnapshot`：UUID、捕获时间、target、source（native/plugin+OCR/OCR）、capabilities、坐标变换、布局树、文字区域、用于失效检测的 revision。图片只在 OCR/验证失效所需时短暂持有。
- `TextRegion`：稳定 snapshot 内 ID、原文、kind（prose/code/command/prompt/path/diff/log/table/TUI/unknown）、confidence、window-local 点矩形、readingOrder、parent layout ID、可选网格/字体/底色证据。unknown 保守保护并在 UI 提示，不伪造状态。
- `LayoutRegion`：ID、parentID、kind、矩形、可见/裁剪边界；所有文字必须属于选区且受父区域裁剪。
- `CaptureCapabilities`：visibleText、textGeometry、paneLayout、contentRevision、fontRevision，各项分 verified/partial/unsupported，并附接口版本/限制说明。
- `CapturePlugin`：固定 ID/协议版本、应用匹配、probe(target)、capture(target, selection)、validate(snapshot)。probe 返回能力及所需权限；capture 返回 snapshot 或明确 unsupported/error。禁止修改 tab/pane 焦点、输入事件或翻译设置。

统一调度负责目标解析、权限、取消、OCR 补齐、后端与显示。无插件或 unsupported 可以 OCR；partial 可用布局裁剪 OCR并显示“插件布局 + OCR”。插件执行失败必须呈现错误，不自动伪装无插件；用户可明确选择另一次 OCR 捕获。不能把无几何的原生全文与 OCR 区域按行号硬拼，只有有证据的匹配才合并，否则该区域以 OCR 为来源。

## 3. 目标身份、捕获一致性与撤除

快捷键触发时，先保存真正前台应用身份，再显示选择 UI（避免把自身覆盖层当目标）。活动窗口用 AX focusedWindow 与 CG 窗口信息核对 PID、窗口 ID/边界；匹配不唯一、窗口不可访问、无可靠身份时明确停止。需要 AX 的路径单独请求辅助功能授权，不以首个同 PID 窗口替代。窗口标题不能成为唯一键。窗口必须可见且不被不相关窗口覆盖；选区限制在可见目标内容，遮挡变化使捕获失效，不捕获混入的其他应用。

首次提供区域选择；选区交互支持取消，限制到已锁定窗口，不自动改变目标。捕获前后核对 PID/窗口/前台应用/选区/布局 revision；期间 tab、pane、大小或目标变化就丢弃并提示重新触发。ScreenCaptureKit 以已锁定 window ID 筛选，排除本 app；不能失败后改用全屏或另一窗口。

单次状态机：idle → selecting → capturing → translating → presented → dismissing → idle；任意阶段可取消。每次操作 UUID，所有异步结果在主线程提交前检查 UUID、取消状态和目标有效性。关闭取消 OCR/翻译/子进程并释放图片；迟到结果不重建 UI。

订阅应用激活、窗口移动/尺寸/关闭、显示器与 Space 变化；展示期间低频验证内容/layout/font revision。原生插件无法给 revision 时，以选区小型截图差异检测兜底，不持久保存、不上传图片；变化或无法检查就撤除。终端输出滚动、字体缩放、pane分裂/关闭也失效。不能持续旧坐标覆盖新状态。关闭仅移除覆盖层；目标仍存在且仍合理时恢复焦点，不强行激活已切换到其他应用的用户。后台运行不回滚。

## 4. 权限、截图与 OCR

macOS 15 基线采用 ScreenCaptureKit 捕获锁定窗口选区和 Vision 本机文字识别。屏幕录制预检失败时说明用途并由用户决定打开系统设置；授权未生效、拒绝、捕获期间撤销都返回明确失败。不得修改 TCC 或要求用户全局开放 cmux Socket API。纯原生捕获不额外要求屏幕录制，OCR及截图失效检测只在真正需要时请求；插件 AX 权限独立显示。

截图/原文/译文默认内存生命周期，不写临时图、不把内容放日志或错误详情。测试截图仅使用公共 fixture 并明确输出位置。OCR 本机执行；pi 只发送待翻译正文，继续 stdin、隔离扩展/工具与既有用户认证。选择 pi 时 UI 明示 provider、模式、捕获来源；不自动切模式或重试。保留配置路径与默认本机模式，不重置快捷键。

OCR 用 VNRecognizeTextRequest accurate 并保留候选置信度和 bounding box，按空间邻接、基线、间距及插件布局形成多行段落/按钮/代码/表格区域。不跨 pane、表格单元或按钮合并。低置信度与复杂底色标示警告并可展开看原文；无文字明确提示。代码与提示符区域保持原文，通用 OCR 对代码的语义不保证，不能用翻译造出可执行命令。

## 5. 坐标管线与定位证据

所有 overlay 排版使用 window-local 点坐标；图片 pixel 坐标只在截图边界使用。每份截图记录实际像素尺寸、对应 Quartz 桌面点 crop 和窗口原点，分别计算 sx=pixelWidth/cropWidth、sy=pixelHeight/cropHeight，不假设固定 Retina 2 倍。禁止从显示器名称猜缩放。跨屏窗口以实际捕获尺寸和 crop 变换为准。

对 Vision 左下角归一化框 (x,y,w,h)，映射到图片左上角像素框：(xW, (1-y-h)H, wW, hH)，再除以 sx/sy 并加 crop 原点，得到 Quartz 桌面点；减窗口 Quartz 原点得到 window-local 点。最终转 AppKit 全局点时，使用统一 Quartz→AppKit 桌面变换，参考主显示器桌面高度翻转 y，保留负 x/y，绝不逐显示器独立翻转。通过 corner/round-trip 测试约束该变换；字体和边距同样使用点而非像素。

不可直接将 Vision boundingBox 填 NSWindow frame。矩形裁剪到选区/父布局，记录变换 provenance。验收 public fixture 在至少 1x/2x、跨屏、非主屏负坐标测四角：坐标数学映射误差≤1 point；真实 OCR框对人工标注框的边缘误差≤4 points（识别边界误差单列，不隐藏在坐标误差中）。不满足则不宣称定位通过。

## 6. 定位覆盖与中文溢出

用目标窗口上方的只读覆盖容器，只有 TextRegion 的遮罩/译文块遮住对应原文；不能整窗白底重排。图标、非文字内容、区域外桌面不遮盖。背景估计只能用于本区域且标示复杂背景限制；不声称还原底图。父区域裁剪和相邻区域占用图阻止中文覆盖按钮、相邻文本或 pane。

排版优先保持分组/阅读顺序，以实际字体测量换行，字号不得小于 12pt。空间不足显示明确溢出标记，用户可点击展开独立可滚动阅读面板（含完整译文与受保护片段），不能静默截断、压成不可读小字或扩张到邻居。原位块与展开面板共享 region ID。代码/路径/命令不参与译文遮罩；原有 Segments 保护规则复用到每个区域，后端结果按区域/片段 ID 完整性校验。

覆盖状态键盘/鼠标不得穿透造成底层应用操作；区域外如需拦截可用透明事件屏障但不涂白。快捷键与 Esc 始终关闭。移动/resize/Space/目标失效先撤除所有窗和展开面板再提示；不拖动旧译文“跟随猜测”。

## 7. 五种终端：能力先证据，仍全部交付

| 插件 | 基线事实 | 开发探针与交付要求 |
|---|---|---|
| cmux | 现有 identify/read-screen 可见文本；没有文字坐标 | 核实 pane/surface/viewport 几何、网格与revision接口；沿用显式目标及清空启动目标环境；不加 --lines/scrollback |
| iTerm2 | 002记录本机安装 iTerm.app | 验证官方自动化/原生或 AX 的可见文本、分屏几何与权限，不能把全 session 内容当 viewport |
| Ghostty | 002记录本机安装 | 独立验证原生/AX能力；不能假设 cmux接口适用 |
| Terminal.app | 系统应用 com.apple.Terminal | 验证 tab/窗口身份、可见范围而非历史 contents，以及几何可靠性 |
| Kaku | 002记录本机安装 | 核对实际 bundle ID、版本、布局与文字接口，不从相似外观推断 |

各插件先在实际安装版本记录接口名称/版本、只读探针步骤、返回元数据、权限、支持范围和失败条件；仅公共样例可记录内容。完整 native 必须有文本+几何+viewport证据；布局可靠但文字不可靠标 partial 并用共享 OCR；连布局都不可得则插件明确 unsupported 并标 OCR。五个应用都须可真实触发、得到可读定位翻译/安全撤除与来源标签；OCR partial是诚实能力结果，不允许删掉某个应用或将 mock 当交付。原生几何映射必须覆盖宽字符、emoji、组合字符、软换行、字体缩放；无法可靠映射的区域转明确 OCR，不简单按字符数推列宽。

## 8. 切片与依赖

1. **共享契约/目标安全**：模型、注册表、窗口锁定、选择 UI、状态机、取消和权限说明；将 cmux旧捕获调用迁到共享路径。门槛：错窗/取消/捕获期间目标变化测试通过，保留现有设置兼容。
2. **截图/OCR/变换**（依赖1）：ScreenCaptureKit窗口捕获、Vision、分组、坐标fixture、permission错误。门槛：真实无插件应用定位和拒绝/撤销权限证据。
3. **定位覆盖/后端接入**（依赖1、2）：区域Segmentation、共享本机/pi、溢出展开、事件屏障、目标失效撤除。门槛：段落/按钮/代码/表格不越界，完整关闭和迟到隔离。
4. **五插件能力探针**（依赖1，五应用可独立研究）：形成每个应用能力记录并确定 native/partial/OCR组合，不写未经证实适配。
5. **五插件实现**（依赖2、3、各自4）：分别交付 cmux、iTerm2、Ghostty、Terminal.app、Kaku；注册表/共享模型由单一集成负责人维护，各适配器互不改共享API。门槛：每个应用002全部适用场景真实验证。
6. **集中交付验收**（依赖全部）：主负责人统一运行构建/测试/UI矩阵、更新支持表与用户文档，移除旧整窗定位路径和废弃契约，保存公共证据。未通过门槛不得标全部完成。

开发只在审查通过后的新 worktree开展。子切片不并发跑测试/构建；整合后主负责人集中验证，避免半成品共享状态影响证据。

## 9. 最终验收门槛与证据

- 001逐项：精确bundle/PID/window匹配与可见来源；一个插件和一个无插件目标真实运行；unsupported与error区分；双缩放/跨屏/负坐标误差报告；多行/按钮/代码/表格和中文溢出；快捷键/Esc/翻译取消/迟到/目标变化；屏幕权限拒绝与撤销；本机/pi与旧配置兼容。
- 002对**每个五应用**逐项矩阵：单窗、多tab、支持时split、仅可见viewport、不改焦点；正文翻译和代码/提示符/命令/路径/diff保护；宽字符/emoji/组合字符/软换行/Retina/负坐标；TUI/动态日志和旧快照；pane关闭/字体缩放/目标切换/取消；两个翻译模式及持久化不受影响。终端不提供某场景须记录事实，不能以未测代替不支持。
- 公共单元fixture覆盖坐标round-trip/裁剪、region分组、overflow、capability路由、配置保持与generation取消；现有 Segments/Shortcut/TranslationSettings/PiResponse检查继续保留。UI集成覆盖权限、事件不穿透、窗口identity竞争、移动/Space/显示器移除、输出变化与后台app焦点。仅单元或mock不足。
- 证据记录 app/OS版本、屏幕缩放/位置、捕获来源、探针接口、命令/步骤、实际结果、公共fixture截图及误差；不记录用户私有屏幕。支持表明确 verified native / partial+OCR / unsupported+OCR，不能将安装事实升级为验证事实。
- 审查阻塞项包括：目标身份仍不唯一、权限路径静默错窗、不可测坐标、无溢出策略、缺任何五应用交付/证据、迟到结果复活或内容变化继续贴旧坐标。发现任一项先修方案/实现再复审，不缩减范围。

## 10. 迁移与本次交付边界

实际根为 `~/ai/desktop-translate`；launcher解析PATH符号链接，源目录仍 `cmux-translate-app`。配置、bundle身份、安装数据目录暂不改名，无迁移脚本或第二份实现。本次只迁移源码/已有测试/001与002并准备此方案，没有执行构建、测试或smoke，没有启动未来桌面/OCR能力。
