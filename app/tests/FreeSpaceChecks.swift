import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: proven-free extension of overflowing inline translations

    /// 1 pixel per point RGBA image of `w`x`h`, white, with opaque dark columns [x, x+width) over the full height.
    static func flatImage(_ w: Int, _ h: Int, darkColumns: [(x: Int, width: Int)] = [], darkRows: [(y: Int, height: Int)] = []) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        for c in darkColumns { ctx.fill(CGRect(x: c.x, y: 0, width: c.width, height: h)) }
        // Rows are given from the image TOP (CGContext origin is bottom-left).
        for r in darkRows { ctx.fill(CGRect(x: 0, y: h - r.y - r.height, width: w, height: r.height)) }
        return ctx.makeImage()!
    }

    static func freeSpaceChecks() {
        let white = RegionBackgroundEvidence(red: 1, green: 1, blue: 1, alpha: 1, verified: false)
        let text = "A rather long sentence"
        func item(_ regions: [TextRegion], layout: [LayoutRegion], size: CGSize, selection: CGRect, image: CGImage,
                  forge: [CGFloat]? = nil, keepDown: Bool = false) -> (OverlayItem, TextRegion) {
            var regs = regions
            let bounds = CGRect(origin: .zero, size: size)
            let containers = Dictionary(uniqueKeysWithValues: layout.map { ($0.id, $0.rect) })
            FreeSpace.attach(to: &regs, image: image, crop: selection, bounds: bounds, containers: containers)
            if let forge { regs[0].freeRight = forge }
            if !keepDown { for i in regs.indices { regs[i].freeDown = [] } }
            let t = RegionTranslation(regionID: regs[0].id, parentID: regs[0].parentID, kind: .prose, readingOrder: 0,
                                      original: regs[0].text, text: text, rects: regs[0].lineRects, unionRect: regs[0].rect, protectedFragments: [])
            let snap = snapshot(regs, layout: layout, t: target(w: size.width, h: size.height))
            return (OverlayItem.make(from: [t], snapshot: snap, selection: selection)[0], regs[0])
        }
        let line = rect(10, 10, 60, 16)
        let parent = LayoutRegion(id: "p", role: .content, rect: rect(0, 0, 300, 60))
        func mine(_ extra: [CGRect] = []) -> TextRegion {
            TextRegion(id: "r", parentID: "p", kind: .prose, rect: line, text: "短句", background: white)
        }
        let sel = rect(0, 0, 300, 60)
        let size = CGSize(width: 300, height: 60)

        // Pure geometry: nearest recognized rectangle sharing rows limits the room; rows apart / entirely-left ones do not.
        expect(FreeSpace.room(line: line, obstacles: [], limitX: 300) == 230, "Room reaches the limit with no obstacle")
        expect(FreeSpace.room(line: line, obstacles: [rect(200, 12, 40)], limitX: 300) == 200 - FreeSpace.gap - 70, "Neighbour on the same rows stops the room")
        expect(FreeSpace.room(line: line, obstacles: [rect(100, 40, 40)], limitX: 300) == 230, "Obstacle on other rows is ignored")
        expect(FreeSpace.room(line: line, obstacles: [rect(100, 26, 40)], limitX: 300) == 100 - FreeSpace.gap - 70, "Neighbour touching the rows within the margin stops the room")
        expect(FreeSpace.room(line: line, obstacles: [rect(100, 26 + FreeSpace.gap, 40)], limitX: 300) == 230, "Beyond the margin is ignored")
        expect(FreeSpace.room(line: line, obstacles: [rect(0, 10, 40)], limitX: 300) == 230, "Obstacle entirely left is ignored")
        expect(FreeSpace.room(line: line, obstacles: [rect(60, 10, 40)], limitX: 300) == 0, "Obstacle straddling the right edge proves nothing")
        expect(FreeSpace.room(line: line, obstacles: [rect(72, 10, 40)], limitX: 300) == 0, "Neighbour closer than the safety gap leaves no room")

        // Overflow without proof stays overflow (no obstacle info needed: nothing flat was measured).
        let narrow = item([mine()], layout: [parent], size: size, selection: sel, image: flatImage(300, 60), forge: [])
        expect(narrow.0.outcome == .paintedCover && narrow.0.extended.isEmpty && narrow.0.paintRects == narrow.0.cover && narrow.0.baseRects == narrow.0.occupied,
               "Text wider than the line without proven room is no extension: it falls to the last-resort cover (source stays the baseline)")

        // Free row to the right: widened in place, same y/height/x origin, layout fits at >= 12pt.
        let free = item([mine()], layout: [parent], size: size, selection: sel, image: flatImage(300, 60))
        let grown = free.0
        expect(grown.outcome == .painted && grown.isExtended && grown.extended.count == 1, "Free right space paints the overflow inline")
        expect(grown.extended[0].minX == line.minX && grown.extended[0].minY == line.minY && grown.extended[0].height == line.height
               && grown.extended[0].maxX > line.maxX && grown.extended[0].maxX <= 300, "Extension only grows to the right on the same rows: \(grown.extended)")
        expect(grown.fontSize >= OverlayItem.minimumFontSize && grown.paintRects == grown.extended && grown.occupied == [line],
               "Paint is the extension; the source line stays the baseline occupancy")
        expect(OverlayTextLayout(text: text, rects: grown.paintRects, size: grown.fontSize, color: .black).fits,
               "Fit and draw share one layout: ink lies inside the extended rect")
        expect(OverlayItem.counts([grown]) == OverlayItem.Counts(painted: 1, fitOverflow: 0, collisionUnavailable: 0, noOccupancy: 0, extended: 1, extendedRight: 1),
               "Extended items are painted and separately counted")

        // Extension stops at a recognized neighbour on the same row (protected path region), and never overlaps it.
        let path = TextRegion(id: "n", parentID: "p", kind: .path, rect: rect(150, 12, 40), text: "/usr/bin")
        let blocked = item([mine(), path], layout: [parent], size: size, selection: sel, image: flatImage(300, 60))
        let blockedRoom = 150 - FreeSpace.gap - line.maxX
        expect(blocked.1.freeRight == [blockedRoom], "Capture-time room stops at the protected neighbour: \(blocked.1.freeRight)")
        if blocked.0.isExtended {
            expect(blocked.0.extended[0].maxX <= 150 - FreeSpace.gap && !blocked.0.extended[0].intersects(path.rect), "No overlap with protected neighbour")
        } else { expect(blocked.0.outcome != .painted && blocked.0.extended.isEmpty, "Too little room is no extension: \(blocked.0.outcome)") }
        // A forged, over-wide freeRight is clamped by the geometry re-derived from the snapshot.
        let forged = item([mine(), path], layout: [parent], size: size, selection: sel, image: flatImage(300, 60), forge: [250])
        expect(forged.0.extended.allSatisfy { $0.maxX <= 150 - FreeSpace.gap + 0.001 && !$0.intersects(path.rect) },
               "Forged freeRight never extends past a recognized neighbour")

        // Crop / parent edge: no growth past the selection or the verified parent.
        let cropSel = rect(0, 0, 120, 60)
        let cropped = item([mine()], layout: [parent], size: size, selection: cropSel, image: flatImage(120, 60))
        expect(cropped.1.freeRight[0] <= 120 - line.maxX && cropped.0.extended.allSatisfy { $0.maxX <= 120 }, "Extension stays inside the selection crop")
        let smallParent = LayoutRegion(id: "p", role: .content, rect: rect(0, 0, 130, 60))
        let parented = item([mine()], layout: [smallParent], size: size, selection: sel, image: flatImage(300, 60))
        expect(parented.0.extended.allSatisfy { $0.maxX <= 130 } && parented.1.freeRight[0] <= 130 - line.maxX, "Extension stays inside the verified parent")

        // Pixel half: non-text ink (icon/rule) not recognized as text still stops the extension; background must match.
        let icon = item([mine()], layout: [parent], size: size, selection: sel, image: flatImage(300, 60, darkColumns: [(x: 100, width: 4)]))
        expect(icon.1.freeRight[0] == 30, "Pixel-flat width stops at the first non-background column: \(icon.1.freeRight)")
        expect(icon.0.extended.allSatisfy { $0.maxX <= 100 }, "Extension never covers non-background pixels")
        let iconNear = item([mine()], layout: [parent], size: size, selection: sel, image: flatImage(300, 60, darkColumns: [(x: 72, width: 4)]))
        expect(iconNear.1.freeRight == [0] && iconNear.0.extended.isEmpty && iconNear.0.outcome == .paintedCover && iconNear.0.baseRects == iconNear.0.occupied,
               "Ink right next to the line proves nothing: no extension, only the last-resort cover with the source as baseline")
        var other = mine(); other.background = RegionBackgroundEvidence(red: 0, green: 0, blue: 0, alpha: 1, verified: false)
        let mismatch = item([other], layout: [parent], size: size, selection: sel, image: flatImage(300, 60))
        expect(mismatch.1.freeRight == [0], "Strip that differs from the sampled background is not free")

        // Protected regions never get extension evidence; another region's overlap makes the extended rects collide.
        var prot = mine(); prot.kind = .path
        var attached = [prot]
        FreeSpace.attach(to: &attached, image: flatImage(300, 60), crop: sel, bounds: CGRect(origin: .zero, size: size), containers: ["p": parent.rect])
        expect(attached[0].freeRight.isEmpty, "Protected region receives no free-space proof")

        // Baseline: the freshness areas (built from the held original) contain the source line AND exactly the proven
        // strip, so every pixel an extended translation paints is covered by the one immutable baseline.
        var withProof = [mine()]
        FreeSpace.attach(to: &withProof, image: flatImage(300, 60), crop: sel, bounds: CGRect(origin: .zero, size: size), containers: ["p": parent.rect])
        withProof[0].freeDown = []
        let snapAfter = snapshot(withProof, layout: [parent], t: target(w: 300, h: 60))
        let areas = DesktopPlan(snapshot: snapAfter, unicode: true).replacedSourceRects(snapshot: snapAfter, selection: sel)
        let strip = rect(line.maxX, line.minY, withProof[0].freeRight[0], line.height)
        expect(areas == [line.union(strip)], "Baseline area covers the source line plus its proven strip: \(areas)")
        let growth = item([mine()], layout: [parent], size: size, selection: sel, image: flatImage(300, 60)).0
        expect(growth.paintRects.allSatisfy { p in areas.contains { $0.insetBy(dx: -0.001, dy: -0.001).contains(p) } },
               "Extended paint lies within baselined areas")
        let noProof = snapshot([mine()], layout: [parent], t: target(w: 300, h: 60))
        expect(DesktopPlan(snapshot: noProof, unicode: true).replacedSourceRects(snapshot: noProof, selection: sel) == [line],
               "Without proof the baseline is just the source line")

        downExtensionChecks(white: white)
        paragraphBlockChecks()
    }
}
