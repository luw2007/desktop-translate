import Foundation

@main
struct TranslationSettingsChecks {
    static func main() throws {
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        func parse(_ json: String) -> Result<AppConfig, ShortcutError> {
            do { return .success(try AppConfig.parse(Data(json.utf8))) } catch { return .failure(error as! ShortcutError) }
        }
        func rejects(_ json: String, _ message: String) {
            if case .success = parse(json) { preconditionFailure("Must reject: \(message)") }
        }
        let sc = #""shortcut":{"keyCode":17,"modifiers":["control","option"]}"#

        let full = try parse(#"{\#(sc),"translation":{"mode":"pi","piExecutable":"/opt/homebrew/bin/pi","model":"a/b"}}"#).get()
        expect(full.translation == TranslationSettings(mode: .pi, piExecutable: "/opt/homebrew/bin/pi", model: "a/b"), "Full translation parses")

        // Strict schema.
        rejects(#"{"translation":{"mode":"local"}}"#, "translation without shortcut")
        rejects(#"{\#(sc),"other":1}"#, "unknown root key")
        rejects(#"{\#(sc),"translation":[]}"#, "translation not object")
        rejects(#"{\#(sc),"translation":{"mode":"cloud"}}"#, "unknown mode")
        rejects(#"{\#(sc),"translation":{"mode":1}}"#, "non-string mode")
        rejects(#"{\#(sc),"translation":{"extra":1}}"#, "unknown translation key")
        rejects(#"{\#(sc),"translation":{"piExecutable":""}}"#, "blank executable")
        rejects(#"{\#(sc),"translation":{"piExecutable":"pi --x"}}"#, "command with args")
        rejects(#"{\#(sc),"translation":{"piExecutable":"bin/pi"}}"#, "relative path")
        rejects(#"{\#(sc),"translation":{"piExecutable":"pi\nx"}}"#, "newline executable")
        rejects(#"{\#(sc),"translation":{"piExecutable":"pi\u0000"}}"#, "NUL executable")
        rejects(#"{\#(sc),"translation":{"model":"  "}}"#, "blank model")
        rejects(#"{\#(sc),"translation":{"model":"a\nb"}}"#, "newline model")
        rejects(#"{\#(sc),"translation":{"model":"a\u0000b"}}"#, "NUL model")
        rejects(#"{\#(sc),"translation":{"model":"--help"}}"#, "option-like model")
        rejects(#"{\#(sc),"translation":{"model":7}}"#, "non-string model")
        rejects(#"{"shortcut":{"keyCode":17,"modifiers":["shift"]},"translation":{"mode":"local"}}"#, "bad shortcut still rejected")

        // Executable forms.
        for ok in ["pi", "/opt/homebrew/bin/pi", "/Users/me/my tools/pi"] { try TranslationSettings.validateExecutable(ok) }
        for bad in ["", " ", "pi ", " pi", "~/pi", "-pi", "a b", "./pi", "../pi"] {
            if (try? TranslationSettings.validateExecutable(bad)) != nil { preconditionFailure("Must reject executable \(bad)") }
        }

        // Stores: shortcut and translation preserve each other on every save; writes are atomic.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-translation-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cmux-translate/config.json")
        let shortcutStore = ShortcutStore(url: url)
        let store = TranslationSettingsStore(url: url)
        let custom = TranslationSettings(mode: .pi, piExecutable: "pi", model: "x/y")
        try store.save(custom)
        let other = try Shortcut(keyCode: 38, modifiers: [.control, .option, .command])
        try shortcutStore.save(other)
        expect(try store.load() == custom && (try shortcutStore.load()) == other, "Shortcut save preserves translation")
        let moved = TranslationSettings(mode: .local, piExecutable: "/x/pi", model: "m/n")
        try store.save(moved)
        expect(try store.load() == moved && (try shortcutStore.load()) == other, "Translation save preserves shortcut")

        // Legacy shortcut-only file is migrated, not rejected, and keeps its shortcut.
        let legacyURL = dir.appendingPathComponent("legacy/config.json")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"shortcut":{"keyCode":38,"modifiers":["control","option","command"]}}"#.utf8).write(to: legacyURL)
        let legacyStore = TranslationSettingsStore(url: legacyURL)
        try legacyStore.save(custom)
        expect(try ShortcutStore(url: legacyURL).load() == other, "Legacy shortcut survives translation save")

        // Invalid settings are refused before touching disk; invalid existing file is never overwritten.
        let before = try Data(contentsOf: url)
        for bad in [TranslationSettings(mode: .pi, piExecutable: "", model: "a/b"),
                    TranslationSettings(mode: .pi, piExecutable: "pi -x", model: "a/b"),
                    TranslationSettings(mode: .pi, piExecutable: "pi", model: "a\nb"),
                    TranslationSettings(mode: .pi, piExecutable: "pi", model: "")] {
            do { try store.save(bad); preconditionFailure("Must reject \(bad)") } catch is ShortcutError {}
        }
        expect(try Data(contentsOf: url) == before, "Rejected saves leave file untouched")
        try Data("{ nope".utf8).write(to: url)
        do { try store.save(custom); preconditionFailure("Corrupt config must not be overwritten") } catch let error as ShortcutError {
            expect(error.message.contains(url.path), "Error names the file")
        }
        do { try shortcutStore.save(other); preconditionFailure("Corrupt config must not be overwritten") } catch is ShortcutError {}
        expect(try Data(contentsOf: url) == Data("{ nope".utf8), "Corrupt file preserved")
        do { _ = try store.load(); preconditionFailure("Corrupt config must throw") } catch is ShortcutError {}

        // Disk failure surfaces an explicit error.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        do { try TranslationSettingsStore(url: blocker.appendingPathComponent("config.json")).save(custom); preconditionFailure("Must fail") }
        catch is ShortcutError {}

        print("TranslationSettingsChecks: all passed")
    }
}
