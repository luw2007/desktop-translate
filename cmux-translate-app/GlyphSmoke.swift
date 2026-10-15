import AppKit
import Foundation

/// `--glyph-smoke`: ONE real capture -> OCR -> translation -> positioned overlay -> dismissal against the independent
/// glyph fixture (own bundle/PID, fixtures/GlyphSceneFixtureApp.swift). Product rectangles (OCR line rects and overlay
/// `occupied` source rects) are matched 1:1 by public identity (normalized text + containment of the token centre) and
/// scored by signed edge errors against the fixture's manifest glyph/ink rects. Output = token IDs and numbers only.
/// No activation, no synthetic key events, no retries; the fixture is launched naturally through LaunchServices.
@MainActor
final class GlyphFixtureInstance {
    static let bundlePrefix = "local.desktop-translate.glyph-fixture."
    let app: NSRunningApplication
    let manifestURL: URL
    private let directory: URL
    private var completed = false
    private let launchedURL: URL
    private let usedDefaultPath: Bool
    private let expectedBundleID: String
    private(set) var activation = FixtureActivationRecord(authorized: FixtureActivation.authorized)
    init(app: NSRunningApplication, manifestURL: URL, directory: URL, launchedURL: URL, usedDefaultPath: Bool, expectedBundleID: String) {
        self.app = app; self.manifestURL = manifestURL; self.directory = directory
        self.launchedURL = launchedURL; self.usedDefaultPath = usedDefaultPath; self.expectedBundleID = expectedBundleID
    }

    func scene() throws -> GlyphScene {
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 2_000_000 else { throw PublicFixtureError.invalidManifest }
        let scene = try JSONDecoder().decode(GlyphScene.self, from: data)
        guard GlyphMetric.isOwned(scene, expectedPID: app.processIdentifier) else { throw PublicFixtureError.invalidManifest }
        return scene
    }

    func requireFrontmost() throws {
        guard !app.isTerminated, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == app.processIdentifier,
              front.bundleIdentifier?.hasPrefix(Self.bundlePrefix) == true else {
            throw PublicFixtureError.notFrontmost
        }
    }

    /// Same ordered readiness contract as PublicFixture.Instance.awaitTargetReady (shared HarnessReadiness): window
    /// publication, the single authorized activation of THIS owned fixture, stable owned foreground, revalidation.
    @MainActor func awaitTargetReady(timeout: TimeInterval = 10) async throws {
        activation.expectedPID = app.processIdentifier
        do {
            try await HarnessReadiness.waitReady(app: app, timeout: timeout, stage: { self.activation.stage = $0 }, activate: {
                guard let s = try? self.scene() else { return }
                FixtureActivation.activateOnce(&self.activation, app: self.app, launchedURL: self.launchedURL,
                                               usedDefaultPath: self.usedDefaultPath, expectedBundleID: self.expectedBundleID,
                                               manifestPID: s.pid, manifestBundleID: s.bundleID, manifestWindowID: s.windowID)
            }, front: { try self.requireFrontmost() }) {
                let s = try self.scene()
                return (s.windowID, s.frameQuartz.cg)
            }
        } catch {
            activation.failingStage = activation.stage
            throw error
        }
    }

