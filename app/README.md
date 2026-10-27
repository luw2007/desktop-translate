# 开发指南

用户环境、设置、操作与隐私入口见[根 README](../README.md)；设计和未完成验收见[文档索引](../docs/README.md)。这里的路径与命令均从 Git 检出根执行，不依赖个人 PATH 别名或安装符号链接。当前不是完整验收通过的发行版。

## 源码结构

| 文件组 | 职责 |
|---|---|
| `../desktop-translate`、`App.swift`、`Info.plist` | launcher 构建/隔离/签名、菜单栏生命周期与模式入口 |
| `DesktopModels.swift`、`DesktopCapture*.swift`、`DesktopImageCapture.swift`、`DesktopOCR*.swift`、`DesktopTargetLock.swift`、`TargetMonitor.swift`、`DesktopScreenshot.swift`、`RegionSignature.swift` | 锁定目标、坐标/快照、SCK/OCR、展示前新鲜度 |
| `DesktopSession*.swift`、`DesktopPlan*.swift`、`DesktopInteractionState.swift`、`DesktopWindowOrdering.swift` | 操作 token、取消/迟到结果、翻译规划、会话状态和展示 |
| `DesktopOverlay.swift`、`DesktopSelectionPanel.swift`、`DesktopExpansionPanel.swift`、`DesktopHUD.swift`、`CollapsedHUDIconView.swift`、`Overlay*.swift`、`DebugRegions.swift`、`DebugExport.swift`、`SourceResidue.swift` | 非激活面板/输入屏障、布局绘制、调试分类与显式导出 |
| `Segments*.swift` | 自然语言分段、技术片段保护、跳过原因 |
| `TerminalPlugin.swift`、`TerminalPluginRegistry.swift`、五个 `*Plugin.swift` | 编译内建插件与精确身份/只读接口；注册不等于原生定位支持 |
| `TranslationSettings*.swift`、`LanguagePreparation.swift`、`Shortcut*.swift` | 配置、语言包准备、统一设置窗口、快捷键 |
| `PiTranslation.swift`、`PiModels.swift`、`PiImageGeometry.swift`、`DisclaimSpawner.swift`、`pi-translation-extension.mjs` | 可用模型发现、隔离子进程、文字/图像协议和响应校验 |
| `*Smoke.swift`、`PublicFixture.swift`、`tests/`、`../fixtures/` | 有边界的诊断模式、公开 fixture 与 standalone checks |

菜单栏目前按状态、翻译前台窗口、区域翻译、设置、退出分组。统一“设置…”窗口的“通用”区包含当前快捷键、“更改…”与调试复选框；下方是翻译后端设置。快捷键/调试独立保存，调试对新会话生效。不要恢复旧的单独快捷键/调试菜单文档。

## 隔离构建

```sh
export DESKTOP_TRANSLATE_DEV_TAG=local
./desktop-translate build
```

仅构建，不启动应用；需要运行时再显式执行 `./desktop-translate start` 或 `./desktop-translate run`。launcher 会编译全部应用 Swift 与 `fixtures/GlyphSceneManifest.swift`，复制资源、设置 bundle ID 并签名；不使用 SwiftPM。当前编译目标为 `arm64-apple-macos15.0`，需要支持源码所用 API 的 SDK，最低可用 SDK 未单独验证。

linked worktree 无 tag 会拒绝；tag 匹配 `[A-Za-z0-9-]+`，输出在本检出 `.dev/`，不同 tag 共用这里的路径。构建不应覆盖日常 XDG 配置或 release app。默认 ad-hoc 签名；不要创建证书、改钥匙串或 TCC 来绕过失败。

## 检查命令与范围

以下是供集成负责人按需集中运行的独立检查，不是文档整理时新跑过的证据。不要在多个工作代理仍写入源码时并发构建/测试，也不要把 parse 成功当类型检查或运行通过。

纯语法检查（不启动 app、不验证链接/类型）：

