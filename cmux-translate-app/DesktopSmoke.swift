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
        do { before = try fixture.manifest() } catch { fixture.terminate(); smokeFail("fixture manifest 无效：\(error.localizedDescription)", result) }
        var frontmostReady = false
        for _ in 0..<3 where !frontmostReady {
            frontmostReady = await settle(timeout: 4, { NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.app.processIdentifier })
            if !frontmostReady { try? await Task.sleep(for: .milliseconds(400)) }
        }
        guard frontmostReady else {
            fixture.terminate(); smokeFail("fixture 未成为前台应用（本冒烟不抢焦点，请勿切换应用后重试）。", result)
        }
        do { try installHotkey(initial: .defaultShortcut) } catch { fixture.terminate(); smokeFail("无法注册默认快捷键：\(error)", result) }

        // 1. Full-window run: capture strictly after target lock; HUD shows source and provider before capture.
        let started = Date()
        let session = startSession(run: .fullWindow, frontmost: fixture.app)
        let hudBeforeCapture = await settle(timeout: 20) { session.hudVisible && !session.hudSourceText.isEmpty && !session.hudProviderText.isEmpty }
        check("hudShowsSourceAndProviderBeforeResult", hudBeforeCapture)
        let presented = await settle(timeout: 300) { session.phaseDescription == "presenting" || session.phaseDescription == "failed" || session.isFinished }
        result["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        result["phase"] = session.phaseDescription
        guard presented, session.phaseDescription == "presenting" else {
            let status = session.hudStatusText
            session.dismiss(reason: nil)
            fixture.terminate(); smokeFail(status.isEmpty ? "翻译未进入展示阶段。" : status, result)
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
        // Rect accuracy against the fixture's own known item rectangles (window-local points).
        var errors: [Double] = []
        for known in before.items {
            let expected = known.rect.cgRect
            let best = items.map { item -> Double in
                let c = item.clip
                return max(abs(c.minX - expected.minX), abs(c.minY - expected.minY), abs(c.maxX - expected.maxX), abs(c.maxY - expected.maxY))
            }.min()
            if let best { errors.append(best) }
        }
        result["matchedFixtureItems"] = errors.count
        result["maxEdgeErrorPoints"] = errors.max().map { ($0 * 10).rounded() / 10 } ?? NSNull()
        check("allFixtureItemsLocated", !before.items.isEmpty && errors.count == before.items.count)
        check("barrierCoversTargetFrame", {
            guard let panel = session.barrierPanel else { return false }
            let expected = CoordinateMapper.globalToAppKit(before.frameQuartz.cgRect, primaryHeight: TargetGeometry.primaryHeight)
            return panel.frame.equalTo(expected) && panel.isVisible
        }())
        check("panelsNonactivating", [session.barrierPanel, session.hudPanel].allSatisfy {
            guard let p = $0 else { return false }
            return p.styleMask.contains(.nonactivatingPanel) && p.collectionBehavior.contains(.fullScreenAuxiliary)
        })
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

        // 4. Cancel while translating leaves no resurrected UI.
        let second = startSession(run: .fullWindow, frontmost: fixture.app)
        _ = await settle(timeout: 20) { second.hudVisible }
        postSyntheticHotkey()
        let closed = await settle(timeout: 60) { self.session == nil }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check("cancelDoesNotResurrect", closed && second.isFinished && !second.hudVisible
            && !NSApp.windows.contains { $0 is PassivePanel && $0.isVisible })

        // 5. Esc through the barrier panel dismisses.
        let third = startSession(run: .fullWindow, frontmost: fixture.app)
        _ = await settle(timeout: 300) { third.barrierPanel != nil || third.isFinished }
        if let panel = third.barrierPanel,
           let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)) {
            panel.sendEvent(escape)
        }
        check("escapeDismisses", await settle { self.session == nil } && third.isFinished)

        // 6. Region flow: drag selection remembered per (window), restored in the next region run.
        let region = startSession(run: .region, frontmost: fixture.app)
        _ = await settle(timeout: 60) { region.selectorPanel != nil || region.isFinished }
        let size = before.frameQuartz.cgRect.size
        let chosen = CGRect(x: size.width * 0.1, y: size.height * 0.1, width: size.width * 0.6, height: size.height * 0.5)
        if let selector = region.selectorPanel {
            selector.setSelectionForVerification(chosen)
            selector.confirmCurrent()
        }
        let regionPresented = await settle(timeout: 300) { region.phaseDescription == "presenting" || region.phaseDescription == "failed" || region.isFinished }
        check("regionRunCompletes", regionPresented && region.phaseDescription == "presenting")
        check("regionMasksInsideSelection", region.presentedItems.allSatisfy { chosen.insetBy(dx: -2, dy: -2).contains($0.clip) })
        check("selectionRemembered", selectionMemory.value.restore(for: region.target ?? CaptureTarget(pid: 0, windowID: 0, frame: .zero)) != nil)
        region.dismiss(reason: nil)

        binder?.shutdown(); backend?.shutdown(); binder = nil; backend = nil
        result["checks"] = checks
        let failed = checks.filter { !$0.value }.keys.sorted()
        if !failed.isEmpty { result["failedChecks"] = failed; fixture.terminate(); smokeFail("冒烟断言失败。", result) }
        result["ok"] = true
        fixture.terminate()
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
