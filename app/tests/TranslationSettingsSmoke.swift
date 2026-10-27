import AppKit
import Foundation

/// Drives the real TranslationSettingsController against a throwaway config with an injected model-discovery
/// function (no pi process, no provider, no credential, no network). Covers behaviour only: persistence and
/// migration of the input mode, image-mode model eligibility from pi's reported metadata, stale discovery,
/// unavailable saved choices and the pre-capture disclosure. The user's real config is only fingerprinted.
@main
struct TranslationSettingsSmoke {
    @MainActor
    static func main() async {
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
        func spin(_ seconds: TimeInterval = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        let realURL = ShortcutStore.standardURL()
        let realBefore = fingerprint(realURL)
        let configURL = root.appendingPathComponent("cmux-translate/config.json")
        let store = TranslationSettingsStore(url: configURL)
        let shortcutStore = ShortcutStore(url: configURL)
        let custom = try! Shortcut(keyCode: 38, modifiers: [.control, .option, .command])
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Pre-existing config that predates inputMode: pi with a saved model.
        try? Data(#"{"shortcut":{"keyCode":38,"modifiers":["control","option","command"]},"translation":{"mode":"pi","piExecutable":"pi","model":"saved/gone-model"}}"#.utf8).write(to: configURL)

        var latest = (try? store.load()) ?? .defaults
        check("oldConfigMigratesToOcrText", latest.inputMode == .ocrText && latest.mode == .pi && latest.model == "saved/gone-model")
        check("oldConfigMigratesToEnglishToSimplified", latest.sourceLanguage == "en" && latest.targetLanguage == "zh-Hans")

        let models = [
            PiModel(provider: "alpha", id: "text-only", name: "t", acceptsImages: false),
            PiModel(provider: "alpha", id: "vision", name: "v", acceptsImages: true),
            PiModel(provider: "router", id: "org/sub/vision-2", name: "w", acceptsImages: true),
        ]
        // Controllable discovery: each call takes its own scripted delay and answer.
        var script: [(delay: Double, models: [PiModel]?)] = []
        var calls = 0
        func discover(_ settings: TranslationSettings) async throws -> [PiModel] {
            let step = script[min(calls, script.count - 1)]
            calls += 1
            try await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
            guard let list = step.models else { throw PiTranslationError("模拟失败") }
            return list
        }

        var saveCalls = 0
        var controller = TranslationSettingsController(
            current: latest,
            onSave: { settings in saveCalls += 1; try store.save(settings); latest = settings },
            onClose: {},
            discover: { try await discover($0) })

        func choose(_ input: PiInputMode) {
            let popup = controller.inputModePopup
            popup.selectItem(at: PiInputMode.allCases.firstIndex(of: input)!)
            _ = popup.sendAction(popup.action, to: popup.target)
        }
        func chooseModel(_ identifier: String) -> Bool {
            let popup = controller.modelPopup
            guard let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == identifier }) else { return false }
            popup.selectItem(at: index)
            _ = popup.sendAction(popup.action, to: popup.target)
            return true
        }
        func identifiers() -> [String] { controller.modelPopup.itemArray.compactMap { $0.representedObject as? String } }

        // 1. Stale discovery: the first (slow) refresh is superseded by the second and must be ignored.
        script = [(0.4, [PiModel(provider: "stale", id: "late", name: "s", acceptsImages: true)]), (0.0, models)]
        controller.refreshModelList()          // starts discovery #1 without activating or showing the app
        await spin(0.05)
        controller.refreshModelList()           // supersedes it
        await spin(0.7)
        check("staleDiscoveryIgnored", controller.discovered == models && !identifiers().contains("stale/late"))

        // 2. Saved model that pi no longer offers stays selected and visible; it is not overwritten.
        check("unavailableSavedStaysSelected", controller.selectedModelIdentifier == "saved/gone-model"
            && controller.modelPopup.selectedItem?.title.contains("saved/gone-model") == true
            && controller.modelPopup.selectedItem?.title != "saved/gone-model")

        // 3. Image mode: disclosure changes, text-only models are not offered, unavailable saved model is refused.
        check("textDisclosureWhileOcrText", controller.notice == TranslationSettingsController.textNotice)
        choose(.image)
        check("imageDisclosureNamesScreenshot", controller.notice == TranslationSettingsController.imageNotice
            && controller.notice.contains("截图") && controller.notice.contains("图像"))
        check("textOnlyModelNotOffered", !identifiers().contains("alpha/text-only")
            && identifiers().contains("alpha/vision") && identifiers().contains("router/org/sub/vision-2"))
        controller.save()
        check("imageModeRefusesUnavailableSavedModel", saveCalls == 0 && controller.messageIsError && latest.model == "saved/gone-model" && latest.inputMode == .ocrText)

        // 4. Slashed ids keep provider/id identity through selection and persistence.
        check("selectSlashedModel", chooseModel("router/org/sub/vision-2"))
        controller.save()
        let expected = TranslationSettings(mode: .pi, piExecutable: "pi", model: "router/org/sub/vision-2", inputMode: .image, sourceLanguage: "en")
        check("persistsImageModeAndSlashedModel", saveCalls == 1 && (try? store.load()) == expected
            && expected.modelIdentity?.provider == "router" && expected.modelIdentity?.id == "org/sub/vision-2"
            && (try? shortcutStore.load()) == custom)
        // Saving closes the controller; reopening a new offscreen instance exercises the subsequent failure path.
        controller = TranslationSettingsController(
            current: latest,
            onSave: { settings in saveCalls += 1; try store.save(settings); latest = settings },
            onClose: {},
            discover: { try await discover($0) })

        // 5. Discovery failure never rewrites the choice; switching back to OCR text re-allows text-only models.
        script = [(0.0, nil)]
        calls = 0
        controller.refreshModelList()          // failure path likewise stays offscreen
        await spin(0.3)
        check("failedDiscoveryKeepsChoice", controller.discovered == nil && controller.messageIsError
            && controller.selectedModelIdentifier == "router/org/sub/vision-2")
        script = [(0.0, models)]
        calls = 0
        controller.refreshModelList()
        await spin(0.3)
        choose(.ocrText)
        check("ocrTextOffersTextOnlyModels", identifiers().contains("alpha/text-only"))
        check("selectTextOnly", chooseModel("alpha/text-only"))
        choose(.image)
        controller.save()
        check("imageModeRefusesTextOnlySelection", saveCalls == 1 && latest == expected && controller.messageIsError)
        choose(.ocrText)
        controller.save()
        check("ocrTextSavesTextOnlyModel", saveCalls == 2 && latest.inputMode == .ocrText && latest.model == "alpha/text-only")

        // 5. Language popups: loaded from settings, saved, auto offered as source only, same pair refused.
        controller = TranslationSettingsController(current: latest, onSave: { settings in saveCalls += 1; try store.save(settings); latest = settings },
                                                   onClose: {}, discover: { try await discover($0) })
        check("languagePopupsReflectSettings", controller.selectedSourceLanguage == "en" && controller.selectedTargetLanguage == "zh-Hans"
            && controller.sourcePopup.numberOfItems == controller.targetPopup.numberOfItems + 1
            && TranslationSettingsController.sourceCodes.first == "auto" && !TranslationSettingsController.targetCodes.contains("auto"))
        func chooseLanguage(_ popup: NSPopUpButton, _ codes: [String], _ code: String) {
            popup.selectItem(at: codes.firstIndex(of: code)!)
            _ = popup.sendAction(popup.action, to: popup.target)
        }
        let before = saveCalls
        chooseLanguage(controller.sourcePopup, TranslationSettingsController.sourceCodes, "zh-Hans")
        controller.save()
        check("samePairRefused", saveCalls == before && controller.messageIsError)
        chooseLanguage(controller.sourcePopup, TranslationSettingsController.sourceCodes, "auto")
        chooseLanguage(controller.targetPopup, TranslationSettingsController.targetCodes, "ja")
        controller.save()
        check("autoToJapanesePersists", saveCalls == before + 1 && latest.isAutoSource && latest.targetLanguage == "ja"
            && (try? store.load()) == latest)


        // 6. Language-pack row: state for the pair the popups show, re-checked on every pair change, local mode only.
        var packCalls: [(source: String, target: String)] = []
        var packDelay: Double = 0
        // Deterministic model of every availability outcome; no Apple pack database is touched.
        let packCheck: TranslationSettingsController.PackCheck = { settings in
            packCalls.append((settings.sourceLanguage, settings.targetLanguage))
            if packDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(packDelay * 1_000_000_000)) }
            if settings.isAutoSource { return settings.targetLanguage == "ja" ? .autoDetectPending : .autoTargetUnsupported }
            if settings.sourceLanguage == settings.targetLanguage { return .samePair }
            if settings.sourceLanguage == "fr" { return .unsupported }
            return settings.targetLanguage == "ja" ? .needsInstall : .installed
        }
        var preparedPairs: [(source: String, target: String)?] = []
        controller = TranslationSettingsController(current: latest, onSave: { settings in saveCalls += 1; try store.save(settings); latest = settings },
                                                   onClose: {}, discover: { try await discover($0) }, packCheck: packCheck)
        controller.onPrepareLanguages = { preparedPairs.append($0) }
        await spin(0.3)
        // The saved mode is still pi here; the row is a local-mode concept, so switch to local first.
        controller.modePopup.selectItem(at: TranslationMode.allCases.firstIndex(of: .local)!)
        _ = controller.modePopup.sendAction(controller.modePopup.action, to: controller.modePopup.target)
        await spin(0.3)
        check("packRowShownInLocalMode", !controller.packRowHidden)
        check("autoPairShowsDetectNote", latest.isAutoSource && controller.packState == .autoDetectPending
            && controller.packStatusLabel.stringValue.contains("自动检测") && controller.packButton.isEnabled
            && packCalls.last?.source == "auto" && packCalls.last?.target == "ja")

        chooseLanguage(controller.sourcePopup, TranslationSettingsController.sourceCodes, "en")
        check("packStateReloadsOnSourceChange", controller.packChecking && controller.packState == nil
            && controller.packStatusLabel.stringValue.contains("正在检查"))
        await spin(0.3)
        check("needsInstallStatusAfterSourceChange", controller.packState == .needsInstall
            && controller.packStatusLabel.stringValue.contains("尚未安装") && controller.packButton.isEnabled
            && packCalls.last?.source == "en" && packCalls.last?.target == "ja")

        chooseLanguage(controller.targetPopup, TranslationSettingsController.targetCodes, "zh-Hans")
        await spin(0.3)
        check("installedStatusAfterTargetChange", controller.packState == .installed
            && controller.packStatusLabel.stringValue.contains("已安装") && !controller.packButton.isEnabled
            && packCalls.last?.source == "en" && packCalls.last?.target == "zh-Hans")

        chooseLanguage(controller.sourcePopup, TranslationSettingsController.sourceCodes, "fr")
        await spin(0.3)
        check("unsupportedPairReported", controller.packState == .unsupported
            && controller.packStatusLabel.stringValue.contains("不支持") && !controller.packButton.isEnabled)

        chooseLanguage(controller.sourcePopup, TranslationSettingsController.sourceCodes, "zh-Hans")
        await spin(0.3)
        check("samePairNeedsNoPack", controller.packState == .samePair
            && controller.packStatusLabel.stringValue.contains("无需语言包") && !controller.packButton.isEnabled)

        // A slow check is superseded by the next pair change; only the newest answer may land.
        packDelay = 0.4
        chooseLanguage(controller.sourcePopup, TranslationSettingsController.sourceCodes, "en")
        await spin(0.05)
        chooseLanguage(controller.targetPopup, TranslationSettingsController.targetCodes, "ja")
        await spin(0.8)
        check("stalePackCheckIgnored", controller.packState == .needsInstall && packCalls.last?.target == "ja"
            && controller.packStatusLabel.stringValue.contains("尚未安装"))
        packDelay = 0

        // The button prepares the pair the popups show, without saving; auto passes nil (pair unknown before detection).
        controller.prepareLanguages()
        let prepared = preparedPairs.last.flatMap { $0 }
        check("prepareUsesDisplayedPair", prepared?.source == "en" && prepared?.target == "ja")

        // Auto source: the pair is unknown before detection, so the button passes nil and no pair is prepared.
        chooseLanguage(controller.targetPopup, TranslationSettingsController.targetCodes, "zh-Hans")
        chooseLanguage(controller.sourcePopup, TranslationSettingsController.sourceCodes, "auto")
        await spin(0.3)
        check("autoTargetUnsupportedReported", controller.packState == .autoTargetUnsupported
            && controller.packStatusLabel.stringValue.contains("不支持目标语言") && !controller.packButton.isEnabled)
        chooseLanguage(controller.targetPopup, TranslationSettingsController.targetCodes, "ja")
        await spin(0.3)
        check("autoDetectPendingReEnablesPrepare", controller.packState == .autoDetectPending && controller.packButton.isEnabled)
        controller.prepareLanguages()
        check("preparePassesNilForAuto", preparedPairs.count == 2 && preparedPairs.last! == nil)
        chooseLanguage(controller.sourcePopup, TranslationSettingsController.sourceCodes, "en")
        await spin(0.3)
        // Pi mode has no local pack: the row is hidden, nothing is re-checked, and the button goes with the row.
        let packsAfterLocal = packCalls.count
        check("localPairCheckedBeforePi", controller.packState == .needsInstall)
        controller.modePopup.selectItem(at: TranslationMode.allCases.firstIndex(of: .pi)!)
        _ = controller.modePopup.sendAction(controller.modePopup.action, to: controller.modePopup.target)
        check("piModeHidesPackRow", controller.packRowHidden && controller.packState == nil && !controller.packChecking
            && controller.packStatusLabel.stringValue.contains("未检查") && packCalls.count == packsAfterLocal)
        controller.modePopup.selectItem(at: TranslationMode.allCases.firstIndex(of: .local)!)
        _ = controller.modePopup.sendAction(controller.modePopup.action, to: controller.modePopup.target)
        await spin(0.3)
        check("localModeRechecksPack", !controller.packRowHidden && controller.packState == .needsInstall
            && packCalls.count == packsAfterLocal + 1)
        controller.close()
        await spin(0.2)
        check("userConfigUntouched", fingerprint(realURL) == realBefore)
        finish()
    }
}
