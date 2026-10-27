import AppKit
import Foundation

/// Escape cancels, like the shortcut recorder; everything else is a normal titled window.
final class TranslationSettingsWindow: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Translation backend settings. `onSave` receives validated settings and persists/applies them; if it throws,
/// the window stays open and shows the error. The window never touches the config file itself.
/// The model list is pi's own `get_available_models` (no model request), refreshed asynchronously with a bounded,
/// cancellable task; results of a superseded refresh are ignored. A saved model that pi no longer offers (or that
/// cannot take images in image mode) stays visible and labelled; it is never silently replaced.
/// The language-pack row shows the availability of the pair currently selected in the popups (local mode only) and
/// opens the same pair-aware preparation flow the session HUD offers. Pack checks are read-only: nothing is ever
/// installed from here without the user pressing the button and confirming Apple's own sheet.
@MainActor
final class TranslationSettingsController: NSObject {
    /// Read-only availability query for a pair. Injectable so checks can script every state without touching
    /// Apple's real pack database; production always uses `LanguagePreflight`.
    typealias PackCheck = @MainActor (TranslationSettings) async -> LanguagePackState
    typealias Discover = (TranslationSettings) async throws -> [PiModel]

    let window: NSWindow
    private let settingsWindow: TranslationSettingsWindow
    private(set) var current: TranslationSettings
    private let onSave: (TranslationSettings) throws -> Void
    private let onClose: () -> Void
    let discover: Discover
    /// Opens the pair-aware preparation window for the pair the popups currently select (local mode).
    var onPrepareLanguages: ((source: String, target: String)?) -> Void = { _ in }
    var onConfigureShortcut: (() -> Void)?
    var onSetDebugRegions: ((Bool) throws -> Void)?
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let shortcutButton = NSButton(title: "更改…", target: nil, action: nil)
    private let debugCheckbox = NSButton(checkboxWithTitle: "显示识别区域", target: nil, action: nil)
    private let packCheck: PackCheck

    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let executableField = NSTextField(string: "")
    let inputModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let refreshButton = NSButton(title: "刷新模型", target: nil, action: nil)
    let saveButton = NSButton(title: "保存", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var messageIsError = false
    var closed = false

    /// nil = not (successfully) discovered; otherwise the last accepted snapshot.
    internal(set) var discovered: [PiModel]?
    internal(set) var discoveryInFlight = false
    var discoveryTask: Task<Void, Never>?
    var discoveryGeneration = 0
    let packStatusLabel = NSTextField(wrappingLabelWithString: "")
    let packButton = NSButton(title: "准备语言包…", target: nil, action: nil)
    /// Whether the pack row is hidden, i.e. the window is in pi mode where no local pack is involved.
    var packRowHidden: Bool { packRowContainer?.isHidden ?? true }
    /// Availability of the pair currently shown in the popups. nil = no answer yet (check in flight, or pi mode).
    private(set) var packState: LanguagePackState?
    private(set) var packChecking = false
    /// Row holding the pack status and its button; hidden in pi mode, where no local pack is involved.
    private var packRowContainer: NSStackView?
    private var packGeneration = 0
    private var packTask: Task<Void, Never>?
    /// provider/id the popup currently selects. Survives list rebuilds; only a user choice changes it.
    var selectedModel: String

    static let localTitle = "本地（Apple 翻译）"
    static let piTitle = "pi（无头模型）"
    static let textTitle = "OCR 文字 → pi"
    static let imageTitle = "截图 → pi（图像输入）"
    static let textNotice = "选择 pi 的“OCR 文字”后，本机 Vision 识别出的文字会作为纯文本发送给所选模型的 provider；翻译请求按无工具方式发起，不加载 pi 用户扩展。"
    static let imageNotice = "选择 pi 的“截图”后，每次翻译时所选区域的完整截图（你框选或捕获的那块窗口图像，包含其中可见的一切，可能有密码或私人信息）会作为图像发送给所选模型的 provider，不经过本机 OCR；译文位置由模型给出，未经原生或 OCR 验证。请求按无工具方式发起，不加载 pi 用户扩展。仅可选择 pi 声明支持图像输入的模型。"
    static func notice(for mode: PiInputMode) -> String { mode == .image ? imageNotice : textNotice }

    init(current: TranslationSettings, onSave: @escaping (TranslationSettings) throws -> Void, onClose: @escaping () -> Void,
         discover: @escaping Discover = { try await PiTranslationRunner.discoverModels(settings: $0) },
         packCheck: @escaping PackCheck = { await LanguagePreflight.packState(for: $0) }) {
        self.current = current
        self.onSave = onSave
        self.onClose = onClose
        self.discover = discover
        selectedModel = current.model
        self.packCheck = packCheck
        settingsWindow = TranslationSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                                   styleMask: [.titled], backing: .buffered, defer: false)
        window = settingsWindow
        super.init()
        build()
        load(current)
    }

