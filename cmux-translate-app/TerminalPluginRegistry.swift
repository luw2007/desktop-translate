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

    static let safeCLIWhitelist: [TerminalPluginCLIWhitelist] = [
        .init(bundleID: "com.cmuxterm.app", executableRelativePath: "Contents/Resources/bin/cmux", arguments: ["identify", "--no-caller", "--json"]),
        .init(bundleID: "fun.tw93.kaku", executableRelativePath: "Contents/MacOS/kaku", arguments: ["--skip-config", "--version"])
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

    func capture(target: CaptureTarget, selection: CGRect) async -> RouterOutcome {
        operation &+= 1
        let generation = operation
        currentCaptureSource = nil
        guard hasPlugin(for: target) else { return .none }
        guard TerminalPluginValidation.validRect(selection), selection == target.effectiveSelection,
              CGRect(origin: .zero, size: target.frame.size).contains(selection) else {
            return .error("终端捕获选区无效或与锁定目标不一致。")
        }
        guard let plugin = plugin(for: target) else { return .error("终端进程或窗口身份已变化，请重新捕获。") }
        let probe = await plugin.probe(target: target)
        guard generation == operation, runtimeMatches(target), probe.bundleID == target.bundleID else {
            return .error("终端捕获已过期，请重新捕获。")
        }
        // Permission and execution failures stay explicit; the registry never silently invokes OCR.
        switch probe.outcome {
        case .error, .needsPermission:
            currentCaptureSource = .init(bundleID: probe.bundleID, evidence: probe.evidence, provenance: nil)
            return probe.outcome
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
