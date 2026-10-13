import AppKit
import Foundation
import CoreGraphics

/// Manifest is public fixed sample data only. No private screen text or screenshot is persisted.
struct FixtureRect: Codable, Equatable {
    let x: Double; let y: Double; let w: Double; let h: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
struct FixtureItem: Codable {
    let id: String; let text: String; let kind: String; let rect: FixtureRect
    /// Measured per-line extents of the exact drawn string (window-local points, top-left). Public manifest only;
    /// product output never contains these and the verifier compares geometry, never text from the product.
    let lines: [FixtureRect]?
}
struct FixtureManifest: Codable {
    let schema: Int
    let pid: Int32
    let bundleID: String
    let windowID: UInt32
    let frameQuartz: FixtureRect
    let contentTopInset: Double
    let backingScale: Double
    let displayID: UInt32
    let mode: String
    let items: [FixtureItem]
    let mouseDownCount: Int
    let scrollCount: Int
    let keyDownCount: Int
    let buttonPressCount: Int
    let resignActiveCount: Int
    let isActive: Bool
    let sequence: Int
}

enum PublicFixtureError: LocalizedError {
    case missingBundle, invalidBundle, unavailable, invalidManifest
    case notFrontmost
    /// Numeric, owned-fixture-only diagnostics (pid/windowID/sharing/layer/frame); never other apps' windows.
    case notReady(String)
    var errorDescription: String? {
        switch self {
        case .missingBundle: return "独立公共 fixture 尚未构建；请运行 fixtures/build-fixture.sh。"
        case .invalidBundle: return "fixture 必须是独立的 local.desktop-translate.public-fixture 应用。"
        case .unavailable: return "独立公共 fixture 未启动或尚未提供窗口。"
        case .invalidManifest: return "公共 fixture 的进程、窗口或坐标清单不匹配。"
        case .notFrontmost: return "被验证的 fixture 不是前台应用（预期 PID/bundle 不匹配）；未捕获任何屏幕，本验证不抢焦点。未记录其他应用的任何信息。"
        case .notReady(let detail): return "公共 fixture 窗口尚未满足捕获前提：\(detail)"
        }
    }
}

@MainActor
enum PublicFixture {
    enum Option { case black, sharingNone, noText }
    nonisolated static let bundleID = "local.desktop-translate.public-fixture"
    final class Instance {
        let app: NSRunningApplication
        private let manifestURL: URL
        private let directory: URL
        private let exitURL: URL
        private var completed = false
        init(app: NSRunningApplication, manifestURL: URL, directory: URL) {
            self.app = app; self.manifestURL = manifestURL; self.directory = directory
            self.exitURL = directory.appendingPathComponent("exit")
        }
        func manifest() throws -> FixtureManifest {
            let data = try Data(contentsOf: manifestURL)
            guard data.count <= 1_000_000 else { throw PublicFixtureError.invalidManifest }
            let manifest = try JSONDecoder().decode(FixtureManifest.self, from: data)
            guard manifest.schema == 1, manifest.pid == app.processIdentifier,
                  manifest.bundleID == PublicFixture.bundleID, manifest.windowID > 0,
                  manifest.frameQuartz.cgRect.width > 0, manifest.frameQuartz.cgRect.height > 0 else { throw PublicFixtureError.invalidManifest }
            return manifest
        }
        /// Bounded wait for the natural LaunchServices activation of THIS fixture (PID + bundle ID). Polls only;
        /// never activates, retries a launch, or accepts any other frontmost app.
        func awaitFrontmost(timeout: TimeInterval = 10) async throws {
            let end = Date().addingTimeInterval(timeout)
            while true {
                do { try requireFrontmost(); return }
                catch let error as PublicFixtureError {
                    if Date() >= end { throw error }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        /// Launch readiness (a protocol prerequisite, not re-capture polling); shared implementation in HarnessReadiness.
        @MainActor func awaitTargetReady(timeout: TimeInterval = 10) async throws {
            try await HarnessReadiness.waitReady(app: app, timeout: timeout, front: { try self.requireFrontmost() }) {
                let m = try self.manifest()
                return (m.windowID, m.frameQuartz.cgRect)
            }
        }
        /// The capture precondition for every fixture command: the frontmost app IS this exact fixture
        /// (PID and bundle ID). Never activates anything; a mismatch is reported, not repaired.
        func requireFrontmost() throws {
            guard !app.isTerminated, let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier == app.processIdentifier, front.bundleIdentifier == PublicFixture.bundleID else {
                throw PublicFixtureError.notFrontmost
            }
        }
        /// Harness completion: create the exit file; the fixture quits itself. Call only after the overlay is dismissed
        /// and results are recorded, so foreground return to the launching terminal cannot precede any assertion.
        func finish() async {
            guard !completed else { return }
            completed = true
            FileManager.default.createFile(atPath: exitURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            for _ in 0..<100 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
            if !app.isTerminated { app.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    static func launch(frame: CGRect? = nil, options: [Option] = []) async throws -> Instance {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let bundleURL: URL
        if let path = env["DESKTOP_TRANSLATE_FIXTURE_APP"], !path.isEmpty {
            bundleURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            // Dev app is <repo>/.dev/build/<app>.app; fixture shares that isolated .dev directory.
            let dev = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            bundleURL = dev.appendingPathComponent("fixture/Public Fixture.app", isDirectory: true)
        }
        guard fm.fileExists(atPath: bundleURL.path) else { throw PublicFixtureError.missingBundle }
        guard let bundle = Bundle(url: bundleURL), bundle.bundleIdentifier == bundleID,
              let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path),
              bundleURL.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else { throw PublicFixtureError.invalidBundle }
        let directory = fm.temporaryDirectory.appendingPathComponent("desktop-public-fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var arguments = ["--manifest", manifestURL.path, "--exit-file", directory.appendingPathComponent("exit").path,
                         "--owner-pid", String(ProcessInfo.processInfo.processIdentifier)]
        if let frame {
            arguments += ["--frame", "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"]
        }
        for option in options {
            switch option { case .black: arguments.append("--black"); case .sharingNone: arguments.append("--sharing-none"); case .noText: arguments.append("--no-text") }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.createsNewApplicationInstance = true
        config.activates = true
        config.environment = [:]
        do {
            // LaunchServices opens an independent public app. No AppleScript/events/keystrokes/focus injection.
            let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
                    if let app { continuation.resume(returning: app) }
                    else { continuation.resume(throwing: error ?? PublicFixtureError.unavailable) }
                }
            }
            let instance = Instance(app: app, manifestURL: manifestURL, directory: directory)
            // isActive tracks NSApp activation, which macOS may deny a freshly launched app while
            // another app holds focus; window presence is the real capture precondition.
            for _ in 0..<300 {
                try Task.checkCancellation()
                if !app.isTerminated, let manifest = try? instance.manifest(),
                   manifest.windowID > 0, !manifest.items.isEmpty || manifest.mode != "text" { return instance }
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

/// S0 permission evidence is distinct from --smoke: precisely one cropped-window SCK call, no OCR,
/// no saved screenshots and no Accessibility permission calls. Output contains only public metadata.
@MainActor
enum PermissionProbe {
    static func run() async -> Never {
        var fixture: PublicFixture.Instance?
        var report: [String: Any] = ["mode": "permission-probe", "ocr": false, "imageSaved": false, "sckCalls": 0]
        var code: Int32 = 1
        do {
            fixture = try await PublicFixture.launch()
            guard let fixture else { throw PublicFixtureError.unavailable }
            let manifest = try fixture.manifest()
            report["fixturePID"] = manifest.pid
            report["fixtureWindowID"] = manifest.windowID
            try await fixture.awaitFrontmost()
            try await fixture.awaitTargetReady()
            let target = try TargetLocker.lock(app: fixture.app).get()
            guard target.windowID == manifest.windowID, target.frame == manifest.frameQuartz.cgRect else { throw PublicFixtureError.invalidManifest }
            // One SCK capture can present Screen Recording consent; a denial is a precise blocker.
            report["screenRecordingPreflight"] = await ScreenCapturePermission.preflight()
            report["sckCalls"] = 1
            let size = try await DesktopCapture.permissionShot(target: target)
            report["pixelWidth"] = size.width; report["pixelHeight"] = size.height
            report["ok"] = true; code = 0
        } catch let error as PublicFixtureError { report["ok"] = false; report["error"] = error.localizedDescription }
        catch let error as TargetLockError { report["ok"] = false; report["error"] = error.localizedDescription }
        catch {
            report["ok"] = false
            report["error"] = "独立公共窗口 SCK 探针未成功；请在系统设置 → 隐私与安全性 → 屏幕录制中授权此开发应用，并重新启动后再试。未请求辅助功能权限。"
            report["blocker"] = "screen-recording-or-window-capture"
        }
        await fixture?.finish()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
        exit(code)
    }
}

/// Harness-only launch readiness for an OWNED fixture window (never product capture, never other apps' windows).
/// Succeeds only when the on-screen list shows EXACTLY the manifest's windowID, owned by the fixture PID, layer 0,
/// alpha > 0, frame equal to the manifest frame and sharing state 1 or 2 (not none) on at least two consecutive
/// ticks, the PID has no other ordinary window, and the unchanged product `TargetLocker.lock` then agrees.
/// A manifest windowID/frame change or a row that violates layer/alpha/frame fails closed at once; a missing row or
/// sharing 0 only waits until the deadline. Failures report fixture-owned numbers only. No capture, no activation.
@MainActor
enum HarnessReadiness {
    static func waitReady(app: NSRunningApplication, timeout: TimeInterval, front: () throws -> Void,
                        manifest: () throws -> (windowID: UInt32, frame: CGRect)) async throws {
        try front()
        let first = try manifest()
        let pid = app.processIdentifier
        let end = Date().addingTimeInterval(timeout)
        var consecutive = 0
        var last = "row=absent"
        while true {
            let now = try manifest()
            guard now.windowID == first.windowID, now.frame == first.frame else {
                throw PublicFixtureError.notReady("manifest changed pid=\(pid) windowID=\(first.windowID)→\(now.windowID) frame=\(first.frame)→\(now.frame)")
            }
            if let row = TargetLocker.publication(windowID: now.windowID, pid: pid) {
                last = "pid=\(pid) windowID=\(now.windowID) sharing=\(row.sharing) layer=\(row.layer) alpha=\(row.alpha) frame=\(row.frame) manifestFrame=\(now.frame)"
                guard row.layer == 0, row.alpha > 0, row.frame == now.frame else { throw PublicFixtureError.notReady(last) }
                if row.sharing == 1 || row.sharing == 2 { consecutive += 1 } else { consecutive = 0 }
                if consecutive >= 2 {
                    guard TargetLocker.ordinaryWindowIDs(pid: pid) == [now.windowID] else {
                        throw PublicFixtureError.notReady("\(last) ordinaryWindowIDs=\(TargetLocker.ordinaryWindowIDs(pid: pid))")
                    }
                    switch TargetLocker.lock(app: app) {
                    case .success(let target):
                        guard target.windowID == now.windowID, target.frame == now.frame else {
                            throw PublicFixtureError.notReady("\(last) lockedWindowID=\(target.windowID) lockedFrame=\(target.frame)")
                        }
                        return
                    case .failure(let error):
                        throw PublicFixtureError.notReady("\(last) lock=\(error.localizedDescription)")
                    }
                }
            } else { consecutive = 0; last = "pid=\(pid) windowID=\(now.windowID) row=absent" }
            guard Date() < end else { throw PublicFixtureError.notReady("timeout \(last) consecutiveReady=\(consecutive)") }
            try front()
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
