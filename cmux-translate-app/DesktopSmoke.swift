import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// `--smoke` / `--pi-smoke`: real end-to-end OCR against the independent public fixture app (its own bundle/PID).
/// Nothing is written to disk and no private window is captured; output contains counts and geometry only.
extension AppDelegate {
    private func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    func runSmoke() async {
        if mode == .piSmoke {
            currentSettings.mode = .pi
            if let model = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_PI_MODEL"] { currentSettings.model = model }
            if let executable = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_PI_EXECUTABLE"] { currentSettings.piExecutable = executable }
        }
        var result: [String: Any] = ["backend": currentSettings.mode.rawValue]
        if currentSettings.mode == .pi { result["model"] = currentSettings.model }
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) { checks[name] = value }

        let fixture: PublicFixture.Instance
        do { fixture = try await PublicFixture.launch() } catch { smokeFail("独立公共 fixture 无法启动：\(error.localizedDescription)", result) }
        let before: FixtureManifest
        do { before = try fixture.manifest() } catch { await fixture.finish(); smokeFail("fixture manifest 无效：\(error.localizedDescription)", result) }
        // Window presence is the capture precondition; the fixture's natural LaunchServices activation is awaited
        // (bounded, PID + bundle ID) and never forced. A non-frontmost fixture is a declined run.
        do { try await fixture.awaitFrontmost(); try await fixture.awaitTargetReady() } catch { await fixture.finish(); smokeFail(error.localizedDescription, result) }
        do { try installHotkey(initial: .defaultShortcut) } catch { await fixture.finish(); smokeFail("无法注册默认快捷键：\(error)", result) }

        // 1. Full-window run: capture strictly after target lock; HUD shows source and provider before capture.
        let started = Date()
        // awaitFrontmost above already established the guard; recheck immediately before the product locks the target.
        do { try fixture.requireFrontmost() } catch { await fixture.finish(); smokeFail(error.localizedDescription, result) }
        let session = startSession(run: .fullWindow, frontmost: fixture.app)
        let hudBeforeCapture = await settle(timeout: 20) { session.hudVisible && !session.hudSourceText.isEmpty && !session.hudProviderText.isEmpty }
        check("hudShowsSourceAndProviderBeforeResult", hudBeforeCapture)
        let presented = await settle(timeout: 300) { session.phaseDescription == "presenting" || session.phaseDescription == "failed" || session.isFinished }
        result["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        result["phase"] = session.phaseDescription
        guard presented, session.phaseDescription == "presenting" else {
            let status = session.hudStatusText
            session.dismiss(reason: nil)
            await fixture.finish(); smokeFail(status.isEmpty ? "翻译未进入展示阶段。" : status, result)
        }
        let items = session.presentedItems
        result["regions"] = items.count
        check("hasChinese", items.contains { containsChinese($0.text) })
        check("minimumFontSize", items.allSatisfy { $0.fontSize >= OverlayItem.minimumFontSize })
        check("masksClippedToTarget", items.allSatisfy { CGRect(origin: .zero, size: before.frameQuartz.cgRect.size).insetBy(dx: -1, dy: -1).contains($0.clip) })
        check("masksDoNotCoverWholeWindow", {
            let area = before.frameQuartz.cgRect.width * before.frameQuartz.cgRect.height
            return items.reduce(0) { $0 + $1.clip.width * $1.clip.height } < area * 0.9
        }())
        // Mask-to-item accuracy is deliberately unmeasured: overlay text is the translation, so a mask cannot be
        // associated to a specific public fixture item by text identity, and nearest-rectangle matching would be a tautology.
        result["maskAccuracy"] = "unmeasured"
        check("barrierCoversTargetFrame", {
            guard let panel = session.barrierPanel else { return false }
            let expected = CoordinateMapper.globalToAppKit(before.frameQuartz.cgRect, primaryHeight: TargetGeometry.primaryHeight)
            return panel.frame.equalTo(expected) && panel.isVisible
        }())
        check("targetStayedFrontmost", NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.app.processIdentifier && !NSApp.isActive)

        // 2. The fixture never received input and never lost activation because of our UI.
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let after = try? fixture.manifest() {
            check("fixtureReceivedNoInput", after.mouseDownCount == before.mouseDownCount && after.scrollCount == before.scrollCount
                && after.keyDownCount == before.keyDownCount && after.buttonPressCount == before.buttonPressCount)
            check("fixtureNeverResignedActive", after.resignActiveCount == before.resignActiveCount)
            result["fixtureResignActiveCount"] = after.resignActiveCount
        } else { check("fixtureManifestReadable", false) }

        // 3. Real Carbon hotkey dismisses.
        postSyntheticHotkey()
        check("hotkeyDismisses", await settle { self.session == nil } && session.isFinished && !(session.barrierPanel?.isVisible ?? false))

        binder?.shutdown(); backend?.shutdown(); binder = nil; backend = nil
        result["checks"] = checks
        let failed = checks.filter { !$0.value }.keys.sorted()
        if !failed.isEmpty { result["failedChecks"] = failed; await fixture.finish(); smokeFail("冒烟断言失败。", result) }
        result["ok"] = true
        // Completion protocol: overlays are already dismissed and results recorded; only now is the fixture released.
        await fixture.finish()
        emit(result)
        exit(0)
    }

    /// `--child-permission-report`: the disclaimed child must NOT inherit this app's Screen Recording/Accessibility trust.
    func runChildPermissionReport() async {
        let parentSR = await ScreenCapturePermission.preflight()
        let parentAX = AXIsProcessTrusted()
        do {
            let child = try await ChildPermissionProbe.run()
            emit(["ok": !child.screenRecordingPreflight && !child.accessibilityTrusted,
                  "parent": ["screenRecording": parentSR, "accessibility": parentAX],
                  "child": ["screenRecording": child.screenRecordingPreflight, "accessibility": child.accessibilityTrusted]])
            exit(child.screenRecordingPreflight || child.accessibilityTrusted ? 1 : 0)
        } catch {
            emit(["ok": false, "error": "子进程权限探针失败：\(error.localizedDescription)（符号缺失时按设计失败关闭）"])
            exit(1)
        }
    }
}
