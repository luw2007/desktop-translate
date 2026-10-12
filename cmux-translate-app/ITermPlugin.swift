import AppKit
import Foundation

/// The result of an explicitly requested iTerm2 read-only AppleScript probe.
/// The visible contents are kept only in memory for the caller; this type never logs or persists them.
struct ITermNativeReadOnlyProbe: Sendable {
    var pid: Int32
    var windowID: UInt32
    var sessionID: String
    var visibleContents: String
    var rows: Int
    var columns: Int
}

/// iTerm2's public dictionary exposes the current session's visible contents and grid dimensions,
/// but does not map text cells to window coordinates. Consequently this plugin deliberately routes
/// positioning through the shared OCR path rather than inventing cell rectangles.
@MainActor
struct ITermPlugin: BuiltinTerminalPlugin {
    let bundleID = "com.googlecode.iterm2"

    private static let knownInterfaceVersion = "3.7.0"
    private static let interfaceDescription =
        "iTerm2 NSAppleScript: current tab/current session visible contents, rows/columns and session id; no pane or text-cell geometry"
    private static let geometryLimitation =
        "iTerm2 exposes visible session text and grid dimensions but no independently proven text-cell or split-pane geometry; use shared OCR for positioned regions."

    func probe(target: CaptureTarget) async -> TerminalPluginProbe {
        let evidence = makeEvidence(target: target)
        guard validateRuntimeTarget(target) else {
            return TerminalPluginProbe(bundleID: bundleID, evidence: evidence,
                                       outcome: .unsupported("目标不是正在运行且匹配的 iTerm2 窗口。"))
        }
        return TerminalPluginProbe(bundleID: bundleID, evidence: evidence,
                                   outcome: partialOutcome(target: target, selection: nil))
    }

    /// Native capture intentionally does not call AppleScript. Without independently proven
    /// coordinates, native text cannot be presented as positioned text; the shared OCR provider
    /// consumes this honest partial result instead.
    func capture(target: CaptureTarget, selection: CGRect) async -> RouterOutcome {
        guard validateRuntimeTarget(target) else {
            return .unsupported("目标不是正在运行且匹配的 iTerm2 窗口。")
        }
        guard let clamped = SelectionMemory.clamp(selection, to: target.frame.size) else {
            return .error("iTerm2 选择区域无效。")
        }
        return partialOutcome(target: target, selection: clamped)
    }

