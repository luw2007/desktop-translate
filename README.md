# Desktop Translate

macOS 菜单栏桌面翻译工具：锁定前台窗口或用户选区，用 ScreenCaptureKit / Vision 识别文字，通过 Apple 本机翻译或用户配置的 pi 模型翻译，再以可撤销覆盖层显示；不修改目标应用、文档或终端缓冲区。

**当前是开发中的源码项目，不是已完成验收的发行版。** 通用桌面 OCR、覆盖层与五种终端适配器已部分实现；定位精度、真实键鼠隔离、权限拒绝/撤销、显示器矩阵及五终端端到端等门槛仍未完成。方案审查通过只表示允许开发，不代表产品验收通过。项目采用 [MIT 许可证](LICENSE)。

## 环境与启动

- Apple Silicon Mac，macOS 15 或更新版本；当前 launcher 仅构建 arm64。
- Git clone 的完整检出（launcher 读取 Git 元数据，不能直接用无 `.git` 的源码压缩包）。
- Xcode Command Line Tools：需提供 `xcrun swiftc` 和所用 macOS SDK。源码包含 macOS 26 的受可用性保护 API，旧 SDK 是否能编译未确认，不将 macOS 15 运行下限等同于任意旧工具链支持。
- 本机翻译需要所选语言对受 Apple Translation 支持并已安装语言包；首次下载可能需要网络。
- pi 为可选后端，需自行安装、配置认证和模型。项目不提供安装器、凭据或预配置服务。

在检出目录根执行，推荐先使用隔离开发模式：

```sh
export DESKTOP_TRANSLATE_DEV_TAG=local
./desktop-translate build
./desktop-translate start
```

tag 只允许字母、数字和 `-`。此模式将构建、数据与配置放到当前检出的 `.dev/` 内；显示名仍是 **Desktop Translate**，内部 app 路径为 `.dev/build/Desktop Translate DEV.app`，bundle ID 为 `local.cmux.translate.dev.local`。不同 tag 共用该检出的 `.dev/` 路径，并非多套独立数据目录。

普通主检出不设 tag 时，构建放到 `$XDG_DATA_HOME/cmux-translate/Desktop Translate.app`（默认 `~/.local/share/...`），配置使用 `$XDG_CONFIG_HOME/cmux-translate/config.json`（默认 `~/.config/...`）；linked worktree 缺 tag 会拒绝构建/启动，防止覆盖日常实例。不要用清除 tag 的方式绕过隔离。

命名已统一为 Desktop Translate：入口只有 `desktop-translate`，不提供旧 launcher 兼容别名；产品环境变量统一使用 `DESKTOP_TRANSLATE_*`。为保留既有设置与应用身份，配置和数据目录的 `cmux-translate` 命名空间以及 bundle ID `local.cmux.translate` / `local.cmux.translate.dev.<tag>` **刻意保持不变**；不迁移用户文件或修改 TCC。

启动后菜单栏出现“译”。`./desktop-translate run` 可在前台运行，`./desktop-translate help` 查看命令。launcher 默认 ad-hoc 签名，重建可能需要重新授权；目前没有稳定生产签名或已验收发行包，不提供绕过系统安全限制的操作。

## 操作与设置

1. 从“译 → 设置…”打开“设置”窗口，在翻译后端设置中选择源语言、目标语言和后端。无配置时默认 `auto` → `zh-Hans`；旧配置没有语言字段时保留 `en` → `zh-Hans`。已完全是目标语言的高置信度文字会跳过，不限于英文或长正文；UI 标签、标题和短片段也可进入翻译，代码/命令/路径/标识符等仍受保护。
2. 本机模式在设置中查看语言包状态，必要时点“准备语言包…”。安装完成后重新触发翻译；自动检测不能确定语言或语言对不可用时会明确停止，不悄悄换后端。
3. pi 模式设置可执行文件和模型。模型列表来自 pi 自身的 `get_available_models`，不是项目硬编码的支持清单；选择用户已配置且可用的模型。默认输入 `ocr-text` 只发送本机 OCR 后的待翻译正文；显式改为 `image` 才发送所选区域完整裁剪图像，且只允许声明支持图像输入的模型，不自动回退模式或模型。
4. 切到目标窗口，按快捷键翻译；默认快捷键为 Control+Option+T，隔离开发模式为 Control+Option+Shift+T，已保存配置优先。在“设置… → 通用”中查看当前快捷键并点“更改…”。默认取锁定窗口完整 bounds（可能含标题栏），只有已证明 pane 几何时才用聚焦 pane；“区域翻译…”可拖选，Return 确认，Esc 取消。
5. Esc 或再次按快捷键关闭覆盖层。成功展示后 HUD 约 1.5 秒收起为可拖动小图标，点击可展开；需要时展开阅读完整译文。覆盖期间目标窗口输入被屏障拦截，先关闭再操作原应用。

