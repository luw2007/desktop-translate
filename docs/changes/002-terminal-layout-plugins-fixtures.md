# 产品变更 002：终端 fixture 设施

[返回概览](002-terminal-layout-plugins.md) · [此前证据与限制](002-terminal-layout-plugins-evidence.md)

### 2026-10-16 终端 fixture 设施

新增源码：`fixtures/terminal_public_producer.py` report schema 升到 **2**（新增 `scenarioMode` cycle/fixed、`revision`、`xpixel`/`ypixel` 取 `TIOCGWINSZ`，0 表示 emulator 不上报像素；`SIGWINCH` 只置 dirty 让下一 tick 重读尺寸）。`revision` 是 tick 计数器而非内容变化证明：每次场景渲染和每个 0.5s tick 都递增，静止场景同样递增；区分真实重绘要看 `sceneChanges`（场景切换）与 `renderCount`（完整场景渲染）。`fixtures/terminal_fixture_launcher.py` 新增 `handoff`/`attach-plan`/`attach` 子命令；`app/TerminalSmoke.swift` 是新的 handoff 消费者。

能力边界按实际源码写死：`launch` 只对「已安装 bundle 有文档化隔离独立启动路径」的应用新建进程（当前仅 Ghostty/Kaku 为 candidate，且两者都未被观察过），其余三应用必须走 `attach-plan` + `attach` 的用户手工路径；`attach` 的机器校验只有四项——plan 文件存在且未被改写、owner 进程 `ps lstart` 严格晚于 plan 时间、report 为 running 且新鲜且其 pid 是本 token 的活 `terminal_public_producer.py`、该 pid 是 owner 的后代。「全新一次性进程、非日常实例」是 `--attest-new-disposable-process` 的操作者声明，`state.json` 里也如实记成 `operator-asserted; machine-checked only: …`；该路径**不证明**附加进程没有其他 tab/pane，`--window-id` 由操作者提供。

消费者侧不信任 launcher 的派生数据：`TerminalSmoke.swift` 用 `sysctl` 重取 owner/producer 启动时间与 `lstart` 字符串比对、重算后代链、用 `stat` 校验控制 tty 的 `st_rdev`、要求 owner 是预期 bundle 的活进程、要求锁定的目标是 owner **唯一**普通窗口且非空标题包含 `DT-Fixture-<token>`；就绪要求 owner 自然前台且该唯一窗口连续两 tick 稳定（10s 上限），全程不激活、不输入、不启动、不终止，失败不回退到其他窗口。输出刻意声明 `geometry.measured = false`：终端文字没有字形几何 oracle，因此它只报公共计数/来源，不报 ≤4pt。

最终集中 gate（Main 报告，2026-10-16）：DEV app 与 glyph fixture 构建 exit 0（fixture 未启动），两个实际 PTY/CLI Python 测试通过，fresh attach 的真实进程/TTY 与合成 bundle 边界检查通过。这仍不是 emulator UI、物理 FocusLost 或五应用证据，`geometry.measured = false` 不变，S6 与原始 S2/S3/S4 仍未验收。

2026-10-15批准不新增运行证据：历史sharing readiness被取代，精确owned PID/window/frame/layer/alpha/单普通窗口两tick与重验证保留。激活只允许显式opt-in对本次新建、身份核实的公共fixture owned PID至多一次，不适用于五个既有用户终端，不注入输入；无新权限或TCC/钥匙串/日常配置更改。原始S2/S3/S4/S6及001/002仍未验收。
