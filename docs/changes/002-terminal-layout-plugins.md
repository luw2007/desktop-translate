# 产品变更 002：常见终端布局与文本插件

状态：方案经 Opus 复审 **PASS_WITH_NONBLOCKING**，允许开始开发；[报告](../reviews/opus-plan-review.md)。已部分实现，**未验收**，不是已发布能力。依赖产品变更 001 的目标识别、插件加载与定位覆盖契约；五适配器注册或编译不等于五终端完整交付。

> 本文保留原始验收矩阵和历史证据。后续已批准的 9pt/半透明覆盖、窗口 z-order、展示后停止内容监视、所有非目标语言自然语言翻译等修正，见 [design.md 当前契约摘要](../design.md#当前契约摘要2026-10-21-文档整理)。早期同 frame 拒绝、ASCII-only、光标持续内容监视等文字仅是当时记录，不是现行行为；原始未通过门槛保持不变。

## 用户目标

为常见终端开发插件，识别窗口/分屏布局、可见文字内容及正文/代码区域，使终端翻译优先使用可靠的文字与几何数据，而非通用 OCR 猜测。

对应请求条目 3。不缩减成仅支持 cmux，也不把全屏纯文本输出称为布局插件。

## 文档导航

- [首批终端范围、插件职责与状态变化](002-terminal-layout-plugins-scope.md)
- [验收矩阵与范围边界](002-terminal-layout-plugins-acceptance.md)
- [当前证据与限制](002-terminal-layout-plugins-evidence.md)
- [2026-10-16 终端 fixture 设施](002-terminal-layout-plugins-fixtures.md)
- [2026-10-16 终端翻译输入与绘制结果](002-terminal-layout-plugins-implementation.md)

以上分册保留原始章节；历史条款与当前契约的关系以上方说明为准。共享捕获契约见 [产品变更 001](001-desktop-plugin-ocr.md)。
