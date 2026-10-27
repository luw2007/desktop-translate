import AppKit
import Foundation

extension AppDelegate {
    private func terminalLevels(_ c: SnapshotCapabilities) -> [String: String] {
        ["visibleText": c.visibleText.effectiveLevel.rawValue, "textGeometry": c.textGeometry.effectiveLevel.rawValue,
         "paneLayout": c.paneLayout.effectiveLevel.rawValue, "contentRevision": c.contentRevision.effectiveLevel.rawValue,
         "fontRevision": c.fontRevision.effectiveLevel.rawValue]
    }

    /// ONE real session over the handed-off public terminal fixture. Refuses (no fallback) on any identity, ownership,
    /// readiness or window mismatch. Never activates, types, spawns or signals; the selected backend is kept (`--pi`
    /// variant overrides to pi explicitly, like glyph-pi-smoke).
    func runTerminalFixtureSmoke() async {
        loadSelectedSettings()
        if mode == .terminalFixturePiSmoke {
            currentSettings.mode = .pi
            if let model = ProcessInfo.processInfo.environment["DESKTOP_TRANSLATE_PI_MODEL"] { currentSettings.model = model }
            if let executable = ProcessInfo.processInfo.environment["DESKTOP_TRANSLATE_PI_EXECUTABLE"] { currentSettings.piExecutable = executable }
        }
        var result: [String: Any] = ["backend": currentSettings.mode.rawValue, "workflow": "terminal-fixture-smoke"]
        let proof: TerminalFixtureProof
        let app: NSRunningApplication
        do {
            proof = try TerminalFixtureProof.load(environment: ProcessInfo.processInfo.environment)
            app = try proof.verifyProcesses()
        } catch { smokeFail(error.localizedDescription, result) }
        result["token"] = proof.handoff.token
        result["app"] = TerminalPluginRegistry.supportedTerminalNames[proof.handoff.bundleId] ?? "unknown"
        result["bundleID"] = proof.handoff.bundleId
        result["origin"] = proof.handoff.origin
        result["appVersion"] = (app.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        result["ownerPID"] = Int(app.processIdentifier)
        let before: TerminalFixtureReport
        do { before = try proof.readReport() } catch { smokeFail(error.localizedDescription, result) }

        // Owned-window readiness without any activation: exactly one ordinary window of the owner pid, stable on two
        // ticks, and the owner naturally frontmost on two ticks. The window is then re-bound through the product lock.
        let deadline = Date().addingTimeInterval(10)
        var stable = 0, last: CaptureTarget?
        while stable < 2 {
            guard !app.isTerminated else { smokeFail("owner 应用在就绪前退出。", result) }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
               case .success(let t) = TargetLocker.lock(app: app),
               TargetLocker.ordinaryWindowIDs(pid: t.pid) == [t.windowID] {
                stable = (last.map { $0.windowID == t.windowID && $0.frame == t.frame } ?? false) ? stable + 1 : 1
                last = t
            } else { stable = 0; last = nil }
            if stable >= 2 { break }
            guard Date() < deadline else { smokeFail("owner 窗口未在期限内自然成为前台的唯一普通窗口（不会激活或切换）。", result) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let locked: CaptureTarget
        do {
            guard let candidate = last else { throw TerminalSmokeError("没有可锁定的窗口") }
            try proof.verifyWindow(candidate)
            locked = candidate
        } catch { smokeFail(error.localizedDescription, result) }
        result["windowID"] = Int(locked.windowID)
        result["windowSize"] = ["width": locked.frame.width, "height": locked.frame.height]
        result["displays"] = locked.displayIDs.count
        result["builtinPlugin"] = TerminalPluginRegistry().hasPlugin(for: locked)

        do { try installHotkey(initial: .defaultShortcut) } catch { smokeFail("无法注册默认快捷键。", result) }
        let started = Date()
        let session = startSession(run: .fullWindow, frontmost: app)
        let presented = await settle(timeout: 300) { session.phaseDescription == "presenting" || session.phaseDescription == "failed" || session.isFinished }
        result["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        result["phase"] = session.phaseDescription
        guard presented, session.phaseDescription == "presenting", let snapshot = session.presentedSnapshot, let sessionTarget = session.target else {
            // Raw HUD status can carry backend/pi/provider text; report only the fixed class and the session phase.
            let phase = session.phaseDescription
            session.dismiss(reason: nil)
            result["failureClass"] = presented ? "session-not-presenting" : "session-timeout"
            result["failurePhase"] = phase
            smokeFail("翻译未进入展示阶段（详情不转发，见阶段码）。", result)
        }
        var checks: [String: Bool] = [:]
        checks["sessionTargetIsBoundWindow"] = sessionTarget.sameWindow(as: locked) && (try? proof.verifyWindow(sessionTarget)) != nil
        checks["snapshotTargetIsBoundWindow"] = snapshot.target.sameWindow(as: locked)

        // Surface source/support/association; geometry accuracy is deliberately NOT measured (no oracle).
        result["source"] = ["label": session.hudSourceText, "snapshotProvenance": snapshot.provenance.rawValue,
                            "capabilities": terminalLevels(snapshot.capabilities)]
        if let source = pluginRegistry.currentCaptureSource {
            result["pluginSource"] = ["interface": source.evidence.interface, "applicationVersion": source.evidence.applicationVersion,
                                      "versionVerified": source.evidence.versionVerified,
                                      "provenance": source.provenance?.rawValue ?? "none",
                                      "evidence": ["visibleText": source.evidence.visibleText.rawValue, "textGeometry": source.evidence.textGeometry.rawValue,
                                                   "paneLayout": source.evidence.paneLayout.rawValue, "contentRevision": source.evidence.contentRevision.rawValue,
                                                   "fontRevision": source.evidence.fontRevision.rawValue]]
        } else { result["pluginSource"] = NSNull() }
        var lineMismatch = 0, maskItems = 0, maskLines = 0, maskBroken = 0, collisions = 0, overflows = 0
        for region in snapshot.regions {
            let lines = region.text.components(separatedBy: "\n").count
            if lines != (region.lineRects.isEmpty ? 1 : region.lineRects.count) { lineMismatch += 1 }
        }
        for item in session.presentedItems {
            if item.overflow { overflows += 1 }
            if item.occupancyUnavailable { collisions += 1; continue }
            maskItems += 1
            guard let region = snapshot.regions.first(where: { $0.id == item.regionID }) else { maskBroken += 1; continue }
            let expected = region.lineRects.isEmpty ? 1 : region.lineRects.count
            if expected != item.occupied.count || region.text.components(separatedBy: "\n").count != expected { maskBroken += 1 } else { maskLines += expected }
        }
        result["counts"] = ["regions": snapshot.regions.count, "layoutRegions": snapshot.layout.count, "overlayItems": session.presentedItems.count,
                            "ocrLineMismatchRegions": lineMismatch, "maskItems": maskItems, "maskLines": maskLines, "maskAssociationBroken": maskBroken,
                            "occupancyUnavailableItems": collisions, "overflowItems": overflows]
        result["geometry"] = ["measured": false, "note": "no oracle for terminal glyph geometry; source/support/association only"]
        checks["maskAssociated"] = maskBroken == 0 && maskItems > 0
        checks["hasChinese"] = session.presentedItems.contains { $0.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        checks["minimumFontSize"] = session.presentedItems.allSatisfy { $0.fontSizeAllowed }
        checks["targetStayedFrontmost"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier && !NSApp.isActive

        // Real PTY counters (producer-reported): disclosed deltas; synthetic CSI is never physical-input evidence.
        let after = try? proof.readReport()
        if let after {
            func delta(_ a: Int?, _ b: Int?) -> Int? { (a != nil && b != nil) ? b! - a! : nil }
            var counters: [String: Any] = ["before": before.json, "after": after.json]
            for (name, a, b) in [("focusIn", before.focusIn, after.focusIn), ("focusOut", before.focusOut, after.focusOut),
                                 ("discardedInputBytes", before.discardedInputBytes, after.discardedInputBytes),
                                 ("revision", before.revision, after.revision), ("renderCount", before.renderCount, after.renderCount),
                                 ("sceneChanges", before.sceneChanges, after.sceneChanges)] {
                if let d = delta(a, b) { counters[name + "Delta"] = d }
            }
            result["producerCounters"] = counters
            checks["fixtureReceivedNoInput"] = delta(before.discardedInputBytes, after.discardedInputBytes) == 0
            checks["sceneStableDuringCapture"] = delta(before.sceneChanges, after.sceneChanges) == 0
        } else { checks["fixtureReceivedNoInput"] = false; checks["sceneStableDuringCapture"] = false }
        checks["ownershipStillProven"] = (try? proof.verifyProcesses()) != nil

        postSyntheticHotkey()
        checks["hotkeyDismisses"] = await settle { self.session == nil } && session.isFinished && !(session.barrierPanel?.isVisible ?? false)
        binder?.shutdown(); backend?.shutdown(); binder = nil; backend = nil
        result["checks"] = checks
        // The fixture and its processes are NOT touched here; launcher `cleanup --token` owns spawned-only cleanup.
        let failed = checks.filter { !$0.value }.keys.sorted()
        if !failed.isEmpty { result["failedChecks"] = failed; smokeFail("terminal fixture 冒烟断言失败。", result) }
        result["ok"] = true
        emit(result)
        exit(0)
    }
}
