import AppKit
import CoreGraphics
import Foundation

/// Fail-closed public window baseline. No Accessibility calls, window titles are never used as identity.
enum TargetLockError: LocalizedError {
    case ownApp, terminated, noWindow, ambiguous, offscreen, changed, obscured
    case unavailable, overlappingWindows
    /// Same as `changed`, but names which public identity component differed (pid/ids/geometry only, never text).
    case changedBecause(String)
    /// Window id / frame / display set differed: resize, pane or layout change. Distinct so the session can clear the selection at once.
    case layoutChangedBecause(String)
    /// True when the locked window's geometry or layout (not identity/occlusion) is what broke.
    var isLayoutChange: Bool {
        switch self {
        case .layoutChangedBecause, .overlappingWindows, .ambiguous, .offscreen: return true
        default: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .ownApp: return "请在要翻译的应用中按快捷键，不能捕获翻译器自身。"
        case .terminated: return "目标应用已退出或进程身份改变，请重新选择。"
        case .noWindow: return "没有可确认的前台普通窗口；请切回目标窗口再试。"
        case .ambiguous: return "无法确定主窗口或模态窗口的边界，请关闭弹窗后重新选择。"
        case .overlappingWindows: return "目标应用最上层窗口是半透明的，且其下方还有重叠的同应用窗口，无法确定实际显示的是哪一个；请关闭多余窗口后重试。"
        case .offscreen: return "目标窗口不在当前可见桌面或显示器上。"
        case .changed: return "目标窗口、显示器或前台应用已改变，请重新按快捷键。"
        case .changedBecause(let detail), .layoutChangedBecause(let detail): return "目标窗口、显示器或前台应用已改变（\(detail)），请重新按快捷键。"
        case .obscured: return "其他应用遮挡了翻译区域，已撤除覆盖。"
        case .unavailable: return "无法获取系统窗口列表，未捕获任何屏幕。"
        }
    }
}

fileprivate struct PublicWindow {
    let id: UInt32
    let pid: Int32
    let layer: Int
    let frame: CGRect
    let sharing: Int
    let alpha: Double
    let name: String
    init?(_ row: [String: Any]) {
        guard let id = row[kCGWindowNumber as String] as? NSNumber,
              let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = row[kCGWindowLayer as String] as? NSNumber,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let sharing = row[kCGWindowSharingState as String] as? NSNumber else { return nil }
        self.id = id.uint32Value; self.pid = pid.int32Value; self.layer = layer.intValue
        self.frame = frame; self.sharing = sharing.intValue
        self.alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        self.name = row[kCGWindowName as String] as? String ?? ""
    }
    var ordinary: Bool { entry.ordinary }
    var entry: WindowListEntry { WindowListEntry(id: id, pid: pid, layer: layer, frame: frame, alpha: alpha) }
}

