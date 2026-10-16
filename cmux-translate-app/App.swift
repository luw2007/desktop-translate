import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI
import Translation

// MARK: - App delegate

enum LaunchMode {
    case normal
    case smoke
    case capture
    case piSmoke
    case shortcutSmoke
    case permissionProbe
    case requestScreenRecording
    case childPermissionReport
    case glyphSmoke
    case glyphPiSmoke
    case terminalFixtureSmoke
    case terminalFixturePiSmoke
}

private let usage = """
用法: cmux-translate-app [选项]
  （无参数）         常驻后台，快捷键（默认 ⌃⌥T，开发版 ⌃⌥⇧T）翻译前台应用窗口：先锁定前台窗口，再截图 OCR 并在原位置覆盖译文；再按快捷键或 Esc 撤除
                     菜单栏“译”→“区域翻译”：拖选区域，Return 确认，Esc 取消；“准备本机语言包”：独立窗口安装英中语言包
                     菜单栏“译” → “设置快捷键…”：直接按下新组合，保存后立即生效并持久化到
                     $XDG_CONFIG_HOME/cmux-translate/config.json（默认 ~/.config/cmux-translate/config.json）
                     菜单栏“翻译模式与模型…”选择 Apple 本机（默认）或 pi 无头模式，配置 pi 可执行文件和 provider/model。
                     pi 模式将正文发给所选模型服务，无工具/历史会话，空 system prompt。
  --smoke            独立公共 fixture 上的真实端到端 OCR 翻译冒烟（本机翻译，不保存截图），输出 JSON
  --pi-smoke         同上，使用 pi 翻译（可用 CMUX_TRANSLATE_PI_MODEL/EXECUTABLE 覆盖）；会把公共示例文字发给所选模型服务
  --permission-probe S0：仅对独立公共 fixture 做一次 ScreenCaptureKit 探针（不 OCR、不保存），输出 JSON
  --request-screen-recording  仅预检一次，未授权时请求一次系统屏幕录制权限；输出结果元数据，不捕获、不自动打开设置
  --glyph-smoke      独立 glyph fixture 上一次真实捕获，按当前所选后端翻译，输出 OCR/遮罩边缘误差（仅公共 ID 与数值）
  --glyph-pi-smoke   同上，使用 pi（CMUX_TRANSLATE_PI_MODEL/EXECUTABLE 可覆盖）
  --terminal-fixture-smoke  消费 fixtures/terminal_fixture_launcher.py handoff：对已证明归属的公共终端 fixture 窗口做一次真实会话（插件→OCR），按所选后端翻译，输出公共计数/来源（不测量字形几何，不激活/输入/启动/终止）
  --terminal-fixture-pi-smoke  同上，显式使用 pi
  --child-permission-report  由共享 disclaim spawner 启动自身子进程，比较子进程与本进程的屏幕录制/辅助功能预检，输出 JSON
  --shortcut-smoke   真实快捷键设置冒烟：临时配置目录内走录制窗口、保存、撞键回滚、写盘失败回滚、恢复，输出 JSON；不碰用户配置
  --capture          只输出前台应用锁定的元数据（不含标题、文字或截图）
  --help             显示本说明

"""

