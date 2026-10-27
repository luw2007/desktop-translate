# 产品变更 001：证据与批准修正

[返回概览](001-desktop-plugin-ocr.md)

## 当前证据与限制

通用桌面捕获、插件路由、定位 OCR 与覆盖路径已部分实现；不再以旧 `Capture.swift` 的 cmux 纯文本路径描述全部现状。当前终端来源为 window-only partial/unsupported + OCR，原生文字探针没有已证明的 positioned mapping，OCR 本身也未完成真实验收。

已读取的 ScreenTextGrab 1.1.1 bundle 资源包含区域截图、OCR、代码/表格等捕获模式与授权描述；没有找到可直接依赖的外部文字坐标输出契约。这些事实仅支持参考交互，不证明它内部的具体定位算法。

DEV host 独立公共 fixture SCK 探针曾成功（1520×1040，无保存、无 OCR），disclaim 子进程 SR/AX=false 仅是该次预检事实。TCC=true 的确切来源及因果未证实，不归因于 Doubao 或其他应用，也不据此宣称完整权限隔离。旧 smoke 的 ok 标志不证明精度或键盘隔离：未一一对应框的最小距离匹配曾报告最大 159.8pt，输入为合成事件；不能声称真实误差≤4pt、真实键鼠不穿透或 FocusLost=0。

最新公共流程：本机捕获前缺Apple en→zh包，pi捕获前无普通CG窗口；newglyph首次sharing=None，guard未通过且无OCR。owned PID/window及当时含sharing1/2连续两tick的readiness加入后重建exit0，newglyph-pi仍捕获前notFrontmost（该sharing条件已被下方2026-10-15批准取代）。没有模型请求、成功展示、≤4pt或真实输入证据。

剩余门槛包括真实文字框≤4pt、真实点击/滚轮/按键在遮罩与未遮罩区域的隔离、原生全屏、负坐标、1x/2x 与跨屏/Space、本机/pi 真实端到端、权限拒绝/撤销及隔离、复杂布局/溢出/失效。五应用 tab/分屏/TUI/Unicode/字体缩放与逐应用 FocusLost 实际次数见 002；完整 001/002 未验收，production 稳定签名仍是发布门槛。

最新实现：RegionSignature按原始SCK译文实测行rect计算raw像素FNV（最多4096），绑定crop/尺寸/格式/不可变rect set，忽略相关区域外/间隙/保护内容变化。签名和绘制共用精确OccupiedGeometry，碰撞不画正文或marker，由HUD展开；实际置信度/背景/透明/边界省略警告及skipped数经过固定清洗。

最终集中证据：最终源码DEV构建exit0、24.90s、无warning输出；最终DesktopChecks通过。实际源码内存/offscreen签名内部1px/几何变化、外部/间隙/保护像素忽略、pane/跨界/保护命令/软换行、精确选区/碰撞原文不涂绘等检查通过。静态签名复审未报告P0–P2。HUD/Expansion非展示，无实际key；session start/live SCK/present及屏幕/UI/权限未新增验证。

caret在相关行内仍触发fail-closed，误报排除开发未完成，不是仅缺物理验收；图标/非文字占用无安全证明，真实门槛未验收。

caret边界：SCK像素不能安全区分caret/字形，周期复现掩码或debounce放宽未批准、未实现。后续优先同时验证native visible-text revision与cursor/cell几何及attributes；AX selected-range bounds+value备用路线需新范围/隐私审查、AXSecure排除与用户授权，本轮不实现。最终精确源码编译exit0、30.4s，不证明真实验收。

字形 oracle fixture（2026-10-16）：`fixtures/GlyphSceneFixtureApp.swift` 让 oracle 与真实绘制共用同一 `CTLine` 与同一 `drawToken`（抗锯齿开/字体平滑关移入共用路径），`cjk` 场景新增 `cjk.combining.1` 组合字符样本，`caret` 阶段改为四 tick 后 `caret-stop`（`caretVisible=false`、计时器失效、`runRevision` 不变，caret 位于最后一个可见 token 的 ink 矩形内），mutation 仅在 token 实际文本变化时递增 `runRevision`，事件分区改为字形 ink 的 covered/uncovered 矩形（`keyDown` 只记事件类型），resize 重新生成场景规格，发布要求真实 `window.screen` 与非零 display id。`GlyphSmoke`/`GlyphMetric` 只对实际 `paintRects` 评分、逐行精确一一关联、overflow/collision 与 OCR 未对齐均判失败、重复 token/缺失 ink/oracle 不一致 fail-closed。最终源码已构建：DEV app 与 fixture 构建 exit 0，GlyphMatcherChecks、DesktopChecks（含实际 paint/clip/gap/overflow/collision 与 signatureChecks）通过，实际 `drawToken` 离屏 oracle 六场景 1x/2x 共 68 次绘制通过（向外像素对齐加一个设备像素的抗锯齿模型）；`GlyphMatcher` 容差未放宽（OCR/mask 4pt），不是通用物理精度证明。产品相关行内 caret 仍 fail-closed，属开发未完成（非仅缺物理验收），产品图标/非文字安全证明仍缺；真实 oracle 渲染几何、≤4pt 指标、模型请求、成功展示与输入隔离证据均不存在。

### 2026-10-15 用户批准修正

用户选择“批准修正契约并继续”，批准以实际SCK结果取代legacy sharing guard，产品/harness共用策略，无OS猜测、fixture豁免或fallback。历史sharing1/2 readiness及“不放宽sharing guard”已被取代；精确owned身份/frame/layer/alpha/单普通窗口连续两tick和重验证仍保留。只有显式opt-in才允许对本次新建公共fixture的精确owned PID至多一次激活，不激活既有用户应用，不注入输入；不新增权限或改TCC/钥匙串/日常配置。此批准不等于S2/S3/S4或001/002验收，不新增运行证据。
