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
    var errorDescription: String? {
        switch self {
        case .missingBundle: return "独立公共 fixture 尚未构建；请运行 fixtures/build-fixture.sh。"
        case .invalidBundle: return "fixture 必须是独立的 local.desktop-translate.public-fixture 应用。"
        case .unavailable: return "独立公共 fixture 未启动或尚未提供窗口。"
        case .invalidManifest: return "公共 fixture 的进程、窗口或坐标清单不匹配。"
        }
    }
}

@MainActor
enum PublicFixture {
    enum Option { case black, sharingNone, noText }
    static let bundleID = "local.desktop-translate.public-fixture"
    final class Instance {
        let app: NSRunningApplication
        private let manifestURL: URL
        private let directory: URL
        init(app: NSRunningApplication, manifestURL: URL, directory: URL) {
            self.app = app; self.manifestURL = manifestURL; self.directory = directory
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
        func terminate() {
            // Only the instance opened here, never an existing user's process.
            app.terminate()
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
        var arguments = ["--manifest", manifestURL.path]
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
            instance.terminate()
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
        fixture?.terminate()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
        exit(code)
    }
}
