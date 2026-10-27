import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

@main
struct DesktopChecks {
    static func expect(_ c: Bool, _ m: String) { precondition(c, m) }

    static func target(w: CGFloat = 800, h: CGFloat = 600, tab: String? = "t1", pane: String? = "p1",
                       revision: UInt64 = 1, selection: CGRect? = nil) -> CaptureTarget {
        CaptureTarget(pid: 42, windowID: 7, appLaunchTime: 1000, frame: CGRect(x: -1200, y: 30, width: w, height: h),
                      selection: selection, tabID: tab, paneID: pane, revision: revision)
    }

    static func snapshot(_ regions: [TextRegion], layout: [LayoutRegion] = [], t: CaptureTarget? = nil) -> CaptureSnapshot {
        CaptureSnapshot(target: t ?? target(), provenance: .ocr, layout: layout, regions: regions)
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 50, _ h: CGFloat = 14) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    static func validation(_ s: CaptureSnapshot, rev: UInt64? = nil) -> SnapshotValidationError? {
        do { try s.validate(currentRevision: rev); return nil } catch let e as SnapshotValidationError { return e } catch { return .invalidBounds }
    }

    static func main() {
        transforms()
        validationChecks()
        routerChecks()
        selectionChecks()
        operationChecks()
        groupingChecks()
        planChecks()
        signatureChecks()
        paintAssociationChecks()
        freeSpaceChecks()
        overflowFallbackChecks()
        windowOrderingChecks()
        debugRegionChecks()
        residueChecks()
        terminalBulletChecks()
        debugExportChecks()
        print("Desktop checks passed")
    }

}