    var message: String { messageLabel.stringValue }
    var notice: String { noticeLabel.stringValue }
    var selectedMode: TranslationMode { TranslationMode.allCases[max(0, modePopup.indexOfSelectedItem)] }
    var selectedInputMode: PiInputMode { PiInputMode.allCases[max(0, inputModePopup.indexOfSelectedItem)] }
    var selectedModelIdentifier: String { selectedModel }
    /// `TranslationLanguages.auto` or a language code; popups are index-aligned with `sourceCodes` / `targetCodes`.
    static let sourceCodes = [TranslationLanguages.auto] + TranslationLanguages.all.map(\.code)
    static let targetCodes = TranslationLanguages.all.map(\.code)
    var selectedSourceLanguage: String { Self.sourceCodes[max(0, sourcePopup.indexOfSelectedItem)] }
    var selectedTargetLanguage: String { Self.targetCodes[max(0, targetPopup.indexOfSelectedItem)] }

    // MARK: Build

    private func build() {
        settingsWindow.title = "设置"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.level = .floating
        settingsWindow.onCancel = { [weak self] in self?.cancel() }

        let heading = NSTextField(labelWithString: "翻译后端")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let generalHeading = NSTextField(labelWithString: "通用")
        generalHeading.font = heading.font
        shortcutLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        shortcutButton.target = self
        shortcutButton.action = #selector(configureShortcut)
        shortcutButton.bezelStyle = .rounded
        let shortcutRow = NSStackView(views: [shortcutLabel, shortcutButton])
        shortcutRow.spacing = 12
        debugCheckbox.target = self
        debugCheckbox.action = #selector(changeDebugRegions)
        let generalNotice = NSTextField(labelWithString: "快捷键和调试独立保存；调试更改对下一次翻译生效。")
        generalNotice.font = .systemFont(ofSize: 11)
        generalNotice.textColor = .secondaryLabelColor

        modePopup.addItems(withTitles: TranslationMode.allCases.map { $0 == .local ? Self.localTitle : Self.piTitle })
        modePopup.target = self
        modePopup.action = #selector(modeChanged)

        inputModePopup.addItems(withTitles: PiInputMode.allCases.map { $0 == .ocrText ? Self.textTitle : Self.imageTitle })
        inputModePopup.target = self
        inputModePopup.action = #selector(inputModeChanged)

        sourcePopup.addItems(withTitles: Self.sourceCodes.map { TranslationLanguages.name($0) })
        targetPopup.addItems(withTitles: Self.targetCodes.map { TranslationLanguages.name($0) })
        sourcePopup.target = self
        sourcePopup.action = #selector(languagePairChanged)
        targetPopup.target = self
        targetPopup.action = #selector(languagePairChanged)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.translatesAutoresizingMaskIntoConstraints = false
        modelPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        refreshButton.target = self
        refreshButton.action = #selector(refreshModels)
        refreshButton.bezelStyle = .rounded
        let modelRow = NSStackView(views: [modelPopup, refreshButton])
        modelRow.spacing = 8

        executableField.placeholderString = "pi 或 /opt/homebrew/bin/pi"
        executableField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        executableField.translatesAutoresizingMaskIntoConstraints = false
        executableField.widthAnchor.constraint(equalToConstant: 330).isActive = true

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.maximumNumberOfLines = 8

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 3

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.spacing = 10

        func row(_ title: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            let stack = NSStackView(views: [label, control])
            stack.spacing = 8
            return stack
        }
        packStatusLabel.font = .systemFont(ofSize: 11)
        packStatusLabel.textColor = .secondaryLabelColor
        packStatusLabel.maximumNumberOfLines = 3
        packStatusLabel.widthAnchor.constraint(equalToConstant: 380).isActive = true
        packButton.target = self
        packButton.action = #selector(prepareLanguages)
        packButton.bezelStyle = .rounded
        let packRow = NSStackView(views: [packStatusLabel, packButton])
        packRow.orientation = .vertical
        packRow.alignment = .leading
        packRow.spacing = 6
        let languagePackRow = row("语言包", packRow)
        packRowContainer = languagePackRow

        let stack = NSStackView(views: [generalHeading, row("快捷键", shortcutRow), row("调试", debugCheckbox), generalNotice,
                                        heading, row("从", sourcePopup), row("译成", targetPopup), languagePackRow,
                                        row("引擎", modePopup), row("pi 可执行", executableField),
                                        row("输入", inputModePopup), row("模型", modelRow), noticeLabel, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setHuggingPriority(.required, for: .vertical)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel.widthAnchor.constraint(equalToConstant: 480).isActive = true
        messageLabel.widthAnchor.constraint(equalToConstant: 480).isActive = true
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
    }

    func updateGeneralSettings(shortcut: String, showRegions: Bool) {
        shortcutLabel.stringValue = shortcut
        debugCheckbox.state = showRegions ? .on : .off
    }

    @objc private func configureShortcut() { onConfigureShortcut?() }

    @objc private func changeDebugRegions() {
        let enabled = debugCheckbox.state == .on
        do {
            try onSetDebugRegions?(enabled)
        } catch {
            debugCheckbox.state = enabled ? .off : .on
            setMessage("无法保存调试设置：\((error as? ShortcutError)?.message ?? error.localizedDescription)", error: true)
        }
    }

    func load(_ settings: TranslationSettings) {
        cancelDiscovery()
        discovered = nil
        selectedModel = settings.model
        modePopup.selectItem(at: TranslationMode.allCases.firstIndex(of: settings.mode) ?? 0)
        inputModePopup.selectItem(at: PiInputMode.allCases.firstIndex(of: settings.inputMode) ?? 0)
        sourcePopup.selectItem(at: Self.sourceCodes.firstIndex(of: settings.sourceLanguage) ?? 0)
        targetPopup.selectItem(at: Self.targetCodes.firstIndex(of: settings.targetLanguage) ?? 0)
        executableField.stringValue = settings.piExecutable
        rebuildModelPopup()
        refreshPackState()
        applyModeState()
        setMessage("“保存”后新的翻译立即使用所选后端；正在进行的翻译不受影响。", error: false)
    }

    func applyModeState() {
        let piSelected = selectedMode == .pi
        executableField.isEnabled = piSelected
        inputModePopup.isEnabled = piSelected
        refreshButton.isEnabled = piSelected && !discoveryInFlight
        rebuildModelPopup()
        // The pack row is a local-mode concept; in pi mode nothing local is prepared.
        packRowContainer?.isHidden = piSelected
        // The disclosure shown before capture is always the one for the CURRENTLY selected input mode.
        noticeLabel.stringValue = piSelected ? Self.notice(for: selectedInputMode) : "本地模式使用 Apple 设备端翻译，文字不会离开本机。"
    }

    func setMessage(_ text: String, error: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
        messageIsError = error
    }

    // MARK: Language pack

    /// Settings as currently entered, in local mode: what the pack row describes. The disabled pi fields only count
    /// when valid, so a stale invalid edit can never change which pair is checked.
    private var displayedPairSettings: TranslationSettings {
        let candidate = TranslationSettings(mode: .local, piExecutable: executableField.stringValue, model: selectedModel,
                                            inputMode: selectedInputMode, sourceLanguage: selectedSourceLanguage,
                                            targetLanguage: selectedTargetLanguage)
        guard let valid = try? candidate.validated() else {
            return TranslationSettings(mode: .local, piExecutable: current.piExecutable, model: current.model,
                                       inputMode: current.inputMode, sourceLanguage: selectedSourceLanguage,
                                       targetLanguage: selectedTargetLanguage)
        }
        return valid
    }

    /// Local mode only; the pair is checked exactly as the popups show it, including the not-yet-saved selection.
    @objc func prepareLanguages() {
        let settings = displayedPairSettings
        onPrepareLanguages(settings.isAutoSource ? nil : (settings.sourceLanguage, settings.targetLanguage))
    }

    /// Re-reads the pack state of the selected pair. Pi mode hides the row entirely: no local pack is involved.
    /// Superseded checks are ignored, and every answer is read-only.
    func refreshPackState() {
        packTask?.cancel()
        packTask = nil
        packGeneration += 1
        guard selectedMode == .local else {
            packState = nil
            packChecking = false
            applyPackState()
            return
        }
        let generation = packGeneration
        let settings = displayedPairSettings
        let check = packCheck
        packState = nil
        packChecking = true
        applyPackState()
        packTask = Task { @MainActor [weak self] in
            let state = await check(settings)
            guard let self, !Task.isCancelled, generation == self.packGeneration, !self.closed else { return }
            self.packChecking = false
            self.packState = state
            self.applyPackState()
        }
    }

    /// Row text and button enablement for the current pair. The button opens the real preparation window, which
    /// performs Apple's own download approval; nothing is installed automatically from here.
    private func applyPackState() {
        let pair = "\(TranslationLanguages.name(selectedSourceLanguage))→\(TranslationLanguages.name(selectedTargetLanguage))"
        let text: String
        var canPrepare = false
        switch packState {
        case .none:
            text = packChecking ? "正在检查 \(pair) 的本机语言包…" : "本机语言包状态未检查。"
            canPrepare = !packChecking
        case .some(.installed):
            text = "\(pair) 语言包已安装，可直接翻译。"
        case .some(.needsInstall):
            text = "\(pair) 语言包尚未安装，翻译前需要先准备。"
            canPrepare = true
        case .some(.unsupported):
            text = "此系统的 Apple 本机翻译不支持 \(pair)，无法准备语言包。"
        case .some(.samePair):
            text = "源语言与目标语言相同，无需语言包。"
        case .some(.autoDetectPending):
            text = "源语言为“自动检测”：语言包按翻译时识别出的语言检查，无法提前确定。"
            canPrepare = true
        case .some(.autoTargetUnsupported):
            text = "此系统的 Apple 本机翻译不支持目标语言 \(TranslationLanguages.name(selectedTargetLanguage))。"
        }
        packStatusLabel.stringValue = text
        packButton.isEnabled = canPrepare && !packChecking
    }

    /// A pair change re-reads pack availability for the newly selected pair; nothing is installed.
    @objc func languagePairChanged() { refreshPackState() }

    /// Settings as currently entered. In local mode the (disabled) pi fields only count if they are valid;
    /// otherwise the previously saved pi values are kept so a stale invalid edit cannot block switching to local.
    private func entered() throws -> TranslationSettings {
        window.endEditing(for: nil)
        let mode = selectedMode
        let candidate = TranslationSettings(mode: mode, piExecutable: executableField.stringValue, model: selectedModel,
                                            inputMode: selectedInputMode, sourceLanguage: selectedSourceLanguage, targetLanguage: selectedTargetLanguage)
        if selectedSourceLanguage == selectedTargetLanguage { throw ShortcutError("源语言与目标语言不能相同。") }
        if mode == .pi {
            let valid = try candidate.validated()
            if valid.inputMode == .image {
                guard valid.modelIdentity != nil else { throw ShortcutError("图像模式需要 provider/id 形式的 pi 模型。") }
                if let problem = imageModeProblem(for: valid.model) { throw ShortcutError(problem) }
            }
            return valid
        }
        if let valid = try? candidate.validated() { return valid }
        return TranslationSettings(mode: .local, piExecutable: current.piExecutable, model: current.model, inputMode: current.inputMode,
                                   sourceLanguage: selectedSourceLanguage, targetLanguage: selectedTargetLanguage)
    }

    @objc func save() {
        do {
            let settings = try entered()
            try onSave(settings)
            current = settings
            close()
        } catch {
            setMessage((error as? ShortcutError)?.message ?? error.localizedDescription, error: true)
        }
    }

    @objc func cancel() { close() }

    func close() {
        guard !closed else { return }
        closed = true
        cancelDiscovery()
        packTask?.cancel()
        packTask = nil
        packGeneration += 1
        window.orderOut(nil)
        onClose()
    }

    func snapshotPNG() -> Data? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
