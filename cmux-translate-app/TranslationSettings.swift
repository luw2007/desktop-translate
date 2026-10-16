import Foundation

// Foundation-only (compiles standalone with Shortcut.swift). Owns the single config schema:
//   {"shortcut":{"keyCode":17,"modifiers":["control","option"]},
//    "translation":{"mode":"local"|"pi","piExecutable":"pi","model":"deepseek/deepseek-flash",
//                   "inputMode":"ocr-text"|"image","sourceLanguage":"auto"|"en"|...,"targetLanguage":"zh-Hans"|...}}
// Root keys other than shortcut/translation are rejected. No config file = defaults (auto -> zh-Hans). An existing file
// whose translation lacks both language fields (or lacks "translation") keeps its old meaning: en -> zh-Hans.

enum TranslationMode: String, CaseIterable {
    case local, pi
}

/// What pi receives. `ocrText`: locally recognised text only (default; also what every pre-existing config means).
/// `image`: the exact submitted crop as one in-memory PNG; the model must declare image input.
enum PiInputMode: String, CaseIterable {
    case ocrText = "ocr-text"
    case image
}

/// Languages offered for translation (the set Apple Translation supports on this OS generation). `auto` is only a
/// valid SOURCE. Codes are BCP-47 as used by `Locale.Language(identifier:)`.
enum TranslationLanguages {
    static let auto = "auto"
    static let legacySource = "en"
    static let defaultTarget = "zh-Hans"
    /// (code, Chinese display name)
    static let all: [(code: String, name: String)] = [
        ("en", "英文"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁体中文"), ("ja", "日文"), ("ko", "韩文"),
        ("fr", "法文"), ("de", "德文"), ("es", "西班牙文"), ("it", "意大利文"), ("pt", "葡萄牙文"),
        ("ru", "俄文"), ("uk", "乌克兰文"), ("ar", "阿拉伯文"), ("hi", "印地文"), ("id", "印尼文"),
        ("nl", "荷兰文"), ("pl", "波兰文"), ("th", "泰文"), ("tr", "土耳其文"), ("vi", "越南文"),
    ]
    static func isSupported(_ code: String) -> Bool { all.contains { $0.code == code } }
    static func name(_ code: String) -> String {
        code == auto ? "自动检测" : (all.first { $0.code == code }?.name ?? code)
    }
    /// English names for model prompts.
    static func promptName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh-Hans": return "Simplified Chinese"
        case "zh-Hant": return "Traditional Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "ru": return "Russian"
        case "uk": return "Ukrainian"
        case "ar": return "Arabic"
        case "hi": return "Hindi"
        case "id": return "Indonesian"
        case "nl": return "Dutch"
        case "pl": return "Polish"
        case "th": return "Thai"
        case "tr": return "Turkish"
        case "vi": return "Vietnamese"
        default: return code
        }
    }
    /// Vision recognition languages for a source choice. auto = every supported language Vision can read, with
    /// automatic detection on (Vision picks per line).
    static func visionLanguages(source: String) -> [String] {
        switch source {
        case "en": return ["en-US"]
        case "zh-Hans": return ["zh-Hans", "en-US"]
        case "zh-Hant": return ["zh-Hant", "en-US"]
        case "ja": return ["ja-JP", "en-US"]
        case "ko": return ["ko-KR", "en-US"]
        case "fr": return ["fr-FR", "en-US"]
        case "de": return ["de-DE", "en-US"]
        case "es": return ["es-ES", "en-US"]
        case "it": return ["it-IT", "en-US"]
        case "pt": return ["pt-BR", "en-US"]
        case "ru": return ["ru-RU", "en-US"]
        case "uk": return ["uk-UA", "en-US"]
        default: return []   // auto and languages without a Vision recognizer: Vision's own automatic detection
        }
    }
}

struct TranslationSettings: Equatable {
    var mode: TranslationMode
    var piExecutable: String
    var model: String
    var inputMode: PiInputMode = .ocrText
    /// `TranslationLanguages.auto` or a supported code. New installs: auto -> zh-Hans.
    var sourceLanguage: String = TranslationLanguages.auto
    var targetLanguage: String = TranslationLanguages.defaultTarget

