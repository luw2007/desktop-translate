import AppKit
import Carbon.HIToolbox
import Foundation

/// `--shortcut-smoke`: drives the real recorder window, Carbon registration and store against a throwaway
/// config directory. The user's real config is never read for writing; its state is compared before/after.
extension AppDelegate {
    func runShortcutSmoke() async {
        var result: [String: Any] = [:]
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ condition: Bool) { checks[name] = condition }

        let realURL = ShortcutStore.standardURL()
        let realBefore = Self.fileFingerprint(realURL)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-translate-shortcut-smoke-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("cmux-translate/config.json")
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } catch {
            smokeFail("无法创建临时目录：\(error.localizedDescription)")
        }
        let cleanup = { try? FileManager.default.removeItem(at: root) }
        store = ShortcutStore(url: configURL)
        result["tempConfig"] = configURL.path
        result["realConfig"] = realURL.path

        func send(_ controller: ShortcutRecorderController, _ keyCode: Int, _ flags: NSEvent.ModifierFlags) {
            guard let event = ShortcutRecorderController.keyEvent(keyCode: keyCode, modifiers: flags, windowNumber: controller.window.windowNumber) else {
                smokeFail("无法构造按键事件。", result)
            }
            controller.window.sendEvent(event)
        }
        let all: NSEvent.ModifierFlags = [.control, .option, .command]

        // Register the initial shortcut before exercising transactions.
        let initialShortcut = try! Shortcut(keyCode: kVK_ANSI_K, modifiers: [.control, .option, .command])
        do { try installHotkey(initial: initialShortcut) } catch { smokeFail("无法注册测试快捷键：\(error)", result) }
        guard let binder, let backend else { smokeFail("注册后缺少 binder。", result) }

        guard let recorder1 = showShortcutRecorder() else { smokeFail("设置窗口未打开。", result) }
        // 3. Record ⌃⌥⌘J through the window's event path, then save.
        send(recorder1, kVK_ANSI_J, all)
        recorder1.save()
        let jShortcut = try! Shortcut(keyCode: kVK_ANSI_J, modifiers: [.control, .option, .command])
        check("saveClosesAndApplies", recorder?.window == nil && binder.current == jShortcut)
        check("persistedToTemp", (try? store.load()) == jShortcut)
        // The old combo must be free again at the system level.
        switch backend.register(initialShortcut) {
        case .success(let handle): backend.unregister(handle); check("oldComboFreed", true)
        case .failure: check("oldComboFreed", false)
        }

        // 4. Cancel by Esc: no mutation.
        let fileBeforeCancel = Self.fileFingerprint(configURL)
        guard let recorder2 = showShortcutRecorder() else { smokeFail("设置窗口未打开（取消场景）。", result) }
        send(recorder2, kVK_ANSI_K, all)
        send(recorder2, kVK_Escape, [])
        check("escapeCancelsWithoutSideEffects", recorder == nil && !recorder2.window.isVisible && binder.current == jShortcut
            && Self.fileFingerprint(configURL) == fileBeforeCancel)

        // 5. Collision: a real second Carbon registration holds ⌃⌥⌘L.
        let lShortcut = try! Shortcut(keyCode: kVK_ANSI_L, modifiers: [.control, .option, .command])
        guard case .success(let occupant) = backend.register(lShortcut) else { smokeFail("无法占用测试组合。", result) }
        guard let recorder3 = showShortcutRecorder() else { smokeFail("设置窗口未打开（撞键场景）。", result) }
        send(recorder3, kVK_ANSI_L, all)
        recorder3.save()
        check("collisionKeepsOld", binder.current == jShortcut && (try? store.load()) == jShortcut)
        backend.unregister(occupant)
        recorder3.cancel()

        // 6. Disk failure: parent of the config path is a regular file, so the atomic write must fail.
        let blocker = root.appendingPathComponent("blocker")
        try? Data("x".utf8).write(to: blocker)
        let goodStore = store
        store = ShortcutStore(url: blocker.appendingPathComponent("config.json"))
        let mShortcut = try! Shortcut(keyCode: kVK_ANSI_M, modifiers: [.control, .option, .command])
        guard let recorder4 = showShortcutRecorder() else { smokeFail("设置窗口未打开（写盘失败场景）。", result) }
        send(recorder4, kVK_ANSI_M, all)
        recorder4.save()
        check("saveFailureKeepsOld", binder.current == jShortcut && (try? goodStore.load()) == jShortcut)
        switch backend.register(mShortcut) {
        case .success(let handle): backend.unregister(handle); check("candidateRolledBack", true)
        case .failure: check("candidateRolledBack", false)
        }
        recorder4.cancel()
        store = goodStore

        // 7. Invalid config is an explicit error, not silently replaced.
        let temp2 = ShortcutStore(url: root.appendingPathComponent("bad/cmux-translate/config.json"))
        try? FileManager.default.createDirectory(at: temp2.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(#"{"shortcut":{"keyCode":17,"modifiers":["shift"]}}"#.utf8).write(to: temp2.url)
        var invalidReported = false
        do { _ = try temp2.load() } catch { invalidReported = "\(error)".contains(temp2.url.path) }
        check("invalidConfigRejected", invalidReported)


        // 9. Nothing touched the user's real preference.
        check("userConfigUntouched", Self.fileFingerprint(realURL) == realBefore)

        binder.shutdown()
        backend.shutdown()
        result["checks"] = checks
        let failed = checks.filter { !$0.value }.keys.sorted()
        if !failed.isEmpty {
            result["failedChecks"] = failed
            _ = cleanup()
            smokeFail("快捷键设置冒烟断言失败。", result)
        }
        result["ok"] = true
        _ = cleanup()
        emit(result)
        exit(0)
    }

    private static func fileFingerprint(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "absent" }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return "\(modified):\(size)"
    }
}
