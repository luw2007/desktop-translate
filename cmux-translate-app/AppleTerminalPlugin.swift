import AppKit
import Foundation

/// Terminal.app's dictionary exposes selected-tab visible contents and grid/font
/// settings, but not a proven mapping from cells to window points. The normal
/// capture path therefore returns an honest layout-only partial for shared OCR.
@MainActor
struct AppleTerminalPlugin: BuiltinTerminalPlugin {
    let bundleID = "com.apple.Terminal"
    static let bundleIDConstant = "com.apple.Terminal"

    private static let knownInterfaceVersion = "2.15"
    private static let interfaceDescription =
        "Terminal.app NSAppleScript: selected-tab visible contents, rows/columns and font size; no text-cell geometry"
    private static let geometryLimitation =
        "Terminal.app exposes selected-tab contents and grid settings but no independently proven content inset or text-cell geometry; shared OCR is required for positioned regions."

    func probe(target: CaptureTarget) async -> TerminalPluginProbe {
        let evidence = makeEvidence(target: target)
        guard validateRuntimeTarget(target) else {
            return TerminalPluginProbe(bundleID: bundleID, evidence: evidence,
                                       outcome: .unsupported("目标不是正在运行且匹配的 Terminal.app 窗口。"))
        }
        // Do not send an Apple event during the normal probe. No native
        // positioned-text capability exists, so OCR does not need Automation.
        return TerminalPluginProbe(bundleID: bundleID, evidence: evidence,
                                   outcome: partialOutcome(target: target, selection: nil))
    }

    /// Explicit opt-in, read-only native diagnostic. It never runs as part of
    /// ordinary capture, and cannot be used as proof of text positions.
    func probeNativeReadOnly(target: CaptureTarget) async -> Result<AppleTerminalNativeReadOnlyProbe, AppleTerminalNativeProbeError> {
        guard Self.validateRuntimeTarget(target) else { return .failure(.invalidTarget) }
        return Self.readOnlyProbe(target: target)
    }

    func capture(target: CaptureTarget, selection: CGRect) async -> RouterOutcome {
        guard validateRuntimeTarget(target) else {
            return .unsupported("目标不是正在运行且匹配的 Terminal.app 窗口。")
        }
        guard TerminalPluginValidation.validRect(selection), selection == target.effectiveSelection,
              CGRect(origin: .zero, size: target.frame.size).contains(selection) else {
            return .error("Terminal.app 选择区域无效。")
        }
        // Native plaintext has no trustworthy window-local geometry. Do not
        // read it or manufacture TextRegions: the shared OCR route owns this.
        return partialOutcome(target: target, selection: selection)
    }

    private func makeEvidence(target: CaptureTarget) -> TerminalPluginEvidence {
        let version = TerminalPluginApplication.version(bundleID: bundleID)
        let versionVerified = version == Self.knownInterfaceVersion
        let runtimeMatches = validateRuntimeTarget(target)
        let level: TerminalPluginEvidence.Level = runtimeMatches ? .partial : .unsupported
        let limitation = runtimeMatches
            ? Self.geometryLimitation
            : "Terminal.app 目标进程或窗口当前不可验证；未请求 Automation 权限。"
        return TerminalPluginEvidence(applicationVersion: version,
                                      versionVerified: versionVerified,
                                      interface: Self.interfaceDescription,
                                      visibleText: level,
                                      textGeometry: runtimeMatches ? .partial : .unsupported,
                                      paneLayout: runtimeMatches ? .partial : .unsupported,
                                      contentRevision: runtimeMatches ? .partial : .unsupported,
                                      fontRevision: runtimeMatches ? .partial : .unsupported,
                                      limitation: limitation)
    }

