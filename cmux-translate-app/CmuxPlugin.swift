import AppKit
import Foundation

/// Read-only cmux adapter.  cmux's CLI can read a viewport, but its public
/// interfaces do not map that text (or panes) to Core Graphics points.  This
/// adapter therefore emits a layout-only partial snapshot and leaves positioned
/// text to the shared OCR provider.
@MainActor
struct CmuxPlugin: BuiltinTerminalPlugin {
    let bundleID = CmuxPlugin.bundleIDConstant
    static let bundleIDConstant = "com.cmuxterm.app"

    private static let cli = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    private static let knownVersion = "0.65.0"
    private static let identifyArguments = ["identify", "--no-caller", "--json"]
    private static let interfaceDescription =
        "cmux 0.65.0 bundled CLI identify/read-screen viewport interface; no pixel text or pane geometry"
    private static let geometryLimitation =
        "cmux read-screen exposes viewport text but no text-cell, pane, split, or selection geometry; sdef IDs are not Core Graphics window IDs. Native positioned text is unsupported; shared OCR is required."

    func probe(target: CaptureTarget) async -> TerminalPluginProbe {
        let version = TerminalPluginApplication.version(bundleID: bundleID)
        let runtimeMatches = Self.validateRuntimeTarget(target, bundleID: bundleID)
        guard runtimeMatches else {
            return TerminalPluginProbe(
                bundleID: bundleID,
                evidence: Self.evidence(version: version, level: .unsupported,
                                        limitation: "cmux target process/window is not running or no longer matches."),
                outcome: .unsupported("目标不是正在运行且匹配的 cmux 窗口。"))
        }

        do {
            // identify returns only target metadata.  We intentionally do not print,
            // retain, or expose its output; no private terminal text is probed here.
            try await Self.runMetadataProbe()
            return TerminalPluginProbe(
                bundleID: bundleID,
                evidence: Self.evidence(version: version, level: .partial,
                                        limitation: Self.geometryLimitation),
                outcome: Self.partialOutcome(target: target, selection: nil))
        } catch {
            return TerminalPluginProbe(
                bundleID: bundleID,
                evidence: Self.evidence(version: version, level: .unsupported,
                                        limitation: "cmux 的只读 metadata 探针不可用；未读取或显示终端文字。"),
                outcome: .error("cmux 只读探针不可用。"))
        }
    }

    func capture(target: CaptureTarget, selection: CGRect) async -> RouterOutcome {
        guard target.bundleID == nil || target.bundleID == bundleID else {
            return .unsupported("目标不是 cmux。")
        }
        guard Self.validateRuntimeTarget(target, bundleID: bundleID) else {
            return .unsupported("目标不是正在运行且匹配的 cmux 窗口。")
        }
        guard TerminalPluginValidation.validRect(selection), selection == target.effectiveSelection,
              CGRect(origin: .zero, size: target.frame.size).contains(selection) else {
            return .error("cmux 选择区域无效。")
        }
        // Preserve the caller's optional selection verbatim, including whole-window nil.
        return Self.partialOutcome(target: target, selection: selection)
    }

    private static func evidence(version: String, level: TerminalPluginEvidence.Level,
                                 limitation: String) -> TerminalPluginEvidence {
        let versionVerified = version == knownVersion
        let effective: TerminalPluginEvidence.Level =
            level == .verified && !versionVerified ? .partial : level
        return TerminalPluginEvidence(
            applicationVersion: version,
            versionVerified: versionVerified,
            interface: interfaceDescription,
            visibleText: effective == .unsupported ? .unsupported : .partial,
            textGeometry: .unsupported,
            paneLayout: .unsupported,
            contentRevision: .unsupported,
            fontRevision: .unsupported,
            limitation: limitation)
    }

    private static func partialOutcome(target: CaptureTarget, selection: CGRect?) -> RouterOutcome {
        let snapshotTarget = target
        let bounds = selection ?? target.effectiveSelection
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            return .error("cmux 目标窗口边界无效，无法创建捕获快照。")
        }

        let version = TerminalPluginApplication.version(bundleID: CmuxPlugin.bundleIDConstant)
        let versionVerified = version == knownVersion
        let capabilities = SnapshotCapabilities(
            visibleText: CapabilityEvidence(
                level: .partial, interface: interfaceDescription,
                appVersion: version, versionVerified: versionVerified,
                note: "read-screen 可读取 viewport，但没有可验证的文字位置；不作为原生定位文字使用。"),
            textGeometry: CapabilityEvidence(
                level: .unsupported, interface: interfaceDescription,
                appVersion: version, versionVerified: versionVerified,
                note: "cmux CLI/sdef 不提供像素、字形或选择区域几何。"),
            paneLayout: CapabilityEvidence(
                level: .unsupported, interface: interfaceDescription,
                appVersion: version, versionVerified: versionVerified,
                note: "workspace/surface/pane 标识没有与 CG 窗口坐标的映射。"),
            contentRevision: CapabilityEvidence(
                level: .unsupported, interface: interfaceDescription,
                appVersion: version, versionVerified: versionVerified,
                note: "没有稳定的可见 viewport revision。"),
            fontRevision: CapabilityEvidence(
                level: .unsupported, interface: interfaceDescription,
                appVersion: version, versionVerified: versionVerified,
                note: "没有可验证的字体或字形网格 revision。"))
        let snapshot = CaptureSnapshot(
            target: snapshotTarget,
            capabilities: capabilities,
            provenance: .pluginOCR,
            transform: nil,
            layout: [LayoutRegion(id: "window", role: .window, rect: bounds)],
            regions: [])
        return .partial(snapshot, warnings: [
            Self.geometryLimitation,
            "未读取或伪造 cmux 原生文字区域；共享 OCR 仅使用当前窗口选区。"
        ])
    }

    /// Verify the process identity and the exact Core Graphics window owner before
    /// treating a CaptureTarget as usable.  No focus, workspace, pane, or action is
    /// requested, and sdef identifiers are never cast to CGWindowID.
    private static func validateRuntimeTarget(_ target: CaptureTarget, bundleID: String) -> Bool {
        guard target.pid > 0, target.windowID > 0,
              let process = NSRunningApplication(processIdentifier: target.pid),
              !process.isTerminated,
              process.bundleIdentifier == bundleID else { return false }
        if let launchTime = target.appLaunchTime, let actual = process.launchDate?.timeIntervalSince1970,
           abs(actual - launchTime) > 1.0 { return false }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { info in
            guard let id = info[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  id.uint32Value == target.windowID,
                  ownerPID.int32Value == target.pid,
                  layer.intValue == 0 else { return false }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return false
            }
            return frame.width > 0 && frame.height > 0
        }
    }

    /// Run only the fixed, read-only metadata command through the disclaimed
    /// launcher.  The output is parsed for JSON shape and then discarded.
    private static func runMetadataProbe() async throws {
        let request = DisclaimSpawnRequest(
            executable: cli,
            arguments: identifyArguments,
            environment: DisclaimEnvironment.terminalCLI(),
            timeout: 5,
            maxStandardOutput: 256 * 1024,
            maxStandardError: 64 * 1024,
            retainStandardError: false)
        let result = try await DisclaimSpawner.run(request)
        guard result.exitStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: result.standardOutput),
              object is [String: Any] else {
            throw CmuxMetadataError.invalidResponse
        }
    }

    private enum CmuxMetadataError: Error {
        case invalidResponse
    }
}
