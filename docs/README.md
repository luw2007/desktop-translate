# 文档索引

用户安装、设置、控制与隐私说明从[项目 README](../README.md)开始；源码构建、检查和贡献约束见[开发指南](../app/README.md)。

## 当前设计与验收边界

- [设计方案与当前契约摘要](design.md)：目标锁定、坐标、插件、权限、隐私、绘制与后续批准修正。后续摘要优先于早期冲突条款；不是已通过验收的声明。
- 设计正文按原编号分为[基线与隐私 §1–4](design-foundations.md)、[坐标与绘制 §5–6](design-rendering.md)、[终端证据 §7](design-terminal-evidence.md)、[交付与修正 §8–10](design-delivery.md)；设计入口保留当前契约摘要。
- [变更 001：通用桌面插件与定位 OCR](changes/001-desktop-plugin-ocr.md)：原始范围、未勾选验收项、分阶段证据。
- [变更 002：终端布局与文本插件](changes/002-terminal-layout-plugins.md)：五终端能力事实、限制与未完成矩阵。window-only partial/unsupported + OCR 不等于原生定位支持。
- [公共 fixtures 与受控手工流程](../fixtures/README.md)：构建与运行分开；涉及屏幕、网络、权限或真实终端的操作必须明确授权。

**验收状态不因文档整理改变。** S2/S3/S4/S6 及原始 001/002 仍未通过完整验收；历史 build/check/smoke 各有范围，不能推导当前全部测试通过或真实 UI 达标。项目采用 [MIT 许可证](../LICENSE)；稳定生产签名和完整真实验收仍是正式应用发行前提，不是公开开发中源码的同一门槛。

## 历史记录（不作为当前操作指令）

- [原 README 开发历史](development-history.md)：2026-10-21 归档，保留迁移、构建/检查证据与后续修正；历史命令请勿直接执行。
- [隔离开发任务](development-task.md)：当时的内部任务、约束和门槛，不是当前待办或新授权。
- [Opus 初审](reviews/opus-plan-review-initial.md)：原始 **BLOCKED** 结论与理由。
- [Opus 复审](reviews/opus-plan-review.md)：原始 **PASS_WITH_NONBLOCKING**，只批准开始开发，不是实现/发布验收。

审查中的 `D:行号`、代码行号和设备/版本事实均对应当时快照，不能直接套用到整理后的当前行号。保留 verdict，不追改历史为“已通过”；2026-10-15 对 legacy sharing 的替代决定保留在各文档追加段落。

## 目录整理记录（2026-10-21）

本次仅整理文档和目录：设计移至 `docs/design.md`，开发任务移至 `docs/development-task.md`，审查集中于 `docs/reviews/`，产品变更集中于 `docs/changes/`；原根 README 主体归档到 `docs/development-history.md`，根 README 改为用户入口，应用 README 改为开发指南。旧位置不保留重定向或副本。

launcher、Swift 源码、资源、测试及 fixture 源文件位置保持不变。当前 how-to 去除个人检出/安装位置假设；必要历史位置仅保留泛化占位符。不新增运行、捕获、网络或权限证据，不改变未完成验收与历史判定。

## 章节拆分记录（2026-10-22）

长篇设计、001/002 变更、初审、开发历史与 fixture 指南按完整主题拆分至同目录分册；原入口保留概览、当前契约/历史 verdict 与全部分册导航。原始验收清单、限制、批准修正和证据范围完整保留，旧行号仍只对应历史快照。各分册采用 `tiktoken` 的 `cl100k_base` 计数，单文件不超过 5000 tokens；此整理不新增产品运行或验收证据。

## 通用产品命名记录（2026-10-27）

launcher 改为 `desktop-translate`，源码目录改为 `app/`，可执行文件为 `desktop-translate`，release bundle 为 `Desktop Translate.app`，产品环境变量统一为 `DESKTOP_TRANSLATE_*`；不保留旧 launcher 别名。配置/数据的 `cmux-translate` 命名空间和 `local.cmux.translate[.dev.<tag>]` bundle 身份刻意保留，以维持设置与身份，不做用户文件或 TCC 迁移。实际 cmux 终端名称与接口不变。历史文档中的源码/命令按当前路径转写，仅使引用可用，不表示重新构建、测试或验收；旧审查引用的显示名与旧 app 路径仅是当时快照证据。

本轮验证：隔离 DEV 完整构建成功，新 launcher `help` 与可执行文件 `--help` 正常；`shortcut-smoke` 九项通过（包含用户配置未变），终端 fixture Python 检查两项通过；plist、bundle 可执行文件名与签名校验通过，152 个本地 Markdown 链接可解析。仅验证改名切换，不新增翻译、捕获或权限验收。现有 `~/dotfile/bin/cmux-translate` 指向另一个主检出，未修改该个人 PATH 链接；当前使用本检出的 `./desktop-translate`。

## 许可决定（2026-10-27）

维护者选择 MIT 许可证，根目录新增标准 `LICENSE`，版权署名为 `Copyright (c) 2026 luw2007`。同步更新用户指南、贡献约束和当前设计摘要中的许可状态；不改变功能、安全边界或未完成验收项。
