# 产品变更 001：权限与验收

[返回概览](001-desktop-plugin-ocr.md)

## 权限与隐私

目标锁定与窗口变化以无需AX的前台PID/CGWindowList唯一窗口及轮询为基线；AX仅已授权或插件所需的增强。OCR与截图失效检测需要屏幕录制；原生revision为可见文本重读哈希，不需要截图。Terminal/iTerm2原生路径、Ghostty脚本焦点路径按目标请求Automation，Info.plist有NSAppleEventsUsageDescription，进程内发送AE。各插件SR/AX/AE/应用设置、请求时机、拒绝needsPermission与显式另选OCR见[设计权限矩阵](../design-foundations.md#4-权限子进程与隐私)；拒绝、撤销、周期确认均说明用途并停止，不改权限。

截图与原文默认只在内存。OCR 在本机执行；pi 模式默认只把本机识别出的正文发给用户所选 provider，只有用户显式选择截图输入时才把所选区域的完整裁剪作为图像发送。覆盖层、错误和日志不输出私有原文。需测试拒绝授权、撤销授权及敏感区域排除。

敏感排除边界是锁定窗口与选区：ScreenCaptureKit sourceRect只含选区，选区外像素不进入内存；AX跳过AXSecureTextField等安全角色及子树，仅适用于AX读取。捕获前检查屏幕录制权限，缺失/撤销单独报告；SCShareableContent未列出同windowID+PID、onScreen、layer0、相同frame目标、SCK错误或全黑结果均明确报“该窗口无法捕获（可能受系统或应用保护）”，不能报无文字或回退其他窗口/显示器，不将所有错误归因于保护。legacy sharingState/NSWindow.sharingType=.none既不证明保护也不证明安全，不作为允许/拒绝或用户警告，仅可作非权威诊断。没有公开保护/安全像素检测接口；OCR不能识别或排除防截图意图、安全字段与敏感控件，局部黑块的剩余像素仍可能OCR。pi provider在捕获前可见；默认只发送待翻译正文，只有用户显式选择截图模式时才发送所选区域截图（内存 PNG、经 stdin、不落盘、不入日志或错误、不放进进程参数）。所有pi/认证助手/终端CLI通过共享disclaim spawner放弃TCC责任，符号缺失fail closed；只加载内建插件。

## 验收标准

- [ ] 插件匹配使用正确应用/窗口标识，不依赖标题猜测；当前插件/来源可见。
- [ ] 一个插件目标与一个无插件目标分别真实运行，后者走 OCR；插件不支持和插件错误可区分。
- [ ] 实际截图 OCR 在至少两个缩放比例、跨显示器、非主屏负坐标下定位正确；提供测试样例标注的矩形误差证据。
- [ ] 多行段落、按钮、代码块、表格等区域正确分组；中文扩张不覆盖邻近控件，不静默截断。
- [ ] 快捷键/Esc关闭、翻译中取消、目标变化撤除、迟到结果隔离均在实际 UI 验证。
- [ ] 屏幕录制未授权/撤销后错误明确，无错窗捕获。
- [ ] 本机/pi 两种后端可选，默认和原快捷键设置不被迁移覆盖。
- [ ] 默认完整CG bounds一键及显式区域两流程、选区会话记忆及resize/pane失效真实验证；HUD显示source/provider，承载可见translationTask，展开完整译文；语言包未安装时无目标捕获，独立准备窗口安装后重触发有首次下载证据。
- [ ] pi 截图模式（显式选择）在真实 UI 验证：模型下拉来自 pi 自身 `get_available_models` 并只允许声明图像输入的模型，所选模型不可用或非图像模型时明确拒绝发送；截图经内存 PNG/stdin 发送且不落盘、不入日志或错误、不进进程参数；模型自报位置经严格校验（裁剪内、受保护片段逐字、否则整批拒绝）且不冒充原生/OCR 几何；展示前以同一张已持有原图基线核对，无重新截图、无模式/模型回退；四类绘制计数与实际结果一致，HUD 在无任何区域绘制时报失败。当前仅逐文件 `swiftc -parse`，以上全部未验证。
- [ ] UI单词按钮/菜单/表头/单元、含分号/管道/列表的文案可翻译；标识符仅含下划线、camelCase或数字字母混排的词，Cancel/Settings/OK必须翻译；软换行合并请求不跨控件，路径/URL/代码保护，不越界。
- [ ] 权限矩阵每个拒绝格、撤销/周期确认、原生revision无需SR且失效不能展示有真实UI证据；共享spawner子进程SR/AX预检false与缺符号fail closed有证据。
- [ ] “权限与隐私”边界逐条验证：选区外无像素、secure AX不读取、SCK目标未列出/错误/全黑各自明确报捕获不可用、捕获前provider可见，截图/私有文本不落盘或日志。`--sharing-none`只记录实际拒绝/全黑/仍捕获，不保证拒绝，不替代保护路径证据。
- [ ] 非激活UI及fullScreenAuxiliary在原生全屏终端Space真实验证；全窗口屏障在遮罩/未遮罩区域点击滚动不穿透，外部切换撤除；自身overlay与系统层不误撤除，其他PID layer0遮挡失效有证据。用户已接受临时ad-hoc开发：S0每次重建后重新授权，以独立公共fixture做一次SCK截图探针（无OCR、不保存），拒绝停止；S2验收完整捕获/OCR管线。不要求两次重建TCC保持；dev与日常app/配置隔离并可并存。
- B1已决定：产品名Desktop Translate、release保留local.cmux.translate与原配置；dev显示名与产品同为Desktop Translate（内部 .dev 构建路径名不变），隔离身份为local.cmux.translate.dev.<tag>（tag匹配[A-Za-z0-9-]+）、每worktree .dev/data/config/build及XDG覆盖，默认⌃⌥⇧T（配置优先，release用户设置不变），Bundle.main动态单实例。S0第一笔实现提交仅launcher隔离，非主worktree缺合法tag拒绝构建并忽略.dev；隔离落地前禁止构建。当前可用签名身份0，用户选择临时签名，不创建证书/改钥匙串；稳定production签名是发布前提而非开发阻塞。可选sign identity，证书默认禁用，源码/launcher别名保留至正式产品迁移。
