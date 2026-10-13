import AppKit
import CoreGraphics
import Foundation

/// No titles, guessed application names, or externally loaded plugin code participate in matching.
enum TerminalPluginValidation {
    struct RunningIdentity: Sendable {
        var pid: Int32
        var bundleID: String
        var launchTime: TimeInterval?
        var windowID: UInt32
        var windowOwnerPID: Int32
        var frame: CGRect
    }

    static func matches(target: CaptureTarget, identity: RunningIdentity) -> Bool {
        guard let launch = target.appLaunchTime, launch.isFinite,
              let runningLaunch = identity.launchTime, runningLaunch.isFinite else { return false }
        return target.pid > 0 && target.windowID != 0 &&
            target.pid == identity.pid && target.pid == identity.windowOwnerPID &&
            target.bundleID == identity.bundleID && target.windowID == identity.windowID &&
            launch == runningLaunch && target.frame == identity.frame && validRect(target.frame)
    }

    static func validRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
    }

    /// Adapters cannot redirect an operation to a different window, pane, generation, or crop.
    static func validated(outcome: RouterOutcome, target: CaptureTarget) -> RouterOutcome {
        let snapshot: CaptureSnapshot
        switch outcome {
        case .snapshot(let value), .partial(let value, _): snapshot = value
        default: return outcome
        }
        let captured = snapshot.target
        guard captured.sameContent(as: target), captured.bundleID == target.bundleID,
              captured.frame == target.frame, captured.tabID == target.tabID, captured.paneID == target.paneID,
              captured.selection == target.selection else {
            return .error("插件结果的窗口、pane、选区或 revision 已变化，请重新捕获。")
        }
        do {
            try snapshot.validate(currentRevision: target.revision)
            let crop = target.effectiveSelection
            guard validRect(crop), CGRect(origin: .zero, size: target.frame.size).contains(crop),
                  snapshot.regions.allSatisfy({ region in
                      crop.contains(region.rect) && region.lineRects.allSatisfy { crop.contains($0) }
                  }) else {
                return .error("插件文字区域超出本次选区。")
            }
            if let transform = snapshot.transform, transform.crop != crop {
                return .error("插件坐标变换与本次选区不一致。")
            }
            return outcome
        } catch {
            return .error("插件快照无效：\(error)")
        }
    }
}

struct TerminalCaptureSource: Sendable {
    var bundleID: String
    var evidence: TerminalPluginEvidence
    var provenance: SnapshotProvenance?
}

/// User-facing built-in capability evidence, never snapshot text or subprocess diagnostics.
struct TerminalPluginMetadata: Sendable {
    var application: String
    var support: String
    var applicationVersion: String
    var versionUnknown: Bool
    var interface: String
    var limitation: String
    var warnings: [String]

    var summary: String {
        let version = versionUnknown ? "\(applicationVersion)（版本未验证 / unknown）" : applicationVersion
        return (["\(application) · \(support) · \(version)", "接口：\(interface)",
                 "限制：\(limitation)"] + warnings.map { "警告：\($0)" }).joined(separator: "\n")
    }
}

struct TerminalPluginRoute: Sendable {
    var outcome: RouterOutcome
    var metadata: TerminalPluginMetadata?
}

/// This metadata is deliberately finite: it is not a command dispatcher or a shell-command API.
struct TerminalPluginCLIWhitelist: Sendable {
    var bundleID: String
    var executableRelativePath: String
    var arguments: [String]
}

@MainActor
final class TerminalPluginRegistry {
    private let plugins: [any BuiltinTerminalPlugin]
    private var operation: UInt64 = 0
    private(set) var currentCaptureSource: TerminalCaptureSource?

    nonisolated static let safeCLIWhitelist: [TerminalPluginCLIWhitelist] = [
        .init(bundleID: "com.cmuxterm.app", executableRelativePath: "Contents/Resources/bin/cmux", arguments: ["identify", "--no-caller", "--json"]),
        .init(bundleID: "fun.tw93.kaku", executableRelativePath: "Contents/MacOS/kaku", arguments: ["--skip-config", "--version"])
    ]

