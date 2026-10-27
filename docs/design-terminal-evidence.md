# Desktop Translate：五终端证据与只读约束

[设计总览与当前契约摘要](design.md) · [文档索引](README.md)

本文保留原设计的章节编号与历史记录；当前契约以[总览摘要](design.md#当前契约摘要2026-10-21-文档整理)为准，历史要求不代表已通过验收。

## 7. 五终端证据与只读约束

以下是只读采集事实与当前实现状态，不是能力通过证据：

| 应用/精确 bundleID/版本 | 当前实现与诚实基线 |
|---|---|
| cmux `com.cmuxterm.app` 0.65.0 | CLI metadata-only identify；read-screen 为可见 viewport；未证明 CG 几何，partial + OCR |
| iTerm2 `com.googlecode.iterm2` 3.7.0 | 显式数值 ID、NSAppleScript visible-contents probe；无已证明 split/inset 几何，partial + OCR |
| Terminal.app `com.apple.Terminal` 2.15 | 选中 tab visible contents；不读 history；无已证明 content inset，partial + OCR |
| Ghostty `com.mitchellh.ghostty` 1.3.1 | 无文字接口，unsupported + OCR |
| Kaku `fun.tw93.kaku` 0.19.0 | 全局 list 未映射 CG；screen row 0 不等于 viewport，partial + OCR |

当前五终端均为 window-only partial/unsupported + OCR；OCR 本身仍未完成真实验收。没有已证明的 native positioned mapping、tab/pane 精确几何、原生 Unicode 列宽或字体缩放映射。插件注册/编译不等于五终端产品交付。插件按 bundle ID、PID、launch identity、window owner 匹配，保留 adapter 的 none/unsupported/partial/error/needsPermission，不对 error 或 needsPermission 隐式 OCR。CLI 通过 LaunchServices 找应用和 bundle 内固定路径，静态只读白名单排除写入/输入命令，清除 CMUX_*/WEZTERM_* 与 Kaku 目标变量，Kaku 使用 `--no-auto-start`。

已观察的开发证据：DEV host 公共 fixture ScreenCaptureKit 探针成功（1520×1040，无保存、无 OCR）；disclaim spawner 子进程报告 SR/AX=false。此证据不证明完整权限隔离或 TCC 授权来源，TCC=true 的确切责任归属和因果未证实，不归因于 Doubao 或其他应用。旧本机 smoke 的 ok 标志不是定位/输入隔离证明：未一一对应框的最小距离匹配曾报告最大 159.8pt，输入为合成事件；不能据此声称真实误差≤4pt、真实键鼠不穿透或 FocusLost=0。后续修正仍未完成真实验收。

历史公共验收门槛（早于下述 2026-10-16 最终集中 gate）：S2本机流程在捕获前缺Apple en→zh包，pi在捕获前缺普通CG窗口；newglyph首次sharing=None未通过guard且未OCR。owned PID/window、sharing1/2连续两tick readiness加入后重建exit0，newglyph-pi仍捕获前notFrontmost（该sharing条件已被下方2026-10-15批准取代）。没有模型请求或成功展示；S3真实显示/权限矩阵、S4≤4pt及输入隔离仍无证据。S6 owned PTY14项仅证明五canned场景、合成CSI计数、22byte丢弃与清理，不是真实应用；Ghostty/Kaku候选需safeguard token，其他三应用缺用户批准fixture。builder不activate，自然启动仍必须通过精确owned身份就绪与重验证；未改权限、未生成新私有截图。原任务未完成。
终端 fixture 设施（2026-10-16）：`fixtures/terminal_fixture_launcher.py` 新增 `handoff`/`attach-plan`/`attach`，`fixtures/terminal_public_producer.py` report schema 升到 2（`scenarioMode`/`revision`/`xpixel`/`ypixel`；`revision` 是每 tick 递增的计数器，不是内容变化证明，真实重绘看 `sceneChanges`/`renderCount`），`app/TerminalSmoke.swift` 为新消费者（`terminal-fixture-smoke`/`terminal-fixture-pi-smoke`）。能力边界：只有 Ghostty/Kaku 有文档化隔离启动路径且均为未观察的 candidate；cmux/iTerm2/Terminal.app 只能由用户手工新建一次性进程后 `attach`，launcher 的机器校验只有 plan 时间早于 owner 启动、report 身份/新鲜度、producer 为 owner 后代，tty 与窗口由消费者侧再校验，其余（「非日常实例」、无其他 tab/pane、`--window-id`）是操作者声明。消费者重新对活体事实取证，失败不回退，且明确 `geometry.measured=false`（终端无字形 oracle）。最终源码已构建，集中 gate 中两个实际 PTY/CLI 测试与真实进程/TTY（合成 bundle 边界）fresh attach 检查通过；这不构成真实 emulator UI、物理 FocusLost 或五应用证据，S6 仍未验收。

字形 oracle fixture（2026-10-16）：`fixtures/GlyphSceneFixtureApp.swift` 让 oracle 与真实绘制共用同一 `CTLine` 与同一 `drawToken`（抗锯齿开/字体平滑关在共用路径内设置），`cjk` 场景新增 `cjk.combining.1` 组合字符样本，`caret` 阶段改为四 tick 后 `caret-stop`（`caretVisible=false`、计时器失效、`runRevision` 不变，caret 落在最后一个可见 token 的 ink 矩形内），mutation 仅在 token 实际文本变化时递增 `runRevision`，事件分区改为字形 ink 的 covered/uncovered 矩形（`keyDown` 只记事件类型），resize 重新生成场景规格，发布要求真实 `window.screen` 与非零 display id（无 `NSScreen.main`/零边界/默认缩放回退）。`GlyphSmoke.swift`/`GlyphMetric.measure` 只对实际 `paintRects` 评分，逐行以产品 `OccupiedGeometry` 重新裁剪并精确一一关联（无排序 zip/最近匹配回退），overflow/collision 计入 `maskCounts` 并判失败（故意不绘制的 overflow/受保护文本可以是正确产品行为，但不提供几何精度证据），OCR 未对齐区域计入 `ocrMisalignedRegions` 并判失败，重复 token/缺失 ink/oracle 不一致 fail-closed，另校验目标 PID/window/frame/display id/缩放前后一致。最终源码已构建：DEV app 与 fixture 构建 exit 0，GlyphMatcherChecks、DesktopChecks（实际 paint/clip/gap/overflow/collision 与 signatureChecks）通过，实际 `drawToken` 离屏 oracle 六场景 1x/2x 共 68 次绘制通过（向外像素对齐加一个设备像素的抗锯齿模型）；`GlyphMatcher` 容差未放宽（OCR/mask 4pt），这不是通用物理精度证明。产品相关行内 caret 仍 fail-closed，属开发未完成（非仅缺物理验收），产品非文字安全证明仍缺；真实 oracle 渲染几何、≤4pt 指标、模型请求、成功展示与输入隔离证据均不存在。

剩余门槛：真实文字框定位误差≤4pt；真实点击/滚轮/按键在遮罩及未遮罩区域的屏障隔离；原生全屏、负坐标、1x/2x 两种缩放、跨屏/Space；五应用的 tab/分屏/TUI/Unicode/字体缩放；逐应用 FocusLost 实际次数；本机/pi 真实端到端；逐格权限拒绝/撤销及隔离、复杂布局/溢出/失效与完整 001/002 验收。现有两台设备均为 2x，不可将数学 round-trip 替代真实 1x 证据；production 稳定签名仍是发布门槛。

最新实现：`RegionSignature.swift` 按原始SCK图片的译文实测行矩形生成原始像素FNV哈希（最多4096），绑定crop/尺寸/格式/不可变矩形集合；区域外、间隙、受保护内容变化不影响该签名。verified插件布局在OCR分组前传入，父区域须完整包含，token须完整切分，跨界项否则省略并显示固定清洗警告；pane/font仅复制verified能力。保守软换行按实际词间距、无容差判断下一词不能容纳verified容器，不按字体样式合并控件标签。签名与绘制共用精确选区/窗口/父区域OccupiedGeometry，比较全部受保护/未译文字占用；碰撞连marker也不画，由HUD展开。警告反映实际置信度、背景、透明、边界省略及skipped数。

历史最终集中证据（命令仅按当前名称转写，未重新执行）：当时源码以 `DESKTOP_TRANSLATE_DEV_TAG=desktop-plugins-ocr ./desktop-translate build` 构建exit0，24.90s，无warning输出。最终DesktopChecks通过；实际源码内存/offscreen检查通过：签名忽略间隙/保护/区域外像素、检测内部1px与几何变化，pane/跨界/保护命令/软换行分组，精确选区与碰撞原文不涂绘、行间隙不填、只读展开保留完整溢出文字。静态ScopedSignatureReview未报告P0–P2，检查了索引/raw/fallback/不可变baseline fail-closed。HUD/Expansion只构建或非展示，未测实际key；session start/live SCK/present未覆盖，没有新增屏幕/UI/权限证据。

开发仍未完成：相关行内caret变化仍fail closed，光标误报没有排除，属于未完成开发而非仅缺物理验收；图标/非文字占用没有安全证明。真实S4/001/002门槛保持未验收。

caret决策边界：仅SCK像素无法可靠区分caret与真实字形变化；周期复现掩码或放宽debounce未获批准、未实现。下一步优先独立验证native可见文本revision与cursor/cell几何（含attributes），两者都可靠才可排除caret。否则AX focused selected-range bounds+value路线须另行范围/隐私审查、AXSecure排除与用户授权；本轮不新增该代码。最终精确源码编译再次exit0，30.4s；不新增运行验收证据。

以下原始探针事实仍适用：

 | 应用/精确 bundleID/版本 | 接口事实与诚实基线 |
 |---|---|
 | cmux `com.cmuxterm.app` 0.65.0 | read-screen 默认 viewport；tree --json/list-panes 无像素几何，sdef 无文本属性。禁 --lines/--scrollback；几何未证实前 partial+OCR |
