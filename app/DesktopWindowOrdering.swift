import CoreGraphics
import Foundation

// Target-window choice and occlusion rules over the public CGWindowList. No AppKit.

/// One row of the public CGWindowList on-screen list (front-to-back). Pure value type so selection rules are unit-checkable.
struct WindowListEntry: Equatable, Sendable {
    var id: UInt32
    var pid: Int32
    var layer: Int
    var frame: CGRect
    var alpha: Double
    var ordinary: Bool { layer == 0 && alpha > 0 && frame.width > 1 && frame.height > 1 }
}

enum WindowChoiceFailure: Error, Equatable, Sendable {
    /// Duplicate ids: the ordering evidence is not trustworthy.
    case duplicateIDs
    case noWindow
    /// The topmost window is translucent and a lower same-app window sits under it, so what the user sees is a blend.
    case translucentOverLower
}

/// Target-window choice and occlusion rules over the front-to-back on-screen list.
/// Supersedes the earlier blanket refusal of several overlapping same-app windows: the list order is the z-order,
/// so the topmost ordinary window of the app is what the user sees; siblings below it (even with an equal frame)
/// are fully covered by it and are not captured because capture filters the single chosen window id.
enum WindowOrdering {
    static func pickTopmost(_ rows: [WindowListEntry], pid: Int32) -> Result<WindowListEntry, WindowChoiceFailure> {
        guard Set(rows.map(\.id)).count == rows.count else { return .failure(.duplicateIDs) }
        let owned = rows.filter { $0.pid == pid && $0.ordinary }
        guard let first = owned.first else { return .failure(.noWindow) }
        if first.alpha < 1, owned.dropFirst().contains(where: { $0.frame.intersects(first.frame) }) {
            return .failure(.translucentOverLower)
        }
        return .success(first)
    }

    /// True when the target is missing from the list or any ordinary window of another app (other than the translator)
    /// above it intersects the global selection rect.
    static func isOccluded(_ rows: [WindowListEntry], targetID: UInt32, targetPID: Int32, ownPID: Int32, global: CGRect) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == targetID && $0.pid == targetPID }) else { return true }
        return rows[..<index].contains { $0.ordinary && $0.pid != targetPID && $0.pid != ownPID && $0.frame.intersects(global) }
    }
}