```sh
for file in app/*.swift; do
  xcrun swiftc -parse "$file" || break
done
```

分段/保护边界回归（编译后执行测试；显式运行）：

```sh
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/desktop-translate-checks.XXXXXX")"
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 \
  app/Segments*.swift app/tests/SegmentsChecks.swift \
  -framework NaturalLanguage -o "$CHECK_DIR/segments-checks"
"$CHECK_DIR/segments-checks"

xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 \
  app/Shortcut.swift app/TranslationSettings.swift \
  app/tests/TranslationSettingsChecks.swift \
  -framework Carbon -o "$CHECK_DIR/settings-checks"
"$CHECK_DIR/settings-checks"

xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 \
  app/Shortcut.swift app/TranslationSettings.swift \
  app/tests/ShortcutChecks.swift \
  -framework Carbon -o "$CHECK_DIR/shortcut-checks"
"$CHECK_DIR/shortcut-checks"
```

绘制/坐标/分组/规划/签名/调试回归：从应用源码构建可测试模块（不包含 `App.swift`、会话/截屏实现或依赖 app delegate 的 `*Smoke.swift`），再将**一个** `@main` 与另外 14 个检查文件链接为一个可执行文件。以下使用上方已有的 `CHECK_DIR`，保留断言，不启动应用：

```sh
APP=app
xcrun swiftc -emit-module -emit-library -enable-testing -parse-as-library \
  -module-name DesktopChecksModule -target arm64-apple-macos15.0 \
  "$APP"/{DesktopModels,DesktopCaptureRouting,DesktopInteractionState,DesktopWindowOrdering,DesktopPlan,DesktopPlanGeometry,DesktopTextSegmentation,DesktopOCRGrouping,DesktopOCRGroupingRules,DesktopOverlay,OverlayTextLayout,OverlayItem,OverlayItemLayout,OverlayOccupancy,DebugRegions,DebugExport,SourceResidue,RegionSignature,Shortcut,TranslationSettings,Segments,SegmentsProse,SegmentsVerdict,SegmentsTargetLanguage}.swift \
  -framework AppKit -framework CoreText -framework Carbon -framework NaturalLanguage \
  -o "$CHECK_DIR/libDesktopChecksModule.dylib"
xcrun swiftc -parse-as-library -D DESKTOP_CHECKS_MODULE -target arm64-apple-macos15.0 \
  -I "$CHECK_DIR" -L "$CHECK_DIR" -lDesktopChecksModule \
  "$APP"/tests/{DesktopChecks,GeometryChecks,LifecycleChecks,GroupingChecks,PlanChecks,SignatureChecks,PaintAssociationChecks,FreeSpaceChecks,DownExtensionChecks,OverflowFallbackChecks,WindowOrderingChecks,DebugRegionChecks,ResidueChecks,ParagraphChecks,DebugExportChecks}.swift \
  -framework AppKit -framework CoreText -framework Carbon -framework NaturalLanguage \
  -o "$CHECK_DIR/desktop-checks"
DYLD_LIBRARY_PATH="$CHECK_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$CHECK_DIR/desktop-checks"
```

其他 standalone 检查源位于 `tests/`，包括 GlyphMatcherChecks、GlyphFixtureOracleChecks、ShortcutChecks、TranslationSettingsChecks/Smoke、PiResponseChecks、PiImageChecks、PluginRegistryChecks 及 Python terminal fixture 检查。它们依赖不同源文件，不能用把所有 `tests/*.swift` 混编的方式运行（含多个入口）。具体选择必须与改动范围匹配，绘制 oracle/合成事件仍不能证明真实 OCR 精度、焦点或输入隔离。

Python fixture 检查仅使用自己创建的 PTY 和临时状态目录（不是终端 emulator GUI、捕获或权限证明）：

```sh
python3 -m unittest discover -s app/tests -p test_terminal_fixture.py -v
```