    func finish() async {
        guard !completed else { return }
        completed = true
        FileManager.default.createFile(atPath: directory.appendingPathComponent("exit").path, contents: Data(), attributes: [.posixPermissions: 0o600])
        for _ in 0..<100 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
        if !app.isTerminated { app.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    static func launch(scene: String) async throws -> GlyphFixtureInstance {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let bundleURL: URL
        var usedDefaultPath = true
        if let path = env["DESKTOP_TRANSLATE_GLYPH_FIXTURE_APP"], !path.isEmpty {
            usedDefaultPath = false
            bundleURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let id = Bundle.main.bundleIdentifier ?? ""
            let prefix = "local.cmux.translate.dev."
            guard id.hasPrefix(prefix) else { throw PublicFixtureError.missingBundle }
            let tag = String(id.dropFirst(prefix.count))
            let dev = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            bundleURL = dev.appendingPathComponent("glyph-fixture/\(tag)/Glyph Fixture \(tag).app", isDirectory: true)
        }
        guard fm.fileExists(atPath: bundleURL.path) else { throw PublicFixtureError.missingBundle }
        guard let bundle = Bundle(url: bundleURL), bundle.bundleIdentifier?.hasPrefix(bundlePrefix) == true,
              let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path),
              bundleURL.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else { throw PublicFixtureError.invalidBundle }
        let directory = fm.temporaryDirectory.appendingPathComponent("desktop-glyph-fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--manifest", manifestURL.path, "--scene", scene, "--phase", "stable",
                            "--exit-file", directory.appendingPathComponent("exit").path,
                            "--owner-pid", String(ProcessInfo.processInfo.processIdentifier)]
        config.createsNewApplicationInstance = true
        config.activates = true
        config.environment = [:]
        do {
            let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
                    if let app { continuation.resume(returning: app) }
                    else { continuation.resume(throwing: error ?? PublicFixtureError.unavailable) }
                }
            }
            let instance = GlyphFixtureInstance(app: app, manifestURL: manifestURL, directory: directory, launchedURL: bundleURL,
                                                usedDefaultPath: usedDefaultPath, expectedBundleID: bundle.bundleIdentifier ?? "")
            for _ in 0..<300 {
                try Task.checkCancellation()
                if !app.isTerminated, (try? instance.scene()) != nil { return instance }
                try await Task.sleep(for: .milliseconds(100))
            }
            await instance.finish()
            throw PublicFixtureError.unavailable
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }
}

extension AppDelegate {
    private func json(_ report: GlyphMetricReport) -> Any {
        guard let data = try? JSONEncoder().encode(report), let object = try? JSONSerialization.jsonObject(with: data) else {
            return ["passed": false, "failures": ["reportEncodingFailed"]]
        }
        return object
    }

    /// Source line texts of a region, aligned 1:1 with `lineRects` (soft-wrapped lines joined by "\n").
    /// Anything that does not align yields no boxes for that region, so the metric reports the loss instead of guessing.
    private func lineBoxes(_ region: TextRegion) -> [GlyphObservedBox] {
        let lines = region.text.components(separatedBy: "\n")
        let rects = region.lineRects.isEmpty ? [region.rect] : region.lineRects
        guard lines.count == rects.count else { return [] }
        return zip(lines, rects).map { GlyphObservedBox(text: $0, rect: $1) }
    }

