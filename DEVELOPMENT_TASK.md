# Desktop Translate 隔离开发任务

用户批准将产品独立于 dotfile，并要求 Opus 审查无阻塞后，在新 cmux workspace 和新 Git worktree 开发。

## 启动门槛

先读取 DESIGN.md、cmux-translate-app/changes/001-desktop-plugin-ocr.md、002-terminal-layout-plugins.md、[reviews/opus-plan-review.md](reviews/opus-plan-review.md)（报告已保存且可读取）。Opus结论为 **PASS_WITH_NONBLOCKING**，允许开始开发，非阻塞决策已写入方案；这不是实现或验收通过，全部构建/测试/真实UI门槛尚未执行。若改变权限矩阵（尤其event tap新增输入监控/AX权限），先重新提交Opus复审，不越过门槛。

S0第一笔实现提交只做launcher隔离：非主worktree缺tag时fail closed拒绝构建，tag须匹配`[A-Za-z0-9-]+`，dev输出不能落release路径，`.dev/`加入.gitignore。隔离落地之前worktree里禁止任何构建；不要先试跑现有launcher。之后才实现其余S0基座。dev默认快捷键Control+Option+Shift+T（⌃⌥⇧T），已配置值优先，release用户设置不变。S0授权证据仅独立公共fixture的一次SCK截图探针（不OCR、不保存），完整捕获/OCR管线在S2验收。

## 完整目标

完成两项产品变更，而非仅脚手架：通用前台应用识别、编译内建插件、窗口/区域截图、无插件时 Vision OCR、原位置可撤销中文覆盖，以及 cmux/iTerm2/Ghostty/Terminal.app/Kaku 五种终端插件的布局/可见文字能力与明确 OCR 部分支持。复用本机/pi可选翻译、用户配置与快捷键，不回退成个人定制。

依照已审查方案的切片/依赖执行，先交付可真实运行的端到端桌面 OCR 定位翻译，再完成全部终端矩阵。任何拆分不减少最终范围。共享契约由一个集成负责人维护，适配器研究可委派只读 scout，独立实现可委派 bounded fast 或 load-bearing smart；Opus 仅做审查/架构仲裁。

## 工作约束

- 仅当前 worktree 修改实现，不改主 checkout，不覆盖用户配置/密钥，不在用户私有屏幕上保存证据。
- 不修改终端缓冲区/目标应用数据，不向 Shell 输入，不偷偷改焦点，不修改 TCC/安全设置。
- 区分 native/partial+OCR/unsupported+OCR，不编造五终端接口支持。
- 子代理中途不跑构建/测试/格式化；集成负责人统一验证真实 UI与边界。不得以单元/mock代替桌面捕获/权限/恢复证明。
- 获取必要屏幕录制/辅助功能权限需要用户授权时，用明确中文提示，完成其余可达工作，不绕过权限或宣称成功。
- 可后台持续开发，不因阶段完成停下；但真实缺失用户授权时记录精确阻塞并告知负责人。
- 完整行为验证后更新文档与支持矩阵，清除临时脚本。不要自行推送、发布或合并。

## 与负责人沟通

这是独立可见开发 session。启动后立即通过 intercom 向 `迁移项目并安排 Opus review 开发` session（同机列表确认实际名称/ID）报告当前工作目录、worktree branch、第一项实际实现，并在里程碑/真实阻塞时发送压缩结果。不要向别的 session 终端敲字；用 intercom 或 cmux agent message。
