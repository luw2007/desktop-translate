# 产品变更 001：通用桌面翻译、应用插件与定位 OCR

状态：方案经 Opus 复审 **PASS_WITH_NONBLOCKING**，允许开始开发；[报告](../../reviews/opus-plan-review.md)。已部分实现，**未验收**，不是已发布能力；现有探针不代表全部验收门槛通过。

## 用户目标

把当前 cmux 专用阅读层升级为通用桌面翻译工具，类似截图翻译：识别桌面中的目标软件，优先加载该软件插件；没有插件时使用 OCR，在原文字位置显示译文。再次按快捷键或 Esc 完整恢复显示。

对应请求条目 1、2。终端专用插件见产品变更 002。两项变更共用已有的本机/pi 可选翻译后端和可配置快捷键。

## 范围与行为

1. 目标为当前前台应用活动窗口；默认一键使用锁定窗口完整 CG bounds（window-local `(0,0,w,h)`，包含标题栏，无需 AX/content inset），终端只有已证明聚焦 pane 身份、几何与可靠 inset 时使用该 pane；无法唯一确定 CG bounds 停止，不猜 inset。菜单“区域翻译”拖选、Return确认、Esc取消；仅按(bundleID,windowID)会话记忆，resize/pane变化清除，不扫描后台窗口。
2. 用 bundle identifier、进程标识和窗口标识确定软件和捕获对象；匹配经过注册的插件，显示当前捕获来源。
3. 插件优先；none/unsupported走本机OCR，partial用可靠布局裁剪OCR。error或needsPermission明确显示原因，用户可另选一次OCR，不静默fallback；所有路径先验证唯一目标，身份歧义不能用OCR绕过。
4. OCR 参考 `/Applications/ScreenTextGrab.app` 的截图/区域捕获体验，不依赖它提供未证实的第三方 API，也不复制其代码。
5. 在识别区域的原位置覆盖译文。原应用、文档和终端缓冲区不变，恢复操作只撤除覆盖层。
6. 翻译引擎与捕获插件分离：同一份定位文本可以用本机或用户选择的 pi 模型翻译。
7. 没有必要授权、无法识别文字、失去目标窗口等情况要明确提示，禁止悄悄捕获其他窗口。
8. 本机模式捕获前查询 LanguageAvailability；支持但未安装时不捕获，菜单“准备本机语言包”打开独立可激活、无目标绑定的设置窗口。安装完成后用户重新触发，首次下载实际路径纳入验收。

## 共享捕获契约

拟定数据，实现在变更交付时确定语言/API细节：

- `CaptureTarget`：应用 bundle id、PID、窗口 id、窗口边界、显示器、捕获区域。
- `CaptureSnapshot`：唯一快照标识、时间、目标、捕获来源、坐标变换。
- `TextRegion`：稳定区域 id、原文、文字类型/置信度、原坐标矩形、阅读顺序、可选字体/底色估计。
- `LayoutRegion`：父子区域及边界，用于窗口、分屏、正文、代码块、表格。
- 插件声明可用性、应用匹配规则和捕获能力，输出同一契约，不拥有翻译后端和全局快捷键。

坐标必须明确区分屏幕像素、窗口点坐标、显示器缩放与 Vision 的归一化左下角坐标；禁止直接用 OCR bounding box 当作 AppKit frame。

## “精确替换”的可交付定义

精确指**定位和恢复**，不是保证中文与英文长度相同，也不是修改目标应用文本。

- 覆盖矩形与对应原文矩形对齐；不能整窗铺白后把全文重排冒充定位替换。
- 使用原区域布局分组译文，文字不得越界覆盖邻近按钮/文本；有最低可读字号，空间不足需提供用户可见的展开阅读方式，不能静默截断。
- 保护图标、非文字内容及不在选择区域内的桌面；复杂背景、OCR 低置信度需要明确标记，不保证还原底图。
- 选择、HUD、覆盖与展开用非激活NSPanel并保持fullScreenAuxiliary；全目标窗口透明事件屏障为必选，吞点击/滚轮/手势及非关闭键，Esc/快捷键可用。窗口外操作引起目标切换则撤除，不强行抢回焦点；终端FocusLost实际次数必须记录，不承诺未测为零，非0披露限制。当前不引入event tap；任何新增输入监控/AX权限的event tap路线须更新权限矩阵并经Opus复审。
- 原目标移动、尺寸变化、切换显示器/Space 或消失时，撤除过期覆盖层，不将旧译文贴到新位置；重新捕获由用户触发。
- 展示遮挡只统计其他PID、目标之上的layer 0窗口，排除自身屏障/HUD/overlay；通知/Dock等系统层不导致误撤除。