Swift checks 不加产品构建的 `-O` 优化参数，保留断言；每个 standalone `@main` 文件独立编译，DesktopChecks 是上面列出的 15 文件组合。以上命令为复现指南；不以离屏检查替代真实捕获、模型、权限或物理输入验收。

## 手工 fixture 与诊断边界

公共样例、准确命令与协议见[fixtures 指南](../fixtures/README.md)。构建 fixture 和运行 fixture 必须分开；在获得当前操作授权前，不运行任何捕获、权限请求、网络、终端启动/attach 或键鼠流程。

| launcher 命令 | 实际边界 |
|---|---|
| `help` | 命令帮助；不运行翻译 |
| `capture` | 前台锁定目标元数据与屏幕录制预检，不截图/OCR/输出正文；仍是运行诊断 |
| `child-permission-report` | 子进程权限预检报告，不代表授权因果或完整隔离 |
| `request-screen-recording` | 一次预检和必要时一次系统请求；退出 0 / `commandCompleted` 仅表示完成，不代表授权 |
| `permission-probe` | 公开 fixture 的一次真实 SCK 截图，无 OCR、不保存；不是通用权限验收 |
| `smoke` / `pi-smoke` | 公共窗口真实 OCR/翻译；本机可能需语言包，pi 会发公共文字到模型服务 |
| `glyph-smoke` / `glyph-pi-smoke` | 独立 glyph fixture 的捕获/翻译与定位诊断；需先构建公开 fixture |
| `terminal-fixture-smoke` / `terminal-fixture-pi-smoke` | 消费授权 handoff，重验证归属后一次真实会话；不激活/输入/启动/终止目标，`geometry.measured=false` |
| `shortcut-smoke` | 隔离临时设置下的快捷键 UI 检查，不是翻译或输入屏障验收 |

launcher 支持上述 terminal-fixture 两个子命令；不要沿用“仅 app 参数、不是 launcher 子命令”的旧说明。`--authorize-fixture-activation` 仅适用于 launcher 明确允许的公开 fixture 命令，显式允许本次新建且身份核实的 fixture PID 至多一次激活，不授权既有用户应用激活或输入。目标不明确/缺失/过期必须拒绝，不能换窗口或整屏兜底。

## 贡献与证据

1. 从隔离 worktree/检出开始，保留现有配置 schema、精确目标与取消 token 约束；先读[当前契约摘要](../docs/design.md#当前契约摘要2026-10-21-文档整理)。
2. 修改共享契约时同步调用方、对应检查、设计和变更记录，不增兼容别名或第二套捕获路径。权限矩阵、新权限或安全边界变更需要明确复审，不在“顺手整理”中扩权。
3. 开发代理不运行测试；集成负责人在合并修改后统一执行适用 checks。手工 GUI/捕获/网络/权限动作另行明确授权，只用可分享公开样例。
4. 报告具体版本、命令、退出码、实际覆盖和未执行项。把“源码修改”“编译通过”“离屏 checks”“设置 UI”“真实 OCR/模型/输入”分开，不以 fixture、适配器注册或旧 smoke 替代完整验收。
5. 提交前审查导出/截图与日志：调试 JSON 包含原文、译文和保护片段，不能直接附到公开 issue；不要提交 `.dev/`、个人配置、认证、私有样例或屏幕证据。项目采用 [MIT 许可证](../LICENSE)；贡献前确认有权提交相关代码与资源，并保留适用的第三方版权与许可声明。

历史开发/验证与设置 UI 的窄范围实测记录已归入[开发历史](../docs/development-history.md#变更记录)。2026-10-21 设置归并的 build、菜单/窗口截图、取消录制、debug 0→1→0 和九项 shortcut-smoke 仅证明当时设置流程，不证明翻译、下载、OCR 精度或输入屏障。当时目录与文档整理没有执行构建或测试；该历史记录不描述后来单独执行的离屏检查。
