import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: plan

    static func planChecks() {
        let cancel = TextRegion(id: "btn/1", kind: .button, rect: rect(10, 10), text: "Cancel")
        let settings = TextRegion(id: "btn/2", kind: .label, rect: rect(70, 10), text: "Settings", readingOrder: 1)
        let url = TextRegion(id: "p1", kind: .path, rect: rect(10, 40), text: "/usr/bin/swift", readingOrder: 2)
        let unknown = TextRegion(id: "u", kind: .unknown, rect: rect(10, 60), text: "Some words here", readingOrder: 3)
        let code = TextRegion(id: "term", kind: .log, rect: CGRect(x: 0, y: 100, width: 400, height: 60),
                              text: "$ git status\nThe build finished successfully today.\n", readingOrder: 4)
        let plan = DesktopPlan(snapshot: snapshot([cancel, settings, url, unknown, code]))
        let reqs = plan.requests

        var tr: [String: String] = [:]
        for r in reqs { tr[r.id] = "译" + r.text.prefix(1) }
        let out = try! plan.rendered(translations: tr)
        expect(out.first { $0.regionID == code.id }?.text.components(separatedBy: "\n").first == "$ git status", "Terminal command line kept byte-exact")

        // Adversarial responses.
        let first = reqs[0].id
        func fails(_ t: [String: String], _ e: DesktopPlanError, _ m: String) {
            do { _ = try plan.rendered(translations: t); expect(false, m) } catch let x as DesktopPlanError { expect(x == e, "\(m): \(x)") } catch { expect(false, m) }
        }
        var missing = tr; missing[first] = nil
        fails(missing, .missing([first]), "Missing id")
        var extra = tr; extra["btn%2F1/zzz"] = "x"
        fails(extra, .unexpected(["btn%2F1/zzz"]), "Unexpected id")
        var empty = tr; empty[first] = "  \n"
        fails(empty, .empty([first]), "Empty translation")
        do {
            _ = try plan.rendered(pairs: reqs.map { (id: $0.id, text: "x") } + [(id: first, text: "y")])
            expect(false, "Duplicate must throw")
        } catch let e as DesktopPlanError { expect(e == .duplicate([first]), "Duplicate id: \(e)") } catch { expect(false, "Duplicate") }
        // Protected paths survive rendered prose.
        let prose = TextRegion(id: "para", kind: .prose, rect: CGRect(x: 0, y: 0, width: 300, height: 30),
                               text: "Please open /tmp/out.txt and\nreview the result carefully.",
                               lineRects: [rect(0, 0, 300, 14), rect(0, 16, 200, 14)])
        let pp = DesktopPlan(snapshot: snapshot([prose]))
        let ppOut = try! pp.rendered(translations: Dictionary(uniqueKeysWithValues: pp.requests.map { ($0.id, "X") }))
        expect(ppOut[0].text.contains("/tmp/out.txt"), "Path kept: \(ppOut[0].text)")
        // Consumer contract: measured wraps become one request, without replacing occupied boxes.
        let lines = [rect(10, 100, 300, 14), rect(10, 116, 180, 14)]
        let wrapped = TextRegion(id: "wrapped", kind: .log, rect: lines[0].union(lines[1]),
                                 text: "This paragraph continues across the\nnext visual line", lineRects: lines)
        let wrapPlan = DesktopPlan(snapshot: snapshot([wrapped]))
        expect(wrapPlan.requests.count == 1, "Measured terminal continuation has one context request")
        let wrapOutput = try! wrapPlan.rendered(translations: [wrapPlan.requests[0].id: "完整段落"])
        expect(wrapOutput[0].text == "完整段落" && wrapOutput[0].rects == lines &&
               wrapOutput[0].original == wrapped.text, "Consumer preserves original geometry and source")
        var uncertain = wrapped
        uncertain.lineRects = [lines[0], rect(400, 116, 180, 14)]
        expect(DesktopPlan(snapshot: snapshot([uncertain])).requests.count == 2,
               "Unaligned terminal lines retain separate requests")
        uncertain.lineRects = []
        expect(DesktopPlan(snapshot: snapshot([uncertain])).requests.count == 2,
               "Absent measured boxes cannot authorize joining")
        let sourceLines = "This paragraph continues across the\nnext visual line"
        expect(OCRGrouper.visualContinuationLines(text: sourceLines, rects: lines) == Set([1]),
               "Extracted OCR grouping recognizes the same measured wrap used by the plan")
        expect(OCRGrouper.visualContinuationLines(text: sourceLines, rects: [lines[0]]).isEmpty,
               "Missing measured box never supplies continuation evidence")
        expect(OCRGrouper.visualContinuationLines(text: sourceLines, rects: [lines[0], rect(400, 116, 180, 14)]).isEmpty,
               "Unaligned boxes never authorize a visual continuation")
        expect(OCRGrouper.visualContinuationLines(text: sourceLines, rects: [lines[0], rect(10, 116, 0, 14)]).isEmpty &&
               OCRGrouper.visualContinuationLines(text: sourceLines, rects: [lines[0], rect(.nan, 116, 180, 14)]).isEmpty,
               "Empty or nonfinite geometry fails closed")
        expect(OCRGrouper.visualContinuationLines(text: sourceLines + "\n- New item",
                                                   rects: lines + [rect(10, 132, 180, 14)]) == Set([1]),
               "A new list item does not join an otherwise measured visual wrap")
        let protectedRows = ["$ git status", "git diff --stat", "/tmp/file", "+ source change", "```swift",
                             "let value = 1", "```"]
        for row in protectedRows {
            var boundary = wrapped
            boundary.text = "This paragraph continues across the\n" + row + "\nMore ordinary prose follows"
            boundary.lineRects = [lines[0], lines[1], rect(10, 132, 180, 14)]
            let boundaryPlan = DesktopPlan(snapshot: snapshot([boundary]))
            let output = try! boundaryPlan.rendered(translations: Dictionary(uniqueKeysWithValues:
                boundaryPlan.requests.map { ($0.id, "译文") }))
            expect(output[0].text.contains("\n" + row + "\n"), "Protected terminal boundary is byte-exact")
        }
        for word in ["A", "I"] {
            let ui = TextRegion(id: word, kind: .button, rect: rect(0, 0), text: word)
            let uiPlan = DesktopPlan(snapshot: snapshot([ui]))
            expect(uiPlan.requests.count == 1, "One-letter UI word reaches backend")
            expect((try! uiPlan.rendered(translations: [uiPlan.requests[0].id: "译"]))[0].text == "译",
                   "One-letter UI result reaches consumer")
            var codeWord = ui; codeWord.kind = .code
            expect(DesktopPlan(snapshot: snapshot([codeWord])).requests.isEmpty, "Code letter stays protected")
        }
        // Non-English sources: the Unicode planner requests non-ASCII UI text and caseless-script prose that the
        // original English-only planner (default) leaves untouched.
        for word in ["設定", "Réglages"] {
            let ui = TextRegion(id: word, kind: .button, rect: rect(0, 0), text: word)
            expect(DesktopPlan(snapshot: snapshot([ui]), unicode: true).requests.count == 1, "Unicode UI word reaches backend: \(word)")
            expect(DesktopPlan(snapshot: snapshot([ui])).requests.count == 1, "Source switch no longer changes the plan for \(word)")
        }
        let jaProse = TextRegion(id: "ja", kind: .prose, rect: rect(0, 0, 300, 14), text: "これは日本語の文章です。")
        expect(DesktopPlan(snapshot: snapshot([jaProse]), unicode: true).requests.count == 1, "Unicode prose request")
        // Target language: confidently-target text is K(target); labels, single words and mixed text still translate.
        func regionPlan(_ text: String, _ kind: RegionKind = .label, source: Bool = true, target: String) -> DesktopPlan {
            DesktopPlan(snapshot: snapshot([TextRegion(id: "r", kind: kind, rect: rect(0, 0, 200, 14), text: text)]), unicode: source, target: target)
        }
        for word in ["Settings", "Sidebar", "OK", "x", "Idle"] {
            expect(regionPlan(word, target: "zh-Hans").requests.count == 1, "Short English text translates: \(word)")
        }
        expect(regionPlan("设置", target: "zh-Hans").requests.isEmpty && regionPlan("设置", target: "zh-Hans").skipped.first?.detail == .target
               && regionPlan("设置", target: "zh-Hans").skipped.first?.reason == "nothing to translate", "Chinese label with Chinese target is K(target)")
        expect(regionPlan("设置", target: "en").requests.count == 1, "Chinese label with English target translates")
        expect(regionPlan("设置 Settings", target: "zh-Hans").requests.count == 1, "Mixed text translates")
        let identifier = regionPlan("max_retries", target: "zh-Hans").skipped.first
        expect(identifier?.detail == .identifier && identifier?.reason.hasPrefix(DesktopPlan.protectedReasonPrefix) == true, "Pure identifier is P, not K")
        expect(regionPlan("16GB", target: "zh-Hans").skipped.first?.reason == "nothing to translate", "Unit-only text is K")
    }

}