    nonisolated static func allowsCLI(bundleID: String, relativePath: String, arguments: [String]) -> Bool {
        safeCLIWhitelist.contains {
            $0.bundleID == bundleID && $0.executableRelativePath == relativePath && $0.arguments == arguments
        }
    }

    /// Display names for the HUD's pre-capture "matched terminal" line (bundle IDs match the built-in adapters).
    nonisolated static let supportedTerminalNames: [String: String] = [
        "com.cmuxterm.app": "cmux", "com.googlecode.iterm2": "iTerm2", "com.apple.Terminal": "Terminal.app",
        "com.mitchellh.ghostty": "Ghostty", "fun.tw93.kaku": "Kaku"
    ]

    init() {
        plugins = [CmuxPlugin(), ITermPlugin(), GhosttyPlugin(), AppleTerminalPlugin(), KakuPlugin()]
        precondition(Set(plugins.map(\.bundleID)).count == plugins.count, "Duplicate built-in plugin bundle ID")
    }

    /// A supported bundle whose identity is no longer provable must not become an OCR fallback.
    func hasPlugin(for target: CaptureTarget) -> Bool {
        plugins.contains { $0.bundleID == target.bundleID }
    }

    func plugin(for target: CaptureTarget) -> (any BuiltinTerminalPlugin)? {
        guard runtimeMatches(target) else { return nil }
        return plugins.first { $0.bundleID == target.bundleID }
    }

    func invalidate() {
        operation &+= 1
        currentCaptureSource = nil
    }

    func probe(target: CaptureTarget) async -> TerminalPluginProbe? {
        operation &+= 1
        let generation = operation
        currentCaptureSource = nil
        guard hasPlugin(for: target) else { return nil }
        guard let plugin = plugin(for: target) else {
            return rejectedProbe(target, message: "终端进程或窗口身份已变化，请重新捕获。")
        }
        var result = await plugin.probe(target: target)
        guard generation == operation else { return rejectedProbe(target, message: "插件操作已被新请求替代。") }
        guard runtimeMatches(target), result.bundleID == target.bundleID else {
            return rejectedProbe(target, message: "终端进程或窗口身份在探测期间变化。")
        }
        result.outcome = TerminalPluginValidation.validated(outcome: result.outcome, target: target)
        switch result.outcome {
        case .error, .needsPermission, .unsupported, .none:
            result.focusedPaneRect = nil
            result.paneID = nil
        default: break
        }
        // Pane defaults require all independent evidence, not just a rectangle supplied by an adapter.
        if let rect = result.focusedPaneRect {
            let bounds = CGRect(origin: .zero, size: target.frame.size)
            if result.paneID?.isEmpty != false || !TerminalPluginValidation.validRect(rect) || !bounds.contains(rect) ||
                !result.evidence.versionVerified || result.evidence.visibleText != .verified ||
                result.evidence.textGeometry != .verified || result.evidence.paneLayout != .verified {
                result.focusedPaneRect = nil
                result.paneID = nil
            }
        } else { result.paneID = nil }
        currentCaptureSource = .init(bundleID: result.bundleID, evidence: result.evidence, provenance: provenance(result.outcome))
        return result
    }

