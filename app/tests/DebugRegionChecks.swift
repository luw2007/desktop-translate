import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: debug overlay categories (pure classification; no drawing, no capture)

    static func debugRegionChecks() {
        let white = NSColor.white
        func region(_ id: String, _ order: Int, _ kind: RegionKind, _ text: String, y: CGFloat) -> TextRegion {
            TextRegion(id: id, kind: kind, rect: rect(10, y, 120, 14), text: text, readingOrder: order)
        }
        let regions = [
            region("painted", 0, .label, "Cancel", y: 10), region("extended", 1, .label, "Settings", y: 30),
            region("overflow", 2, .label, "Preferences", y: 50), region("collision", 3, .label, "Network", y: 70),
            region("nooccupancy", 4, .label, "General", y: 90), region("path", 5, .path, "/usr/bin/swift", y: 110),
            region("nothing", 6, .label, "...", y: 130), region("missing", 7, .label, "Advanced", y: 150),
            region("condensed", 8, .label, "Keyboard", y: 170), region("cover", 9, .label, "Accessibility", y: 190),
        ]
        let snap = snapshot(regions)
        let plan = DesktopPlan(snapshot: snap)
        expect(plan.skipped.contains { $0.regionID == "path" && $0.reason.hasPrefix(DesktopPlan.protectedReasonPrefix) }, "path is a protected skip")
        expect(plan.skipped.contains { $0.regionID == "nothing" && $0.reason == "nothing to translate" }, "punctuation is a nothing-to-translate skip")
        func item(_ id: String, _ outcome: OverlayItem.Outcome, extended: [CGRect] = []) -> OverlayItem {
            let r = regions.first { $0.id == id }!
            return OverlayItem(regionID: id, readingOrder: r.readingOrder, text: "x", protectedFragments: [],
                               occupied: outcome == .noOccupancy ? [] : [r.rect], clip: outcome == .noOccupancy ? .zero : r.rect,
                               extended: extended, background: white, fontSize: 12, outcome: outcome)
        }
        let items = [item("painted", .painted), item("extended", .painted, extended: [rect(10, 30, 200, 14)]),
                     item("overflow", .fitOverflow), item("collision", .collisionUnavailable), item("nooccupancy", .noOccupancy),
                     item("condensed", .paintedCondensed), item("cover", .paintedCover)]
        let marks = [DebugMark(kind: .lowConfidence, rects: [rect(300, 10)]), DebugMark(kind: .straddleOmitted, rects: [rect(300, 30)]),
                     DebugMark(kind: .dropped, rects: [rect(300, 50), rect(300, 66)]), DebugMark(kind: .straddleOmitted, rects: [rect(300, 90)])]
        let boxes = DebugRegions.boxes(snapshot: snap, plan: plan, items: items, marks: marks, targetLanguage: "zh-Hans")
        func code(_ label: String) -> DebugCode? { boxes.first { $0.label == label }?.code }
        expect(code("T1") == .painted && code("E2") == .extended && code("O3") == .overflow && code("C4") == .collision
               && code("N5") == .noOccupancy && code("P6") == .protected && code("K7") == .skipped && code("R8") == .missing
               && code("S9") == .condensed && code("V10") == .cover,
               "Region categories: \(boxes.map(\.label))")
        expect(code("L1") == .lowConfidence && code("X1") == .straddle && code("X2") == .straddle && code("D1") == .dropped,
               "Mark categories and per-code numbering: \(boxes.map(\.label))")
        expect(boxes.first { $0.label == "D1" }?.rects.count == 2, "Dropped region keeps every line rectangle")
        let counts = Dictionary(uniqueKeysWithValues: DebugRegions.counts(boxes).map { ($0.code, $0.count) })
        expect(counts[.painted] == 1 && counts[.extended] == 1 && counts[.straddle] == 2 && counts.values.reduce(0, +) == boxes.count,
               "Legend counts add up to the drawn boxes")
        expect(Set(DebugCode.allCases.map(\.rawValue)).count == DebugCode.allCases.count, "Codes are unique")
        expect(Set(boxes.map(\.code)) == Set(DebugCode.allCases), "Every code is reachable from the synthetic plan")
        expect(DebugRegions.logLine(DebugRegions.counts(boxes)).contains("T=1") && !DebugRegions.logLine(DebugRegions.counts(boxes)).contains("Cancel"),
               "Log line is counts only")
        // Capture failure with geometry only: marks alone still draw; nothing at all draws nothing.
        expect(DebugRegions.boxes(snapshot: nil, plan: nil, items: [], marks: marks, targetLanguage: "zh-Hans").count == 4, "Marks draw without a snapshot")
        expect(DebugRegions.boxes(snapshot: nil, plan: nil, items: [], marks: [], targetLanguage: "zh-Hans").isEmpty, "Nothing recognized, nothing drawn")
        // Planned and presented-empty (no items yet): every translatable region is R, never silently omitted.
        let pending = DebugRegions.boxes(snapshot: snap, plan: plan, items: [], marks: [], targetLanguage: "zh-Hans")
        expect(pending.filter { $0.code == .missing }.count == 8 && pending.count == 10, "Without items planned regions are R")
        // Export uses the identical classifier, including missing items, K subreasons and discarded observations.
        let export = DebugSessionExport.make(settings: .defaults, target: snap.target, snapshot: snap, plan: plan,
                                             items: items, marks: marks, phase: "presented", captureCounts: ["lowConfidence": 1])
        expect(export.regions.map(\.code) == ["T", "E", "O", "C", "N", "P", "K", "R", "S", "V"], "Export codes match drawn region codes")
        expect(export.regions.map(\.index) == Array(1...10), "Export uses reading-order display indices")
        expect(export.regions[6].subreason == boxes.first { $0.label == "K7" }?.detail?.rawValue, "K export retains classifier subreason")
        expect(export.regions[1].isExtended == true && export.regions[1].extendedRects.count == 1, "Extension evidence exported")
        expect(export.regions[3].collisionPartnerIndex == nil, "Never infer collision partner from overlapping geometry")
        expect(export.regions[2].paintRects.isEmpty && export.regions[2].outcome == "fitOverflow", "Overflow does not pretend to paint")
        expect(export.regions[7].translation == nil && export.regions[7].outcome == nil, "Pending translation is absent, not fabricated")
        expect(export.observations.map(\.code) == ["L", "X", "D", "X"] && export.observations.map(\.index) == [1, 1, 1, 2], "Discarded observations keep per-code numbering")
        expect(export.observations[2].rects.count == 2 && export.observations.allSatisfy { $0.source == nil && $0.sourceText == nil && $0.confidence == nil }, "Discarded observations carry geometry only")
        expect(export.legendCounts.values.reduce(0, +) == boxes.count, "Export legend equals displayed legend")
        do {
            let data = try JSONEncoder().encode(export)
            expect(try JSONDecoder().decode(DebugSessionExport.self, from: data) == export, "All debug outcomes JSON roundtrip")
        } catch { expect(false, "Debug export JSON failed: \(error)") }
        // Label placement: above the outline when it fits, otherwise inside the top-left corner, always inside bounds.
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let above = DebugBoxPainter.labelRect(for: rect(50, 100), textWidth: 20, bounds: bounds)
        expect(above.maxY <= 100 && above.minX == 50, "Label sits above the outline")
        let top = DebugBoxPainter.labelRect(for: rect(390, 2), textWidth: 20, bounds: bounds)
        expect(top.minY == 2 && top.maxX <= 400 && top.minX >= 0, "Label falls back inside and stays in bounds")

        // Grouper marks: low confidence and straddle-omitted lines are recorded as geometry, without text.
        let crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        let pane = LayoutRegion(id: "pane", parentID: "selection", role: .pane, rect: CGRect(x: 0, y: 0, width: 300, height: 600))
        let right = LayoutRegion(id: "right", parentID: "selection", role: .pane, rect: CGRect(x: 300, y: 0, width: 300, height: 600))
        func line(_ text: String, x: CGFloat, w: CGFloat, y: CGFloat, confidence: Double) -> OCRObservation {
            OCRObservation(text: text, confidence: confidence, normalizedBox: CoordinateMapper.localToVision(CGRect(x: x, y: y, width: w, height: 20), crop: crop))
        }
        let grouped = OCRGrouper.grouped([line("faint", x: 20, w: 80, y: 40, confidence: 0.1), line("Left words Right", x: 200, w: 150, y: 300, confidence: 0.9),
                                          line("Inside", x: 20, w: 80, y: 100, confidence: 0.9)], crop: crop, target: target(), layout: [pane, right])
        expect(grouped.marks.map(\.kind) == [.lowConfidence, .straddleOmitted] && grouped.regions.count == 1 && grouped.omittedObservations == 1,
               "Grouper reports low-confidence and straddle marks: \(grouped.marks)")
        expect(abs(grouped.marks[0].rects[0].minX - 20) < 0.5 && abs(grouped.marks[0].rects[0].minY - 40) < 0.5, "Low-confidence mark is window-local geometry")
    }
}