配置文件是严格 JSON；无效配置不会静默回退或被覆盖。优先通过设置界面保存。隔离模式配置为 `.dev/config/cmux-translate/config.json`；新增配置键为单向演进，旧版本可能拒绝新文件，不应混用。

## 隐私与诊断

- OCR 在本机运行，截图与会话文字默认在内存中，不自动导出。屏幕录制权限由用户通过 macOS 授予；目标不明确、截图失败或全黑时拒绝，不改捕获其他窗口/整屏。按实际路径使用的 Automation / AX 权限与限制见[设计文档](docs/design.md)。
- **pi 会将数据交给所选 provider。** `ocr-text` 发送待翻译正文；`image` 会发送选区内可见的一切，包括敏感信息、非文字和未预期内容。图像经内存 PNG/stdin 发送，不写截图临时文件、不放进进程参数。模型自报位置不等于经 OCR/原生接口验证的几何。pi 的认证、provider 和服务端数据处理由用户另行配置并负责确认。
- 选区是隐私边界，不是安全字段识别器。OCR 无法保证排除密码控件、敏感像素或应用的防截图意图；legacy `NSWindow.sharingType=.none` / sharing=0 不能证明保护或安全。不要在私有屏幕上试验或向模型发送不愿共享的内容。
- “设置… → 通用”内的“显示识别区域”复选框默认关闭；快捷键和调试独立保存，调试更改对下次翻译生效。图例可查看区域分类；**图例中的调试 JSON 导出是显式持久化操作，包含原文、译文、保护片段及诊断几何，不是匿名报告**。点击后先关闭覆盖层，再由保存对话框选址，取消也不会恢复覆盖。导出不包含截图、凭据、环境、可执行路径或整个配置；分享前仍必须逐项脱敏。
- 默认日志为构建/数据目录下的 `app.log`（DEV：`.dev/build/app.log`），会追加记录触发动作、前台应用 bundle ID/PID 和诊断/错误信息；不是匿名日志，分享前检查，可在退出应用后删除。仓库忽略 `.dev/`、构建目录、日志、本地 `.env*`（`.env.example` 除外）和默认命名的调试 JSON；忽略规则不覆盖已跟踪文件、任意改名导出或 Git 提交元数据，不能替代脱敏。发布时只使用 Git 源码快照，不打包整个工作目录。
- 调试码：T 已绘制；E 向确认空白处扩展；S 窄体/缩小至最低 9pt；V 半透明覆盖（会遮住邻近内容）；O 空间不足；C 冲突；N 无原文位置；P 保护；K 无需翻译；R 已规划无译文或源语言残留；X 跨界；D 越界；L 低置信度。分类和计数不证明定位准确或覆盖完整。

## 已知限制

- 五终端（cmux、iTerm2、Ghostty、Terminal.app、Kaku）目前均是 window-only partial/unsupported + OCR；原生文字探针不等于已有原生定位集成，不保证 tab/pane/Unicode 列宽映射。见[终端变更与未完成矩阵](docs/changes/002-terminal-layout-plugins.md)。
- 同 app 多窗口按 CGWindowList 前到后顺序取最上层普通窗口；透明叠窗或缺失顺序证据仍拒绝，不凭标题猜窗口。
- 译文较长时可能向确认空白处扩展、使用窄体/9pt，最后采用约 85% 不透明的覆盖兜底；此兜底**可能盖住邻近未译/受保护内容**，不保证还原复杂背景。仍放不下可展开全文。
- 展示前仍检查新鲜度；**展示后不再因内容变化自动撤除**，底层滚动或动态输出可能使译文过期。窗口身份/几何/Space/屏幕/遮挡/前台变化仍会失效；需要新内容时关闭后重触发。
- 非激活面板不意味着终端 FocusLost 为零；真实键鼠与逐应用焦点行为仍需实测披露。未完成验收项不会因本次文档整理而通过，本次也没有重跑测试。

## 项目目录与文档

```text
desktop-translate              构建与启动入口
app/                       Swift 源码、资源、tests/ 与开发指南
fixtures/                  公共样例、构建器和安全边界说明
docs/                      设计、变更、审查与开发历史
```

- [文档索引](docs/README.md)：设计、原始验收清单和历史证据
- [开发与检查指南](app/README.md)：架构、命令、贡献约束
- [公共 fixtures](fixtures/README.md)：仅用于公开样例的受控手工流程
- [开发历史归档](docs/development-history.md)：原 README 开发记录，不是当前操作指南
