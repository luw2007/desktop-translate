import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - Carbon backend

nonisolated(unsafe) private var carbonHotkeyDispatch: ((UInt32) -> Void)?

private let carbonHotkeyCallback: EventHandlerUPP = { _, event, _ in
    var id = EventHotKeyID()
    guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return noErr }
    let number = id.id
    DispatchQueue.main.async { carbonHotkeyDispatch?(number) }
    return noErr
}

struct CarbonHandle {
    let ref: EventHotKeyRef
    let id: UInt32
}

/// Registers real Carbon hotkeys with unique ids. A press is forwarded only while its id is registered.
@MainActor
final class CarbonHotkeyBackend: HotkeyBackend {
    static let signature = OSType(0x434D5854) // 'CMXT'

    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var active: Set<UInt32> = []
    private let onPressed: @MainActor (UInt32) -> Void

    init(onPressed: @escaping @MainActor (UInt32) -> Void) throws {
        self.onPressed = onPressed
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyCallback, 1, &spec, nil, &handlerRef)
        guard status == noErr else { throw ShortcutError("无法安装快捷键事件处理器（OSStatus \(status)）。") }
        carbonHotkeyDispatch = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self, self.active.contains(id) else { return }
                self.onPressed(id)
            }
        }
    }

    func register(_ shortcut: Shortcut) -> Result<CarbonHandle, ShortcutError> {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            let reason = status == OSStatus(eventHotKeyExistsErr) ? "该组合已被占用" : "系统拒绝注册"
            return .failure(ShortcutError("\(reason)（OSStatus \(status)）"))
        }
        active.insert(id)
        return .success(CarbonHandle(ref: ref, id: id))
    }

    func unregister(_ handle: CarbonHandle) {
        UnregisterEventHotKey(handle.ref)
        active.remove(handle.id)
    }

    func shutdown() {
        carbonHotkeyDispatch = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        active.removeAll()
    }

    /// Verification only: queue a real kEventHotKeyPressed so the installed Carbon handler performs the dispatch.
    func postSyntheticPress(id: UInt32) {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event) == noErr,
              let event else { return }
        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        PostEventToQueue(GetMainEventQueue(), event, EventPriority(kEventPriorityStandard))
        ReleaseEvent(event)
    }
}

// MARK: - Recorder window

/// Consumes every key while open: nothing reaches the terminal, Cmd+Q/Cmd+W cannot act on the app.
final class RecorderWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Void)?
    var onFlagsChanged: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            onKeyDown?(event)
        case .keyUp:
            break
        case .flagsChanged:
            onFlagsChanged?(event)
        default:
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown { onKeyDown?(event) }
        return true
    }

    override func keyDown(with event: NSEvent) {}
}

@MainActor
final class ShortcutRecorderController: NSObject {
    private(set) var window: RecorderWindow
    private let current: Shortcut
    private let apply: (Shortcut) throws -> Void
    private let onClose: () -> Void
    private let promptLabel = NSTextField(labelWithString: "")
    private let comboLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private(set) var candidate: Shortcut?
    private var closed = false

    init(current: Shortcut, apply: @escaping (Shortcut) throws -> Void, onClose: @escaping () -> Void) {
        self.current = current
        self.apply = apply
        self.onClose = onClose
        window = RecorderWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                                styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    var candidateDisplay: String { candidate?.display ?? "" }
    var message: String { messageLabel.stringValue }
    var isSaveEnabled: Bool { saveButton.isEnabled }

    private func build() {
        window.title = "设置翻译快捷键"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.onKeyDown = { [weak self] event in self?.handleKeyDown(event) }
        window.onFlagsChanged = { [weak self] event in self?.handleFlags(event) }

        promptLabel.stringValue = "现在直接按下新的快捷键组合"
        promptLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        let currentLabel = NSTextField(labelWithString: "当前：\(current.display)　·　Esc 取消　·　按键位置按物理键计，与输入法无关")
        currentLabel.font = .systemFont(ofSize: 11)
        currentLabel.textColor = .secondaryLabelColor

        comboLabel.font = .monospacedSystemFont(ofSize: 34, weight: .medium)
        comboLabel.alignment = .center
        comboLabel.wantsLayer = true
        comboLabel.layer?.cornerRadius = 8
        comboLabel.layer?.borderWidth = 2
        comboLabel.layer?.borderColor = NSColor.controlAccentColor.cgColor
        comboLabel.translatesAutoresizingMaskIntoConstraints = false
        comboLabel.heightAnchor.constraint(equalToConstant: 64).isActive = true

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 3

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.refusesFirstResponder = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.refusesFirstResponder = true
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.spacing = 10

        let stack = NSStackView(views: [promptLabel, currentLabel, comboLabel, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            comboLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window.contentView = content
        window.center()
        reset()
    }

    private func reset() {
        candidate = nil
        comboLabel.stringValue = "等待按键…"
        comboLabel.textColor = .secondaryLabelColor
        messageLabel.stringValue = "按住修饰键（⌃ ⌥ ⌘）并按一个字母、数字、F 键或方向键。"
        messageLabel.textColor = .secondaryLabelColor
        saveButton.isEnabled = false
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func modifiers(of event: NSEvent) -> Set<ShortcutModifier> {
        let flags = event.modifierFlags
        var result = Set<ShortcutModifier>()
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private func handleFlags(_ event: NSEvent) {
        guard candidate == nil else { return }
        let held = Self.modifiers(of: event)
        let text = ShortcutModifier.ordered.filter { held.contains($0) }.map(\.symbol).joined()
        comboLabel.stringValue = text.isEmpty ? "等待按键…" : text + "…"
    }

    func handleKeyDown(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            cancel()
            return
        }
        if event.isARepeat { return }
        do {
            let value = try Shortcut(keyCode: Int(event.keyCode), modifiers: Self.modifiers(of: event))
            candidate = value
            comboLabel.stringValue = value.display
            comboLabel.textColor = .labelColor
            messageLabel.stringValue = value == current ? "与当前快捷键相同。点“保存”确认，或重新按键。" : "点“保存”立即生效，或重新按键更换。"
            messageLabel.textColor = .secondaryLabelColor
            saveButton.isEnabled = true
        } catch {
            candidate = nil
            let held = Self.modifiers(of: event)
            comboLabel.stringValue = ShortcutModifier.ordered.filter { held.contains($0) }.map(\.symbol).joined()
                + (Shortcut.keyLabels[Int(event.keyCode)] ?? "?")
            comboLabel.textColor = .systemRed
            messageLabel.stringValue = (error as? ShortcutError)?.message ?? error.localizedDescription
            messageLabel.textColor = .systemRed
            saveButton.isEnabled = false
        }
    }

    @objc func save() {
        guard let candidate, saveButton.isEnabled else { return }
        do {
            try apply(candidate)
            close()
        } catch {
            messageLabel.stringValue = (error as? ShortcutError)?.message ?? error.localizedDescription
            messageLabel.textColor = .systemRed
            comboLabel.textColor = .systemRed
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

    /// Verification only: a real key event delivered through the window's event path.
    static func keyEvent(keyCode: Int, modifiers: NSEvent.ModifierFlags, windowNumber: Int) -> NSEvent? {
        let characters = Shortcut.keyLabels[keyCode]?.lowercased() ?? ""
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                keyCode: UInt16(keyCode))
    }
}
