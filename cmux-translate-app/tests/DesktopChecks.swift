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
        windowOrderingChecks()
        print("Desktop checks passed")
    }

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
    // MARK: transforms

    static func transforms() {
        // Vision bottom-left normalized -> window-local top-left, negative origin, non-uniform crop.
        let crop = CGRect(x: -20, y: 10, width: 200, height: 100)
        let r = CoordinateMapper.visionToLocal(CGRect(x: 0.5, y: 0.75, width: 0.25, height: 0.25), crop: crop)
        expect(r == CGRect(x: 80, y: 10, width: 50, height: 25), "Vision top-right quarter maps to top of crop: \(r)")
        let back = CoordinateMapper.localToVision(r, crop: crop)
        expect(back == CGRect(x: 0.5, y: 0.75, width: 0.25, height: 0.25), "Vision round trip")
        let bottom = CoordinateMapper.visionToLocal(CGRect(x: 0, y: 0, width: 1, height: 0.1), crop: crop)
        expect(abs(bottom.maxY - crop.maxY) < 1e-9 && bottom.minX == crop.minX, "Vision bottom edge is crop bottom")

        // Pixel crop: different x/y scale, outward rounding, clamping, empty.
        let px = CoordinateMapper.cropPixelRect(local: CGRect(x: 10.2, y: 5.5, width: 20, height: 10),
                                                windowSize: CGSize(width: 100, height: 50), imageSize: CGSize(width: 300, height: 50))
        expect(px == CGRect(x: 30, y: 5, width: 91 - 30 + 0, height: 11) || px == CGRect(x: 30, y: 5, width: 91 - 30, height: 11),
               "Non-uniform pixel crop rounds outward: \(String(describing: px))")
        let clamped = CoordinateMapper.cropPixelRect(local: CGRect(x: -10, y: -10, width: 500, height: 500),
                                                     windowSize: CGSize(width: 100, height: 50), imageSize: CGSize(width: 200, height: 100))
        expect(clamped == CGRect(x: 0, y: 0, width: 200, height: 100), "Pixel crop clamps to image")
        expect(CoordinateMapper.cropPixelRect(local: CGRect(x: 200, y: 0, width: 10, height: 10),
                                              windowSize: CGSize(width: 100, height: 50), imageSize: CGSize(width: 200, height: 100)) == nil,
               "Crop fully outside window is nil")
        expect(CoordinateMapper.cropPixelRect(local: .zero, windowSize: CGSize(width: 1, height: 1), imageSize: CGSize(width: 1, height: 1)) == nil,
               "Empty crop is nil")

        // Global (CG) <-> AppKit with negative origin (display left of / below primary).
        let g = CGRect(x: -1200, y: 900, width: 300, height: 200)
        let ak = CoordinateMapper.globalToAppKit(g, primaryHeight: 1000)
        expect(ak == CGRect(x: -1200, y: -100, width: 300, height: 200), "CG to AppKit negative y: \(ak)")
        expect(CoordinateMapper.appKitToGlobal(ak, primaryHeight: 1000) == g, "AppKit round trip")
        let local = CoordinateMapper.globalToLocal(g, windowOrigin: CGPoint(x: -1200, y: 30))
        expect(local == CGRect(x: 0, y: 870, width: 300, height: 200), "Global to local")
        expect(CoordinateMapper.localToGlobal(local, windowOrigin: CGPoint(x: -1200, y: 30)) == g, "Local to global")

        let prov = TransformProvenance(crop: CGRect(x: 0, y: 0, width: 100, height: 50), imagePixelSize: CGSize(width: 300, height: 100), windowOrigin: .zero)
        expect(prov.scaleX == 3 && prov.scaleY == 2, "Per-axis scale")
        expect(prov.imageSizeMatches(expectedPixels: CGSize(width: 300.8, height: 99.2)), "Within 1px accepted")
        expect(!prov.imageSizeMatches(expectedPixels: CGSize(width: 302, height: 100)), "Over 1px rejected")
    }

    // MARK: validation

    static func validationChecks() {
        let pane = LayoutRegion(id: "pane", role: .pane, rect: CGRect(x: 0, y: 0, width: 400, height: 300))
        let ok = TextRegion(id: "a", parentID: "pane", kind: .label, rect: rect(10, 10), text: "Cancel")
        expect(validation(snapshot([ok], layout: [pane])) == nil, "Valid snapshot")
        let free = TextRegion(id: "f", kind: .label, rect: rect(10, 10), text: "Cancel")
        expect(validation(snapshot([free]), rev: 1) == nil && validation(snapshot([free]), rev: 2) == .stale, "Stale revision rejected")
        expect(validation(snapshot([TextRegion(id: "", kind: .label, rect: rect(0, 0), text: "x")])) == .emptyID, "Empty id")
        expect(validation(snapshot([ok, ok], layout: [pane])) == .duplicateID("a"), "Duplicate id")
        expect(validation(snapshot([TextRegion(id: "pane", kind: .label, rect: rect(0, 0), text: "x")], layout: [pane])) == .duplicateID("pane"),
               "Region id colliding with layout id")
        expect(validation(snapshot([TextRegion(id: "b", parentID: "nope", kind: .label, rect: rect(0, 0), text: "x")])) == .missingParent(id: "b", parent: "nope"),
               "Missing parent")
        let cyc = [LayoutRegion(id: "x", parentID: "y", rect: rect(0, 0)), LayoutRegion(id: "y", parentID: "x", rect: rect(0, 0))]
        expect(validation(snapshot([], layout: cyc)) == .parentCycle("x") || validation(snapshot([], layout: cyc)) == .parentCycle("y"), "Parent cycle")
        expect(validation(snapshot([TextRegion(id: "o", kind: .label, rect: rect(790, 10), text: "x")])) == .outOfBounds(id: "o"), "Outside window")
        expect(validation(snapshot([TextRegion(id: "o", kind: .label, rect: rect(-0.5, 10), text: "x")])) == nil, "1pt tolerance")
        expect(validation(snapshot([TextRegion(id: "n", kind: .label, rect: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), text: "x")])) == .invalidRect(id: "n"), "NaN rect")
        expect(validation(snapshot([TextRegion(id: "c", kind: .label, rect: rect(0, 0), text: "x", confidence: 1.5)])) == .invalidConfidence(id: "c"), "Confidence range")
        let child = TextRegion(id: "in", parentID: "pane", kind: .label, rect: rect(390, 10), text: "x")
        expect(validation(snapshot([child], layout: [pane])) == .outOfBounds(id: "in"), "Text must stay inside parent")
        let line = TextRegion(id: "ln", kind: .prose, rect: CGRect(x: 0, y: 0, width: 50, height: 20), text: "a\nb",
                              lineRects: [CGRect(x: 0, y: 0, width: 60, height: 10)])
        expect(validation(snapshot([line])) == .outOfBounds(id: "ln"), "Line rect inside region rect")
        let long = TextRegion(id: "L", kind: .prose, rect: rect(0, 0), text: String(repeating: "a", count: SnapshotLimits.maxCharactersPerRegion + 1))
        expect(validation(snapshot([long])) == .regionTooLong(id: "L"), "Per-region limit")
        let many = (0...SnapshotLimits.maxRegions).map { TextRegion(id: "r\($0)", kind: .label, rect: rect(0, 0), text: "x") }
        expect(validation(snapshot(many)) == .tooManyRegions(many.count), "Region count limit")
        let tot = (0..<11).map { TextRegion(id: "t\($0)", kind: .prose, rect: rect(0, 0), text: String(repeating: "a", count: 19_000)) }
        expect(validation(snapshot(tot)) == .totalTooLong, "Total limit")
        expect(validation(snapshot([], t: target(w: 0, h: 10))) == .invalidBounds, "Zero-size window")

    }


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
            expect(DesktopPlan(snapshot: snapshot([ui])).requests.isEmpty, "English planner unchanged for \(word)")
        }
        let jaProse = TextRegion(id: "ja", kind: .prose, rect: rect(0, 0, 300, 14), text: "これは日本語の文章です。")
        expect(DesktopPlan(snapshot: snapshot([jaProse]), unicode: true).requests.count == 1, "Unicode prose request")
    }

    static func routerChecks() {
        expect(CaptureRouter.resolve([.error("e"), .needsPermission(.screenRecording)]) == .needsPermission(.screenRecording), "Permission beats error")
        expect(CaptureRouter.resolve([.unsupported("u"), .error("e"), .none]) == .error("e"), "Error beats none")
    }

    static func selectionChecks() {
        var mem = SelectionMemory()
        let t = target()
        let selected = CGRect(x: 80, y: 60, width: 160, height: 120)
        expect(mem.remember(selected, for: t) == selected, "Remember")
        var moved = t; moved.frame.origin = CGPoint(x: 5, y: 5)
        expect(mem.restore(for: moved) == selected, "Moving window keeps exact window-local selection")
        expect(mem.restore(for: target(revision: 5)) == selected, "Content revision alone keeps selection")
        var wider = t; wider.frame.size.width += 1
        expect(mem.restore(for: wider) == nil && mem.isEmpty && mem.window == nil, "Width change invalidates and clears")
        expect(mem.restore(for: t) == nil, "Returning to original size does not revive selection")
        mem.remember(selected, for: t)
        var taller = t; taller.frame.size.height += 1
        expect(mem.restore(for: taller) == nil && mem.isEmpty && mem.window == nil, "Height change invalidates and clears")
        mem.remember(selected, for: t)
        expect(mem.restore(for: target(pane: "p2")) == nil && mem.isEmpty, "Pane change invalidates and clears")
        mem.remember(selected, for: t)
        expect(mem.restore(for: target(tab: "t2")) == nil && mem.isEmpty, "Tab change invalidates and clears")
        mem.remember(selected, for: t)
        var relaunched = t; relaunched.appLaunchTime = 5
        expect(mem.restore(for: relaunched) == nil && mem.isEmpty, "App relaunch invalidates and clears")
        mem.remember(selected, for: t)
        var newWindow = t; newWindow.windowID = 8
        expect(mem.restore(for: newWindow) == nil && mem.isEmpty, "Different window invalidates and clears")
        mem.remember(selected, for: t)
        var newProcess = t; newProcess.pid += 1
        expect(mem.restore(for: newProcess) == nil && mem.isEmpty, "Different process invalidates and clears")
        mem.remember(selected, for: t)
        var newApp = t; newApp.bundleID = "other.app"
        expect(mem.restore(for: newApp) == nil && mem.isEmpty, "Different bundle invalidates and clears")
        mem.remember(selected, for: t)
        expect(mem.remember(CGRect(x: 900, y: 900, width: 5, height: 5), for: t) == nil && mem.isEmpty, "Invalid remember clears previous")
    }

    static func operationChecks() {
        var op = OperationTracker()
        let a = op.begin()
        expect(op.state == .capturing && op.isActive && op.isCurrent(a), "Begin captures")
        expect(!op.advance(a, to: .idle), "Cannot jump capturing->idle")
        expect(op.advance(a, to: .translating) && op.advance(a, to: .presenting), "Forward path")
        expect(!op.advance(a, to: .translating), "No going backwards")
        let b = op.begin()
        expect(!op.isCurrent(a) && op.isCurrent(b), "New operation supersedes")
        expect(!op.advance(a, to: .presenting), "Stale token cannot advance")
        expect(op.state == .capturing, "Stale token left state untouched")
        op.cancelActive()
        expect(op.state == .cancelled && !op.isActive && !op.isCurrent(b), "Cancel invalidates token")
        expect(!op.advance(b, to: .translating), "Late result after cancel ignored")
        let c = op.begin()
        expect(op.advance(c, to: .failed) && op.advance(c, to: .idle) && op.current == nil, "Failed -> idle")
        var idle = OperationTracker()
        idle.cancelActive()
        expect(idle.state == .idle, "Cancel when idle is a no-op")
    }

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
        expect(group([first, second], layout: []).regions.count == 2, "No container evidence keeps independent lines")
        let shortFirst = obs([("Please", 20, 50), ("review", 75, 50), ("this", 130, 30), ("soon", 165, 40)], y: 100)
        expect(group([shortFirst, second]).regions.count == 2, "Four words on a short line is not fullness evidence")
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

    // MARK: relevant-area content signature (in-memory images, no screen)

    /// BGRA 8-bit image of w x h pixels, mid-grey background, with optional single-pixel overrides.
    static func image(_ w: Int, _ h: Int, set: [(Int, Int, UInt8)] = []) -> CGImage {
        var bytes = [UInt8](repeating: 0x80, count: w * h * 4)
        for (x, y, v) in set { let i = (y * w + x) * 4; bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255 }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func signatureChecks() {
        let crop = CGRect(x: 0, y: 0, width: 200, height: 100)   // 1 px per point
        let lines = [CGRect(x: 10, y: 10, width: 100, height: 14), CGRect(x: 10, y: 40, width: 100, height: 14)]
        guard let areas = RelevantAreas(rects: lines, crop: crop) else { expect(false, "valid areas"); return }
        func sig(_ img: CGImage) -> RegionSignature { try! ContentSignature.sample(image: img, crop: crop, areas: areas).signature }
        let base = sig(image(200, 100))
        expect(base.hashes.count == 2 && base.pixelRects.count == 2, "One bounded hash per relevant rectangle")

        // Inside a line: one-pixel glyph change differs; invalidates only after two consecutive samples.
        let inside = sig(image(200, 100, set: [(50, 15, 0xFF)]))
        expect(inside.differs(from: base), "One-pixel change inside a line differs")
        var tracker = FreshnessTracker(baseline: base)
        expect(!tracker.observe(inside) && tracker.observe(inside), "Two consecutive inside changes invalidate")
        var transient = FreshnessTracker(baseline: base)
        expect(!transient.observe(inside) && !transient.observe(base) && !transient.observe(inside), "Unchanged sample resets the streak; baseline never moves")

        // Outside every rectangle: line gap, below, right of the lines -> no change.
        for p in [(50, 30), (150, 15), (5, 15), (50, 80), (10, 9), (110, 15)] {
            expect(!sig(image(200, 100, set: [(p.0, p.1, 0xFF)])).differs(from: base), "Change outside relevant areas ignored at \(p)")
        }
        // Edge pixels inside the rectangle (first and last) are covered.
        expect(sig(image(200, 100, set: [(10, 10, 0xFF)])).differs(from: base), "First pixel covered")
        expect(sig(image(200, 100, set: [(109, 23, 0xFF)])).differs(from: base), "Last pixel covered")

        // Relocation of the area set, a different crop or a different image size is not equal.
        let moved = RelevantAreas(rects: lines.map { $0.offsetBy(dx: 1, dy: 0) }, crop: crop)!
        expect((try! ContentSignature.sample(image: image(200, 100), crop: crop, areas: moved).signature).differs(from: base), "Moved area set differs")
        let other = RelevantAreas(rects: lines, crop: CGRect(x: 0, y: 0, width: 400, height: 200))!
        expect((try! ContentSignature.sample(image: image(400, 200), crop: other.crop, areas: other).signature).differs(from: base), "Different crop/size differs")
        // Refusal diagnostics disclose counts and set overlap, never the changed pixels or hash values.
        var trace = FreshnessTrace(baseline: base)
        trace.record(inside)
        trace.record(inside)
        let stable = trace.summary(elapsedMilliseconds: 42)
        expect(stable == "内容变化诊断：区域总数 2；第1次不一致区域数 1；第2次不一致区域数 1；两次不一致区域集合相同 是；距基线 42 ms",
               "Two identical changed-area sets expose counts only")
        trace.record(sig(image(200, 100, set: [(50, 45, 0xFF)])))
        expect(trace.summary(elapsedMilliseconds: 50).contains("两次不一致区域集合相同 否"),
               "Different relevant areas do not appear identical in trace")
        trace.record(try! ContentSignature.sample(image: image(200, 100), crop: crop, areas: moved).signature)
        expect(trace.summary(elapsedMilliseconds: 51).contains("第2次不一致区域数 结构不一致"),
               "Structural mismatch is not misreported as an area count")

        // Fail closed: nothing valid, non-finite, outside crop; mismatched crop is rejected by the sampler.
        expect(RelevantAreas(rects: [], crop: crop) == nil, "No rects -> no areas")
        expect(RelevantAreas(rects: [CGRect(x: 300, y: 300, width: 10, height: 10)], crop: crop) == nil, "Rect outside crop -> no areas")
        expect(RelevantAreas(rects: [CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)], crop: crop) == nil, "Non-finite rect -> no areas")
        expect(RelevantAreas(rects: lines, crop: .zero) == nil, "Empty crop -> no areas")
        do { _ = try ContentSignature.sample(image: image(200, 100), crop: CGRect(x: 1, y: 0, width: 200, height: 100), areas: areas); expect(false, "crop mismatch must throw") }
        catch { expect((error as? SignatureError) == .invalidAreas, "crop mismatch rejected") }
        // Entirely near-black image is protected content and is rejected.
        let blackProvider = CGDataProvider(data: Data(count: 200 * 100 * 4) as CFData)!
        let blackInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        let black = CGImage(width: 200, height: 100, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: blackInfo), provider: blackProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        do { _ = try ContentSignature.sample(image: black, crop: crop, areas: areas); expect(false, "black must throw") }
        catch { expect((error as? SignatureError) == .black, "black image rejected") }

        // Plan geometry: the replaced rectangles are the per-line occupied rects, no union / gap fill, clipped to parent and selection.
        let parent = LayoutRegion(id: "p", role: .content, rect: CGRect(x: 0, y: 0, width: 300, height: 200))
        let region = TextRegion(id: "r", parentID: "p", kind: .prose, rect: CGRect(x: 10, y: 10, width: 100, height: 44),
                                text: "Hello there world friend\nthis is another line", lineRects: lines)
        let snap = snapshot([region], layout: [parent], t: target(w: 300, h: 200))
        let plan = DesktopPlan(snapshot: snap)
        let replaced = plan.replacedSourceRects(snapshot: snap, selection: CGRect(x: 0, y: 0, width: 300, height: 200))
        expect(replaced == lines, "Replaced rects are the measured line rects: \(replaced)")
        let gapPixel = RelevantAreas(rects: replaced, crop: CGRect(x: 0, y: 0, width: 300, height: 200))!
        expect(!gapPixel.rects.contains { $0.contains(CGPoint(x: 50, y: 30)) }, "Line gap is not a relevant area")
    }

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
        expect(painted.count == 1 && !painted[0].overflow, "Short translation fits measured source lines")
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
               && collision[0].occupancyUnavailable && collision[0].paintRects.isEmpty,
               "An overlapping untranslated neighbour prevents both body painting and source mask")

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
        expect(tiny.count == 1 && tiny[0].outcome == .fitOverflow && tiny[0].paintRects.isEmpty
               && tiny[0].fontSize == OverlayItem.minimumFontSize && !tiny[0].text.isEmpty,
               "Physically impossible fit is reported as fit overflow, not painted below 12pt")

        // Selection removes every source rectangle: the translation is kept and reported as no occupancy.
        let none = OverlayItem.make(from: [tightTranslation], snapshot: tightSnap, selection: rect(150, 40, 20, 10))
        expect(none.count == 1 && none[0].outcome == .noOccupancy && none[0].occupied.isEmpty
               && none[0].paintRects.isEmpty && none[0].occupancyUnavailable && !none[0].text.isEmpty,
               "No exact occupancy keeps the full translation without painting")
        let counts = OverlayItem.counts(tight + tiny + none + collision)
        expect(counts == OverlayItem.Counts(painted: 1, fitOverflow: 1, collisionUnavailable: 1, noOccupancy: 1) && counts.total == 4,
               "Outcome counts partition the presented items")
    }

}
