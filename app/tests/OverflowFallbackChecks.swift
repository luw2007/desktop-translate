import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: overflow fallbacks: narrow font, shrink to 9pt, then the user-accepted translucent cover

    /// Smallest width (1pt resolution) of a single 16pt-high container into which `text` fits at `size`; nil above 800.
    static func minimumFitWidth(_ text: String, size: CGFloat, narrow: Bool) -> CGFloat? {
        func fits(_ w: CGFloat) -> Bool { OverlayTextLayout(text: text, rects: [rect(0, 0, w, 16)], size: size, color: .black, narrow: narrow).fits }
        guard fits(800) else { return nil }
        var lo: CGFloat = 4, hi: CGFloat = 800
        while hi - lo > 1 { let mid = ((lo + hi) / 2).rounded(); if fits(mid) { hi = mid } else { lo = mid } }
        return hi
    }

    static func overflowFallbackChecks() {
        let text = "Preferences and settings for the application"
        let wRegular = minimumFitWidth(text, size: 12, narrow: false)!
        let wNarrow12 = minimumFitWidth(text, size: 12, narrow: true)!
        let wNarrow9 = minimumFitWidth(text, size: 9, narrow: true)!
        expect(wNarrow12 + 4 < wRegular, "Narrow font is genuinely narrower: \(wNarrow12) vs \(wRegular)")
        expect(wNarrow9 + 4 < wNarrow12, "Smaller size is genuinely narrower: \(wNarrow9) vs \(wNarrow12)")

        let size = CGSize(width: 900, height: 300)
        let sel = rect(0, 0, 900, 300)
        let parent = LayoutRegion(id: "p", role: .content, rect: rect(0, 0, 900, 300))
        func make(width: CGFloat, y: CGFloat = 10, others: [(CGRect, String)] = [], selection: CGRect? = nil,
                  window: CGSize? = nil) -> (items: [OverlayItem], snap: CaptureSnapshot) {
            let line = rect(10, y, width, 16)
            let mine = TextRegion(id: "r", parentID: "p", kind: .prose, rect: line, text: "设置", background: RegionBackgroundEvidence(red: 1, green: 1, blue: 1, alpha: 1, verified: false))
            var regions = [mine]
            var translations = [RegionTranslation(regionID: "r", parentID: "p", kind: .prose, readingOrder: 0, original: "设置", text: text,
                                                  rects: [line], unionRect: line, protectedFragments: [])]
            for (index, other) in others.enumerated() {
                let id = "o\(index)"
                regions.append(TextRegion(id: id, parentID: "p", kind: .prose, rect: other.0, text: "其他", readingOrder: index + 1,
                                          background: RegionBackgroundEvidence(red: 1, green: 1, blue: 1, alpha: 1, verified: false)))
                translations.append(RegionTranslation(regionID: id, parentID: "p", kind: .prose, readingOrder: index + 1, original: "其他",
                                                      text: other.1, rects: [other.0], unionRect: other.0, protectedFragments: []))
            }
            let win = window ?? size
            let snap = snapshot(regions, layout: [parent], t: target(w: win.width, h: win.height))
            return (OverlayItem.make(from: translations, snapshot: snap, selection: selection ?? CGRect(origin: .zero, size: win)), snap)
        }

        // 1. Regular does not fit, narrow at the current size does: condensed, never below 12pt, no cover.
        let mid1 = ((wNarrow12 + wRegular) / 2).rounded()
        let condensed = make(width: mid1).items[0]
        expect(condensed.outcome == .paintedCondensed && condensed.fontSize >= OverlayItem.minimumFontSize && condensed.cover.isEmpty
               && condensed.paintRects == condensed.occupied && condensed.fontSizeAllowed,
               "Narrow font fits where regular does not: \(condensed.outcome) \(condensed.fontSize)")
        expect(!OverlayTextLayout(text: text, rects: condensed.paintRects, size: OverlayItem.minimumFontSize, color: .black).fits
               && OverlayTextLayout(text: text, rects: condensed.paintRects, size: condensed.fontSize, color: .black, narrow: true).fits,
               "Regular really fails and the stored size is the narrow size that fits (same layout as drawing)")

        // 2. Narrow 12pt fails, a smaller size fits: shrunk between 9 and 12pt.
        let mid2 = ((wNarrow9 + wNarrow12) / 2).rounded()
        let shrunk = make(width: mid2).items[0]
        expect(shrunk.outcome == .paintedCondensed && shrunk.fontSize < OverlayItem.minimumFontSize
               && shrunk.fontSize >= OverlayItem.shrinkFloorFontSize && shrunk.fontSizeAllowed,
               "Shrinks below 12pt only in the narrow font: \(shrunk.outcome) \(shrunk.fontSize)")
        expect(!OverlayTextLayout(text: text, rects: shrunk.paintRects, size: OverlayItem.minimumFontSize, color: .black, narrow: true).fits,
               "Narrow at 12pt really failed before shrinking")

        // 3. Shrink stops at 9pt: just narrower than the 9pt requirement falls through to the cover at 12pt, never a 8pt paint.
        let tooNarrow = make(width: wNarrow9 - 4)
        let covered = tooNarrow.items[0]
        expect(!OverlayTextLayout(text: text, rects: covered.occupied, size: OverlayItem.shrinkFloorFontSize, color: .black, narrow: true).fits,
               "Even 9pt narrow does not fit the source line")
        expect(covered.outcome == .paintedCover && covered.fontSize == OverlayItem.minimumFontSize && covered.fontSizeAllowed,
               "Cover is used only after shrinking to 9pt failed, at 12pt: \(covered.outcome) \(covered.fontSize)")
        expect(OverlayItem.counts([condensed, shrunk, covered]) == OverlayItem.Counts(painted: 3, condensed: 2, cover: 1),
               "Condensed and cover are counted separately inside painted")
        for plain in [make(width: wRegular + 6).items[0]] { expect(plain.outcome == .painted && plain.cover.isEmpty, "Fitting text never takes a fallback") }

        // Cover geometry: starts at the source corner, contains the source, fits its text, stays in the window.
        let box = covered.cover.dropFirst().reduce(covered.cover[0]) { $0.union($1) }
        expect(box.minX == covered.clip.minX && box.minY == covered.clip.minY && box.contains(covered.clip) && covered.cover.count >= 1
               && box.maxX <= size.width && box.maxY <= size.height && box.width > covered.clip.width,
               "Cover grows from the source corner and contains it: \(box)")
        expect(OverlayTextLayout(text: text, rects: covered.cover, size: 12, color: .black, narrow: true).fits, "Cover layout fits (fit and draw share the layout)")
        expect(covered.baseRects == covered.occupied && covered.paintRects == covered.cover && !covered.overflow && !covered.occupancyUnavailable,
               "Opaque base stays the source line; paint is the cover")

        // Clamped to the selection/window: a narrow selection limits the right edge and pushes the cover down.
        let clampedSel = rect(0, 0, 150, 300)
        let clamped = make(width: wNarrow9 - 4, selection: clampedSel).items[0]
        expect(clamped.outcome == .paintedCover, "Clamped cover still fits by growing down: \(clamped.outcome)")
        expect(clamped.cover.allSatisfy { clampedSel.contains($0) } && clamped.cover.count > covered.cover.count,
               "Cover never leaves the selection and grows down instead: \(clamped.cover)")
        let tinyWindow = make(width: wNarrow9 - 4, window: CGSize(width: 140, height: 120))
        expect(tinyWindow.items[0].cover.allSatisfy { CGRect(x: 0, y: 0, width: 140, height: 120).contains($0) },
               "Cover never leaves the window: \(tinyWindow.items[0].cover)")

        // Never over another item's paint: a neighbour directly below blocks growth down -> orange marker, not a cover.
        let wide = wNarrow9 - 4
        let blockedDown = make(width: wide, others: [(rect(10, 28, 60, 16), "Ok")], selection: clampedSel)
        expect(blockedDown.items[0].outcome == .fitOverflow && blockedDown.items[0].cover.isEmpty && blockedDown.items[0].paintRects.isEmpty
               && blockedDown.items[1].outcome == .painted,
               "Cover that would hit another translation refuses: \(blockedDown.items.map(\.outcome))")
        // A neighbour further down is respected: the cover stops above it and never intersects it.
        let neighbour = rect(10, 120, 60, 16)
        let respected = make(width: wide, others: [(neighbour, "Ok")], selection: clampedSel)
        expect(respected.items[0].outcome == .paintedCover && respected.items[1].outcome == .painted
               && !respected.items[0].cover.contains { $0.intersects(neighbour) },
               "Cover avoids the other item's paint: \(respected.items[0].cover)")
        // A neighbour to the right on the cover's rows limits its width instead of being covered.
        let rightNeighbour = rect(10 + wide + 30, 10, 80, 16)
        let limited = make(width: wide, others: [(rightNeighbour, "Ok")])
        expect(limited.items[1].outcome == .painted && !limited.items[0].cover.contains { $0.intersects(rightNeighbour) }
               && limited.items[0].cover.allSatisfy { $0.maxX <= rightNeighbour.minX + 0.001 },
               "Cover width stops at a right neighbour: \(limited.items[0].outcome) \(limited.items[0].cover)")
        // Two overflowing items below each other never produce overlapping covers.
        let pair = make(width: wide, others: [(rect(10, 60, wide, 16), text)], selection: clampedSel)
        let covers = pair.items.map(\.cover)
        expect(pair.items.allSatisfy { $0.outcome == .paintedCover || $0.outcome == .fitOverflow }
               && !covers[0].contains { a in covers[1].contains { a.intersection($0).width > 0 && a.intersection($0).height > 0 } }
               && !covers[0].contains { $0.intersects(pair.items[1].occupied[0]) } && !covers[1].contains { $0.intersects(pair.items[0].occupied[0]) },
               "Covers never overlap each other or another item's source: \(pair.items.map(\.outcome))")

        // Freshness baseline: the source line is baselined, the cover outside it is not.
        let plan = make(width: wide)
        let areas = DesktopPlan(snapshot: plan.snap, unicode: true).replacedSourceRects(snapshot: plan.snap, selection: sel)
        let item = plan.items[0]
        expect(item.outcome == .paintedCover, "Baseline scenario produced a cover")
        expect(item.baseRects.allSatisfy { p in areas.contains { $0.insetBy(dx: -0.001, dy: -0.001).contains(p) } },
               "The opaque source area is baselined")
        expect(item.cover.contains { p in !areas.contains { $0.insetBy(dx: -0.001, dy: -0.001).contains(p) } }
               && areas.allSatisfy { a in item.baseRects.contains { $0.insetBy(dx: -0.001, dy: -0.001).contains(a) } },
               "The cover outside the source is not part of the baseline: \(areas) vs \(item.cover)")

        // Debug classification of the real outcomes.
        let debug = DebugRegions.boxes(snapshot: plan.snap, plan: DesktopPlan(snapshot: plan.snap, unicode: true), items: plan.items, marks: [], targetLanguage: "zh-Hans")
        expect(debug.first?.code == .cover && DebugCode.cover.rawValue == "V" && DebugCode.condensed.rawValue == "S", "Cover is debug V")
        let s = make(width: mid2)
        expect(DebugRegions.boxes(snapshot: s.snap, plan: DesktopPlan(snapshot: s.snap, unicode: true), items: s.items, marks: [], targetLanguage: "zh-Hans").first?.code == .condensed,
               "Condensed/shrunk is debug S")

        // Truly impossible: a sliver window leaves no room for any cover either -> the orange marker remains.
        let cramped = make(width: wide, selection: rect(0, 0, 60, 26), window: CGSize(width: 60, height: 26))
        expect(cramped.items[0].outcome == .fitOverflow && cramped.items[0].cover.isEmpty && !cramped.items[0].text.isEmpty,
               "No room for a cover keeps fitOverflow with the text: \(cramped.items[0].outcome)")
    }

}
