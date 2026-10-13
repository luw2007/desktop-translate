# Desktop Translate

独立 macOS 桌面翻译项目。当前交付包含 cmux 可见屏幕阅读层，以及已组装但仍需真实 UI 验收的通用桌面/定位 OCR/终端插件路径；Apple 本机或用户选择的 pi 翻译、可配置快捷键、可撤销的只读覆盖层保持不变。本文不把未完成的真实 UI 证据宣称为发布能力。
开发隔离：DEV 应用默认快捷键为 **Control + Option + Shift + T（⌃⌥⇧T）**；若 `.dev/config` 已有快捷键则配置优先，release 用户设置不被覆盖。每个 worktree 使用独立 `.dev/data`、`.dev/config`、`.dev/build` 和 XDG 覆盖路径；release 路径与日常配置保持不变。


## 使用当前实现

要求 Apple Silicon、macOS 15+、Xcode Command Line Tools 和 cmux。

```sh
cd ~/ai/desktop-translate
./cmux-translate help
./cmux-translate start
# 现有 PATH 入口仍可使用：
cmux-translate
```

`~/dotfile/bin/cmux-translate` 是指向本项目实际 launcher 的安装符号链接；launcher 解析链接后从本项目读取源码，与从独立根目录直接运行一致。没有复制第二套实现。源码目录暂保留 `cmux-translate-app/`，所有源文件、测试与产品变更记录随项目迁移。

配置继续使用 `$XDG_CONFIG_HOME/cmux-translate/config.json` 或 `~/.config/cmux-translate/config.json`，无需导入、重置或改名；快捷键和本机/pi选择保持兼容。安装 app 继续位于 `$XDG_DATA_HOME/cmux-translate/CMux Translate.app` 或 `~/.local/share/cmux-translate/CMux Translate.app`。迁移没有改动个人配置、已安装 app 或正在运行的实例；下次执行构建类命令可能按源码时间戳重新构建。

- [当前功能、隐私、设置及诊断](cmux-translate-app/README.md)
- [实施方案（部分实现，未验收）](DESIGN.md)
- [001：通用桌面插件与定位 OCR](cmux-translate-app/changes/001-desktop-plugin-ocr.md)
- [002：五种终端布局与文本插件](cmux-translate-app/changes/002-terminal-layout-plugins.md)

## 迁移记录

- 2026-10-12：从 dotfile/bin 分离为独立 Git 项目；保留历史命令、配置目录与源码名称，PATH 入口改为符号链接。DEV 隔离与插件/OCR代码已组装；真实 UI 验收仍有明确阻塞项，未宣称通用桌面/OCR能力完成。

## 当前实现状态与剩余门槛

DEV host 的独立公共 fixture ScreenCaptureKit 探针曾成功（1520×1040，无保存、无 OCR）；disclaim spawner 子进程报告 SR/AX=false。这只证明该次探针及预检结果，不证明完整权限隔离或 TCC 授权来源。TCC=true 的确切责任归属与因果未证实，不归因于 Doubao 或其他应用。

旧本机 smoke 的 ok 标志不是定位或键盘隔离证明：其框匹配采用未一一对应的最小距离，曾报告最大 159.8pt，输入使用合成事件。不能据此声称精度达标、真实点击/滚轮/按键不穿透或 FocusLost=0；后续修正仍待真实 UI 验收。本机与 pi 的真实端到端流程均未验收。

最新集中验证：DEV 与公共 fixture 构建成功，六个有实际断言的检查程序通过。最初公共 fixture 本机 smoke 约2.7s报 target changed；后续 lifecycle 探针在 SCK+OCR 完成4项后、展示前观察 frontmostPID 从 fixture51226 转为 cmux1799（`com.cmuxterm.app`），正确 fail-closed 撤除，未成功展示。cmux 重新前台原因未证实，首个检查返回不能证明 Space/frame/display 原因。真实失效原因已保留到 HUD/失败输出。lifecycle tag 暴露的缓存身份问题代码已修正，最终编译观察 CFBundleIdentifier 为 `local.cmux.translate.dev.desktop-plugins-ocr`；正常 DEV 未启动，运行时未验证。合成 merge 检查仅证明模型合并及终端提示符保护，不证明 UI；当前重建后的子进程权限、权限撤销、本机/pi 和五终端矩阵仍未验证。

五种终端适配器已注册，但注册或编译不等于五终端产品交付。当前来源是 window-only partial/unsupported + OCR：cmux 0.65.0（CLI metadata-only identify）；iTerm2 3.7.0（显式数值 ID、只读 visible-contents probe）；Terminal.app 2.15（选中 tab、无 history）；Ghostty 1.3.1（无文字接口）；Kaku 0.19.0（全局 list 未映射 CG，screen row 0 不证明 viewport）。没有已证明的 native positioned mapping、tab/pane 精确几何或原生 Unicode 列宽映射；OCR 路径本身也未完成真实验收。

剩余门槛：真实文字框定位误差≤4pt；真实点击/滚轮/按键在遮罩及未遮罩区域的屏障隔离；原生全屏、负坐标、1x/2x 两种缩放、跨屏/Space；五应用的 tab/分屏/TUI/Unicode/字体缩放；逐应用 FocusLost 实际次数；本机/pi 真实端到端；权限拒绝/撤销及隔离、复杂布局/溢出/失效与完整 001/002 验收。production 稳定签名仍是发布门槛，临时开发签名不是 TCC 稳定性证明。
***

## 集中验证

从本项目根目录运行现有文档中的检查命令。迁移过程未运行构建、测试或 smoke；后续集成负责人集中执行。`pi-smoke` 会把公共示例发送给已配置模型服务，`smoke` 可能要求下载 Apple 语言包。
