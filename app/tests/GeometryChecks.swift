import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
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


}
