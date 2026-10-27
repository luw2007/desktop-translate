import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: down extension (right AND down share one evidence chain)

    static func downExtensionChecks(white: RegionBackgroundEvidence) {
        let text = "A rather long sentence"
        let line = rect(10, 10, 60, 16)
        let parent = LayoutRegion(id: "p", role: .content, rect: rect(0, 0, 300, 100))
        func mine() -> TextRegion { TextRegion(id: "r", parentID: "p", kind: .prose, rect: line, text: "短句", background: white) }
        func make(_ regions: [TextRegion], layout: [LayoutRegion], size: CGSize, selection: CGRect, image: CGImage,
                  forgeRight: [CGFloat]? = nil, forgeDown: [CGFloat]? = nil) -> (OverlayItem, TextRegion, CaptureSnapshot) {
            var regs = regions
            let containers = Dictionary(uniqueKeysWithValues: layout.map { ($0.id, $0.rect) })
            FreeSpace.attach(to: &regs, image: image, crop: selection, bounds: CGRect(origin: .zero, size: size), containers: containers)
            if let forgeRight { regs[0].freeRight = forgeRight }
            if let forgeDown { regs[0].freeDown = forgeDown }
            let t = RegionTranslation(regionID: regs[0].id, parentID: regs[0].parentID, kind: .prose, readingOrder: 0,
                                      original: regs[0].text, text: text, rects: regs[0].lineRects, unionRect: regs[0].rect, protectedFragments: [])
            let snap = snapshot(regs, layout: layout, t: target(w: size.width, h: size.height))
            return (OverlayItem.make(from: [t], snapshot: snap, selection: selection)[0], regs[0], snap)
        }
        let sel = rect(0, 0, 300, 100)
        let size = CGSize(width: 300, height: 100)
        // Right blocked by ink next to the line, free background below: grows DOWN only, same x and width.
        let blockedRight = darkColumnsImage(inkX: 72)
        let down = make([mine()], layout: [parent], size: size, selection: sel, image: blockedRight)
        expect(down.1.freeRight == [0] && down.1.freeDown[0] > 0, "Right blocked, down proven: \(down.1.freeRight) \(down.1.freeDown)")
        expect(down.0.outcome == .painted && down.0.isExtendedDown && !down.0.isExtendedRight && down.0.fontSize >= OverlayItem.minimumFontSize,
               "Down-only extension paints at >= 12pt: \(down.0.outcome) \(down.0.extended)")
        expect(down.0.extended[0].minX == line.minX && down.0.extended[0].minY == line.minY && down.0.extended[0].width == line.width
               && down.0.extended[0].maxY > line.maxY && down.0.extended[0].maxY <= 100, "Down extension keeps x/y/width: \(down.0.extended)")
        expect(OverlayItem.counts([down.0]) == OverlayItem.Counts(painted: 1, fitOverflow: 0, collisionUnavailable: 0, noOccupancy: 0,
                                                                  extended: 1, extendedRight: 0, extendedDown: 1), "Down extension is counted separately")
        // Baseline: the held-original areas contain exactly the painted extension.
        let areas = DesktopPlan(snapshot: down.2, unicode: true).replacedSourceRects(snapshot: down.2, selection: sel)
        expect(areas == [CGRect(x: 10, y: 10, width: 60, height: 16 + down.1.freeDown[0])], "Baseline contains the proven down strip: \(areas)")
        expect(down.0.paintRects.allSatisfy { p in areas.contains { $0.insetBy(dx: -0.001, dy: -0.001).contains(p) } }, "Down paint lies within baselined areas")

        // Both directions free: both extend, down strip spans the right-extended width.
        let both = make([mine()], layout: [parent], size: size, selection: sel, image: flatImage(300, 100))
        expect(both.1.freeRight[0] > 0 && both.1.freeDown[0] > 0, "Both proofs attach on a flat background")
        let bothAreas = DesktopPlan(snapshot: both.2, unicode: true).replacedSourceRects(snapshot: both.2, selection: sel)
        expect(bothAreas == [CGRect(x: 10, y: 10, width: 60 + both.1.freeRight[0], height: 16 + both.1.freeDown[0])],
               "Baseline contains the right and down strips: \(bothAreas)")
        if both.0.isExtended { expect(both.0.paintRects.allSatisfy { p in bothAreas.contains { $0.insetBy(dx: -0.001, dy: -0.001).contains(p) } }, "Paint within baseline") }

        // Pixel stop: first mismatching row ends the proof; ink right below the line proves nothing.
        let rowInk = make([mine()], layout: [parent], size: size, selection: sel, image: flatImage(300, 100, darkColumns: [(x: 72, width: 4)], darkRows: [(y: 40, height: 4)]))
        expect(rowInk.1.freeDown == [14], "Down proof stops at the first non-background row: \(rowInk.1.freeDown)")
        expect(rowInk.0.extended.allSatisfy { $0.maxY <= 40 }, "Never paints over the ink row")
        let rowNear = make([mine()], layout: [parent], size: size, selection: sel, image: flatImage(300, 100, darkColumns: [(x: 72, width: 4)], darkRows: [(y: 27, height: 4)]))
        expect(rowNear.1.freeDown == [0] && rowNear.0.extended.isEmpty && rowNear.0.baseRects == rowNear.0.occupied, "Ink right below proves nothing")
        var wrongBackground = mine(); wrongBackground.background = RegionBackgroundEvidence(red: 0, green: 0, blue: 0, alpha: 1, verified: false)
        expect(make([wrongBackground], layout: [parent], size: size, selection: sel, image: flatImage(300, 100)).1.freeDown == [0], "Background mismatch proves nothing")

        // Recognized rect below (protected path, within the margin) blocks; a forged proof is re-clamped.
        let path = TextRegion(id: "n", parentID: "p", kind: .path, rect: rect(10, 30, 40), text: "/usr/bin")
        let obstructed = make([mine(), path], layout: [parent], size: size, selection: sel, image: blockedRight)
        expect(obstructed.1.freeDown == [0], "Neighbour within the margin below blocks: \(obstructed.1.freeDown)")
        let farPath = TextRegion(id: "n", parentID: "p", kind: .path, rect: rect(10, 50, 40), text: "/usr/bin")
        let forged = make([mine(), farPath], layout: [parent], size: size, selection: sel, image: blockedRight, forgeRight: [0], forgeDown: [500])
        expect(forged.0.extended.allSatisfy { $0.maxY <= 50 - FreeSpace.gap + 0.001 && !$0.intersects(farPath.rect) }, "Forged down proof re-clamped at paint: \(forged.0.extended)")
        expect(DesktopPlan(snapshot: forged.2, unicode: true).replacedSourceRects(snapshot: forged.2, selection: sel).allSatisfy { $0.maxY <= 50 - FreeSpace.gap + 0.001 },
               "Forged proof is also clamped in the baseline")
        // An untranslated/omitted rectangle (extensionObstacles) blocks both directions.
        var withObstacle = [mine()]
        FreeSpace.attach(to: &withObstacle, image: blockedRight, crop: sel, bounds: CGRect(origin: .zero, size: size), containers: ["p": parent.rect],
                         omitted: [rect(10, 40, 30)])
        expect(withObstacle[0].freeDown[0] <= 40 - FreeSpace.gap - 26 + 0.001, "Omitted observation limits down room: \(withObstacle[0].freeDown)")

        // Selection, parent, window clamps (image dimensions follow the selection crop).
        let cropSel = rect(0, 0, 300, 40)
        let cropped = make([mine()], layout: [parent], size: size, selection: cropSel, image: flatImage(300, 40, darkColumns: [(x: 72, width: 4)]))
        expect(cropped.1.freeDown[0] <= 40 - 26 && cropped.0.extended.allSatisfy { $0.maxY <= 40 }, "Down stays inside the selection: \(cropped.1.freeDown)")
        let shortParent = LayoutRegion(id: "p", role: .content, rect: rect(0, 0, 300, 34))
        let parented = make([mine()], layout: [shortParent], size: size, selection: sel, image: blockedRight)
        expect(parented.1.freeDown[0] <= 34 - 26 && parented.0.extended.allSatisfy { $0.maxY <= 34 }, "Down stays inside the parent: \(parented.1.freeDown)")
        let windowSize = CGSize(width: 300, height: 36)
        let windowed = make([mine()], layout: [LayoutRegion(id: "p", role: .content, rect: rect(0, 0, 300, 36))], size: windowSize,
                            selection: rect(0, 0, 300, 36), image: flatImage(300, 36, darkColumns: [(x: 72, width: 4)]),
                            forgeRight: [0], forgeDown: [500])
        expect(windowed.0.extended.allSatisfy { $0.maxY <= 36 }, "Forged down proof never leaves the window")
    }

    static func darkColumnsImage(inkX: Int) -> CGImage { flatImage(300, 100, darkColumns: [(x: inkX, width: 4)]) }
}
