import AppKit
import Foundation

/// Compiled-in, exact-bundle plugins only. A probe cannot certify text geometry by itself.
struct TerminalPluginEvidence: Sendable {
    enum Level: String, Sendable { case verified, partial, unsupported }
    var applicationVersion: String
    var versionVerified: Bool
    var interface: String
    var visibleText: Level
    var textGeometry: Level
    var paneLayout: Level
    var contentRevision: Level
    var fontRevision: Level
    var limitation: String
}

struct TerminalPluginProbe: Sendable {
    var bundleID: String
    var evidence: TerminalPluginEvidence
    var outcome: RouterOutcome
    /// Only filled after pane identity, geometry and viewport have independent evidence.
    var focusedPaneRect: CGRect? = nil
    var paneID: String? = nil
}

@MainActor
protocol BuiltinTerminalPlugin {
    var bundleID: String { get }
    func probe(target: CaptureTarget) async -> TerminalPluginProbe
    func capture(target: CaptureTarget, selection: CGRect) async -> RouterOutcome
}

enum TerminalPluginApplication {
    static func version(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return "未安装" }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
    static func executable(bundleID: String, relativePath: String) -> String? {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let path = url.appendingPathComponent(relativePath).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
