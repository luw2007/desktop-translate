import AppKit
import Foundation

/// Kaku exposes a WezTerm-compatible CLI, but its process-wide pane listing does
/// not include a Core Graphics window map and `get-text` starts at screen row 0
/// rather than proving the currently visible viewport.  The plugin therefore
/// never presents that output as positioned text.  Shared OCR owns positioned
/// capture for Kaku.
@MainActor
struct KakuPlugin: BuiltinTerminalPlugin {
    let bundleID = "fun.tw93.kaku"

    private static let knownInterfaceVersion = "0.19.0"
    private static let executableRelativePath = "Contents/MacOS/kaku"
    private static let interfaceDescription =
        "Kaku 只读 CLI --skip-config --version；WezTerm-compatible list/get-text 无 CG 窗口映射，get-text 从 screen row 0 开始"
    private static let geometryLimitation =
        "Kaku CLI 没有 pane 到 Core Graphics 窗口坐标的映射，且 get-text 未证明是当前可见 viewport；仅返回窗口布局，文字位置由共享 OCR 生成。"

    func probe(target: CaptureTarget) async -> TerminalPluginProbe {
        guard validateRuntimeTarget(target) else {
            return TerminalPluginProbe(
                bundleID: bundleID,
                evidence: makeEvidence(target: target, cliVersion: nil),
                outcome: .unsupported("目标不是正在运行且匹配的 Kaku 窗口。")
            )
        }

        let executable = TerminalPluginApplication.executable(
            bundleID: bundleID,
            relativePath: Self.executableRelativePath
        )
        let cliVersion = await Self.readMetadataVersion(executable: executable)
        return TerminalPluginProbe(
            bundleID: bundleID,
            evidence: makeEvidence(target: target, cliVersion: cliVersion),
            outcome: partialOutcome(target: target)
        )
    }

    /// Kaku has no proven read-only interface that maps one pane's visible
    /// viewport to window coordinates.  Do not call global `list` or
    /// `get-text`: doing so could read an unrelated pane and cannot establish
    /// viewport identity.  The shared OCR provider captures the requested
    /// window/selection instead.
    func capture(target: CaptureTarget, selection: CGRect) async -> RouterOutcome {
        _ = selection
        guard validateRuntimeTarget(target) else {
            return .unsupported("目标不是正在运行且匹配的 Kaku 窗口。")
        }
        return partialOutcome(target: target)
    }

    private func makeEvidence(target: CaptureTarget, cliVersion: String?) -> TerminalPluginEvidence {
        let applicationVersion = TerminalPluginApplication.version(bundleID: bundleID)
        let bundleVersionVerified = applicationVersion == Self.knownInterfaceVersion
        // A CLI mismatch is meaningful when the safe metadata probe succeeded;
        // an unavailable probe does not turn an exact LaunchServices version
        // into an unverified one.
        let versionVerified = bundleVersionVerified && (cliVersion == nil || cliVersion == Self.knownInterfaceVersion)
        let runtimeMatches = validateRuntimeTarget(target)
        let visibleText: TerminalPluginEvidence.Level = runtimeMatches ? .partial : .unsupported
        let limitation = runtimeMatches
            ? Self.geometryLimitation
            : "Kaku 目标进程或窗口当前不可验证；未读取 CLI pane 内容，也未请求额外权限。"
        return TerminalPluginEvidence(
            applicationVersion: applicationVersion,
            versionVerified: versionVerified,
            interface: Self.interfaceDescription,
            visibleText: visibleText,
            textGeometry: .unsupported,
            paneLayout: .unsupported,
            contentRevision: .unsupported,
            fontRevision: .unsupported,
            limitation: limitation
        )
    }

    /// A layout-only partial result is intentional: an empty `regions` array
    /// must cause the shared OCR path to supply text and geometry.  No CLI text
    /// is copied into a snapshot, and no pane rectangle is invented.
    private func partialOutcome(target: CaptureTarget) -> RouterOutcome {
        let bounds = target.effectiveSelection
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            return .error("Kaku 目标窗口边界无效，无法创建捕获快照。")
        }

        let interface = Self.interfaceDescription
        let version = TerminalPluginApplication.version(bundleID: bundleID)
        let capabilities = SnapshotCapabilities(
            visibleText: CapabilityEvidence(
                level: .partial,
                interface: interface,
                appVersion: version,
                versionVerified: version == Self.knownInterfaceVersion,
                note: "CLI 文本未用于本次定位；可见 viewport 未被证明。"
            ),
            textGeometry: CapabilityEvidence(
                level: .unsupported,
                interface: interface,
                appVersion: version,
                versionVerified: version == Self.knownInterfaceVersion,
                note: "没有 pane/text-cell 到窗口坐标的公开映射。"
            ),
            paneLayout: CapabilityEvidence(
                level: .unsupported,
                interface: interface,
                appVersion: version,
                versionVerified: version == Self.knownInterfaceVersion,
                note: "global list 不提供 CG window map，未读取无关 pane。"
            ),
            contentRevision: .unsupported,
            fontRevision: .unsupported
        )
        let snapshot = CaptureSnapshot(
            target: target,
            capabilities: capabilities,
            provenance: .pluginOCR,
            transform: nil,
            layout: [LayoutRegion(id: "window", role: .window, rect: bounds)],
            regions: []
        )
        return .partial(snapshot, warnings: [
            Self.geometryLimitation,
            "未调用 global list/get-text；请由共享 OCR 在锁定的 Kaku 窗口中生成可定位文字。"
        ])
    }

    /// Metadata-only probe.  The executable and argv are compile-time fixed;
    /// no shell/PATH lookup, user text, target pane, or terminal environment is
    /// passed to Kaku.  Failure is deliberately silent to the evidence caller:
    /// LaunchServices' exact bundle version remains the primary version source.
    private static func readMetadataVersion(executable: String?) async -> String? {
        guard let executable, isFixedExecutable(executable), DisclaimSpawner.isAvailable else {
            return nil
        }
        let request = DisclaimSpawnRequest(
            executable: executable,
            arguments: ["--skip-config", "--version"],
            environment: DisclaimEnvironment.terminalCLI(),
            workingDirectory: .privateTemporary(prefix: "kaku-version"),
            timeout: 5,
            maxStandardOutput: 16 * 1024,
            maxStandardError: 16 * 1024,
            retainStandardError: false
        )
        guard let result = try? await DisclaimSpawner.run(request), result.exitStatus == 0,
              let output = String(data: result.standardOutput, encoding: .utf8) else {
            return nil
        }
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized.contains(Self.knownInterfaceVersion) ? Self.knownInterfaceVersion : normalized
    }

    private static func isFixedExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        guard path.hasSuffix("/" + executableRelativePath) else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private func validateRuntimeTarget(_ target: CaptureTarget) -> Bool {
        guard target.bundleID == nil || target.bundleID == bundleID,
              let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == bundleID,
              !app.isTerminated else { return false }
        if let launchTime = target.appLaunchTime, let actual = app.launchDate {
            guard abs(actual.timeIntervalSince1970 - launchTime) < 1 else { return false }
        }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard let id = info[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  id.uint32Value == target.windowID,
                  ownerPID.int32Value == target.pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  frame.width > 0, frame.height > 0 else { return false }
            return true
        }
    }
}
