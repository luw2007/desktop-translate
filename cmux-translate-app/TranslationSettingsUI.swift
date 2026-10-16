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
    private let discover: Discover
    /// Opens the pair-aware preparation window for the pair the popups currently select (local mode).
    var onPrepareLanguages: ((source: String, target: String)?) -> Void = { _ in }
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
    private var closed = false

    /// nil = not (successfully) discovered; otherwise the last accepted snapshot.
    private(set) var discovered: [PiModel]?
    private(set) var discoveryInFlight = false
    private var discoveryTask: Task<Void, Never>?
    private var discoveryGeneration = 0
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
    private var selectedModel: String

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
        settingsWindow = TranslationSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
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
        settingsWindow.title = "翻译设置"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.level = .floating
        settingsWindow.onCancel = { [weak self] in self?.cancel() }

        let heading = NSTextField(labelWithString: "翻译后端")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

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
        packRowContainer = packRow

        let stack = NSStackView(views: [heading, row("从", sourcePopup), row("译成", targetPopup), row("语言包", packRow),
                                        row("引擎", modePopup), row("pi 可执行", executableField),
                                        row("输入", inputModePopup), row("模型", modelRow), noticeLabel, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
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
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
    }

    private func load(_ settings: TranslationSettings) {
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

    private func applyModeState() {
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

    private func setMessage(_ text: String, error: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
        messageIsError = error
    }

    // MARK: Model list

    /// Items: the selected model first when pi does not (or cannot yet) vouch for it, then pi's real models.
    /// In image mode only models whose pi metadata declares image input are choosable; a saved text-only choice stays
    /// visible but disabled and labelled. Nothing here infers capability from a model name.
    private func rebuildModelPopup() {
        let imageMode = selectedInputMode == .image
        modelPopup.removeAllItems()
        let models = discovered ?? []
        let known = Set(models.map(\.identifier))
        func add(_ title: String, identifier: String, enabled: Bool) {
            modelPopup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let item = modelPopup.lastItem
            item?.representedObject = identifier
            item?.isEnabled = enabled
        }
        if !selectedModel.isEmpty, !known.contains(selectedModel) {
            let note = discovered == nil ? "（未验证，点“刷新模型”）" : "（pi 当前不可用）"
            add(selectedModel + note, identifier: selectedModel, enabled: true)
        }
        for model in models {
            if imageMode && !model.acceptsImages {
                // Visible only when it is the saved/selected choice, so it is never silently dropped or replaced.
                if model.identifier == selectedModel { add(model.identifier + "（不支持图像输入）", identifier: model.identifier, enabled: false) }
                continue
            }
            add(model.identifier, identifier: model.identifier, enabled: true)
        }
        if let index = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedModel }) {
            modelPopup.selectItem(at: index)
        }
        modelPopup.isEnabled = selectedMode == .pi
    }

    /// Image-mode problem with the selected model, if pi has told us enough to know. nil = no known problem.
    private func imageModeProblem(for identifier: String) -> String? {
        guard selectedMode == .pi, selectedInputMode == .image, let discovered else { return nil }
        guard let model = discovered.first(where: { $0.identifier == identifier }) else { return "所选模型不在 pi 当前可用模型中，请重新选择。" }
        return model.acceptsImages ? nil : "所选模型不支持图像输入，请选择支持图像的模型或改用“OCR 文字”。"
    }

    private func cancelDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryGeneration += 1
        discoveryInFlight = false
    }

    /// Bounded (the transport has a 20 s timeout and output cap), cancellable, stale results ignored.
    func refreshModelList() {
        guard selectedMode == .pi else { return }
        discoveryTask?.cancel()
        discoveryGeneration += 1
        let generation = discoveryGeneration
        // Discovery does not depend on the language pair; keep it valid even while the pair is mid-edit.
        let settings = TranslationSettings(mode: .pi, piExecutable: executableField.stringValue, model: selectedModel,
                                           inputMode: selectedInputMode)
        discoveryInFlight = true
        refreshButton.isEnabled = false
        setMessage("正在读取 pi 当前可用的模型…", error: false)
        let discover = self.discover
        discoveryTask = Task { @MainActor [weak self] in
            let result: Result<[PiModel], Error>
            do { result = .success(try await discover(settings)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, generation == self.discoveryGeneration, !self.closed else { return }
            self.discoveryInFlight = false
            self.refreshButton.isEnabled = self.selectedMode == .pi
            switch result {
            case .success(let models):
                self.discovered = models
                self.rebuildModelPopup()
                let problem = self.imageModeProblem(for: self.selectedModel)
                self.setMessage(problem ?? "已读取 \(models.count) 个 pi 可用模型。", error: problem != nil)
            case .failure(let error):
                self.discovered = nil
                self.rebuildModelPopup()
                self.setMessage("无法读取 pi 模型列表：\((error as? PiTranslationError)?.message ?? "未知错误")（已保存的选择未改变）", error: true)
            }
        }
    }

    // MARK: Actions

    /// Shows the latest saved settings, discarding unsaved edits, then refreshes the model list in the background.
    func show() {
        closed = false
        load(current)                 // also re-reads the pack state for the loaded pair
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if current.mode == .pi { refreshModelList() }
    }

    @objc func modeChanged() {
        applyModeState()
        if selectedMode == .pi {
            setMessage("配置 pi 可执行文件、输入方式与模型；保存后下一次翻译生效。", error: false)
            if discovered == nil { refreshModelList() }
        } else {
            cancelDiscovery()
            setMessage("本地模式使用 Apple 设备端翻译，文字不会离开本机。", error: false)
        }
        refreshPackState()
    }

    @objc func inputModeChanged() {
        applyModeState()
        let problem = imageModeProblem(for: selectedModel)
        setMessage(problem ?? (selectedInputMode == .image ? "图像模式：翻译时所选区域截图会发送给模型。" : "OCR 文字模式：只发送本机识别出的文字。"), error: problem != nil)
    }

    @objc func modelChanged() {
        guard let identifier = modelPopup.selectedItem?.representedObject as? String else { return }
        selectedModel = identifier
    }

    @objc func refreshModels() { refreshModelList() }

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
