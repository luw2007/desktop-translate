import AppKit
import Foundation
import CoreGraphics

struct TerminalSnapshot: Sendable {
    let text: String
    let workspace: String
    let surface: String
    let window: String
}

enum CaptureFailure: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

enum CmuxCapture {
    private static let cli = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    // Never inherit a launch terminal's target: each hotkey targets the currently focused terminal.
    private static func run(_ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            for key in ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID", "CMUX_WINDOW_ID"] {
                environment.removeValue(forKey: key)
            }
            process.environment = environment
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let errorReader = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
            // Read while running so a full output pipe cannot block termination.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            let errorData = await errorReader.value
            guard process.terminationStatus == 0 else {
                let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw CaptureFailure.unavailable("无法读取 cmux：请确认 cmux 正在运行且 Socket API 已启用。\(detail.isEmpty ? "" : "\n" + detail)")
            }
            return data
        }.value
    }

    private static func focused() async throws -> [String: String] {
        let data = try await run(["identify", "--no-caller", "--json"])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let focus = json["focused"] as? [String: Any],
              focus["surface_type"] as? String == "terminal",
              let workspace = focus["workspace_ref"] as? String,
              let surface = focus["surface_ref"] as? String,
              let window = focus["window_ref"] as? String else {
            throw CaptureFailure.unavailable("请先选中 cmux 中的终端，不支持浏览器页面。")
        }
        return ["workspace": workspace, "surface": surface, "window": window]
    }

    static func snapshot() async throws -> TerminalSnapshot {
        let target = try await focused()
        let workspace = target["workspace"]!
        let surface = target["surface"]!
        let window = target["window"]!
        let data = try await run(["read-screen", "--json", "--workspace", workspace, "--surface", surface, "--window", window])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureFailure.unavailable("当前终端没有可翻译的可见文字。")
        }
        guard try await focused() == target else {
            throw CaptureFailure.unavailable("读取时终端焦点发生变化，请重新按快捷键。")
        }
        return TerminalSnapshot(text: text, workspace: workspace, surface: surface, window: window)
    }

    @MainActor static func isCmuxFrontmost() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.bundleIdentifier == "com.cmuxterm.app" || app.executableURL?.lastPathComponent == "cmux"
    }

    @MainActor static func frontmostBounds() throws -> CGRect {
        guard let app = NSWorkspace.shared.frontmostApplication, isCmuxFrontmost() else {
            if CommandLine.arguments.contains("--smoke"), let screen = NSScreen.main {
                return screen.visibleFrame.insetBy(dx: 80, dy: 80)
            }
            throw CaptureFailure.unavailable("请在 cmux 终端中按快捷键。")
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let info = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? Int) == 0 &&
                  (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 100
              }),
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let primary = NSScreen.screens.first else {
            throw CaptureFailure.unavailable("无法获取 cmux 窗口位置。")
        }
        // Quartz uses top-left desktop coordinates; AppKit uses bottom-left coordinates.
        return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
