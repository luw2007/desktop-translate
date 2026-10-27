import Carbon.HIToolbox
import Foundation

// MARK: - Model (Foundation + Carbon constants only, so it compiles standalone for checks)

enum ShortcutModifier: String, CaseIterable {
    case control, option, shift, command

    var carbonFlag: UInt32 {
        switch self {
        case .control: return UInt32(controlKey)
        case .option: return UInt32(optionKey)
        case .shift: return UInt32(shiftKey)
        case .command: return UInt32(cmdKey)
        }
    }

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    /// Canonical display / serialization order.
    static let ordered: [ShortcutModifier] = [.control, .option, .shift, .command]
}

struct ShortcutError: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

struct Shortcut: Hashable {
    let keyCode: Int
    let modifiers: Set<ShortcutModifier>

    static var defaultShortcut: Shortcut {
        let isDev = Bundle.main.bundleIdentifier?.hasPrefix("local.cmux.translate.dev.") == true
        return Shortcut(uncheckedKeyCode: kVK_ANSI_T, modifiers: isDev ? [.control, .option, .shift] : [.control, .option])
    }

    /// Supported physical keys (macOS virtual key codes, position based) and their labels.
    static let keyLabels: [Int: String] = {
        var table: [Int: String] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_Home, "Home"), (kVK_End, "End"), (kVK_PageUp, "PageUp"), (kVK_PageDown, "PageDown"),
            (kVK_Space, "Space"),
        ]
        for (code, label) in letters { table[code] = label }
        return table
    }()

    private init(uncheckedKeyCode: Int, modifiers: Set<ShortcutModifier>) {
        self.keyCode = uncheckedKeyCode
        self.modifiers = modifiers
    }

    /// Single validation point for user config and recorder candidates.
    init(keyCode: Int, modifiers: Set<ShortcutModifier>) throws {
        if keyCode == kVK_Escape { throw ShortcutError("Esc 保留用于取消，不能作为快捷键。") }
        guard Shortcut.keyLabels[keyCode] != nil else {
            throw ShortcutError("不支持的按键（keyCode \(keyCode)）。支持字母、数字、F1–F12、方向键、Home/End/PageUp/PageDown 和空格。")
        }
        guard !modifiers.isDisjoint(with: [.control, .option, .command]) else {
            throw ShortcutError("快捷键至少需要 ⌃、⌥ 或 ⌘ 之一（仅 ⇧ 会干扰正常输入）。")
        }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var carbonModifiers: UInt32 { modifiers.reduce(0) { $0 | $1.carbonFlag } }

    var display: String {
        ShortcutModifier.ordered.filter { modifiers.contains($0) }.map(\.symbol).joined() + (Shortcut.keyLabels[keyCode] ?? "?")
    }

    // MARK: JSON schema (whole-file schema lives in AppConfig, TranslationSettings.swift)

    /// Parses and validates the whole config file (including translation) and returns its shortcut.
    static func parse(_ data: Data) throws -> Shortcut {
        try AppConfig.parse(data).shortcut
    }

    /// Decodes the value of the root "shortcut" key.
    static func decode(_ raw: Any) throws -> Shortcut {
        guard let object = raw as? [String: Any] else { throw ShortcutError("缺少 shortcut 对象。") }
        if let extra = object.keys.sorted().first(where: { $0 != "keyCode" && $0 != "modifiers" }) {
            throw ShortcutError("shortcut 包含未知字段 “\(extra)”。")
        }
        guard let rawKey = object["keyCode"] as? NSNumber, CFGetTypeID(rawKey) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(rawKey as CFNumber), NSNumber(value: rawKey.int64Value) == rawKey else {
            throw ShortcutError("keyCode 必须是整数。")
        }
        guard let rawModifiers = object["modifiers"] as? [Any] else { throw ShortcutError("modifiers 必须是字符串数组。") }
        var modifiers = Set<ShortcutModifier>()
        for item in rawModifiers {
            guard let name = item as? String, let modifier = ShortcutModifier(rawValue: name) else {
                throw ShortcutError("未知的修饰键 \(item)；只允许 control、option、shift、command。")
            }
            guard modifiers.insert(modifier).inserted else { throw ShortcutError("修饰键 “\(name)” 重复。") }
        }
        return try Shortcut(keyCode: rawKey.intValue, modifiers: modifiers)
    }

    var jsonObject: [String: Any] {
        ["keyCode": keyCode, "modifiers": ShortcutModifier.ordered.filter { modifiers.contains($0) }.map(\.rawValue)]
    }

    /// Shortcut-only config with default translation settings.
    func encoded() throws -> Data {
        try AppConfig(shortcut: self, translation: .defaults).encoded()
    }
}

// MARK: - Persistent store

struct ShortcutStore {
    let url: URL

    /// Real location: $XDG_CONFIG_HOME or ~/.config, /cmux-translate/config.json.
    static func standardURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("cmux-translate/config.json")
    }

    /// Missing file means the default; an existing but unreadable/invalid file throws. The whole file is validated.
    func load() throws -> Shortcut { try AppConfig.load(from: url).shortcut }

    /// Atomic replace of the shortcut; stored translation settings are preserved.
    func save(_ shortcut: Shortcut) throws {
        try AppConfig.update(at: url) { $0.shortcut = shortcut }
    }
}

// MARK: - Rebind transaction

/// Abstract hotkey backend so the transaction invariants are testable without Carbon.
@MainActor
protocol HotkeyBackend: AnyObject {
    associatedtype Handle
    func register(_ shortcut: Shortcut) -> Result<Handle, ShortcutError>
    func unregister(_ handle: Handle)
}

/// Owns the active registration. `apply` is all-or-nothing: the candidate is registered before the old
/// one is released, persisted, and rolled back (old binding kept) if persistence fails.
@MainActor
final class ShortcutBinder<Backend: HotkeyBackend> {
    private let backend: Backend
    private let persist: (Shortcut) throws -> Void
    private(set) var current: Shortcut
    private(set) var handle: Backend.Handle

    init(backend: Backend, initial: Shortcut, persist: @escaping (Shortcut) throws -> Void) throws {
        self.backend = backend
        self.persist = persist
        switch backend.register(initial) {
        case .success(let handle): self.handle = handle
        case .failure(let error): throw error
        }
        current = initial
    }

    func apply(_ candidate: Shortcut) throws {
        if candidate == current { try persist(candidate); return }
        let newHandle: Backend.Handle
        switch backend.register(candidate) {
        case .success(let handle): newHandle = handle
        case .failure(let error):
            throw ShortcutError("无法注册 \(candidate.display)：\(error.message)。仍使用 \(current.display)。")
        }
        do { try persist(candidate) } catch {
            backend.unregister(newHandle)
            let detail = (error as? ShortcutError)?.message ?? error.localizedDescription
            throw ShortcutError("\(detail)。仍使用 \(current.display)。")
        }
        backend.unregister(handle)
        handle = newHandle
        current = candidate
    }

    func shutdown() { backend.unregister(handle) }
}
