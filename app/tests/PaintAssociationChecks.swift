import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {

    /// The same source lines, product clipping and actual painted rectangles must agree one-to-one.
    static func paintAssociationChecks() {
        let lines = [rect(10, 10, 90, 22), rect(10, 50, 90, 22)]
        let parent = LayoutRegion(id: "p", role: .content, rect: rect(0, 0, 120, 100))
        let region = TextRegion(id: "r", parentID: "p", kind: .prose,
                                rect: lines[0].union(lines[1]), text: "one\ntwo", lineRects: lines)
        let snap = snapshot([region], layout: [parent], t: target(w: 120, h: 100))
        let selection = rect(20, 0, 80, 100)
        let source = RegionTranslation(regionID: "r", parentID: "p", kind: .prose, readingOrder: 0,
                                       original: "one\ntwo", text: "ok", rects: lines,
                                       unionRect: region.rect, protectedFragments: [])
        let painted = OverlayItem.make(from: [source], snapshot: snap, selection: selection)
        expect(painted.count == 1 && !painted[0].overflow && painted[0].outcome == .painted, "Short translation fits measured source lines")
        let expected = lines.map { $0.intersection(selection) }
        expect(painted[0].paintRects == expected, "Painted mask remains one-to-one with clipped source lines")
        expect(painted[0].clip.height > painted[0].paintRects.map(\.height).reduce(0, +),
               "The bounding clip includes an unpainted line gap")
        let gap = CGPoint(x: 30, y: 40)
        expect(!painted[0].paintRects.contains { $0.contains(gap) }, "No paint covers between measured lines")
        var overflow = painted[0]
        overflow.outcome = .fitOverflow
        expect(overflow.paintRects.isEmpty && overflow.overflow && !overflow.occupancyUnavailable,
               "Fit overflow contributes no painted source mask but keeps its marker")

        let neighbour = TextRegion(id: "other", parentID: "p", kind: .prose,
                                   rect: rect(24, 12, 60, 18), text: "preserved")
        let collision = OverlayItem.make(from: [source], snapshot: snapshot([region, neighbour],
                      layout: [parent], t: target(w: 120, h: 100)), selection: selection)
        expect(collision.count == 1 && collision[0].outcome == .collisionUnavailable && collision[0].overflow
               && !collision[0].occupancyUnavailable && collision[0].paintRects.isEmpty && !collision[0].markerRect.isEmpty,
               "An overlapping untranslated neighbour prevents body painting and source mask, but keeps the expandable marker")
        expect(OverlayItem.counts(collision).collisionUnavailable == 1, "Unresolved collision stays counted")
        let collisionBoxes = DebugRegions.boxes(snapshot: snapshot([region, neighbour], layout: [parent], t: target(w: 120, h: 100)),
                                                plan: nil, items: collision, marks: [], targetLanguage: "zh-Hans")
        expect(collisionBoxes.first { $0.code == .collision } != nil, "Collision keeps debug code C")

        // Two TRANSLATED items whose source boxes overlap: the lower-priority one (later reading order) is clipped to
        // exclude the other's source rectangle; both paint, never on top of each other.
        let upperRegion = TextRegion(id: "up", parentID: "p", kind: .label, rect: rect(10, 10, 90, 22), text: "Upper", readingOrder: 0)
        let lowerRegion = TextRegion(id: "low", parentID: "p", kind: .label, rect: rect(10, 20, 90, 40), text: "Lower", readingOrder: 1)
        func translation(_ r: TextRegion, _ text: String) -> RegionTranslation {
            RegionTranslation(regionID: r.id, parentID: "p", kind: r.kind, readingOrder: r.readingOrder, original: r.text, text: text,
                              rects: [r.rect], unionRect: r.rect, protectedFragments: [])
        }
        let overlapSnap = snapshot([upperRegion, lowerRegion], layout: [parent], t: target(w: 120, h: 100))
        let overlapFull = rect(0, 0, 120, 100)
        let resolved = OverlayItem.make(from: [translation(upperRegion, "上"), translation(lowerRegion, "下")], snapshot: overlapSnap, selection: overlapFull)
        expect(resolved.count == 2 && resolved.allSatisfy(\.isPainted), "Overlapping translated items both paint: \(resolved.map(\.outcome))")
        expect(resolved[0].paintRects == [upperRegion.rect], "Higher-priority item keeps its whole source rectangle")
        expect(resolved[1].paintRects.allSatisfy { r in resolved[0].paintRects.allSatisfy { r.intersection($0).isNull || r.intersection($0).isEmpty } }
               && resolved[1].paintRects.allSatisfy { lowerRegion.rect.contains($0) && $0.intersection(upperRegion.rect).isEmpty },
               "Lower-priority paint is clipped out of the other source: \(resolved[1].paintRects)")
        let reversed = OverlayItem.make(from: [translation(lowerRegion, "下"), translation(upperRegion, "上")], snapshot: overlapSnap, selection: overlapFull)
        expect(reversed.filter(\.isPainted).count == 2, "Priority follows reading order, not input order")
        // A lower-priority item entirely inside the higher-priority one cannot be clipped: marker, no double painting.
        let swallowed = TextRegion(id: "in", parentID: "p", kind: .label, rect: rect(20, 14, 40, 10), text: "Inner", readingOrder: 1)
        let swallowedItems = OverlayItem.make(from: [translation(upperRegion, "上"), translation(swallowed, "内")],
                                              snapshot: snapshot([upperRegion, swallowed], layout: [parent], t: target(w: 120, h: 100)), selection: overlapFull)
        expect(swallowedItems[0].isPainted && swallowedItems[1].outcome == .collisionUnavailable && swallowedItems[1].paintRects.isEmpty,
               "A fully swallowed item keeps a marker instead of painting over its neighbour")

        // Realistic tight English OCR box -> Chinese (fallback font): the measured glyph ink must fit the exact
        // 14pt-tall source line at 12pt, and drawing must use that same measurement.
        let tightLine = rect(10, 10, 160, 14)
        let tightParent = LayoutRegion(id: "tp", role: .content, rect: rect(0, 0, 200, 60))
        let tightRegion = TextRegion(id: "t", parentID: "tp", kind: .prose, rect: tightLine, text: "Settings", lineRects: [tightLine])
        let tightSnap = snapshot([tightRegion], layout: [tightParent], t: target(w: 200, h: 60))
        let tightTranslation = RegionTranslation(regionID: "t", parentID: "tp", kind: .prose, readingOrder: 0,
                                                 original: "Settings", text: "设置与偏好", rects: [tightLine],
                                                 unionRect: tightLine, protectedFragments: [])
        let tight = OverlayItem.make(from: [tightTranslation], snapshot: tightSnap, selection: rect(0, 0, 200, 60))
        expect(tight.count == 1 && tight[0].outcome == .painted && tight[0].fontSize >= OverlayItem.minimumFontSize
               && tight[0].paintRects == [tightLine], "Tight CJK line paints on exact source line at >= 12pt: \(tight.map(\.outcome))")
        let tightLayout = OverlayTextLayout(text: "设置与偏好", rects: [tightLine], size: tight[0].fontSize, color: .black)
        // Render the production view, not only the layout verdict. The bitmap contains synthetic text,
        // never a captured desktop image; dark glyph pixels must stay in the exact 14pt occupancy.
        let width = 200, height = 60
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let bitmap = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.translateBy(x: 0, y: CGFloat(height))
            bitmap.scaleBy(x: 1, y: -1)
            let previousContext = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
            let view = OverlayContentView(frame: rect(0, 0, CGFloat(width), CGFloat(height)))
            view.items = tight
            view.draw(view.bounds)
            NSGraphicsContext.current = previousContext
            var inkInside = 0, inkOutside = 0
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    guard bytes[i + 3] > 30, bytes[i] < 80, bytes[i + 1] < 80, bytes[i + 2] < 80 else { continue }
                    if tightLine.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { inkInside += 1 }
                    else { inkOutside += 1 }
                }
            }
            expect(inkInside > 0 && inkOutside == 0, "Offscreen product drawing paints CJK ink only inside the source line (inside \(inkInside), outside \(inkOutside))")
        }
        expect(tightLayout.fits && abs(tightLayout.verticalShift(containerIndex: 0)) <= tightLine.height,
               "Fit and draw share one measured ink shift inside the source rect")

        // Source line too short for any 12pt glyph ink: true overflow, nothing painted, marker retained, text kept.
        let sliver = rect(10, 10, 160, 6)
        let sliverRegion = TextRegion(id: "s", parentID: "tp", kind: .prose, rect: sliver, text: "dot", lineRects: [sliver])
        let sliverTranslation = RegionTranslation(regionID: "s", parentID: "tp", kind: .prose, readingOrder: 0,
                                                  original: "dot", text: "设置与偏好", rects: [sliver],
                                                  unionRect: sliver, protectedFragments: [])
        let tiny = OverlayItem.make(from: [sliverTranslation], snapshot: snapshot([sliverRegion], layout: [tightParent], t: target(w: 200, h: 60)),
                                    selection: rect(0, 0, 200, 60))
        // Sliver too short for any 9..12pt ink: shrinking cannot help, so the last resort applies (no obstacle: cover grows down).
        expect(tiny.count == 1 && tiny[0].outcome == .paintedCover && tiny[0].fontSize == OverlayItem.minimumFontSize
               && tiny[0].paintRects == tiny[0].cover && !tiny[0].cover.isEmpty && tiny[0].occupied == [sliver],
               "Sliver falls through to the cover: \(tiny.map(\.outcome))")
        expect(tiny[0].cover[0].minX == sliver.minX && tiny[0].cover[0].minY == sliver.minY
               && OverlayTextLayout(text: "设置与偏好", rects: tiny[0].cover, size: 12, color: .black, narrow: true).fits,
               "Cover starts at the source corner and its layout fits")

        // Selection removes every source rectangle: the translation is kept and reported as no occupancy.
        let none = OverlayItem.make(from: [tightTranslation], snapshot: tightSnap, selection: rect(150, 40, 20, 10))
        expect(none.count == 1 && none[0].outcome == .noOccupancy && none[0].occupied.isEmpty
               && none[0].paintRects.isEmpty && none[0].occupancyUnavailable && !none[0].text.isEmpty,
               "No exact occupancy keeps the full translation without painting")
        let counts = OverlayItem.counts(tight + tiny + none + collision)
        expect(counts == OverlayItem.Counts(painted: 2, fitOverflow: 0, collisionUnavailable: 1, noOccupancy: 1, condensed: 0, cover: 1) && counts.total == 4,
               "Outcome counts partition the presented items: \(counts)")
    }

}
