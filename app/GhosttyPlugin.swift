import AppKit
import CoreGraphics
import Foundation

/// Ghostty 1.3.1 exposes window/tab/terminal identities and focused-terminal metadata,
/// but no readable viewport text or native pane/text geometry. No AppleEvents are sent:
/// granting Automation cannot improve this adapter's positioned capture capability.
@MainActor
struct GhosttyPlugin: BuiltinTerminalPlugin {
    let bundleID = "com.mitchellh.ghostty"
    private let knownVersion = "1.3.1"
    private let limitation = "Ghostty 的脚本字典仅提供窗口/tab/terminal 身份和聚焦 terminal 元数据，不提供可见文字或分屏/字形几何。仅确认完整窗口边界（包含标题栏），由共享 OCR 读取所选区域；不将整窗称为聚焦 pane。"

    func probe(target: CaptureTarget) async -> TerminalPluginProbe {
        let version = runningVersion(target: target)
        let evidence = TerminalPluginEvidence(
            applicationVersion: version,
            versionVerified: version == knownVersion,
            interface: "Ghostty 1.3.1 scripting dictionary (static evidence); CGWindow bounds",
            visibleText: .unsupported,
            textGeometry: .unsupported,
            paneLayout: .partial,
            contentRevision: .unsupported,
            fontRevision: .unsupported,
            limitation: limitation + (version == knownVersion ? "" : " 当前版本未经接口验证。")
        )
        return TerminalPluginProbe(bundleID: bundleID, evidence: evidence,
                                   outcome: windowLayout(target: target, selection: target.effectiveSelection))
    }

    func capture(target: CaptureTarget, selection: CGRect) async -> RouterOutcome {
        windowLayout(target: target, selection: selection)
    }

    private func runningVersion(target: CaptureTarget) -> String {
        guard target.bundleID == bundleID,
              let application = NSRunningApplication(processIdentifier: target.pid),
              !application.isTerminated, application.bundleIdentifier == bundleID,
              let url = application.bundleURL, let bundle = Bundle(url: url),
              bundle.bundleIdentifier == bundleID else { return "未知" }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    private func windowLayout(target: CaptureTarget, selection: CGRect) -> RouterOutcome {
        guard target.bundleID == bundleID else { return .unsupported("Ghostty 插件仅支持精确 bundle com.mitchellh.ghostty。") }
        guard let application = NSRunningApplication(processIdentifier: target.pid),
              !application.isTerminated, application.bundleIdentifier == bundleID,
              let expectedLaunch = target.appLaunchTime,
              let launchDate = application.launchDate,
              launchDate.timeIntervalSince1970 == expectedLaunch else {
            return .error("Ghostty 目标进程已改变或无法验证，请重新捕获。")
        }
        guard target.frame.origin.x.isFinite, target.frame.origin.y.isFinite,
              target.frame.width.isFinite, target.frame.height.isFinite,
              target.frame.width > 0, target.frame.height > 0,
              TerminalPluginValidation.validRect(selection), selection == target.effectiveSelection,
              CGRect(origin: .zero, size: target.frame.size).contains(selection) else {
            return .error("Ghostty 目标窗口或选区无效。")
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID &&
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid &&
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
              }),
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame == target.frame else {
            return .error("Ghostty 目标窗口已关闭、隐藏或改变边界，请重新捕获。")
        }
        let version = runningVersion(target: target)
        let verifiedVersion = version == knownVersion
        let unsupported = CapabilityEvidence(level: .unsupported,
            interface: "Ghostty scripting dictionary", appVersion: version,
            versionVerified: verifiedVersion, note: limitation)
        let windowEvidence = CapabilityEvidence(level: .partial, interface: "CGWindowList window bounds",
            appVersion: version, versionVerified: verifiedVersion,
            note: "仅完整窗口边界；无聚焦 pane、content inset 或分屏几何证据。")
        let snapshot = CaptureSnapshot(target: target,
            capabilities: SnapshotCapabilities(visibleText: unsupported, textGeometry: unsupported,
                paneLayout: windowEvidence, contentRevision: unsupported, fontRevision: unsupported),
            provenance: .native,
            layout: [LayoutRegion(id: "ghostty-window-\(target.windowID)", role: .window,
                                  rect: CGRect(origin: .zero, size: target.frame.size))],
            regions: [])
        var warnings = [limitation]
        if !verifiedVersion { warnings.append("Ghostty \(version) 未经接口验证；不声明原生文字或几何支持。") }
        return .partial(snapshot, warnings: warnings)
    }
}