func emit(_ object: [String: Any], to handle: FileHandle = .standardOutput) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    handle.write(data + Data("\n".utf8))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "local.cmux.translate" }

    let mode: LaunchMode
    var backend: CarbonHotkeyBackend?
    var binder: ShortcutBinder<CarbonHotkeyBackend>?
    var store = ShortcutStore(url: ShortcutStore.standardURL())
    private var translationSettings = TranslationSettings.defaults
    private var translationController: TranslationSettingsController?
    private var translationItem: NSMenuItem?
    private(set) var recorder: ShortcutRecorderController?
    private(set) var pressCount = 0
    private var translateItem: NSMenuItem?
    private var settingsReturnTarget: NSRunningApplication?
    private var statusItem: NSStatusItem?
    private(set) var session: DesktopTranslationSession?
    let selectionMemory = DesktopTranslationSession.SelectionMemoryBox()
    private var languagePreparation: LanguagePreparationController?
    /// Plugin routing hook (nil = OCR only). Plugin registry integration sets this.
    let pluginRegistry = TerminalPluginRegistry()
    /// Built-in plugins only: exact bundle/PID/launch/window match. nil -> OCR. Error/needsPermission never fall back silently.
    lazy var pluginProvider: DesktopPluginProvider? = { [pluginRegistry] target, selection in
        guard pluginRegistry.hasPlugin(for: target) else { return nil }
        return await pluginRegistry.captureRoute(target: target, selection: selection)
    }
    var currentSettings: TranslationSettings {
        get { translationSettings }
        set { translationSettings = newValue }
    }

    init(mode: LaunchMode) {
        self.mode = mode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch mode {
        case .normal: startNormal()
        case .capture: Task { await runCapture() }
        case .smoke, .piSmoke: Task { await runSmoke() }
        case .permissionProbe: Task { await PermissionProbe.run() }
        case .requestScreenRecording: break // Handled before constructing the app delegate.
        case .childPermissionReport: Task { await runChildPermissionReport() }
        case .glyphSmoke, .glyphPiSmoke: Task { await runGlyphSmoke() }
        case .terminalFixtureSmoke, .terminalFixturePiSmoke: Task { await runTerminalFixtureSmoke() }
        case .shortcutSmoke: Task { await runShortcutSmoke() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dismiss()
        binder?.shutdown()
        backend?.shutdown()
    }

    // MARK: normal mode

    private func startNormal() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).filter { $0.processIdentifier != me }
        if !others.isEmpty {
            FileHandle.standardError.write(Data("CMux Translate 已在运行（pid \(others[0].processIdentifier)），本实例退出。\n".utf8))
            exit(3)
        }
        let shortcut: Shortcut
        do {
            shortcut = try store.load()
            translationSettings = try TranslationSettingsStore(url: store.url).load()
        } catch {
            FileHandle.standardError.write(Data("工具配置无效，未启动（不会回退到默认值）：\(error)\n修正配置后重试。\n".utf8))
            exit(5)
        }
        do { try installHotkey(initial: shortcut) } catch {
            FileHandle.standardError.write(Data("无法注册 \(shortcut.display) 全局快捷键：\(error)。可能已被其他程序占用；可修改配置文件后重试。\n".utf8))
            exit(4)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = Self.bundleIdentifier.hasPrefix("local.cmux.translate.dev.") ? "译·DEV" : "译"
        let menu = NSMenu()
        let translate = NSMenuItem(title: "", action: #selector(menuToggle), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)
        translateItem = translate
        let region = NSMenuItem(title: "区域翻译…", action: #selector(menuRegion), keyEquivalent: "")
        region.target = self
        menu.addItem(region)
        let prepare = NSMenuItem(title: "准备本机语言包…", action: #selector(menuPrepareLanguages), keyEquivalent: "")
        prepare.target = self
        menu.addItem(prepare)
        let settings = NSMenuItem(title: "设置快捷键…", action: #selector(openShortcutSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let translation = NSMenuItem(title: "", action: #selector(openTranslationSettings), keyEquivalent: "")
        translation.target = self
        menu.addItem(translation)
        translationItem = translation
        menu.addItem(.separator())
        let quit = NSMenuItem(title: Self.bundleIdentifier.hasPrefix("local.cmux.translate.dev.") ? "退出 Desktop Translate DEV" : "退出 CMux Translate", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        refreshShortcutUI()
        FileHandle.standardError.write(Data("Desktop Translate 已启动：在目标应用中按 \(shortcut.display) 翻译前台窗口。\n".utf8))
    }

    @objc private func menuToggle() { toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openShortcutSettings() { showShortcutRecorder() }
    @objc private func openTranslationSettings() {
        if let translationController { translationController.show(); return }
        let target = NSWorkspace.shared.frontmostApplication
        let controller = TranslationSettingsController(current: translationSettings, onSave: { [weak self] candidate in
            guard let self else { return }
            try TranslationSettingsStore(url: self.store.url).save(candidate)
            self.translationSettings = candidate
            self.refreshShortcutUI()
        }, onClose: { [weak self] in
            guard let self else { return }
            self.translationController = nil
            if self.session == nil, NSApp.isActive, let target, !target.isTerminated,
               target.processIdentifier != ProcessInfo.processInfo.processIdentifier { target.activate() }
        })
        translationController = controller
        controller.show()
    }

    // MARK: shortcut

    /// Registers the hotkey through the shared transaction type; persistence is the store (nil store write in smoke modes).
    func installHotkey(initial: Shortcut) throws {
        let backend = try CarbonHotkeyBackend { [weak self] _ in self?.hotkeyPressed() }
        do {
            binder = try ShortcutBinder(backend: backend, initial: initial) { [weak self] value in
                guard let self else { return }
                try self.store.save(value)
            }
        } catch {
            backend.shutdown()
            throw error
        }
        self.backend = backend
    }

    private func hotkeyPressed() {
        pressCount += 1
        if mode != .shortcutSmoke || session != nil { toggle() }
    }

    var shortcutDisplay: String { binder?.current.display ?? Shortcut.defaultShortcut.display }

    func refreshShortcutUI() {
        let display = shortcutDisplay
        let backendLabel = translationSettings.mode == .local ? "本机" : "pi / \(translationSettings.model)"
        translateItem?.title = "翻译前台窗口（\(display) · \(backendLabel)）"
        translationItem?.title = "翻译模式与模型…（\(backendLabel)）"
        statusItem?.button?.toolTip = "CMux Translate：\(display) · \(backendLabel)"
        session?.updateShortcut(display)
    }

    func applyShortcut(_ candidate: Shortcut) throws {
        guard let binder else { throw ShortcutError("快捷键尚未注册。") }
        try binder.apply(candidate)
        refreshShortcutUI()
        FileHandle.standardError.write(Data("快捷键已更改为 \(candidate.display)。\n".utf8))
    }

    @discardableResult
    func showShortcutRecorder() -> ShortcutRecorderController? {
        guard let binder else { return nil }
        if let recorder {
            recorder.show()
            return recorder
        }
        settingsReturnTarget = NSWorkspace.shared.frontmostApplication
        let controller = ShortcutRecorderController(
            current: binder.current,
            apply: { [weak self] in try self?.applyShortcut($0) },
            onClose: { [weak self] in self?.recorderClosed() })
        recorder = controller
        controller.show()
        return controller
    }

    private func recorderClosed() {
        recorder = nil
        let target = settingsReturnTarget
        settingsReturnTarget = nil
        // Hand focus back only if we still own it and no overlay needs it; never activate a stale app.
        if session == nil, NSApp.isActive, let target, !target.isTerminated,
           target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target.activate()
        }
    }

    /// Single entry point for hotkey and menu: dismiss the running session, else translate the frontmost window.
    func toggle() {
        if session != nil { session?.dismiss(reason: nil); return }
        startSession(run: .fullWindow, frontmost: NSWorkspace.shared.frontmostApplication)
    }

    /// The target is the frontmost application at THIS instant (before any UI exists). Never activates anything.
    @discardableResult
    func startSession(run: DesktopRun, frontmost: NSRunningApplication?) -> DesktopTranslationSession {
        session?.dismiss(reason: nil)
        let environment = DesktopTranslationSession.Environment(
            settings: translationSettings, shortcutDisplay: shortcutDisplay, plugin: pluginProvider,
            selectionMemory: selectionMemory,
            onFinished: { [weak self] finished in
                if self?.session === finished { self?.session = nil }
                FileHandle.standardError.write(Data(("会话结束：\(finished.phaseDescription)\n").utf8))
            },
            onPrepareLanguages: { [weak self] in self?.showLanguagePreparation() },
            onLogEvent: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) })
        let created = DesktopTranslationSession(run: run, environment: environment)
        session = created
        created.start(frontmost: frontmost)
        return created
    }

    func dismiss() { session?.dismiss(reason: nil) }

    @objc private func menuRegion() {
        if session != nil { session?.dismiss(reason: nil) }
        // A status-item menu does not activate this accessory app, so the frontmost app is still the user's target.
        startSession(run: .region, frontmost: NSWorkspace.shared.frontmostApplication)
    }

    @objc private func menuPrepareLanguages() { showLanguagePreparation() }

    /// Independent, activatable, target-unbound window; the only place a translation feature may activate this app.
    func showLanguagePreparation() {
        session?.dismiss(reason: nil)
        if let languagePreparation { languagePreparation.show(); return }
        let controller = LanguagePreparationController()
        controller.onClose = { [weak self] in self?.languagePreparation = nil }
        languagePreparation = controller
        controller.show()
    }

    // MARK: --capture (metadata only: never a screenshot, OCR, title or text)

    private func runCapture() async {
        let preflight = await ScreenCapturePermission.preflight()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            emit(["ok": false, "error": "没有前台应用。", "screenRecordingPreflight": preflight]); exit(1)
        }
        switch TargetLocker.lock(app: app) {
        case .failure(let error):
            emit(["ok": false, "error": error.localizedDescription, "screenRecordingPreflight": preflight]); exit(1)
        case .success(let target):
            emit([
                "ok": true,
                "bundleID": target.bundleID ?? "",
                "pid": Int(target.pid),
                "windowID": Int(target.windowID),
                "width": target.frame.width,
                "height": target.frame.height,
                "displays": target.displayIDs.count,
                "builtinPlugin": TerminalPluginRegistry().hasPlugin(for: target),
                "screenRecordingPreflight": preflight,
            ])
            exit(0)
        }
    }

    func smokeFail(_ message: String, _ extra: [String: Any] = [:]) -> Never {
        var result = extra
        result["ok"] = false
        result["error"] = message
        emit(result)
        exit(1)
    }


    /// Verification only: queue a real kEventHotKeyPressed for the active registration so the installed
    /// Carbon handler (not a direct toggle() call) performs the dispatch.
    func postSyntheticHotkey() {
        guard let binder, let backend else { return }
        backend.postSyntheticPress(id: binder.handle.id)
    }

    func settle(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        return condition()
    }
}

@main
struct CMuxTranslateMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains(ChildPermissionProbe.argument) { ChildPermissionProbe.emitAndExit() }
        let arguments = Array(CommandLine.arguments.dropFirst())
        var mode = LaunchMode.normal
        switch arguments.first {
        case nil: break
        case "--help", "-h":
            FileHandle.standardOutput.write(Data(usage.utf8))
            exit(0)
        case "--smoke": mode = .smoke
        case "--shortcut-smoke": mode = .shortcutSmoke
        case "--pi-smoke": mode = .piSmoke
        case "--capture": mode = .capture
        case "--permission-probe": mode = .permissionProbe
        case "--request-screen-recording" where arguments.count == 1: mode = .requestScreenRecording
        case "--child-permission-report": mode = .childPermissionReport
        case "--glyph-smoke": mode = .glyphSmoke
        case "--glyph-pi-smoke": mode = .glyphPiSmoke
        case "--terminal-fixture-smoke": mode = .terminalFixtureSmoke
        case "--terminal-fixture-pi-smoke": mode = .terminalFixturePiSmoke
        default:
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        let app = NSApplication.shared
        if mode == .requestScreenRecording {
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let preflight = await ScreenCapturePermission.preflight()
                let requestReturn: Bool?
                if preflight {
                    requestReturn = nil
                } else {
                    requestReturn = await ScreenCapturePermission.request()
                }
                emit([
                    "commandCompleted": true,
                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
                    "preflight": preflight,
                    "requestInvoked": !preflight,
                    "requestReturn": requestReturn.map { $0 as Any } ?? NSNull(),
                    "screenRecordingMayRequireUserAction": !preflight
                ])
                exit(0) // Completion is not a claim that permission was granted.
            }
            app.run()
            return
        }
        let delegate = AppDelegate(mode: mode)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