    func runGlyphSmoke() async {
        // Backend is the selected one (config.json); --glyph-pi-smoke is the same geometry path with the configured pi model.
        // Nothing is installed or mocked; a missing local language pack fails before capture, as in the product.
        loadSelectedSettings()
        if mode == .glyphPiSmoke {
            currentSettings.mode = .pi
            if let model = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_PI_MODEL"] { currentSettings.model = model }
            if let executable = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_PI_EXECUTABLE"] { currentSettings.piExecutable = executable }
        }
        var result: [String: Any] = ["backend": currentSettings.mode.rawValue, "workflow": "glyph-smoke"]
        var checks: [String: Bool] = [:]
        let sceneName = ProcessInfo.processInfo.environment["CMUX_TRANSLATE_GLYPH_SCENE"] ?? "boundary"
        result["scene"] = sceneName

        let fixture: GlyphFixtureInstance
        do { fixture = try await GlyphFixtureInstance.launch(scene: sceneName) } catch { smokeFail("独立 glyph fixture 无法启动：\(error.localizedDescription)", result) }
        func fail(_ message: String) async -> Never { await fixture.finish(); smokeFail(message, result) }

        let before: GlyphScene
        do { before = try fixture.scene() } catch { await fail("glyph manifest 无效：\(error.localizedDescription)") }
        do { try await fixture.awaitTargetReady(); result["fixtureActivation"] = fixture.activation.json }
        catch { result["fixtureActivation"] = fixture.activation.json; await fail(error.localizedDescription) }
        do { try installHotkey(initial: .defaultShortcut) } catch { await fail("无法注册默认快捷键：\(error)") }
        do { try fixture.requireFrontmost() } catch { await fail(error.localizedDescription) }

        let started = Date()
        let session = startSession(run: .fullWindow, frontmost: fixture.app)
        let presented = await settle(timeout: 300) { session.phaseDescription == "presenting" || session.phaseDescription == "failed" || session.isFinished }
        result["seconds"] = (Date().timeIntervalSince(started) * 10).rounded() / 10
        result["phase"] = session.phaseDescription
        guard presented, session.phaseDescription == "presenting", let snapshot = session.presentedSnapshot else {
            let status = session.hudStatusText
            session.dismiss(reason: nil)
            await fail(status.isEmpty ? "翻译未进入展示阶段。" : status)
        }
        let after: GlyphScene
        do { after = try fixture.scene() } catch { session.dismiss(reason: nil); await fail("glyph manifest 无效：\(error.localizedDescription)") }

        // OCR stage: the snapshot's own line rects with their line text.
        let ocr = snapshot.regions.flatMap(lineBoxes)
        // Mask stage: overlay `occupied` rects associated to the source region by regionID and line index.
        var masks: [GlyphObservedBox] = []
        var maskAssociationBroken = false
        for item in session.presentedItems where !item.occupancyUnavailable {
            guard let region = snapshot.regions.first(where: { $0.id == item.regionID }) else { maskAssociationBroken = true; continue }
            let lines = lineBoxes(region)
            guard lines.count == item.occupied.count else { maskAssociationBroken = true; continue }
            masks += zip(lines, item.occupied).map { GlyphObservedBox(text: $0.text, rect: $1) }
        }
        let tolerance = 4.0, inflation = 4.0
        let ocrReport = GlyphMetric.measure(scene: after, revisionBefore: before.runRevision, revisionAfter: after.runRevision,
                                            stage: "ocr", observed: ocr, tolerance: tolerance, maxInflation: inflation,
                                            expectedPID: fixture.app.processIdentifier)
        let maskReport = GlyphMetric.measure(scene: after, revisionBefore: before.runRevision, revisionAfter: after.runRevision,
                                             stage: "mask", observed: masks, tolerance: tolerance, maxInflation: inflation,
                                             expectedPID: fixture.app.processIdentifier)
        result["ocrMetric"] = json(ocrReport)
        result["maskMetric"] = json(maskReport)
        checks["ocrEdgesWithin4pt"] = ocrReport.passed && (ocrReport.maxAbsErrorPoints ?? .infinity) <= tolerance
        checks["maskEdgesWithin4pt"] = maskReport.passed && (maskReport.maxAbsErrorPoints ?? .infinity) <= tolerance && !maskAssociationBroken
        checks["sceneStableDuringCapture"] = before.runRevision == after.runRevision && before.sceneID == after.sceneID
        checks["hasChinese"] = session.presentedItems.contains { $0.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        checks["minimumFontSize"] = session.presentedItems.allSatisfy { $0.fontSize >= OverlayItem.minimumFontSize }
        checks["targetStayedFrontmost"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.app.processIdentifier && !NSApp.isActive
        if let end = try? fixture.scene() {
            checks["fixtureReceivedNoInput"] = end.observer.mouseDown == before.observer.mouseDown && end.observer.scroll == before.observer.scroll
                && end.observer.keyDown == before.observer.keyDown
        } else { checks["fixtureReceivedNoInput"] = false }

        // One dismissal through the registered hotkey handler (queued Carbon event; not physical input evidence).
        postSyntheticHotkey()
        checks["hotkeyDismisses"] = await settle { self.session == nil } && session.isFinished && !(session.barrierPanel?.isVisible ?? false)

        binder?.shutdown(); backend?.shutdown(); binder = nil; backend = nil
        result["checks"] = checks
        let failed = checks.filter { !$0.value }.keys.sorted()
        if !failed.isEmpty { result["failedChecks"] = failed; await fixture.finish(); smokeFail("glyph 冒烟断言失败。", result) }
        result["ok"] = true
        await fixture.finish()
        emit(result)
        exit(0)
    }
}