    static let defaults = TranslationSettings(mode: .local, piExecutable: "pi", model: "deepseek/deepseek-flash")
    /// What an existing config file without language fields has always meant (hardcoded English -> Simplified Chinese).
    /// Migration keeps that behaviour explicit instead of silently switching to auto-detect.
    static let legacy = TranslationSettings(mode: .local, piExecutable: "pi", model: "deepseek/deepseek-flash",
                                            sourceLanguage: TranslationLanguages.legacySource)

    var isAutoSource: Bool { sourceLanguage == TranslationLanguages.auto }
    /// e.g. "英文→简体中文" or "自动检测→简体中文"
    var pairLabel: String { "\(TranslationLanguages.name(sourceLanguage))→\(TranslationLanguages.name(targetLanguage))" }
    /// English phrase for model prompts: names the target and the source (or asks the model to detect it).
    var promptDirection: String {
        let target = TranslationLanguages.promptName(targetLanguage)
        return isAutoSource ? "into \(target) (detect the source language yourself)"
                            : "from \(TranslationLanguages.promptName(sourceLanguage)) into \(target)"
    }

    /// Provider/id identity of `model`: provider is everything before the first slash (provider names never contain
    /// one); the id is the rest and may itself contain slashes.
    var modelIdentity: (provider: String, id: String)? {
        guard let slash = model.firstIndex(of: "/") else { return nil }
        let provider = String(model[..<slash]), id = String(model[model.index(after: slash)...])
        return provider.isEmpty || id.isEmpty ? nil : (provider, id)
    }

    /// Returns self when valid. Executable is a bare command name or an absolute path, never command+arguments,
    /// and is passed to Process directly (no shell). Model is an opaque single token that cannot look like an option.
    func validated() throws -> TranslationSettings {
        try Self.validateExecutable(piExecutable)
        try Self.validateModel(model)
        guard sourceLanguage == TranslationLanguages.auto || TranslationLanguages.isSupported(sourceLanguage) else {
            throw ShortcutError("源语言不受支持：\(sourceLanguage)。")
        }
        guard TranslationLanguages.isSupported(targetLanguage) else { throw ShortcutError("目标语言不受支持：\(targetLanguage)。") }
        if sourceLanguage == targetLanguage { throw ShortcutError("源语言与目标语言不能相同。") }
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
        guard let raw else { return .legacy }   // existing file without "translation": same en -> zh-Hans meaning
        guard let object = raw as? [String: Any] else { throw ShortcutError("translation 必须是对象。") }
        if let extra = object.keys.sorted().first(where: { !["mode", "piExecutable", "model", "inputMode", "sourceLanguage", "targetLanguage"].contains($0) }) {
            throw ShortcutError("translation 包含未知字段 “\(extra)”。")
        }
        // A translation object written before language selection existed meant English -> Simplified Chinese.
        var result = object["sourceLanguage"] == nil && object["targetLanguage"] == nil ? TranslationSettings.legacy : TranslationSettings.defaults
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
        if let value = object["inputMode"] {
            guard let name = value as? String, let input = PiInputMode(rawValue: name) else {
                throw ShortcutError("translation.inputMode 只允许 \"ocr-text\" 或 \"image\"。")
            }
            result.inputMode = input
        }
        if let value = object["sourceLanguage"] {
            guard let text = value as? String else { throw ShortcutError("translation.sourceLanguage 必须是字符串。") }
            result.sourceLanguage = text
        }
        if let value = object["targetLanguage"] {
            guard let text = value as? String else { throw ShortcutError("translation.targetLanguage 必须是字符串。") }
            result.targetLanguage = text
        }
        return try result.validated()
    }

    var jsonObject: [String: Any] {
        ["mode": mode.rawValue, "piExecutable": piExecutable, "model": model, "inputMode": inputMode.rawValue,
         "sourceLanguage": sourceLanguage, "targetLanguage": targetLanguage]
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
