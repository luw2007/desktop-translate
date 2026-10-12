import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI
import Translation

// MARK: - Translation operation (one per overlay presentation)

/// Owns one translation run. Dismissing the overlay cancels it; every async
/// completion re-checks `cancelled`, so a stale result can never resurrect UI.
@MainActor
final class TranslationOperation: ObservableObject {
    enum Phase: Equatable {
        case working
        case done
        case failed
    }

    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "zh-Hans")

    @Published private(set) var phase: Phase = .working
    @Published private(set) var status: String = "正在读取终端…"
    @Published private(set) var output: String = ""
    @Published var configuration: TranslationSession.Configuration?
    private(set) var translatedSegments = 0
    private(set) var isCancelled = false
    private var plan: TranslationPlan?
    private var sessionStarted = false
    private let settings: TranslationSettings
    private let piRunner = PiTranslationRunner()
    private var piTask: Task<Void, Never>?
    @Published var shortcutDisplay: String
    var piIsRunning: Bool { piRunner.isRunning }

    init(shortcutDisplay: String, settings: TranslationSettings) {
        self.settings = settings
        self.shortcutDisplay = shortcutDisplay
    }

    func begin(text: String) {
        guard !isCancelled, plan == nil, phase == .working else { return }
        let plan = TranslationPlan(text: text)
        self.plan = plan
        if plan.requests.isEmpty {
            output = text
            status = "没有需要翻译的英文正文（内容原样显示）"
            phase = .done
            return
        }
        if settings.mode == .pi {
            status = "正在通过 pi 翻译（\(settings.model)）…正文将发送到所选模型服务"
            piTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let translations = try await self.piRunner.translate(requests: plan.requests, settings: self.settings)
                    guard !self.isCancelled else { return }
                    self.translatedSegments = translations.count
                    self.output = plan.rendered(translations: translations)
                    self.status = "翻译完成 · pi / \(self.settings.model)"
                    self.phase = .done
                } catch {
                    guard !self.isCancelled else { return }
                    self.fail("pi 翻译失败：\(error.localizedDescription)")
                }
            }
            return
        }
        status = "正在检查 Apple 本机翻译（英文 → 简体中文）…"
        Task { @MainActor [weak self] in
            let availability = LanguageAvailability()
            let state = await availability.status(from: Self.source, to: Self.target)
            guard let self, !self.isCancelled else { return }
            if state == .unsupported {
                self.fail("此系统的 Apple 本机翻译不支持 英文 → 简体中文。")
                return
            }
            self.status = "正在准备翻译…首次使用若弹出系统窗口，请点击“下载”以安装中文语言包（仅本机翻译，不上传文字）"
            self.configuration = TranslationSession.Configuration(source: Self.source, target: Self.target)
        }
    }

    func fail(_ message: String) {
        guard !isCancelled else { return }
        output = message
        status = message
        phase = .failed
    }

    func cancel() {
        isCancelled = true
        configuration = nil
        piTask?.cancel()
        piRunner.cancel()
        piTask = nil
    }

    /// Runs inside SwiftUI's `translationTask`; the session is only valid while the host view lives.
    func run(_ session: TranslationSession) async {
        guard !isCancelled, !sessionStarted, let plan, phase == .working else { return }
        sessionStarted = true
        do {
            // Translation itself presents download approval. Avoid a separate preparation
            // sheet racing the translation sheet while newly approved assets finish installing.
            status = "正在翻译…首次使用若弹出系统窗口，请允许下载英中语言包"
            let requests = plan.requests.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
            }
            let responses = try await session.translations(from: requests)
            guard !isCancelled else { return }
            var translations: [String: String] = [:]
            for response in responses {
                if let id = response.clientIdentifier { translations[id] = response.targetText }
            }
            guard requests.allSatisfy({ translations[$0.clientIdentifier ?? ""] != nil }) else {
                fail("翻译失败：Apple 翻译返回的结果不完整，请重试。")
                return
            }
            translatedSegments = translations.count
            output = plan.rendered(translations: translations)
            status = "翻译完成"
            phase = .done
        } catch {
            guard !isCancelled else { return }
            let detail = error as NSError
            fail("翻译失败：\(error.localizedDescription)（\(detail.domain):\(detail.code)）\n若语言包尚未安装，请在系统窗口允许下载；安装完成后再按快捷键重试。")
        }
    }
}

// MARK: - Overlay UI

private struct OverlayStatusBar: View {
    @ObservedObject var operation: TranslationOperation

