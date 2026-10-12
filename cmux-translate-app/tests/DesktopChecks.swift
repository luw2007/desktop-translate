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
        segmentationChecks()
        planChecks()
        groupingChecks()
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

        let t = target(selection: CGRect(x: 5, y: 6, width: 7, height: 8))
        expect(t.effectiveSelection == CGRect(x: 5, y: 6, width: 7, height: 8), "Explicit selection verbatim")
        expect(target().effectiveSelection == CGRect(x: 0, y: 0, width: 800, height: 600), "Default selection is full window")
        expect(target().selectionKey == "t1|p1" && target(tab: nil, pane: nil).selectionKey == nil, "Selection key")
        var other = target(); other.appLaunchTime = 2000
        expect(!target().sameWindow(as: other), "PID reuse differs by launch time")
        expect(target().sameWindow(as: target(revision: 9)) && !target().sameContent(as: target(revision: 9)), "Revision is content identity")

        var ev = CapabilityEvidence(level: .verified, interface: "iterm-py", appVersion: "3.5", versionVerified: false)
        expect(ev.effectiveLevel == .partial, "Unverified version caps at partial")
        ev.versionVerified = true
        expect(ev.effectiveLevel == .verified, "Verified version")
        var caps = SnapshotCapabilities(visibleText: ev, textGeometry: ev, contentRevision: ev)
        expect(caps.isFullyNative, "Fully native")
        caps.textGeometry.level = .partial
        expect(!caps.isFullyNative, "Partial geometry not fully native")
    }

    // MARK: router

    static func routerChecks() {
        let good = snapshot([TextRegion(id: "a", kind: .label, rect: rect(0, 0), text: "OK")])
        let bad = snapshot([TextRegion(id: "a", kind: .label, rect: rect(900, 0), text: "OK")])
        expect(CaptureRouter.resolve([.unsupported("x"), .snapshot(good)]) == .snapshot(good), "First valid snapshot wins")
        expect(CaptureRouter.resolve([.partial(good, warnings: ["w"]), .snapshot(good)]) == .snapshot(good), "Full beats partial")
        expect(CaptureRouter.resolve([.partial(good, warnings: ["w"]), .error("e")]) == .partial(good, warnings: ["w"]), "Partial beats error")
        expect(CaptureRouter.resolve([.error("e"), .needsPermission(.screenRecording)]) == .needsPermission(.screenRecording), "Permission beats error")
        expect(CaptureRouter.resolve([.unsupported("u"), .error("e"), .none]) == .error("e"), "Error beats none")
        expect(CaptureRouter.resolve([.unsupported("u"), .none]) == .none, "None beats unsupported")
        expect(CaptureRouter.resolve([.unsupported("u"), .unsupported("v")]) == .unsupported("u"), "First unsupported reason")
        expect(CaptureRouter.resolve([]) == .unsupported("no provider"), "Empty provider list")
        if case .error = CaptureRouter.resolve([.snapshot(bad)]) {} else { expect(false, "Invalid snapshot becomes error") }
        expect(CaptureRouter.resolve([.snapshot(bad), .snapshot(good)]) == .snapshot(good), "Invalid skipped for later valid")
        if case .error = CaptureRouter.resolve([.snapshot(good)], currentRevision: 99) {} else { expect(false, "Stale snapshot becomes error") }
    }

    // MARK: selection memory

    static func selectionChecks() {
        let size = CGSize(width: 100, height: 100)
        expect(SelectionMemory.clamp(CGRect(x: -50, y: -50, width: 100, height: 100), to: size) == CGRect(x: 0, y: 0, width: 50, height: 50), "Clamp partially outside")
        expect(SelectionMemory.clamp(CGRect(x: 200, y: 0, width: 10, height: 10), to: size) == nil, "Clamp fully outside")
        expect(SelectionMemory.clamp(CGRect(x: 0, y: 0, width: 0.5, height: 10), to: size) == nil, "Sub-point sliver rejected")
        expect(SelectionMemory.clamp(CGRect(x: 10, y: 10, width: -5, height: -5), to: size) == CGRect(x: 5, y: 5, width: 5, height: 5) || SelectionMemory.clamp(CGRect(x: 10, y: 10, width: -5, height: -5), to: size) == nil,
               "Negative size handled")
        expect(SelectionMemory.clamp(CGRect(x: CGFloat.infinity, y: 0, width: 5, height: 5), to: size) == nil, "Non-finite rejected")

        var mem = SelectionMemory()
        let t = target()
        expect(mem.remember(CGRect(x: 80, y: 60, width: 160, height: 120), for: t) == CGRect(x: 80, y: 60, width: 160, height: 120), "Remember")
        var resized = t; resized.frame.size = CGSize(width: 1600, height: 1200)
        let scaled = mem.restore(for: resized) ?? .zero
        expect(abs(scaled.minX - 160) < 1e-6 && abs(scaled.minY - 120) < 1e-6 && abs(scaled.width - 320) < 1e-6 && abs(scaled.height - 240) < 1e-6, "Selection scales with resize: \(scaled)")
        var moved = t; moved.frame.origin = CGPoint(x: 5, y: 5)
        expect(mem.restore(for: moved) != nil, "Moving window keeps selection")
        expect(mem.restore(for: target(revision: 5)) != nil, "Content revision alone keeps selection")
        expect(mem.restore(for: target(pane: "p2")) == nil && mem.isEmpty, "Pane change invalidates and clears")
        mem.remember(CGRect(x: 0, y: 0, width: 10, height: 10), for: t)
        expect(mem.restore(for: target(tab: "t2")) == nil, "Tab change invalidates")
        mem.remember(CGRect(x: 0, y: 0, width: 10, height: 10), for: t)
        var relaunched = t; relaunched.appLaunchTime = 5
        expect(mem.restore(for: relaunched) == nil, "App relaunch invalidates")
        mem.remember(CGRect(x: 0, y: 0, width: 10, height: 10), for: t)
        var newWindow = t; newWindow.windowID = 8
        expect(mem.restore(for: newWindow) == nil, "Different window invalidates")
        mem.remember(CGRect(x: 0, y: 0, width: 10, height: 10), for: t)
        expect(mem.remember(CGRect(x: 900, y: 900, width: 5, height: 5), for: t) == nil && mem.isEmpty, "Invalid remember clears previous")
    }

    // MARK: operation machine

    static func operationChecks() {
        var op = OperationTracker()
        let a = op.begin()
        expect(op.state == .capturing && op.isActive && op.isCurrent(a), "Begin captures")
        expect(!op.advance(a, to: .idle), "Cannot jump capturing->idle")
        expect(op.advance(a, to: .translating) && op.advance(a, to: .presenting), "Forward path")
        expect(!op.advance(a, to: .translating), "No going backwards")
        let b = op.begin()
        expect(a != b && !op.isCurrent(a) && op.isCurrent(b), "New operation supersedes")
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

    // MARK: segmentation

    /// Translate every `.text` piece to "T" and report the result.
    static func ui(_ s: String) -> String {
        UITextSegmenter.segment(s).map { p -> String in
            switch p {
            case .literal(let t), .protected(let t): return t
            case .text: return "T"
            }
        }.joined()
    }

    static func segmentationChecks() {
        for s in ["Cancel", "Settings", "OK", "Save changes", "Don't save"] {
            expect(ui(s) == "T", "UI word translates: \(s) -> \(ui(s))")
        }
        expect(ui("  Cancel  ") == "  T  ", "Surrounding whitespace preserved")
        expect(ui("Open Settings...") == "T", "Trailing punctuation stays attached to its word: \(ui("Open Settings..."))")
        expect(ui("(Cancel)") == "T", "Wrapped word translates as one request")
        expect(ui("File: foo_bar.txt") == "T foo_bar.txt", "Underscore token protected: \(ui("File: foo_bar.txt"))")
        for s in ["https://example.com/a", "/usr/local/bin", "~/Library", "foo_bar", "fooBar", "getHTTPResponse", "abc123", "A1", "v2.0.1", "user@host.com", "--verbose", "-v", "C:\\Temp", "example.com", "#tag"] {
            expect(UITextSegmenter.segment(s) == [.protected(s)], "Protected token: \(s) -> \(UITextSegmenter.segment(s))")
        }
        expect(ui("Read README.md in docs/ now") == "T README.md T docs/ T" || ui("Read README.md in docs/ now") == "T README.md T docs/ now",
               "Mixed protected/words: \(ui("Read README.md in docs/ now"))")
        expect(UITextSegmenter.segment("Open fooBar now") == [.text("Open "), .protected("fooBar"), .literal(" "), .text("now")] ||
               UITextSegmenter.segment("Open fooBar now") == [.text("Open"), .literal(" "), .protected("fooBar"), .literal(" "), .text("now")],
               "Protected token splits request: \(UITextSegmenter.segment("Open fooBar now"))")
        expect(ui("42") == "42" && ui("12:30") == "12:30" && ui("50%") == "50%" && ui("") == "", "Numbers/empty stay literal")
        expect(ui("OK 3") == "T 3" || ui("OK 3") == "T3", "Trailing number kept")
        expect(ui("中文 Cancel") == "中文 T" || ui("中文 Cancel") == "T", "Non-ASCII text is not a request word: \(ui("中文 Cancel"))")
        expect(ui("中文") == "中文", "CJK-only is untouched")
        expect(ui("A") == "A", "Single letter is not translated")
        for s in ["Cancel", "a_b c", "Open fooBar now https://x.y/z 42 -- ok", "  \t", "tab\tsep", "emoji 🙂 Settings"] {
            let joined = UITextSegmenter.segment(s).map { p -> String in
                switch p { case .literal(let t), .protected(let t), .text(let t): return t }
            }.joined()
            expect(joined == s, "Segmentation reconstructs exactly: \(s)")
        }
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
        expect(reqs.count == 3, "Cancel, Settings and terminal prose only: \(reqs)")
        expect(Set(reqs.map { $0.id }).count == reqs.count, "Request ids unique")
        expect(reqs.map { $0.text } == ["Cancel", "Settings", "The build finished successfully today."], "Request texts: \(reqs.map { $0.text })")
        expect(reqs[0].id != reqs[1].id && reqs[0].id.hasPrefix("btn%2F1/"), "Region ids are namespaced and escaped: \(reqs[0].id)")
        expect(Set(plan.skipped.map { $0.regionID }) == ["p1", "u"], "Path and unknown skipped with reason")

        var tr: [String: String] = [:]
        for r in reqs { tr[r.id] = "译" + r.text.prefix(1) }
        let out = try! plan.rendered(translations: tr)
        expect(out.map { $0.regionID } == ["btn/1", "btn/2", "term"], "Output order follows reading order")
        expect(out[0].text == "译C" && out[1].text == "译S", "UI regions replaced")
        expect(out[2].text == "$ git status\n译T\n", "Terminal command line kept byte-exact: \(out[2].text.debugDescription)")
        expect(out[2].protectedFragments.contains("$ git status"), "Protected fragments reported")
        expect(out[0].unionRect == cancel.rect && out[0].rects == [cancel.rect], "Original geometry carried")

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
        // Same region id across namespaces cannot collide: "a/b" + "t0" vs "a" + "b/t0".
        expect(DesktopPlan.requestID(region: "a/b", piece: "t0") != DesktopPlan.requestID(region: "a", piece: "b/t0"), "Injective request ids")

        // Wrapped prose merges into ONE request; protected token survives.
        let prose = TextRegion(id: "para", kind: .prose, rect: CGRect(x: 0, y: 0, width: 300, height: 30),
                               text: "Please open /tmp/out.txt and\nreview the result carefully.",
                               lineRects: [rect(0, 0, 300, 14), rect(0, 16, 200, 14)])
        let pp = DesktopPlan(snapshot: snapshot([prose]))
        expect(pp.requests.count == 2, "Protected path splits prose into two requests: \(pp.requests)")
        expect(pp.requests.allSatisfy { !$0.text.contains("\n") }, "Soft line breaks removed from requests")
        let ppOut = try! pp.rendered(translations: Dictionary(uniqueKeysWithValues: pp.requests.map { ($0.id, "X") }))
        expect(ppOut[0].text.contains("/tmp/out.txt") && ppOut[0].rects.count == 2, "Path kept, per-line rects kept: \(ppOut[0].text)")
        expect(ppOut[0].unionRect == CGRect(x: 0, y: 0, width: 300, height: 30), "Union rect")

        let nothing = DesktopPlan(snapshot: snapshot([TextRegion(id: "n", kind: .label, rect: rect(0, 0), text: "12:30")]))
        expect(nothing.requests.isEmpty && nothing.skipped.count == 1, "Numeric label skipped")
        let dup = DesktopPlan(snapshot: snapshot([cancel, cancel]))
        expect(dup.requests.count == 1 && dup.skipped.count == 1, "Duplicate region ids cannot double-plan")
    }

    // MARK: grouping

    static func obs(_ text: String, _ r: CGRect, conf: Double = 0.9) -> OCRObservation {
        OCRObservation(text: text, confidence: conf, normalizedBox: r)
    }

    /// Observation positioned from window-local top-left coordinates in a crop covering the full 800x600 window.
    static func lineObs(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 14, conf: Double = 0.9) -> OCRObservation {
        let crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        return obs(text, CoordinateMapper.localToVision(CGRect(x: x, y: y, width: w, height: h), crop: crop), conf: conf)
    }

    static func groupingChecks() {
        let t = target()
        let crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        func group(_ o: [OCRObservation], layout: [LayoutRegion] = []) -> [TextRegion] {
            OCRGrouper.group(o, crop: crop, target: t, layout: layout)
        }
        // Soft-wrapped paragraph: full-width first line, aligned, tight spacing.
        let wrapped = group([
            lineObs("This is a long sentence that wraps across", x: 20, y: 100, w: 400),
            lineObs("several visual lines in a document", x: 20, y: 116, w: 390),
            lineObs("and ends here", x: 20, y: 132, w: 120),
        ])
        expect(wrapped.count == 1 && wrapped[0].kind == .prose && wrapped[0].lineRects.count == 3, "Wrapped lines form one region: \(wrapped.map { $0.text })")
        expect(wrapped[0].text.components(separatedBy: "\n").count == 3, "Line texts preserved")
        // Buttons side by side / stacked short labels never merge.
        let controls = group([
            lineObs("Cancel", x: 20, y: 500, w: 50),
            lineObs("Settings", x: 90, y: 500, w: 60),
            lineObs("Save", x: 20, y: 518, w: 30),
        ])
        expect(controls.count == 3 && controls.allSatisfy { $0.kind == .label }, "Controls stay separate: \(controls.map { $0.text })")
        // Sentence-final line breaks paragraph.
        let sentences = group([
            lineObs("This sentence is complete and long enough.", x: 20, y: 200, w: 400),
            lineObs("A second paragraph starts right below here", x: 20, y: 216, w: 400),
        ])
        expect(sentences.count == 2, "Sentence end splits paragraphs")
        // Large gap splits.
        let gap = group([
            lineObs("This line is long enough to count as prose", x: 20, y: 300, w: 400),
            lineObs("and this one is far below the previous one", x: 20, y: 360, w: 400),
        ])
        expect(gap.count == 2, "Vertical gap splits")
        // Never join across layout parents (e.g. sidebar vs content).
        let layout = [LayoutRegion(id: "left", role: .sidebar, rect: CGRect(x: 0, y: 0, width: 400, height: 600)),
                      LayoutRegion(id: "right", role: .content, rect: CGRect(x: 400, y: 0, width: 400, height: 600))]
        let across = group([
            lineObs("This text sits in the sidebar and goes", x: 100, y: 100, w: 295),
            lineObs("on across into the content column", x: 405, y: 116, w: 300),
        ], layout: layout)
        expect(across.count == 2 && Set(across.compactMap { $0.parentID }) == ["left", "right"], "No grouping across parents: \(across.map { ($0.text, $0.parentID as Any) })")
        // Filtering: low confidence, empty, NaN, outside window.
        let filtered = group([
            lineObs("noise", x: 20, y: 20, w: 40, conf: 0.1),
            lineObs("   ", x: 20, y: 40, w: 40),
            obs("nan", CGRect(x: CGFloat.nan, y: 0, width: 0.1, height: 0.1)),
            obs("zero", CGRect(x: 0.1, y: 0.1, width: 0, height: 0.1)),
            obs("outside", CGRect(x: 1.5, y: 0.1, width: 0.1, height: 0.1)),
            lineObs("Keep", x: 20, y: 60, w: 40),
        ])
        expect(filtered.map { $0.text } == ["Keep"], "Bad observations dropped: \(filtered.map { $0.text })")
        // Output always validates; ids unique; reading order top-down.
        let snap = CaptureSnapshot(target: t, provenance: .ocr, layout: layout, regions: across + wrapped.map { var r = $0; r.id = "w" + r.id; r.parentID = nil; return r })
        expect(validation(snap) == nil, "Grouped regions validate: \(String(describing: validation(snap)))")
        let order = group([lineObs("Bottom", x: 20, y: 400, w: 50), lineObs("Top", x: 20, y: 20, w: 30)])
        expect(order.map { $0.text } == ["Top", "Bottom"] && order.map { $0.readingOrder } == [0, 1], "Reading order top to bottom")
        // Non-uniform crop with negative origin.
        let sel = CGRect(x: 100, y: 50, width: 200, height: 100)
        let o = OCRObservation(text: "Hello world", confidence: 1, normalizedBox: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        let r = OCRGrouper.group([o], crop: sel, target: t)
        expect(r.count == 1 && r[0].rect == CGRect(x: 150, y: 75, width: 100, height: 25), "Crop-relative placement: \(r.map { $0.rect })")
    }
}
