> **历史归档（2026-10-21 整理）**：下文保存原根 README 的开发记录与当时证据，不是当前安装或操作指南，请勿直接执行其中历史命令。当前入口见[项目说明](../README.md)，目录变更见[文档索引](README.md)。历史的通过/阻塞结论仅对当时范围有效；路径中的个人位置已泛化。

# Desktop Translate

独立 macOS 桌面翻译项目。当前交付包含 cmux 可见屏幕阅读层，以及已组装但仍需真实 UI 验收的通用桌面/定位 OCR/终端插件路径；Apple 本机或用户选择的 pi 翻译、可配置快捷键、可撤销的只读覆盖层保持不变。本文不把未完成的真实 UI 证据宣称为发布能力。
开发隔离：DEV 应用默认快捷键为 **Control + Option + Shift + T（⌃⌥⇧T）**；若 `.dev/config` 已有快捷键则配置优先，release 用户设置不被覆盖。每个 worktree 使用独立 `.dev/data`、`.dev/config`、`.dev/build` 和 XDG 覆盖路径；release 路径与日常配置保持不变。显示名不区分构建：DEV 与 release 的应用显示名同为 Desktop Translate，差异只在 bundle id 与 `.dev/` 数据/构建路径。


> 多窗口说明：同一 app 有多个重叠（含等 frame）普通窗口时，取 CGWindowList 前到后顺序最上层者为目标，不再一刀切拒绝；半透明顶层压住同 app 下层窗口或缺少顺序证据时仍拒绝。详见 [design.md](design.md)。

## 使用当前实现

要求 Apple Silicon、macOS 15+ 和 Xcode Command Line Tools；通用前台窗口的 ScreenCaptureKit/OCR 路径不依赖 cmux。终端插件能力与限制见下方支持说明。

```sh
cd <历史项目检出目录>
./desktop-translate help
./desktop-translate start
# 当前从项目根目录运行（不保留旧 PATH 别名）：
./desktop-translate
```

当前入口为 `./desktop-translate`，源码目录为 `app/`；本次改名不保留旧 launcher 兼容别名。已有旧 PATH 入口可能仍指向另一检出目录，不能据此判断本检出已安装；本次未自动修改个人符号链接。若需安装新 PATH 入口，可自行执行 `ln -s <chosen-checkout>/desktop-translate <user-bin>/desktop-translate`，明确选择目标检出。所有源文件、测试与产品变更记录随项目迁移。

配置继续使用 `$XDG_CONFIG_HOME/cmux-translate/config.json` 或 `~/.config/cmux-translate/config.json`，无需导入、重置或改名；快捷键和本机/pi选择保持兼容。当前 release app 构建位置为 `$XDG_DATA_HOME/cmux-translate/Desktop Translate.app` 或 `~/.local/share/cmux-translate/Desktop Translate.app`。迁移没有改动个人配置、已安装 app 或正在运行的实例；下次执行构建类命令可能按源码时间戳重新构建。

- [当前用户说明](../README.md)／[开发指南](../app/README.md)
- [实施方案（部分实现，未验收）](design.md)
- [001：通用桌面插件与定位 OCR](changes/001-desktop-plugin-ocr.md)
- [002：五种终端布局与文本插件](changes/002-terminal-layout-plugins.md)
- [2026-10-16 源码修改（未构建未运行）](development-history-evidence.md#2026-10-16-源码修改未构建未运行)

## 迁移记录

- 2026-10-12：从 dotfile/bin 分离为独立 Git 项目；保留历史命令、配置目录与源码名称，PATH 入口改为符号链接。DEV 隔离与插件/OCR代码已组装；真实 UI 验收仍有明确阻塞项，未宣称通用桌面/OCR能力完成。

## 历史证据导航

[实现状态、剩余门槛、2026-10-16 源码修改、集中验证与 2026-10-15 捕获边界](development-history-evidence.md)保留完整历史正文。集中 gate 的通过仅覆盖当时指定范围；后续源码修改、真实 UI、权限、显示器与五终端验收状态均保留原限制。

## 变更记录

以下 2026-10-21 设置 UI 记录来自执行该变更的独立会话，仅证明当时菜单/设置流程，不由本次文档整理重跑，不扩展为 OCR、翻译、下载、定位或输入屏障验收。两次菜单方案按时间演进，后一轮“设置归并”已取代同日早期分离菜单入口。

- 2026-10-21（设置归并）：按进一步反馈，快捷键和调试均移入“设置…”窗口的“通用”区，不再单列菜单项。快捷键显示当前组合并由“更改…”打开原录制器；识别区域开关独立保存，失败回退并提示，对新会话生效。DEV 构建通过；实际菜单、设置窗口截图、录制入口及取消返回、调试开→关及持久化恢复均已验证；隔离 `shortcut-smoke` 九项检查通过，个人快捷键未变。修正 pi 模式语言包整行隐藏及空行拉伸；未触发翻译或语言包下载。

- 2026-10-21：菜单精简为“翻译设置…”和“快捷键设置…”，语言对/输入模式独立显示；翻译、设置、调试及退出分组，识别区域开关移至“调试”子菜单，DEV/release 统一“退出 Desktop Translate”。隔离 DEV 构建通过，实际菜单截图确认布局，两个设置入口与调试子菜单已运行检查；保留已有快捷键与配置。未触发翻译、模型请求或语言包下载，不构成其他桌面翻译能力的验收证据。

- 2026-10-20（源码修改，未构建未运行）：新增源语言残留标记——英文目标下，已绘制但译文仍以 CJK 为主的区域由 T/E/S/V 改判为 R（子原因 `source-language-residue`），并新增仅含计数的日志行；计划/绘制/遮罩/保护/新鲜度与 HUD 计数不变。除逐文件 `swiftc -parse` 外未构建、未类型检查、未运行；本条不构成验收证据。

- 1.2.0：保留本机默认翻译，新增用户可选 pi 无头模式、可执行文件/模型设置、空 system prompt 隔离和每屏批量翻译；配置保存互相保留快捷键及模式。

- 1.1.0：菜单栏快捷键录制、立即生效、持久化设置；注册或保存失败保留原快捷键；所有快捷键提示随配置更新。

- 1.0.0：历史基线包括可见终端快照、本机英中翻译、⌃⌥T/Esc 可撤销阅读层、取消隔离和受保护文本边界；旧真实应用冒烟记录不证明当前桌面定位、输入隔离或五终端验收。

- 2026-10-15（契约修正，非验收）：用户批准以实际SCK目标缺失/错误/全黑fail-closed取代legacy sharing guard，产品与harness共享策略，不设fixture例外或OS版本猜测。上文历史sharing1/2 readiness/自然前台说明已被取代：保留精确owned PID/window/frame/layer/alpha/单普通窗口连续两tick及重验证，允许每次显式opt-in对新建且核实身份的公共fixture owned PID至多一次激活，绝不激活既有用户应用或注入输入。不新增权限，不改TCC/钥匙串/日常配置；S2/S3/S4/S6及001/002仍未验收，无新增运行证据。
- 2026-10-16（验收反馈，已实现）：展示后内容像素变化不再撤除译文覆盖（展示前新鲜度门槛不变；展示后监视器只看窗口身份/几何/Space/屏幕/遮挡/前台），Esc/快捷键退出。展示成功后 HUD 动画收起为可拖动小图标，点击展开；HUD 不激活也不成为 key，屏障保持 key，Esc 仍有效。
