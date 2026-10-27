import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: window ordering (supersedes the old blanket refusal of overlapping same-app windows)

    static func windowOrderingChecks() {
        func w(_ id: UInt32, _ pid: Int32, _ f: CGRect, layer: Int = 0, alpha: Double = 1) -> WindowListEntry {
            WindowListEntry(id: id, pid: pid, layer: layer, frame: f, alpha: alpha)
        }
        let full = CGRect(x: 0, y: 30, width: 2304, height: 1266)
        // Reported cmux/tmux case: two equal-frame same-app windows; list order says 188642 is on top.
        let twin = [w(188642, 1799, full), w(70904, 1799, full), w(1, 5, CGRect(x: 2304, y: 30, width: 2304, height: 1266))]
        if case .success(let top) = WindowOrdering.pickTopmost(twin, pid: 1799) { expect(top.id == 188642, "Topmost equal-frame sibling wins by z-order") }
        else { expect(false, "Equal-frame same-app windows are distinguishable by list order") }
        // Lower window listed first would pick that one: order alone decides.
        if case .success(let top) = WindowOrdering.pickTopmost(Array(twin[1...2]) + [twin[0]], pid: 1799) { expect(top.id == 70904, "Order decides") }
        else { expect(false, "order decides") }
        // Overlapping partial sibling below the top: still topmost.
        let partial = [w(9, 1799, CGRect(x: 0, y: 0, width: 500, height: 500)), w(8, 1799, CGRect(x: 100, y: 100, width: 800, height: 800))]
        if case .success(let top) = WindowOrdering.pickTopmost(partial, pid: 1799) { expect(top.id == 9, "Partial overlap picks top") }
        else { expect(false, "partial overlap picks top") }
        // Non-ordinary layers and zero-alpha ghosts are skipped; other apps' windows do not matter for the pick.
        let skip = [w(20, 1799, full, layer: 25), w(21, 1799, full, alpha: 0), w(22, 7, full), w(23, 1799, full)]
        if case .success(let top) = WindowOrdering.pickTopmost(skip, pid: 1799) { expect(top.id == 23, "Ghost/overlay layers skipped") }
        else { expect(false, "skip") }
        // Translucent top over a lower overlapping sibling: blend, refuse. Translucent alone is fine.
        expect(WindowOrdering.pickTopmost([w(30, 1, full, alpha: 0.5), w(31, 1, full)], pid: 1) == .failure(.translucentOverLower), "Translucent over sibling refuses")
        if case .success = WindowOrdering.pickTopmost([w(30, 1, full, alpha: 0.5), w(31, 1, CGRect(x: 5000, y: 0, width: 10, height: 10))], pid: 1) {} else { expect(false, "Translucent alone ok") }
        // Missing ordering evidence: duplicate ids and no window refuse.
        expect(WindowOrdering.pickTopmost([w(40, 1, full), w(40, 1, full)], pid: 1) == .failure(.duplicateIDs), "Duplicate ids refuse")
        expect(WindowOrdering.pickTopmost([w(41, 2, full)], pid: 1) == .failure(.noWindow), "No window refuses")
        // Occlusion: another app above intersecting the crop refuses; below, own app, own translator, non-ordinary do not.
        let crop = CGRect(x: 100, y: 100, width: 200, height: 200)
        let ids: (UInt32, Int32) = (50, 1)
        func occluded(_ rows: [WindowListEntry]) -> Bool { WindowOrdering.isOccluded(rows, targetID: 50, targetPID: 1, ownPID: 99, global: crop) }
        expect(occluded([w(60, 2, crop), w(ids.0, ids.1, full)]), "Other app above crop occludes")
        expect(!occluded([w(60, 2, CGRect(x: 1000, y: 1000, width: 10, height: 10)), w(ids.0, ids.1, full)]), "Other app above but off crop is fine")
        expect(!occluded([w(ids.0, ids.1, full), w(60, 2, crop)]), "Other app below does not occlude")
        expect(!occluded([w(61, 99, crop), w(ids.0, ids.1, full)]), "Own overlay does not occlude")
        expect(!occluded([w(62, 2, crop, layer: 25), w(ids.0, ids.1, full)]), "Non-ordinary above does not occlude")
        expect(occluded([w(63, 1, full)]), "Target missing from list is occluded")
        // A same-app sibling above the chosen target cannot exist by construction (target is app's topmost); if it does it is not a foreign occluder but
        // the pick would have chosen it, so the lock revalidation sees a windowID change.
        expect(!occluded([w(64, 1, full), w(ids.0, ids.1, full)]), "Same-app above is not a foreign occluder (revalidation catches id change)")
    }
}