@MainActor
enum TargetLocker {
    fileprivate static func windows() -> [PublicWindow]? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return rows.compactMap(PublicWindow.init)
    }
    static func lock(app: NSRunningApplication) -> Result<CaptureTarget, TargetLockError> {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .failure(.ownApp) }
        guard !app.isTerminated, let launched = app.launchDate,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return .failure(.terminated) }
        guard let rows = windows() else { return .failure(.unavailable) }
        // The on-screen list is front-to-back: the topmost ordinary window of the frontmost app is the one the user sees.
        // Same-app windows below it (including equal-frame ones) are covered by it and are never captured, because capture
        // filters the single locked window id. Missing/duplicate ordering evidence or a translucent top over a lower
        // sibling still refuse. Never fall back to a display.
        let first: PublicWindow
        switch WindowOrdering.pickTopmost(rows.map(\.entry), pid: app.processIdentifier) {
        case .failure(.duplicateIDs): return .failure(.ambiguous)
        case .failure(.noWindow): return .failure(.noWindow)
        case .failure(.translucentOverLower): return .failure(.overlappingWindows)
        case .success(let entry):
            guard let row = rows.first(where: { $0.id == entry.id }) else { return .failure(.noWindow) }
            first = row
        }
        let displays = displayIDs(intersecting: first.frame)
        guard !displays.isEmpty else { return .failure(.offscreen) }
        return .success(CaptureTarget(pid: app.processIdentifier, windowID: first.id,
            appLaunchTime: launched.timeIntervalSince1970, bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "应用", title: first.name, frame: first.frame, displayIDs: displays))
    }
    /// Read-only publication evidence for ONE exact window (id + owner pid) in the on-screen list, for harness
    /// readiness only. nil = not listed (yet). Never used by the product capture path.
    /// Non-authoritative diagnostic only: `kCGWindowSharingState` never decides whether capture is allowed.
    static func publication(windowID: UInt32, pid: Int32) -> (layer: Int, frame: CGRect, alpha: Double, sharing: Int)? {
        guard let row = windows()?.first(where: { $0.id == windowID && $0.pid == pid }) else { return nil }
        return (row.layer, row.frame, row.alpha, row.sharing)
    }
    /// Ids of this pid's ordinary on-screen windows (identity-swap detection for harness readiness).
    static func ordinaryWindowIDs(pid: Int32) -> [UInt32] {
        (windows() ?? []).filter { $0.pid == pid && $0.ordinary }.map(\.id)
    }
    static func revalidate(_ target: CaptureTarget) -> TargetLockError? {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.launchDate?.timeIntervalSince1970 == target.appLaunchTime else { return .terminated }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == target.pid else {
            return .changedBecause("frontmost pid \(target.pid)→\(front.map { String($0.processIdentifier) } ?? "nil") \(front?.bundleIdentifier ?? "-")")
        }
        switch lock(app: app) {
        case .failure(let error): return error
        case .success(let now):
            guard now.windowID == target.windowID else { return .layoutChangedBecause("windowID \(target.windowID)→\(now.windowID)") }
            guard now.frame.size == target.frame.size else { return .layoutChangedBecause("size \(target.frame.size)→\(now.frame.size)") }
            guard now.frame == target.frame else { return .changedBecause("moved \(target.frame.origin)→\(now.frame.origin)") }
            guard now.displayIDs == target.displayIDs else { return .changedBecause("displays \(target.displayIDs)→\(now.displayIDs)") }
            return nil
        }
    }
    fileprivate static func displayIDs(intersecting rect: CGRect) -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayBounds($0).intersects(rect) }.sorted()
    }
    static func isOccluded(_ target: CaptureTarget, selection: CGRect) -> Bool {
        guard let rows = windows() else { return true }
        let global = selection.offsetBy(dx: target.frame.minX, dy: target.frame.minY)
        return WindowOrdering.isOccluded(rows.map(\.entry), targetID: target.windowID, targetPID: target.pid,
                                         ownPID: ProcessInfo.processInfo.processIdentifier, global: global)
    }
    static func isFullyVisible(_ target: CaptureTarget, selection: CGRect) -> Bool {
        var remaining = [selection.offsetBy(dx: target.frame.minX, dy: target.frame.minY)]
        // Subtract active displays: do not accept gaps or missing selected pixels.
        for id in target.displayIDs {
            var next: [CGRect] = []
            for rect in remaining {
                let cut = rect.intersection(CGDisplayBounds(id))
                if cut.isNull || cut.isEmpty { next.append(rect); continue }
                let pieces = [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
                              CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
                              CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
                              CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)]
                next += pieces.filter { $0.width > 0 && $0.height > 0 }
            }
            remaining = next
        }
        return remaining.isEmpty
    }
}

enum ScreenCapturePermission {
    static func preflight() async -> Bool { CGPreflightScreenCaptureAccess() }
    /// Only call following an explicit user's permission action; baseline checks never prompt.
    @MainActor static func request() async -> Bool { CGRequestScreenCaptureAccess() }
}
