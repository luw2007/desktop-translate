# Desktop Translate

独立 macOS 桌面翻译项目。**当前实现仍为 cmux 可见屏幕阅读层**：Apple 本机或用户选择的 pi 翻译、可配置快捷键、可撤销的只读整窗覆盖层。通用桌面、定位 OCR 与五种终端布局插件是待实现目标，不是已发布能力。

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

- 2026-10-12：从 dotfile/bin 分离为独立 Git 项目；保留历史命令、配置目录与源码名称，PATH 入口改为符号链接。仅迁移并记录实现方案，没有发布桌面/OCR能力。

## 集中验证

从本项目根目录运行现有文档中的检查命令。迁移过程未运行构建、测试或 smoke；后续集成负责人集中执行。`pi-smoke` 会把公共示例发送给已配置模型服务，`smoke` 可能要求下载 Apple 语言包。
