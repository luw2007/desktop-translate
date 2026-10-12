import Foundation

// Foundation-only (compiles standalone with Shortcut.swift). Owns the single config schema:
//   {"shortcut":{"keyCode":17,"modifiers":["control","option"]},
//    "translation":{"mode":"local"|"pi","piExecutable":"pi","model":"deepseek/deepseek-flash"}}
// Root keys other than shortcut/translation are rejected. A missing "translation" means local defaults.

enum TranslationMode: String, CaseIterable {
    case local, pi
}

struct TranslationSettings: Equatable {
    var mode: TranslationMode
    var piExecutable: String
    var model: String

    static let defaults = TranslationSettings(mode: .local, piExecutable: "pi", model: "deepseek/deepseek-flash")

    /// Returns self when valid. Executable is a bare command name or an absolute path, never command+arguments,
    /// and is passed to Process directly (no shell). Model is an opaque single token that cannot look like an option.
    func validated() throws -> TranslationSettings {
        try Self.validateExecutable(piExecutable)
        try Self.validateModel(model)
        return self
    }

    static func validateExecutable(_ value: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ShortcutError("pi 可执行文件不能为空。") }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw ShortcutError("pi 可执行文件不能包含换行或控制字符。")
        }
        if value != value.trimmingCharacters(in: .whitespaces) { throw ShortcutError("pi 可执行文件首尾不能有空白。") }
        if value.hasPrefix("/") { return }
        if value.contains("/") { throw ShortcutError("pi 可执行文件必须是命令名（如 pi）或绝对路径，不支持相对路径。") }
        if value.hasPrefix("-") || value.hasPrefix("~") { throw ShortcutError("pi 可执行文件必须是命令名（如 pi）或绝对路径。") }
        if value.unicodeScalars.contains(where: { CharacterSet.whitespaces.contains($0) }) {
            throw ShortcutError("pi 可执行文件只能是命令名或绝对路径，不能包含参数。")
        }
    }

    static func validateModel(_ value: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ShortcutError("模型不能为空。") }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }) {
            throw ShortcutError("模型不能包含空白、换行或控制字符。")
        }
        if value.hasPrefix("-") { throw ShortcutError("模型不能以 “-” 开头。") }
    }

    // MARK: JSON

    static func decode(_ raw: Any?) throws -> TranslationSettings {
        guard let raw else { return .defaults }
        guard let object = raw as? [String: Any] else { throw ShortcutError("translation 必须是对象。") }
        if let extra = object.keys.sorted().first(where: { !["mode", "piExecutable", "model"].contains($0) }) {
            throw ShortcutError("translation 包含未知字段 “\(extra)”。")
        }
        var result = TranslationSettings.defaults
        if let rawMode = object["mode"] {
            guard let name = rawMode as? String, let mode = TranslationMode(rawValue: name) else {
                throw ShortcutError("translation.mode 只允许 \"local\" 或 \"pi\"。")
            }
            result.mode = mode
        }
        if let value = object["piExecutable"] {
            guard let text = value as? String else { throw ShortcutError("translation.piExecutable 必须是字符串。") }
            result.piExecutable = text
        }
        if let value = object["model"] {
            guard let text = value as? String else { throw ShortcutError("translation.model 必须是字符串。") }
            result.model = text
        }
        return try result.validated()
    }

    var jsonObject: [String: Any] {
        ["mode": mode.rawValue, "piExecutable": piExecutable, "model": model]
    }
}

/// The whole config file. Single parser/encoder shared by ShortcutStore and TranslationSettingsStore.
struct AppConfig: Equatable {
    var shortcut: Shortcut
    var translation: TranslationSettings

    static let defaults = AppConfig(shortcut: .defaultShortcut, translation: .defaults)

    static func parse(_ data: Data) throws -> AppConfig {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: []) } catch {
            throw ShortcutError("配置不是有效的 JSON：\(error.localizedDescription)")
        }
        guard let top = root as? [String: Any] else { throw ShortcutError("配置顶层必须是对象。") }
        if let extra = top.keys.sorted().first(where: { $0 != "shortcut" && $0 != "translation" }) {
            throw ShortcutError("配置包含未知字段 “\(extra)”。")
        }
        guard let rawShortcut = top["shortcut"] else { throw ShortcutError("缺少 shortcut 对象。") }
        return AppConfig(shortcut: try Shortcut.decode(rawShortcut), translation: try TranslationSettings.decode(top["translation"]))
    }

    func encoded() throws -> Data {
        let object: [String: Any] = ["shortcut": shortcut.jsonObject, "translation": translation.jsonObject]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
    }

    /// Missing file means defaults; an existing but unreadable/invalid file throws with the path.
    static func load(from url: URL) throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .defaults }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ShortcutError("无法读取 \(url.path)：\(error.localizedDescription)")
        }
        do { return try parse(data) } catch let error as ShortcutError {
            throw ShortcutError("\(url.path)：\(error.message)")
        }
    }

    /// Atomic replace; the previous file is untouched when this throws.
    func save(to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded().write(to: url, options: .atomic)
        } catch {
            throw ShortcutError("无法保存 \(url.path)：\(error.localizedDescription)")
        }
    }

    /// Read-modify-write that preserves the other half of the config. An existing invalid file is never overwritten.
    static func update(at url: URL, _ change: (inout AppConfig) throws -> Void) throws {
        var config = try load(from: url)
        try change(&config)
        try config.save(to: url)
    }
}

struct TranslationSettingsStore {
    var url: URL = ShortcutStore.standardURL()

    init(url: URL = ShortcutStore.standardURL()) { self.url = url }

    func load() throws -> TranslationSettings { try AppConfig.load(from: url).translation }

    /// Validates, then atomically saves while preserving the stored shortcut.
    func save(_ settings: TranslationSettings) throws {
        let valid = try settings.validated()
        try AppConfig.update(at: url) { $0.translation = valid }
    }
}