    /// Keep routing evidence with its result rather than consulting mutable registry state later.
    func captureRoute(target: CaptureTarget, selection: CGRect) async -> TerminalPluginRoute {
        let expectedOperation = operation &+ 1
        let outcome = await capture(target: target, selection: selection)
        guard operation == expectedOperation, let source = currentCaptureSource else {
            return TerminalPluginRoute(outcome: outcome, metadata: nil)
        }
        let evidence = source.evidence
        let support: String
        switch outcome {
        case .snapshot(let snapshot): support = snapshot.provenance == .native ? "native" : "partial"
        case .partial: support = "partial"
        default: support = "unsupported"
        }
        // Built-in partial warnings are fixed capability notes, not subprocess output or captured text.
        var warnings: [String] = []
        if case .partial(_, let notes) = outcome { warnings = notes }
        if !evidence.versionVerified { warnings.append("此应用版本尚未验证；不能据此宣称原生定位文字支持。") }
        if support == "partial" { warnings.append("应用插件只提供部分能力；定位文字需要共享屏幕 OCR。") }
        return TerminalPluginRoute(outcome: outcome, metadata: .init(
            application: Self.supportedTerminalNames[source.bundleID] ?? "终端应用",
            support: support, applicationVersion: evidence.applicationVersion,
            versionUnknown: !evidence.versionVerified, interface: evidence.interface,
            limitation: evidence.limitation, warnings: warnings))
    }

    func capture(target: CaptureTarget, selection: CGRect) async -> RouterOutcome {
        operation &+= 1
        let generation = operation
        currentCaptureSource = nil
        guard hasPlugin(for: target) else { return .none }
        currentCaptureSource = .init(bundleID: target.bundleID ?? "", evidence: rejectedProbe(target,
            message: "捕获尚未完成；窗口身份、接口或权限未验证。").evidence, provenance: nil)
        guard TerminalPluginValidation.validRect(selection), selection == target.effectiveSelection,
              CGRect(origin: .zero, size: target.frame.size).contains(selection) else {
            return .error("终端捕获选区无效或与锁定目标不一致。")
        }
        guard let plugin = plugin(for: target) else { return .error("终端进程或窗口身份已变化，请重新捕获。") }
        let probe = await plugin.probe(target: target)
        guard generation == operation, runtimeMatches(target), probe.bundleID == target.bundleID else {
            return .error("终端捕获已过期，请重新捕获。")
        }
        let probeOutcome = TerminalPluginValidation.validated(outcome: probe.outcome, target: target)
        // Permission and execution failures stay explicit; the registry never silently invokes OCR.
        switch probeOutcome {
        case .error, .needsPermission, .unsupported:
            currentCaptureSource = .init(bundleID: probe.bundleID, evidence: probe.evidence, provenance: nil)
            return probeOutcome
        default: break
        }
        let result = await plugin.capture(target: target, selection: selection)
        guard generation == operation, runtimeMatches(target) else { return .error("终端捕获已过期，请重新捕获。") }
        let checked = TerminalPluginValidation.validated(outcome: result, target: target)
        currentCaptureSource = .init(bundleID: probe.bundleID, evidence: probe.evidence, provenance: provenance(checked))
        return checked
    }

    private func provenance(_ outcome: RouterOutcome) -> SnapshotProvenance? {
        switch outcome {
        case .snapshot(let snapshot), .partial(let snapshot, _): return snapshot.provenance
        default: return nil
        }
    }

    private func rejectedProbe(_ target: CaptureTarget, message: String) -> TerminalPluginProbe {
        .init(bundleID: target.bundleID ?? "", evidence: .init(applicationVersion: "未知", versionVerified: false,
            interface: "精确 bundle / PID / launch / CGWindow 身份验证", visibleText: .unsupported,
            textGeometry: .unsupported, paneLayout: .unsupported, contentRevision: .unsupported,
            fontRevision: .unsupported, limitation: message), outcome: .error(message))
    }

    private func runtimeMatches(_ target: CaptureTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              let bundleID = app.bundleIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], target.windowID) as? [[String: Any]] else { return false }
        let matching = windows.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID }
        guard matching.count == 1, let window = matching.first,
              let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return TerminalPluginValidation.matches(target: target, identity: .init(pid: app.processIdentifier,
            bundleID: bundleID, launchTime: app.launchDate?.timeIntervalSince1970, windowID: target.windowID,
            windowOwnerPID: owner.int32Value, frame: frame))
    }
}