    private func partialOutcome(target: CaptureTarget, selection: CGRect?) -> RouterOutcome {
        let bounds = CGRect(origin: .zero, size: target.frame.size)
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            return .error("Terminal.app 目标窗口边界无效，无法创建捕获快照。")
        }
        let version = TerminalPluginApplication.version(bundleID: bundleID)
        let versionVerified = version == Self.knownInterfaceVersion
        let capabilities = SnapshotCapabilities(
            visibleText: CapabilityEvidence(level: .partial, interface: Self.interfaceDescription,
                                            appVersion: version, versionVerified: versionVerified,
                                            note: "可显式读取 selected tab 可见文字；未作为定位文字使用。"),
            textGeometry: CapabilityEvidence(level: .partial, interface: Self.interfaceDescription,
                                             appVersion: version, versionVerified: versionVerified,
                                             note: "没有公开的 content inset 或文字单元到窗口坐标映射。"),
            paneLayout: CapabilityEvidence(level: .partial, interface: Self.interfaceDescription,
                                           appVersion: version, versionVerified: versionVerified,
                                           note: "selected tab 可识别，但 tab/pane 窗口内边界未证实。"),
            contentRevision: CapabilityEvidence(level: .partial, interface: Self.interfaceDescription,
                                                appVersion: version, versionVerified: versionVerified,
                                                note: "可读当前 viewport，但稳定 revision 未暴露。"),
            fontRevision: CapabilityEvidence(level: .partial, interface: Self.interfaceDescription,
                                             appVersion: version, versionVerified: versionVerified,
                                             note: "font size 可只读获取；不可据此推导 cell 坐标。")
        )
        let captureRect = selection ?? target.effectiveSelection
        let snapshot = CaptureSnapshot(target: target, capabilities: capabilities,
                                       provenance: .pluginOCR, transform: nil,
                                       layout: [LayoutRegion(id: "window", role: .window, rect: captureRect)],
                                       regions: [])
        return .partial(snapshot, warnings: [Self.geometryLimitation,
                                               "原生文字不会被伪造为带位置的区域；共享 OCR 将处理当前选区。"])
    }

    private func validateRuntimeTarget(_ target: CaptureTarget) -> Bool {
        Self.validateRuntimeTarget(target)
    }

    private static func validateRuntimeTarget(_ target: CaptureTarget) -> Bool {
        guard target.bundleID == nil || target.bundleID == Self.bundleIDConstant,
              target.pid > 0, target.windowID > 0,
              let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == Self.bundleIDConstant, !app.isTerminated else { return false }
        if let launchTime = target.appLaunchTime, let actual = app.launchDate {
            guard abs(actual.timeIntervalSince1970 - launchTime) < 1 else { return false }
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowID))
                as? [[String: Any]],
              let info = windows.first,
              let id = info[kCGWindowNumber as String] as? NSNumber,
              let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
              id.uint32Value == target.windowID,
              ownerPID.int32Value == target.pid,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return false }
        return true
    }

    private static func readOnlyScript(windowID: UInt32) -> String {
        // Numeric interpolation is intentional: user/app text never enters the
        // AppleScript source. No history, do script, set, or activate command.
        """
        tell application id "com.apple.Terminal"
            return {contents of selected tab of window id \(windowID), rows of selected tab of window id \(windowID), columns of selected tab of window id \(windowID), font size of selected tab of window id \(windowID), id of window id \(windowID)}
        end tell
        """
    }

    private static func readOnlyProbe(target: CaptureTarget) -> Result<AppleTerminalNativeReadOnlyProbe, AppleTerminalNativeProbeError> {
        guard target.windowID > 0, target.windowID <= UInt32.max else { return .failure(.invalidTarget) }
        guard let script = NSAppleScript(source: readOnlyScript(windowID: target.windowID)) else {
            return .failure(.scriptUnavailable)
        }
        var errorInfo: NSDictionary? = nil
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo, info.count > 0 {
            return .failure(classifyAppleScriptError(info))
        }
        guard descriptor.numberOfItems == 5,
              let contents = descriptor.atIndex(1)?.stringValue,
              let rows = integerValue(descriptor.atIndex(2)), rows > 0,
              let columns = integerValue(descriptor.atIndex(3)), columns > 0,
              let fontSize = doubleValue(descriptor.atIndex(4)), fontSize.isFinite, fontSize > 0,
              let returnedWindowID = integerValue(descriptor.atIndex(5)),
              returnedWindowID > 0, returnedWindowID <= Int(UInt32.max),
              UInt32(returnedWindowID) == target.windowID,
              contents.utf8.count <= SnapshotLimits.maxTotalCharacters else {
            return .failure(.invalidResponse)
        }
        return .success(AppleTerminalNativeReadOnlyProbe(pid: target.pid,
                                                         windowID: target.windowID,
                                                         visibleContents: contents,
                                                         rows: rows,
                                                         columns: columns,
                                                         fontSize: fontSize))
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

    private static func doubleValue(_ descriptor: NSAppleEventDescriptor?) -> Double? {
        guard let descriptor else { return nil }
        let code = descriptor.descriptorType
        if code == typeIEEE32BitFloatingPoint || code == typeIEEE64BitFloatingPoint {
            return descriptor.doubleValue
        }
        guard let value = descriptor.stringValue else { return nil }
        return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func classifyAppleScriptError(_ info: NSDictionary?) -> AppleTerminalNativeProbeError {
        guard let number = info?[NSAppleScript.errorNumber] as? NSNumber else { return .scriptFailed }
        switch number.intValue {
        case -1743, -10004: return .needsPermission
        default: return .scriptFailed
        }
    }
}

struct AppleTerminalNativeReadOnlyProbe: Sendable, Equatable {
    var pid: Int32
    var windowID: UInt32
    var visibleContents: String
    var rows: Int
    var columns: Int
    var fontSize: Double
}

enum AppleTerminalNativeProbeError: Error, Sendable, Equatable {
    case invalidTarget
    case needsPermission
    case scriptUnavailable
    case scriptFailed
    case invalidResponse
}
