# 产品变更 002：验收与范围边界

[返回概览](002-terminal-layout-plugins.md)

## 验收矩阵

每个首批终端均需要真实应用证据，不只以单元测试或 mock 证明支持：

- [ ] 插件匹配正确，支持/部分支持/不支持能力可见；无法原生提取时可用 OCR且显示来源。
- [ ] 单窗口、多个 tab、分屏（终端支持时）下，捕获边界与文字位置正确；不读取无关 pane，不改变焦点。
- [ ] 提示符、代码块、命令、路径、diff保持原文；长英文段落翻译可读且不覆盖邻近区域。
- [ ] 宽字符、emoji、组合字符、软换行、Retina缩放、负屏幕坐标有定位证据。
- [ ] TUI与动态日志场景不误把历史文字当当前内容；不因旧快照覆盖新的状态。
- [ ] 翻译中取消、快捷键/Esc恢复、pane关闭/字体缩放/目标切换均安全。
- [ ] 本机和 pi 模式都复用同一插件结果；模型选择/快捷键持久化不受插件影响。
- [ ] 默认一键/显式区域两流程、会话记忆失效、非激活UI、各终端DECSET-1004 focus-out实数与限制有证据；全窗口屏障在遮罩/未遮罩区吞点击滚动，窗口外切换撤除；fullScreenAuxiliary与原生全屏终端Space真实验证；遮挡仅其他PID layer0，自身overlay与系统层不误撤除。
- [ ] 每插件权限矩阵逐格拒绝、AE逐应用请求/usage说明、AX安全角色、原生revision与展示前重读有证据；所有CLI/pi共享disclaim spawner，app有SR/AX时公开子进程预检false。
- [ ] 只读白名单静态检查，清理CMUX_*/WEZTERM_*/Kaku目标变量，固定bundle内CLI路径，Kaku --no-auto-start、cmux无--lines/--scrollback；回滚viewport不可靠明确布局+OCR。
- [ ] 未知应用版本标未验证，调度器验证ID/裁剪/父区域/上限/revision；OCR双语言与代码禁纠错、半透明背景、光标签名误报及连续两次变化有真实证据。

## 范围边界

不修改终端缓冲区、不注入 Shell、不要求用户安装改变终端行为的命令回显钩子。若某终端需要额外官方自动化权限/集成，必须说明、由用户选择启用。

插件扩展点本轮仅编译进app的内建Swift插件，不加载外部可执行代码。外部插件信任/签名/隔离另审。AE进程内发送而非osascript；CLI与pi/认证助手用共享私有responsibility_spawnattrs_setdisclaim spawner，仅内部native用途，符号缺失fail closed。支持macOS15+本地工作站，不承诺App Store。B1已定：Desktop Translate/release local.cmux.translate保留原配置；DEV显示名同为Desktop Translate（内部 .dev 构建路径名不变）、bundle local.cmux.translate.dev.<tag>（tag匹配[A-Za-z0-9-]+）、独立worktree .dev/data/config/build与XDG覆盖、默认⌃⌥⇧T（配置优先，release用户设置不变）、Bundle.main动态单实例。S0第一笔实现提交仅launcher隔离，非主worktree缺合法tag拒绝构建，忽略.dev；隔离落地前禁止构建。用户明确接受ad-hoc开发每次重建重新授权；S0独立公共fixture SCK截图探针无OCR且不保存，S2完整捕获/OCR管线，拒绝停止；日常app/配置不变且两者并存，不要求两次重建TCC保持。签名identity可选、证书默认禁用，不创建证书/改钥匙串；稳定production签名是发布前提，不阻塞获豁免的开发，源码/launcher别名保留至产品迁移。