    var body: some View {
        HStack(spacing: 10) {
            switch operation.phase {
            case .working:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            }
            Text(operation.status)
                .font(.system(size: 13))
                .lineLimit(2)
                .foregroundColor(operation.phase == .failed ? .red : .primary)
            Spacer(minLength: 12)
            Text("Esc / \(operation.shortcutDisplay) 关闭")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
        .background(Color(nsColor: .windowBackgroundColor))
        // Host of the Apple Translation session; deliberately visible so the first-use
        // language-download approval sheet attaches to a user-visible window.
        .translationTask(operation.configuration) { session in
            await operation.run(session)
        }
    }
}

final class OverlayWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }

    // Unhandled keys end here: never beep, never forward anywhere.
    override func keyDown(with event: NSEvent) {}
}

@MainActor
final class OverlayController {
    let window: OverlayWindow
    let operation: TranslationOperation
    private let textView: NSTextView
    private var subscription: AnyCancellable?

    init(frame: CGRect, operation: TranslationOperation, onEscape: @escaping () -> Void) {
        self.operation = operation
        window = OverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.onEscape = onEscape
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.title = "CMux Translate"

        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        guard let text = scroll.documentView as? NSTextView else { fatalError("scrollableTextView without NSTextView") }
        textView = text
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 24, height: 18)
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let bar = NSHostingView(rootView: OverlayStatusBar(operation: operation))
        bar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.addSubview(scroll)
        content.addSubview(bar)
        content.addSubview(separator)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 48),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setFrame(frame, display: true)
        window.initialFirstResponder = text

        subscription = Publishers.CombineLatest(operation.$phase, operation.$output).sink { [weak self] phase, output in
            self?.render(phase: phase, output: output)
        }
    }

    private func render(phase: TranslationOperation.Phase, output: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: phase == .failed ? NSColor.systemRed : NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: output, attributes: attributes))
        textView.scrollToBeginningOfDocument(nil)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func teardown() {
        subscription = nil
        operation.cancel()
        window.orderOut(nil)
        window.contentView = nil
    }

    /// Renders the real overlay view hierarchy to PNG (no Screen Recording permission involved).
    func snapshotPNG() -> Data? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - App delegate

enum LaunchMode {
    case normal
    case smoke
    case capture
    case piSmoke
    case shortcutSmoke
}

private let usage = """
用法: cmux-translate-app [选项]
  （无参数）         常驻后台，快捷键（默认 ⌃⌥T）翻译当前 cmux 终端屏幕；再按快捷键或 Esc 返回终端
                     菜单栏“译” → “设置快捷键…”：直接按下新组合，保存后立即生效并持久化到
                     $XDG_CONFIG_HOME/cmux-translate/config.json（默认 ~/.config/cmux-translate/config.json）
                     格式: {"shortcut":{"keyCode":17,"modifiers":["control","option"]}}
                     keyCode 为 macOS 物理按键码；modifiers 取 control/option/shift/command，至少含 control/option/command 之一；
                     可用键: 字母、数字、F1–F12、方向键、Home/End/PageUp/PageDown、空格；Esc 保留。配置无效时启动失败（退出码 5）
                     菜单栏“翻译模式与模型…”选择 Apple 本机（默认）或 pi 无头模式，配置 pi 可执行文件和 provider/model。
                     pi 模式将正文发给所选模型服务，无工具/历史会话，空 system prompt。
  --smoke            真实冒烟（始终使用默认 ⌃⌥T，不读写用户配置）：读取终端快照（仅计数）、显示覆盖层、Apple 本机翻译、截图、关闭，输出 JSON
  --pi-smoke         使用 pi 翻译公共示例并验证同一覆盖层生命周期；默认 deepseek/deepseek-flash（可用 CMUX_TRANSLATE_PI_MODEL/EXECUTABLE 覆盖）
  --shortcut-smoke   真实快捷键设置冒烟：临时配置目录内走录制窗口、保存、撞键回滚、写盘失败回滚、恢复，输出 JSON 和截图；不碰用户配置
  --capture          只输出当前 cmux 终端快照的元数据（不含内容）
  --help             显示本说明

"""

func emit(_ object: [String: Any], to handle: FileHandle = .standardOutput) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    handle.write(data + Data("\n".utf8))
}

