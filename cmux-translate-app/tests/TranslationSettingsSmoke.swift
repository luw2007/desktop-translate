import AppKit
import Foundation

/// Drives the real TranslationSettingsController window (popup, text fields, buttons) against a throwaway config.
/// No translation is performed and no provider/credential is involved. The user's real config is only fingerprinted.
@main
struct TranslationSettingsSmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-translation-settings-smoke-\(UUID().uuidString)", isDirectory: true)
        var checks: [String: Bool] = [:]
        var result: [String: Any] = [:]
        func check(_ name: String, _ condition: Bool) { checks[name] = condition }
        func finish() -> Never {
            result["checks"] = checks
            let ok = !checks.isEmpty && checks.values.allSatisfy { $0 }
            result["ok"] = ok
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            try? FileManager.default.removeItem(at: root)
            exit(ok ? 0 : 1)
        }
        func fingerprint(_ url: URL) -> String {
            guard let data = try? Data(contentsOf: url) else { return "absent" }
            return "\(data.count):\(data.hashValue)"
        }
        func spin(_ seconds: TimeInterval = 0.05) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

        let realURL = ShortcutStore.standardURL()
        let realBefore = fingerprint(realURL)
        let configURL = root.appendingPathComponent("cmux-translate/config.json")
        result["tempConfig"] = configURL.path
        let store = TranslationSettingsStore(url: configURL)
        let shortcutStore = ShortcutStore(url: configURL)

        // Pre-existing legacy shortcut-only config with a non-default shortcut.
        let custom = try! Shortcut(keyCode: 38, modifiers: [.control, .option, .command])
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(#"{"shortcut":{"keyCode":38,"modifiers":["control","option","command"]}}"#.utf8).write(to: configURL)

        var saveCalls = 0
        var closeCalls = 0
        var failNextSave = false
        var latest = (try? store.load()) ?? .defaults
        check("legacyLoadsLocalDefaults", latest == .defaults)

        let controller = TranslationSettingsController(
            current: latest,
            onSave: { settings in
                saveCalls += 1
                if failNextSave { throw ShortcutError("无法保存（模拟写盘失败）。") }
                try store.save(settings)
                latest = settings
            },
            onClose: { closeCalls += 1 })

        // Real editing helpers: field editor + insertText, popup selection through its target/action.
        func type(_ text: String, into field: NSTextField) {
            controller.window.makeFirstResponder(field)
            guard let editor = field.currentEditor() else { check("fieldEditorAvailable", false); return }
            editor.selectAll(nil)
            editor.insertText(text)
            spin()
        }
        func choose(_ mode: TranslationMode) {
            let popup = controller.modePopup
            popup.selectItem(at: TranslationMode.allCases.firstIndex(of: mode)!)
            _ = popup.sendAction(popup.action, to: popup.target)
            spin()
        }
        func click(_ button: NSButton) { button.performClick(nil); spin() }

        let screenshots = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/cmux-translate", isDirectory: true)
        try? FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)

        controller.show()
        spin(0.2)
        check("windowVisible", controller.window.isVisible)
        check("initialModeLocal", controller.selectedMode == .local)
        check("piFieldsDisabledInLocal", !controller.executableField.isEnabled && !controller.modelField.isEnabled)

        // 1. Select pi, edit executable/model, save through the Save button.
        choose(.pi)
        check("piFieldsEnabledInPi", controller.executableField.isEnabled && controller.modelField.isEnabled)
        type("/opt/homebrew/bin/pi", into: controller.executableField)
        type("example/smoke-model", into: controller.modelField)
        if let png = controller.snapshotPNG(), (try? png.write(to: screenshots.appendingPathComponent("translation-settings.png"))) != nil {
            result["screenshot"] = screenshots.appendingPathComponent("translation-settings.png").path
        } else {
            check("screenshotWritten", false)
        }
        let piSettings = TranslationSettings(mode: .pi, piExecutable: "/opt/homebrew/bin/pi", model: "example/smoke-model")
        click(controller.saveButton)
        check("saveInvokedOnce", saveCalls == 1)
        check("windowClosedAfterSave", !controller.window.isVisible && closeCalls == 1)
        check("persistedPi", (try? store.load()) == piSettings)
        check("shortcutPreserved", (try? shortcutStore.load()) == custom)
        check("callbackGotSettings", latest == piSettings)

        // 2. Reopen shows the latest settings; cancel after edits changes nothing.
        let afterSave = fingerprint(configURL)
        controller.show()
        check("reopenShowsLatest", controller.selectedMode == .pi && controller.executableField.stringValue == piSettings.piExecutable
            && controller.modelField.stringValue == piSettings.model)
        type("other/model", into: controller.modelField)
        choose(.local)
        click(controller.cancelButton)
        check("cancelClosed", !controller.window.isVisible && closeCalls == 2)
        check("cancelNoSave", saveCalls == 1 && fingerprint(configURL) == afterSave && (try? store.load()) == piSettings)

        // 3. Invalid entries keep the window open with a visible error and write nothing.
        controller.show()
        let invalid: [(String, String, String)] = [
            ("blankExecutable", "", "example/smoke-model"),
            ("executableWithArguments", "pi --verbose", "example/smoke-model"),
            ("relativeExecutable", "bin/pi", "example/smoke-model"),
            ("blankModel", "pi", ""),
            ("newlineModel", "pi", "a\nb"),
            ("optionLikeModel", "pi", "--help"),
        ]
        for (name, executable, model) in invalid {
            choose(.pi)
            controller.executableField.stringValue = executable
            controller.modelField.stringValue = model
            click(controller.saveButton)
            check("invalid.\(name)", controller.window.isVisible && controller.messageIsError && !controller.message.isEmpty
                && saveCalls == 1 && fingerprint(configURL) == afterSave)
            result["error.\(name)"] = controller.message
        }

        // 4. Persistence failure from the parent callback is surfaced; the window stays open.
        controller.executableField.stringValue = "pi"
        controller.modelField.stringValue = "example/other"
        failNextSave = true
        click(controller.saveButton)
        failNextSave = false
        check("saveFailureVisible", controller.window.isVisible && controller.messageIsError && controller.message.contains("无法保存")
            && fingerprint(configURL) == afterSave && latest == piSettings)

        // 5. Valid retry from the same window, then switching to local with the pi fields kept intact.
        click(controller.saveButton)
        let retried = TranslationSettings(mode: .pi, piExecutable: "pi", model: "example/other")
        check("retrySucceeds", !controller.window.isVisible && (try? store.load()) == retried && (try? shortcutStore.load()) == custom)
        controller.show()
        choose(.local)
        controller.modelField.stringValue = "not valid because spaces"
        click(controller.saveButton)
        check("localSaveIgnoresInvalidDisabledFields", !controller.window.isVisible
            && (try? store.load()) == TranslationSettings(mode: .local, piExecutable: "pi", model: "example/other")
            && (try? shortcutStore.load()) == custom)

        // 6. Nothing touched the user's real preference.
        check("userConfigUntouched", fingerprint(realURL) == realBefore)
        finish()
    }
}
