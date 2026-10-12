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
@MainActor
final class TranslationSettingsController: NSObject {
    let window: NSWindow
    private let settingsWindow: TranslationSettingsWindow
    private(set) var current: TranslationSettings
    private let onSave: (TranslationSettings) throws -> Void
    private let onClose: () -> Void

    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let executableField = NSTextField(string: "")
    let modelField = NSTextField(string: "")
    let saveButton = NSButton(title: "保存", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var messageIsError = false
    private var closed = false

    static let localTitle = "本地（Apple 翻译）"
    static let piTitle = "pi（无头模型）"
    static let providerNotice = "选择 pi 后，被翻译的文字会作为纯文本发送给所选模型的 provider；翻译请求按无工具方式发起。"

    init(current: TranslationSettings, onSave: @escaping (TranslationSettings) throws -> Void, onClose: @escaping () -> Void) {
        self.current = current
        self.onSave = onSave
        self.onClose = onClose
        settingsWindow = TranslationSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 290),
                                                   styleMask: [.titled], backing: .buffered, defer: false)
        window = settingsWindow
        super.init()
        build()
        load(current)
    }

    var message: String { messageLabel.stringValue }
    var selectedMode: TranslationMode { TranslationMode.allCases[max(0, modePopup.indexOfSelectedItem)] }

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

        executableField.placeholderString = "pi 或 /opt/homebrew/bin/pi"
        modelField.placeholderString = "deepseek/deepseek-flash"
        for field in [executableField, modelField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }

        let notice = NSTextField(wrappingLabelWithString: Self.providerNotice)
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.maximumNumberOfLines = 3

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

        let stack = NSStackView(views: [heading, row("引擎", modePopup), row("pi 可执行", executableField),
                                        row("模型", modelField), notice, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        notice.widthAnchor.constraint(equalToConstant: 460).isActive = true
        messageLabel.widthAnchor.constraint(equalToConstant: 460).isActive = true
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
        modePopup.selectItem(at: TranslationMode.allCases.firstIndex(of: settings.mode) ?? 0)
        executableField.stringValue = settings.piExecutable
        modelField.stringValue = settings.model
        applyModeState()
        setMessage("“保存”后新的翻译立即使用所选后端；正在进行的翻译不受影响。", error: false)
    }

    private func applyModeState() {
        let piSelected = selectedMode == .pi
        executableField.isEnabled = piSelected
        modelField.isEnabled = piSelected
    }

    private func setMessage(_ text: String, error: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
        messageIsError = error
    }

    // MARK: Actions

    /// Shows the latest saved settings, discarding unsaved edits.
    func show() {
        closed = false
        load(current)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func modeChanged() {
        applyModeState()
        setMessage(selectedMode == .pi ? "配置 pi 可执行文件与模型；保存后下一次翻译生效。" : "本地模式使用 Apple 设备端翻译，文字不会离开本机。", error: false)
    }

    /// Settings as currently entered. In local mode the (disabled) pi fields only count if they are valid;
    /// otherwise the previously saved pi values are kept so a stale invalid edit cannot block switching to local.
    private func entered() throws -> TranslationSettings {
        window.endEditing(for: nil)
        let mode = selectedMode
        let candidate = TranslationSettings(mode: mode, piExecutable: executableField.stringValue, model: modelField.stringValue)
        if mode == .pi { return try candidate.validated() }
        if let valid = try? candidate.validated() { return valid }
        return TranslationSettings(mode: .local, piExecutable: current.piExecutable, model: current.model)
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
        window.orderOut(nil)
        onClose()
    }

    func snapshotPNG() -> Data? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
