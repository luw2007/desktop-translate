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
        freeSpaceChecks()
        overflowFallbackChecks()
        windowOrderingChecks()
        debugRegionChecks()
        terminalBulletChecks()
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
        let cycError = validation(snapshot([], layout: cyc))
        expect(cycError == .parentCycle("x") || cycError == .parentCycle("y"), "Parent cycle")
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
        let boxes = DebugRegions.boxes(snapshot: snap, plan: plan, items: items, marks: marks)
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
        expect(DebugRegions.boxes(snapshot: nil, plan: nil, items: [], marks: marks).count == 4, "Marks draw without a snapshot")
        expect(DebugRegions.boxes(snapshot: nil, plan: nil, items: [], marks: []).isEmpty, "Nothing recognized, nothing drawn")
        // Planned and presented-empty (no items yet): every translatable region is R, never silently omitted.
        let pending = DebugRegions.boxes(snapshot: snap, plan: plan, items: [], marks: [])
        expect(pending.filter { $0.code == .missing }.count == 8 && pending.count == 10, "Without items planned regions are R")
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
                                                plan: nil, items: collision, marks: [])
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
        let debug = DebugRegions.boxes(snapshot: plan.snap, plan: DesktopPlan(snapshot: plan.snap, unicode: true), items: plan.items, marks: [])
        expect(debug.first?.code == .cover && DebugCode.cover.rawValue == "V" && DebugCode.condensed.rawValue == "S", "Cover is debug V")
        let s = make(width: mid2)
        expect(DebugRegions.boxes(snapshot: s.snap, plan: DesktopPlan(snapshot: s.snap, unicode: true), items: s.items, marks: []).first?.code == .condensed,
               "Condensed/shrunk is debug S")

        // Truly impossible: a sliver window leaves no room for any cover either -> the orange marker remains.
        let cramped = make(width: wide, selection: rect(0, 0, 60, 26), window: CGSize(width: 60, height: 26))
        expect(cramped.items[0].outcome == .fitOverflow && cramped.items[0].cover.isEmpty && !cramped.items[0].text.isEmpty,
               "No room for a cover keeps fitOverflow with the text: \(cramped.items[0].outcome)")
    }

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