private func containsChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let bundleIdentifier = "local.cmux.translate"
    static let smokeText = "The deployment completed successfully. Please review the configuration before restarting the service.\nRun `npm test` to verify the changes.\n"

    private let mode: LaunchMode
    private(set) var backend: CarbonHotkeyBackend?
    private(set) var binder: ShortcutBinder<CarbonHotkeyBackend>?
    var store = ShortcutStore(url: ShortcutStore.standardURL())
    private var translationSettings = TranslationSettings.defaults
    private var translationController: TranslationSettingsController?
    private var translationItem: NSMenuItem?
    private(set) var recorder: ShortcutRecorderController?
    private(set) var pressCount = 0
    private var translateItem: NSMenuItem?
    private var settingsReturnTarget: NSRunningApplication?
    private var statusItem: NSStatusItem?
    private var overlay: OverlayController?
    private var generation = 0
    private var returnTarget: NSRunningApplication?

    init(mode: LaunchMode) {
        self.mode = mode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch mode {
        case .normal: startNormal()
        case .capture: Task { await runCapture() }
        case .smoke, .piSmoke: Task { await runSmoke() }
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
        item.button?.title = "译"
        let menu = NSMenu()
        let translate = NSMenuItem(title: "", action: #selector(menuToggle), keyEquivalent: "")
        translate.target = self
        menu.addItem(translate)
        translateItem = translate
        let settings = NSMenuItem(title: "设置快捷键…", action: #selector(openShortcutSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let translation = NSMenuItem(title: "", action: #selector(openTranslationSettings), keyEquivalent: "")
        translation.target = self
        menu.addItem(translation)
        translationItem = translation
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 CMux Translate", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        refreshShortcutUI()
        FileHandle.standardError.write(Data("CMux Translate 已启动：在 cmux 中按 \(shortcut.display) 翻译当前终端。\n".utf8))
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
            if self.overlay == nil, NSApp.isActive, let target, !target.isTerminated,
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
        if mode != .shortcutSmoke || overlay != nil { toggle() }
    }

    var shortcutDisplay: String { binder?.current.display ?? Shortcut.defaultShortcut.display }

    func refreshShortcutUI() {
        let display = shortcutDisplay
        let backendLabel = translationSettings.mode == .local ? "本机" : "pi / \(translationSettings.model)"
        translateItem?.title = "翻译当前终端（\(display) · \(backendLabel)）"
        translationItem?.title = "翻译模式与模型…（\(backendLabel)）"
        statusItem?.button?.toolTip = "CMux Translate：\(display) · \(backendLabel)"
        overlay?.operation.shortcutDisplay = display
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
        if overlay == nil, NSApp.isActive, let target, !target.isTerminated,
           target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target.activate()
        }
    }

    /// Single entry point for hotkey, menu and smoke: dismiss if showing, else present the active cmux terminal.
    func toggle() {
        if overlay != nil {
            dismiss()
            return
        }
        guard CmuxCapture.isCmuxFrontmost() else { return }
        let frame = (try? CmuxCapture.frontmostBounds()) ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        generation += 1
        let token = generation
        returnTarget = NSWorkspace.shared.frontmostApplication
        let controller = present(frame: frame)
        Task { @MainActor [weak self] in
            do {
                let snapshot = try await CmuxCapture.snapshot()
                guard let self, self.generation == token, self.overlay === controller else { return }
                controller.operation.begin(text: snapshot.text)
            } catch {
                guard let self, self.generation == token, self.overlay === controller else { return }
                controller.operation.fail(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func present(frame: CGRect) -> OverlayController {
        let controller = OverlayController(frame: frame, operation: TranslationOperation(shortcutDisplay: shortcutDisplay, settings: translationSettings)) { [weak self] in self?.dismiss() }
        overlay = controller
        controller.show()
        return controller
    }

    func dismiss() {
        generation += 1
        guard let controller = overlay else { return }
        overlay = nil
        controller.teardown()
        let target = returnTarget
        returnTarget = nil
        // Only hand focus back if we still own it; never steal it from another app.
        if NSApp.isActive, let target, !target.isTerminated {
            target.activate()
        }
    }

    // MARK: --capture

    private func runCapture() async {
        do {
            let snapshot = try await CmuxCapture.snapshot()
            emit([
                "ok": true,
                "characters": snapshot.text.count,
                "lines": snapshot.text.split(separator: "\n", omittingEmptySubsequences: false).count,
                "workspace": snapshot.workspace,
                "surface": snapshot.surface,
                "window": snapshot.window,
            ])
            exit(0)
        } catch {
            emit(["ok": false, "error": error.localizedDescription])
            exit(1)
        }
    }

    // MARK: --smoke

    func smokeFail(_ message: String, _ extra: [String: Any] = [:]) -> Never {
        var result = extra
        result["ok"] = false
        result["error"] = message
        emit(result)
        exit(1)
    }

    private func runSmoke() async {
        if mode == .piSmoke {
            translationSettings.mode = .pi
            if let model = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_PI_MODEL"] { translationSettings.model = model }
            if let executable = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_PI_EXECUTABLE"] { translationSettings.piExecutable = executable }
        }
        let snapshot: TerminalSnapshot
        do { snapshot = try await CmuxCapture.snapshot() } catch { smokeFail("捕获失败：\(error.localizedDescription)") }
        var result: [String: Any] = [
            "capture": [
                "characters": snapshot.text.count,
                "lines": snapshot.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            ],
        ]
        let plan = TranslationPlan(text: Self.smokeText)
        result["requests"] = plan.requests.count
        result["backend"] = translationSettings.mode.rawValue
        if translationSettings.mode == .pi { result["model"] = translationSettings.model }
        let started = Date()
        let frame = (try? CmuxCapture.frontmostBounds()) ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        generation += 1
        returnTarget = NSWorkspace.shared.frontmostApplication
        let controller = present(frame: frame)
        controller.operation.begin(text: Self.smokeText)

        // First-use language download approval needs a human; allow generous time.
        let deadline = Date().addingTimeInterval(300)
        while controller.operation.phase == .working && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        result["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        switch controller.operation.phase {
        case .working:
            dismiss()
            smokeFail("翻译超时：可能在等待语言包下载授权。", result)
        case .failed:
            let message = controller.operation.output
            dismiss()
            smokeFail(message, result)
        case .done:
            break
        }
        let output = controller.operation.output
        let hasChinese = containsChinese(output)
        let codePreserved = output.contains("`npm test`")
        result["hasChinese"] = hasChinese
        result["inlineCodePreserved"] = codePreserved
        result["translatedSegments"] = controller.operation.translatedSegments
        result["overlayVisible"] = controller.window.isVisible
        result["overlayOpaque"] = controller.window.isOpaque
        result["overlayFrame"] = NSStringFromRect(controller.window.frame)

        // Let the final text render, then capture the real view hierarchy.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/cmux-translate", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(mode == .piSmoke ? "pi-smoke-overlay.png" : "smoke-overlay.png")
        if let png = controller.snapshotPNG(), (try? png.write(to: path)) != nil {
            result["screenshot"] = path.path
        } else {
            smokeFail("无法渲染覆盖层截图。", result)
        }

        // Lifecycle: the real Carbon hotkey handler must dismiss the overlay, a rapid reopen/close must not
        // resurrect it, and Esc must dismiss through OverlayWindow.sendEvent. Internal events only.
        let operation = controller.operation
        var hotkeyError: String?
        do { try installHotkey(initial: .defaultShortcut) } catch { hotkeyError = "\(error)" }
        let hotkeyRegistered = binder != nil
        result["hotkeyRegistered"] = hotkeyRegistered
        if let hotkeyError { result["hotkeyError"] = hotkeyError }
        result["hintsDefault"] = controller.operation.shortcutDisplay == "⌃⌥T"

        var hotkeyDismissed = false
        if hotkeyRegistered {
            postSyntheticHotkey()
            hotkeyDismissed = await settle { self.overlay == nil } && operation.isCancelled && !controller.window.isVisible
        }
        result["hotkeyDismissed"] = hotkeyDismissed
        if overlay != nil { dismiss() }

        var cancelledWithoutResurrection = false
        if hotkeyRegistered {
            let second = present(frame: frame)
            second.operation.begin(text: Self.smokeText)
            if mode == .piSmoke {
                result["cancelProcessStarted"] = await settle(timeout: 5) { second.operation.piIsRunning }
            }
            postSyntheticHotkey()
            let closed = await settle { self.overlay == nil }
            try? await Task.sleep(nanoseconds: 1_500_000_000) // let the cancelled translation task and callbacks run
            if mode == .piSmoke {
                result["cancelProcessStopped"] = await settle(timeout: 5) { !second.operation.piIsRunning }
            }
            let anyVisible = NSApp.windows.contains { $0 is OverlayWindow && $0.isVisible }
            cancelledWithoutResurrection = closed && overlay == nil && second.operation.isCancelled
                && second.operation.phase == .working && !second.window.isVisible && !anyVisible
        }
        result["cancelledWithoutResurrection"] = cancelledWithoutResurrection
        if overlay != nil { dismiss() }

        let third = present(frame: frame)
        var escapeDismissed = false
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: third.window.windowNumber, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)) {
            third.window.sendEvent(escape)
            escapeDismissed = overlay == nil && third.operation.isCancelled && !third.window.isVisible
        }
        result["escapeDismissed"] = escapeDismissed
        if mode == .piSmoke, result["cancelProcessStarted"] as? Bool != true || result["cancelProcessStopped"] as? Bool != true {
            smokeFail("pi 子进程取消验证失败。", result)
        }
        if overlay != nil { dismiss() }
        binder?.shutdown()
        backend?.shutdown()
        binder = nil
        backend = nil

        let dismissed = hotkeyDismissed
        result["dismissed"] = dismissed
        guard hasChinese, codePreserved, controller.window.isOpaque, hotkeyRegistered, hotkeyDismissed,
              cancelledWithoutResurrection, escapeDismissed else {
            smokeFail("冒烟断言失败。", result)
        }
        result["ok"] = true
        emit(result)
        exit(0)
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
        default:
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(mode: mode)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