## 权限与隐私

目标锁定与窗口变化以无需AX的前台PID/CGWindowList唯一窗口及轮询为基线；AX仅已授权或插件所需的增强。OCR与截图失效检测需要屏幕录制；原生revision为可见文本重读哈希，不需要截图。Terminal/iTerm2原生路径、Ghostty脚本焦点路径按目标请求Automation，Info.plist有NSAppleEventsUsageDescription，进程内发送AE。各插件SR/AX/AE/应用设置、请求时机、拒绝needsPermission与显式另选OCR见DESIGN权限矩阵；拒绝、撤销、周期确认均说明用途并停止，不改权限。

截图与原文默认只在内存。OCR 在本机执行；选择 pi 模式时被翻译的正文发给用户所选 provider。覆盖层、错误和日志不输出私有原文。需测试拒绝授权、撤销授权及敏感区域排除。

敏感排除明确为：ScreenCaptureKit sourceRect只含选区，选区外像素不进入内存；AX跳过AXSecureTextField等安全角色；sharingState=none或全黑保护结果明确报禁止捕获而非无文字。pi provider在捕获前可见。所有pi/认证助手/终端CLI通过共享disclaim spawner放弃TCC责任，符号缺失fail closed；只加载内建插件。

## 验收标准

- [ ] 插件匹配使用正确应用/窗口标识，不依赖标题猜测；当前插件/来源可见。
- [ ] 一个插件目标与一个无插件目标分别真实运行，后者走 OCR；插件不支持和插件错误可区分。
- [ ] 实际截图 OCR 在至少两个缩放比例、跨显示器、非主屏负坐标下定位正确；提供测试样例标注的矩形误差证据。
- [ ] 多行段落、按钮、代码块、表格等区域正确分组；中文扩张不覆盖邻近控件，不静默截断。
- [ ] 快捷键/Esc关闭、翻译中取消、目标变化撤除、迟到结果隔离均在实际 UI 验证。
- [ ] 屏幕录制未授权/撤销后错误明确，无错窗捕获。
- [ ] 本机/pi 两种后端可选，默认和原快捷键设置不被迁移覆盖。
- [ ] 默认完整CG bounds一键及显式区域两流程、选区会话记忆及resize/pane失效真实验证；HUD显示source/provider，承载可见translationTask，展开完整译文；语言包未安装时无目标捕获，独立准备窗口安装后重触发有首次下载证据。
- [ ] UI单词按钮/菜单/表头/单元、含分号/管道/列表的文案可翻译；标识符仅含下划线、camelCase或数字字母混排的词，Cancel/Settings/OK必须翻译；软换行合并请求不跨控件，路径/URL/代码保护，不越界。
- [ ] 权限矩阵每个拒绝格、撤销/周期确认、原生revision无需SR且失效不能展示有真实UI证据；共享spawner子进程SR/AX预检false与缺符号fail closed有证据。
- [ ] “权限与隐私”敏感排除逐条验证：选区外无像素、secure AX不读取、保护窗口报错、捕获前provider可见，截图/私有文本不落盘或日志。
- [ ] 非激活UI及fullScreenAuxiliary在原生全屏终端Space真实验证；全窗口屏障在遮罩/未遮罩区域点击滚动不穿透，外部切换撤除；自身overlay与系统层不误撤除，其他PID layer0遮挡失效有证据。用户已接受临时ad-hoc开发：S0每次重建后重新授权，以独立公共fixture做一次SCK截图探针（无OCR、不保存），拒绝停止；S2验收完整捕获/OCR管线。不要求两次重建TCC保持；dev与日常app/配置隔离并可并存。
- B1已决定：产品名Desktop Translate、release保留local.cmux.translate与原配置；dev名Desktop Translate DEV、local.cmux.translate.dev.<tag>（tag匹配[A-Za-z0-9-]+）、每worktree .dev/data/config/build及XDG覆盖，默认⌃⌥⇧T（配置优先，release用户设置不变），Bundle.main动态单实例。S0第一笔实现提交仅launcher隔离，非主worktree缺合法tag拒绝构建并忽略.dev；隔离落地前禁止构建。当前可用签名身份0，用户选择临时签名，不创建证书/改钥匙串；稳定production签名是发布前提而非开发阻塞。可选sign identity，证书默认禁用，源码/launcher别名保留至正式产品迁移。