    /// Explicit, read-only AppleScript probe for one validated iTerm2 process and window.
    /// This method is never called by `probe` or `capture`, so an ordinary OCR capture does not
    /// cause an Automation prompt. AppleScript errors that indicate denied automation are exposed
    /// as `.needsPermission(.automation)`; no script error is allowed to contain session text.
    func probeNativeReadOnly(target: CaptureTarget) async -> Result<ITermNativeReadOnlyProbe, ITermNativeProbeError> {
        guard validateRuntimeTarget(target) else { return .failure(.invalidTarget) }

        let script = Self.readOnlyScript(windowID: target.windowID)
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.scriptUnavailable)
        }
        var errorInfo: NSDictionary? = nil
        let descriptor = appleScript.executeAndReturnError(&errorInfo)
        if let info = errorInfo, info.count > 0 {
            return .failure(Self.classifyAppleScriptError(info))
        }

        guard descriptor.numberOfItems >= 4,
              let contents = descriptor.atIndex(1)?.stringValue,
              let rows = Self.integerValue(descriptor.atIndex(2)),
              let columns = Self.integerValue(descriptor.atIndex(3)),
              let sessionID = descriptor.atIndex(4)?.stringValue,
              rows >= 0, columns >= 0, !sessionID.isEmpty else {
            return .failure(.invalidResponse)
        }
        return .success(ITermNativeReadOnlyProbe(pid: target.pid, windowID: target.windowID,
                                                   sessionID: sessionID, visibleContents: contents,
                                                   rows: rows, columns: columns))
    }

    private func makeEvidence(target: CaptureTarget) -> TerminalPluginEvidence {
        let actualVersion = TerminalPluginApplication.version(bundleID: bundleID)
        let versionVerified = actualVersion == Self.knownInterfaceVersion
        let runtimeMatches = validateRuntimeTarget(target)
        let visibleText: TerminalPluginEvidence.Level = runtimeMatches ? .partial : .unsupported
        let unsupported: TerminalPluginEvidence.Level = .unsupported
        let note = runtimeMatches
            ? Self.geometryLimitation
            : "iTerm2 目标进程或窗口当前不可验证；未请求 Automation 权限。"
        return TerminalPluginEvidence(applicationVersion: actualVersion,
                                      versionVerified: versionVerified,
                                      interface: Self.interfaceDescription,
                                      visibleText: visibleText,
                                      textGeometry: unsupported,
                                      paneLayout: unsupported,
                                      contentRevision: unsupported,
                                      fontRevision: unsupported,
                                      limitation: note)
    }

    private func partialOutcome(target: CaptureTarget, selection: CGRect?) -> RouterOutcome {
        let bounds = selection ?? target.effectiveSelection
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            return .error("iTerm2 目标窗口边界无效，无法创建捕获快照。")
        }
        let version = TerminalPluginApplication.version(bundleID: bundleID)
        let versionVerified = version == Self.knownInterfaceVersion
        let capabilities = SnapshotCapabilities(
            visibleText: CapabilityEvidence(level: .partial, interface: Self.interfaceDescription,
                                            appVersion: version, versionVerified: versionVerified,
                                            note: "可显式读取当前 session 可见文字；未作为定位文字使用。"),
            textGeometry: CapabilityEvidence(level: .unsupported, interface: Self.interfaceDescription,
                                             appVersion: version, versionVerified: versionVerified,
                                             note: "没有公开的文字单元到窗口坐标映射。"),
            paneLayout: CapabilityEvidence(level: .unsupported, interface: Self.interfaceDescription,
                                           appVersion: version, versionVerified: versionVerified,
                                           note: "split/pane 几何未证实。"),
            contentRevision: CapabilityEvidence(level: .unsupported, interface: Self.interfaceDescription,
                                                appVersion: version, versionVerified: versionVerified,
                                                note: "未提供稳定的可见内容 revision。"),
            fontRevision: CapabilityEvidence(level: .unsupported, interface: Self.interfaceDescription,
                                             appVersion: version, versionVerified: versionVerified,
                                             note: "字体变化未提供可读 revision。"))
        let snapshot = CaptureSnapshot(target: target, capabilities: capabilities,
                                       provenance: .pluginOCR, transform: nil,
                                       layout: [LayoutRegion(id: "window", role: .window, rect: bounds)],
                                       regions: [])
        return .partial(snapshot, warnings: [Self.geometryLimitation,
                                               "原生探针不会改变焦点、标签页、滚动位置或选择；请由共享 OCR 生成可定位区域。"])
    }

    private func validateRuntimeTarget(_ target: CaptureTarget) -> Bool {
        guard target.pid > 0, target.windowID > 0,
              target.bundleID == nil || target.bundleID == bundleID,
              let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == bundleID,
              !app.isTerminated else { return false }
        if let launchTime = target.appLaunchTime, let actual = app.launchDate {
            guard abs(actual.timeIntervalSince1970 - launchTime) < 1 else { return false }
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowID))
                as? [[CFString: Any]] else { return false }
        return windows.contains { info in
            guard let id = info[kCGWindowNumber] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID] as? NSNumber,
                  id.uint32Value == target.windowID,
                  ownerPID.int32Value == target.pid,
                  (info[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds] as? [CFString: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 0, frame.height > 0 else { return false }
            return true
        }
    }

    private static func readOnlyScript(windowID: UInt32) -> String {
        // Numeric interpolation is intentional: user/app text never enters the AppleScript source.
        """
        tell application id "com.googlecode.iterm2"
            set matchingWindow to missing value
            repeat with candidateWindow in windows
                if (id of candidateWindow as integer) is \(windowID) then
                    set matchingWindow to candidateWindow
                    exit repeat
                end if
            end repeat
            if matchingWindow is missing value then error number -1728
            set currentTab to current tab of matchingWindow
            set currentSession to current session of currentTab
            set visibleContents to contents of currentSession
            set sessionRows to rows of currentSession
            set sessionColumns to columns of currentSession
            set sessionIdentifier to (id of currentSession as text)
            return {visibleContents, sessionRows, sessionColumns, sessionIdentifier}
        end tell
        """
    }

    private static func integerValue(_ descriptor: NSAppleEventDescriptor?) -> Int? {
        guard let descriptor else { return nil }
        let code = descriptor.descriptorType
        if code == typeSInt32 || code == typeSInt16 || code == typeSInt64 {
            return Int(descriptor.int32Value)
        }
        guard let value = descriptor.stringValue else { return nil }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func classifyAppleScriptError(_ info: NSDictionary?) -> ITermNativeProbeError {
        guard let number = info?[NSAppleScript.errorNumber] as? NSNumber else { return .scriptFailed }
        switch number.intValue {
        case -1743, -10004: return .needsPermission
        default: return .scriptFailed
        }
    }
}

enum ITermNativeProbeError: Error, Sendable, Equatable {
    case invalidTarget
    case needsPermission
    case scriptUnavailable
    case scriptFailed
    case invalidResponse
}
