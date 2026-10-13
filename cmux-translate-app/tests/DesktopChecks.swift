import CoreGraphics
import Foundation

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
        print("Desktop checks passed")
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
    }

}
