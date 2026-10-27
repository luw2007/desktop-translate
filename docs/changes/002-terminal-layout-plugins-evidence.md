# 产品变更 002：证据与限制

[返回概览](002-terminal-layout-plugins.md)

## 当前证据与限制

当前五终端均为 window-only partial/unsupported + OCR，OCR 本身未完成真实验收。cmux 0.65.0 为 metadata-only identify；iTerm2 3.7.0 有显式数值 ID 的只读 visible-contents probe；Terminal.app 2.15 有选中 tab visible contents、不读 history；Ghostty 1.3.1 无文字接口；Kaku 0.19.0 的全局 list 未映射 CG，screen row 0 不证明 viewport。没有已证明的 native positioned mapping、tab/pane 精确几何、原生 Unicode 列宽或字体缩放映射。

旧 smoke 的 ok 标志不证明定位或键盘隔离：未一一对应框的最小距离匹配曾报告最大 159.8pt，输入为合成事件。FocusLost 未测不能写为零。公共 host SCK 探针及子进程 SR/AX=false 不证明完整权限隔离；TCC=true 的确切来源及因果未证实，不归因于 Doubao 或其他应用。

当前合法 partial-empty 走共享 OCR，保留实际 OCR 能力、provenance 与 revision，不沿用未验证 native revision；不同window ID同frame仍重叠fail closed。最新待验证 `RegionSignature.swift` 按原始SCK译文实测行rect计算原始像素FNV哈希（最多4096），绑定crop/尺寸/格式/不可变rect set，替代整选区64×64分块签名。区域外/间隙/受保护内容变化不影响该签名，行内caret仍fail closed、未解决；不是运行验收证据。

最新公共流程无模型请求/展示/≤4pt/输入证明：本机缺Apple en→zh包，pi缺普通CG窗口；newglyph先sharing=None，readiness修正及build exit0后newglyph-pi仍捕获前notFrontmost。Glyph fixture构建/GlyphMatcher通过，真实oracle几何未验证。S6 owned PTY14项仅覆盖五canned场景、合成CSI计数、22byte丢弃与所有权清理，不是真实五应用；Ghostty/Kaku候选需safeguard token，其余三应用缺用户批准fixture。S2/S3/S4/S6仍阻塞，未改权限或产生新私有截图。

剩余门槛：五应用真实运行及 tab/分屏/TUI/Unicode/字体缩放、真实文字框≤4pt、真实点击/滚轮/按键隔离、逐应用 FocusLost 实际次数、原生全屏/负坐标/1x与2x/跨屏/Space、本机/pi 真实端到端、逐应用权限拒绝/撤销及隔离、复杂布局/溢出/失效，以及完整 001/002 验收。production 稳定签名仍是发布门槛。

最新实现：verified插件布局先于OCR分组，父区域完整包含/token完整切分，跨界省略并显示固定警告，pane/font仅复制verified能力。软换行按实际词间距、无容差判断下一词不能容纳verified容器，不按字体样式合并控件标签。OccupiedGeometry检查受保护/未译文字碰撞，不画任何正文或marker，由HUD展开；实际限制及skipped数经固定清洗显示。

最终集中证据：最终源码DEV构建exit0、24.90s、无warning输出；最终DesktopChecks通过。实际源码内存/offscreen检查通过pane/跨界/保护命令/换行、签名忽略外部/间隙/保护像素并检测内部1px/几何变化、精确选区与碰撞原文未涂绘。静态签名复审未报告P0–P2。HUD/Expansion未展示，无实际key，session start/live SCK/present和屏幕/UI/权限未新增验证。

相关行caret仍fail-closed，误报排除属于未完成开发，不只是物理验收缺证；图标/非文字占用无安全证明。五终端和S4真实门槛未验收。

caret边界：SCK像素不能安全区分caret/字形；周期掩码及debounce放宽未批准、未实现。优先验证native visible-text revision与cursor/cell几何（含attributes）两项；否则AX selected-range bounds+value须新范围/隐私审查、AXSecure排除和用户授权，本轮无新增代码。最终精确源码编译exit0、30.4s，仍不代表S2/S3/S4/S6验收。
