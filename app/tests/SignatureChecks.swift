import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
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
}
