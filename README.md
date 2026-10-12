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
- [实施方案（供 Opus 审查，尚未实现）](DESIGN.md)
- [001：通用桌面插件与定位 OCR](cmux-translate-app/changes/001-desktop-plugin-ocr.md)
- [002：五种终端布局与文本插件](cmux-translate-app/changes/002-terminal-layout-plugins.md)

## 迁移记录

- 2026-10-12：从 dotfile/bin 分离为独立 Git 项目；保留历史命令、配置目录与源码名称，PATH 入口改为符号链接。DEV 隔离与插件/OCR代码已组装；真实 UI 验收仍有明确阻塞项，未宣称通用桌面/OCR能力完成。

## 当前实现状态与剩余门槛

DEV 构建和独立公共 fixture 的屏幕捕获探针已有记录（1520×1040，无保存、无 OCR）；disclaim spawner 的子进程报告为 SR/AX=false，stdin、超时、输出上限、取消与真实 `cat`/`timeout` 路径已验证。一次本机 smoke 曾验证 9 个区域、区域裁剪、快捷键/Esc 撤除和无输入穿透，但发生在词级切分修复之前，160pt 坐标误差修复后尚未对前台目标复测。`pi-smoke` 因前台窗口被占用而阻塞，不能视为通过。

五种终端插件当前均诚实标记为 window-only partial/unsupported，并以 OCR 补齐：cmux 0.65.0（CLI metadata-only identify）；iTerm2 3.7.0（显式数值 ID、只读 visible-contents probe）；Terminal.app 2.15（选中 tab、无 history）；Ghostty 1.3.1（无文字接口）；Kaku 0.19.0（全局 list，未映射 CG，screen row 0 不是 viewport）。没有任何 native positioned mapping 已被证明。

尚未完成的门槛包括：坐标精度修复后的前台复测、pi-smoke、S3 显示器/Space/隐私权限矩阵、S4 复杂布局与溢出、S6 五终端真实运行、FocusLost 次数、production 签名及完整真实 UI 验收。
***

## 集中验证

从本项目根目录运行现有文档中的检查命令。迁移过程未运行构建、测试或 smoke；后续集成负责人集中执行。`pi-smoke` 会把公共示例发送给已配置模型服务，`smoke` 可能要求下载 Apple 语言包。
