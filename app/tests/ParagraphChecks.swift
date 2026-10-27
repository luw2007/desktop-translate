import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: paragraph blocks

    static func paragraphBlockChecks() {
        let crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        let sel = rect(0, 0, 800, 600)
        func obs(_ text: String, x: CGFloat = 20, w: CGFloat = 280, y: CGFloat, h: CGFloat = 20, confidence: Double = 0.9) -> OCRObservation {
            OCRObservation(text: text, confidence: confidence, normalizedBox: CoordinateMapper.localToVision(CGRect(x: x, y: y, width: w, height: h), crop: crop), words: [])
        }
        func group(_ o: [OCRObservation]) -> OCRGrouper.GroupedOCR { OCRGrouper.grouped(o, crop: crop, target: target(), layout: []) }
        let l1 = "Please review the following changes carefully before"
        let l2 = "you merge them into the main branch because the"
        let l3 = "release is scheduled for tomorrow morning"
        let merged = group([obs(l1, y: 100), obs(l2, y: 122), obs(l3, y: 144)])
        expect(merged.regions.count == 1 && merged.regions[0].isParagraphBlock && merged.regions[0].lineRects.count == 3,
               "Consecutive prose lines merge into one block: \(merged.regions)")

        // Boundaries that must NOT merge.
        func noJoin(_ g: OCRGrouper.GroupedOCR, _ m: String) {
            expect(!g.regions.contains { $0.text.contains("Please") && $0.text.contains("you merge") }, m)
        }
        noJoin(group([obs(l1, y: 100), obs("$ git status --short", y: 122), obs(l3, y: 144)]), "Protected/command line is never merged")
        noJoin(group([obs(l1, y: 100), obs("```", y: 122), obs(l3, y: 144)]), "Code fence is never merged")
        noJoin(group([obs(l1, y: 100), obs(l2, x: 80, y: 122)]), "Inconsistent left edge does not merge")
        let uneven = group([obs(l1, y: 100), obs(l2, y: 122), obs(l3, y: 150)])
        expect(uneven.regions.count == 2 && uneven.regions[0].lineRects.count == 2, "Inconsistent line spacing stops the block: \(uneven.regions.map(\.text))")
        noJoin(group([obs(l1, y: 100), obs(l2, y: 128), obs("gap", x: 100, w: 40, y: 121, h: 6)]), "A recognized rect in the gap prevents merge")
        noJoin(group([obs(l1, y: 100), obs(l2, y: 128), obs("faint", x: 100, w: 40, y: 121, h: 6, confidence: 0.05)]), "An omitted (low confidence) rect in the gap prevents merge")
        noJoin(group([obs(l1, y: 100), obs(l2, y: 122, h: 28)]), "Different line heights do not merge")
        noJoin(group([obs(l1, y: 100), obs(l2, y: 122), obs("Cancel", x: 330, w: 50, y: 122)]).regions.isEmpty ? merged : group([obs(l1, y: 100), obs(l2, y: 122), obs("Cancel", x: 310, w: 50, y: 122)]),
               "Adjacent same-row control prevents merge")

        // One request, one block region, union paint.
        let snap = snapshot(merged.regions, t: target())
        let plan = DesktopPlan(snapshot: snap)
        expect(plan.requests.count == 1 && !plan.requests[0].text.contains("\n"), "A block is translated once: \(plan.requests)")
        let english = "Please review the following changes carefully before merging them into the main branch, because the release ships tomorrow."
        let rendered = try! plan.rendered(translations: [plan.requests[0].id: english])
        let union = merged.regions[0].rect
        expect(rendered.count == 1 && rendered[0].text == english && rendered[0].rects == [union], "Block render keeps the whole text over the union: \(rendered[0].rects)")
        expect(plan.replacedSourceRects(snapshot: snap, selection: sel) == [union], "Baseline is the union")
        let items = OverlayItem.make(from: rendered, snapshot: snap, selection: sel)
        expect(items[0].outcome == .painted && items[0].paintRects == [union] && items[0].fontSize >= OverlayItem.minimumFontSize,
               "Wide English fits the union at >= 12pt: \(items[0].outcome) \(items[0].fontSize)")
        expect(!OverlayTextLayout(text: english, rects: [CGRect(x: 20, y: 100, width: 280, height: 20)], size: 12, color: .black).fits,
               "The same text does not fit one source line (the original overflow cause)")
        expect(OverlayTextLayout(text: english, rects: items[0].paintRects, size: items[0].fontSize, color: .black).fits, "Fit and draw share the layout")

        // Unfittable even as a cover (too tall for the window) stays fitOverflow, marker kept, text kept.
        let huge = String(repeating: "This sentence cannot possibly fit in the available space. ", count: 200)
        let over = OverlayItem.make(from: [RegionTranslation(regionID: rendered[0].regionID, parentID: nil, kind: rendered[0].kind, readingOrder: 0,
                                                              original: rendered[0].original, text: huge, rects: [union], unionRect: union, protectedFragments: [])],
                                    snapshot: snap, selection: sel)
        expect(over[0].outcome == .fitOverflow && over[0].paintRects.isEmpty && !over[0].text.isEmpty, "Unfittable block is fitOverflow with text kept")

        // Protected fragments stay verbatim in a merged block.
        let withPath = group([obs("Please open /tmp/out.txt and read the", y: 100), obs("report carefully before you continue", y: 122)])
        if withPath.regions.count == 1 && withPath.regions[0].isParagraphBlock {
            let pp = DesktopPlan(snapshot: snapshot(withPath.regions, t: target()))
            do { _ = try pp.rendered(translations: [pp.requests[0].id: "Open it"]); expect(false, "Dropped protected fragment must fail") }
            catch let e as DesktopPlanError { expect(e == .missing([withPath.regions[0].id]), "Dropped protected fragment is rejected: \(e)") } catch { expect(false, "error type") }
            let ok = try! pp.rendered(translations: [pp.requests[0].id: "Open /tmp/out.txt and read the report"])
            expect(ok[0].protectedFragments.contains("/tmp/out.txt"), "Protected fragment kept verbatim: \(ok[0].protectedFragments)")
        }
    }

    /// Terminal rows: a bullet and its indented wrapped continuation form one block; OCR boxes of adjacent rows that
    /// overlap by a point or two never collide.
    static func terminalBulletChecks() {
        let crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        let sel = rect(0, 0, 800, 600)
        var t = target()
        t.bundleID = "com.cmuxterm.app"
        func obs(_ text: String, x: CGFloat, w: CGFloat, y: CGFloat, h: CGFloat = 16) -> OCRObservation {
            OCRObservation(text: text, confidence: 0.9, normalizedBox: CoordinateMapper.localToVision(CGRect(x: x, y: y, width: w, height: h), crop: crop), words: [])
        }
        let bullet = "- 仍然处理不了的，比如被前一个整个包住、或者和受保护文字重叠，仍算 C。但现在会画橙"
        let wrap = "色标记，点开能看全文，以前什么都不画"
        let next = "- 两条译文不会叠在一起画"
        let grouped = OCRGrouper.grouped([obs(bullet, x: 20, w: 760, y: 100), obs(wrap, x: 36, w: 330, y: 116), obs(next, x: 20, w: 200, y: 132)],
                                         crop: crop, target: t, layout: [], unicode: true)
        expect(grouped.regions.count == 2 && grouped.regions[0].lineRects.count == 2 && grouped.regions[1].lineRects.count == 1,
               "Bullet + indented continuation is one block, next bullet is separate: \(grouped.regions.map(\.text))")
        let snap = snapshot(grouped.regions, t: t)
        let plan = DesktopPlan(snapshot: snap, unicode: true)
        expect(plan.requests.count == 2 && plan.requests[0].text == bullet.dropFirst(2) + " " + wrap, "Continuation joins the bullet request: \(plan.requests.map(\.text))")
        expect(plan.skipped.isEmpty, "Nothing skipped: \(plan.skipped)")
        let proseWithFile = "点击后保存当前信息，文件名是foo-bar-<时间>.json。取消保存时不会再出现。"
        let fileGrouped = OCRGrouper.grouped([obs(proseWithFile, x: 20, w: 700, y: 200), obs("$ ls -la", x: 20, w: 100, y: 260)],
                                             crop: crop, target: t, layout: [], unicode: true)
        expect(fileGrouped.regions.first?.kind == .log && fileGrouped.regions.last?.kind == .prompt,
               "CJK prose with an embedded file token is .log, never .code: \(fileGrouped.regions.map(\.kind))")

        // Adjacent CJK rows whose boxes overlap by 2pt: both translated, both painted, never over each other.
        let rowA = TextRegion(id: "a", parentID: "p", kind: .log, rect: rect(20, 100, 300, 16), text: "第一行中文说明", lineRects: [rect(20, 100, 300, 16)], readingOrder: 0)
        let rowB = TextRegion(id: "b", parentID: "p", kind: .log, rect: rect(20, 114, 300, 16), text: "第二行中文说明", lineRects: [rect(20, 114, 300, 16)], readingOrder: 1)
        let parent = LayoutRegion(id: "p", role: .content, rect: rect(0, 0, 800, 600))
        func tr(_ r: TextRegion, _ text: String) -> RegionTranslation {
            RegionTranslation(regionID: r.id, parentID: "p", kind: r.kind, readingOrder: r.readingOrder, original: r.text, text: text,
                              rects: r.lineRects, unionRect: r.rect, protectedFragments: [])
        }
        let overlapSnap = snapshot([rowA, rowB], layout: [parent], t: t)
        let items = OverlayItem.make(from: [tr(rowA, "First line"), tr(rowB, "Second line")], snapshot: overlapSnap, selection: sel)
        expect(items.count == 2 && items.allSatisfy(\.isPainted), "2pt-overlapping rows both paint: \(items.map(\.outcome))")
        expect(items[0].paintRects == [rowA.rect], "Upper row keeps its whole box")
        expect(items[1].paintRects.count == 1 && items[1].paintRects[0].minY >= rowA.rect.maxY - 0.001 && items[1].paintRects[0].width == rowB.rect.width
               && items[1].paintRects[0].maxY == rowB.rect.maxY, "Lower row is trimmed to the shared edge, full width: \(items[1].paintRects)")
        expect(items[1].paintRects.allSatisfy { $0.intersection(items[0].paintRects[0]).isNull || $0.intersection(items[0].paintRects[0]).isEmpty }, "No double paint")
        // A protected row that touches a translated row by 2pt does not turn it into C.
        let prompt = TextRegion(id: "c", parentID: "p", kind: .prompt, rect: rect(20, 128, 300, 16), text: "$ ls", lineRects: [rect(20, 128, 300, 16)], readingOrder: 2)
        let withPrompt = OverlayItem.make(from: [tr(rowA, "First line"), tr(rowB, "Second line")],
                                          snapshot: snapshot([rowA, rowB, prompt], layout: [parent], t: t), selection: sel)
        expect(withPrompt.allSatisfy(\.isPainted), "Edge contact with a protected row stays painted: \(withPrompt.map(\.outcome))")
        // A real (deep) overlap with a protected row is still a collision.
        let deep = TextRegion(id: "d", parentID: "p", kind: .prompt, rect: rect(20, 120, 300, 16), text: "$ ls", lineRects: [rect(20, 120, 300, 16)], readingOrder: 2)
        let collided = OverlayItem.make(from: [tr(rowB, "Second line")], snapshot: snapshot([rowB, deep], layout: [parent], t: t), selection: sel)
        expect(collided[0].outcome == .collisionUnavailable, "Deep overlap with a protected row remains C: \(collided.map(\.outcome))")
    }
}
