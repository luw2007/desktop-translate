import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    static func groupingChecks() {
        let t = target()
        let crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        func group(_ o: [OCRObservation]) -> [TextRegion] {
            OCRGrouper.group(o, crop: crop, target: t, layout: [])
        }
        func wordBox(_ x: CGFloat, _ w: CGFloat) -> CGRect {
            CoordinateMapper.localToVision(CGRect(x: x, y: 84, width: w, height: 20), crop: crop)
        }
        let row = OCRObservation(text: "Name Value", confidence: 0.9,
                                 normalizedBox: CoordinateMapper.localToVision(CGRect(x: 440, y: 84, width: 220, height: 20), crop: crop),
                                 words: [OCRWord(text: "Name", normalizedBox: wordBox(440, 45)), OCRWord(text: "Value", normalizedBox: wordBox(615, 45))])
        let cols = group([row])
        expect(cols.map { $0.text } == ["Name", "Value"], "Wide-gap line split into columns: \(cols.map { $0.text })")
        expect(abs(cols[0].rect.minX - 440) < 0.01 && abs(cols[0].rect.width - 45) < 0.01 && abs(cols[1].rect.minX - 615) < 0.01, "Column rects follow word boxes: \(cols.map { $0.rect })")
        let tight = OCRObservation(text: "Name Value", confidence: 0.9,
                                   normalizedBox: CoordinateMapper.localToVision(CGRect(x: 440, y: 84, width: 100, height: 20), crop: crop),
                                   words: [OCRWord(text: "Name", normalizedBox: wordBox(440, 45)), OCRWord(text: "Value", normalizedBox: wordBox(495, 45))])
        expect(group([tight]).count == 1, "Ordinary word spacing is not split")
        signatureChecks()
        boundaryGroupingChecks()
    }

    /// Boundary-conservative grouping: a genuine measured paragraph joins; touching/adjacent/interleaved/overlapping
    /// geometry and parent straddles never produce a cross-control paragraph or an invented identity.
    static func boundaryGroupingChecks() {
        let t = target()
        let crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        let pane = LayoutRegion(id: "pane", parentID: "selection", role: .pane, rect: CGRect(x: 0, y: 0, width: 300, height: 600))
        func obs(_ items: [(String, CGFloat, CGFloat)], y: CGFloat) -> OCRObservation {
            let x0 = items.first!.1, x1 = items.last!.1 + items.last!.2
            let box = CoordinateMapper.localToVision(CGRect(x: x0, y: y, width: x1 - x0, height: 20), crop: crop)
            let ws = items.map { OCRWord(text: $0.0, normalizedBox: CoordinateMapper.localToVision(CGRect(x: $0.1, y: y, width: $0.2, height: 20), crop: crop)) }
            return OCRObservation(text: items.map { $0.0 }.joined(separator: " "), confidence: 0.9, normalizedBox: box, words: ws)
        }
        func line(_ text: String, x: CGFloat, w: CGFloat, y: CGFloat) -> OCRObservation {
            let box = CoordinateMapper.localToVision(CGRect(x: x, y: y, width: w, height: 20), crop: crop)
            return OCRObservation(text: text, confidence: 0.9, normalizedBox: box, words: [])
        }
        func group(_ o: [OCRObservation], layout: [LayoutRegion]? = nil) -> OCRGrouper.GroupedOCR {
            OCRGrouper.grouped(o, crop: crop, target: t, layout: layout ?? [pane])
        }
        let first = obs([("Please", 20, 50), ("review", 75, 50), ("the", 130, 30), ("following", 165, 70), ("changes", 240, 50)], y: 100)
        let second = obs([("carefully", 20, 60), ("now", 85, 30)], y: 122)
        let para = group([first, second])
        expect(para.regions.count == 1 && para.regions[0].kind == .prose && para.regions[0].lineRects.count == 2
               && para.regions[0].parentID == "pane", "Measured full first line in verified container is one paragraph: \(para.regions)")
        expect(group([first, second], layout: []).regions.count == 1, "Paragraph merge uses tight line geometry, not a container edge")
        let shortFirst = obs([("Please", 20, 50), ("review", 75, 50), ("this", 130, 30), ("soon", 165, 40)], y: 100)
        expect(group([shortFirst, second]).regions.count == 1, "Fullness is not required: consistent left edge and spacing merge")
        let sibling = line("Other", x: 100, w: 80, y: 122)
        expect(group([first, second, sibling]).regions.count == 3, "Adjacent same-row sibling blocks join")
        let touching = line("Apply", x: 112, w: 60, y: 122)
        expect(group([first, second, touching]).regions.count == 3, "Touching control blocks join")
        let middle = line("Middle row", x: 100, w: 80, y: 111)
        expect(!group([first, middle, second]).regions.contains { $0.text.contains("Please") && $0.text.contains("carefully") },
               "Interleaved row blocks join")
        let columns = group([line("Left column long text here", x: 20, w: 140, y: 100), line("Right column text", x: 150, w: 130, y: 100),
                             line("below", x: 20, w: 100, y: 122)]).regions
        expect(columns.count == 3 && columns.allSatisfy { $0.kind == .label }, "Overlapping columns never merge or gain a type: \(columns)")
        let right = LayoutRegion(id: "right", parentID: "selection", role: .pane, rect: CGRect(x: 300, y: 0, width: 300, height: 600))
        let split = group([obs([("Left", 200, 40), ("words", 245, 40), ("Right", 310, 40)], y: 300)], layout: [pane, right])
        expect(split.regions.map { $0.text } == ["Left words", "Right"] && split.regions.map { $0.parentID } == ["pane", "right"]
               && split.omittedObservations == 0, "Straddle splits on complete tokens: \(split)")
        let blind = group([line("Left words Right", x: 200, w: 150, y: 300)], layout: [pane, right])
        expect(blind.regions.isEmpty && blind.omittedObservations == 1, "Straddle without words is omitted and counted")
        let center = group([line("Mostly inside", x: 250, w: 100, y: 300)], layout: [pane, right])
        expect(center.regions.isEmpty && center.omittedObservations == 1, "Center membership is not containment")
        expect(group([line("Inside", x: 20, w: 80, y: 300)], layout: [pane, right]).regions[0].parentID == "pane", "Full containment sets smallest parent")
    }

}