## 当前证据与限制

通用桌面捕获、插件路由、定位 OCR 与覆盖路径已部分实现；不再以旧 `Capture.swift` 的 cmux 纯文本路径描述全部现状。当前终端来源为 window-only partial/unsupported + OCR，原生文字探针没有已证明的 positioned mapping，OCR 本身也未完成真实验收。

已读取的 ScreenTextGrab 1.1.1 bundle 资源包含区域截图、OCR、代码/表格等捕获模式与授权描述；没有找到可直接依赖的外部文字坐标输出契约。这些事实仅支持参考交互，不证明它内部的具体定位算法。

DEV host 独立公共 fixture SCK 探针曾成功（1520×1040，无保存、无 OCR），disclaim 子进程 SR/AX=false 仅是该次预检事实。TCC=true 的确切来源及因果未证实，不归因于 Doubao 或其他应用，也不据此宣称完整权限隔离。旧 smoke 的 ok 标志不证明精度或键盘隔离：未一一对应框的最小距离匹配曾报告最大 159.8pt，输入为合成事件；不能声称真实误差≤4pt、真实键鼠不穿透或 FocusLost=0。

最新公共流程：本机捕获前缺Apple en→zh包，pi捕获前无普通CG窗口；newglyph首次sharing=None，guard未通过且无OCR。owned PID/window及sharing1/2连续两tick readiness加入后重建exit0，newglyph-pi仍捕获前notFrontmost。没有模型请求、成功展示、≤4pt或真实输入证据；Glyph fixture构建与GlyphMatcher检查通过但真实oracle渲染几何未验证。builder不activate，稳定身份/sharing guard不放宽。S2/S3/S4未验收；无权限变更或新私有截图文件。

剩余门槛包括真实文字框≤4pt、真实点击/滚轮/按键在遮罩与未遮罩区域的隔离、原生全屏、负坐标、1x/2x 与跨屏/Space、本机/pi 真实端到端、权限拒绝/撤销及隔离、复杂布局/溢出/失效。五应用 tab/分屏/TUI/Unicode/字体缩放与逐应用 FocusLost 实际次数见 002；完整 001/002 未验收，production 稳定签名仍是发布门槛。

最新实现：RegionSignature按原始SCK译文实测行rect计算raw像素FNV（最多4096），绑定crop/尺寸/格式/不可变rect set，忽略相关区域外/间隙/保护内容变化。签名和绘制共用精确OccupiedGeometry，碰撞不画正文或marker，由HUD展开；实际置信度/背景/透明/边界省略警告及skipped数经过固定清洗。

最终集中证据：最终源码DEV构建exit0、24.90s、无warning输出；最终DesktopChecks通过。实际源码内存/offscreen签名内部1px/几何变化、外部/间隙/保护像素忽略、pane/跨界/保护命令/软换行、精确选区/碰撞原文不涂绘等检查通过。静态签名复审未报告P0–P2。HUD/Expansion非展示，无实际key；session start/live SCK/present及屏幕/UI/权限未新增验证。

caret在相关行内仍触发fail-closed，误报排除开发未完成，不是仅缺物理验收；图标/非文字占用无安全证明，真实门槛未验收。

caret边界：SCK像素不能安全区分caret/字形，周期复现掩码或debounce放宽未批准、未实现。后续优先同时验证native visible-text revision与cursor/cell几何及attributes；AX selected-range bounds+value备用路线需新范围/隐私审查、AXSecure排除与用户授权，本轮不实现。最终精确源码编译exit0、30.4s，不证明真实验收。
