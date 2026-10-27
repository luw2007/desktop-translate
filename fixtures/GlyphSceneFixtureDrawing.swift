// Drawing half of the standalone GLYPH-SCENE fixture (see GlyphSceneFixtureApp.swift).
//
// The alpha oracle and the real view must render the identical CTLine through the identical drawToken path;
// keeping both here makes that sharing structural rather than conventional. Token geometry lives in
// GlyphSceneFixtureApp.swift (TokenSpec, sceneSpecs); the window/delegate lives in GlyphSceneFixtureDelegate.swift.
//
// Built by fixtures/build-glyph-fixture.sh. No image, pixel or text hash ever leaves memory.
import AppKit
import CoreText

/// Pure token drawing shared by the real view and the alpha oracle so both render the identical CTLine.
func makeLine(_ text: String, font: NSFont) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
}

/// Draw one token into a top-left-origin (flipped) context at baseline `origin`.
func drawToken(_ line: CTLine, at origin: CGPoint, in ctx: CGContext) {
    ctx.saveGState()
    ctx.setShouldAntialias(true)
    ctx.setShouldSmoothFonts(false)
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// Typographic glyph path bounds in flipped view coordinates.
func glyphBounds(_ line: CTLine, at origin: CGPoint) -> CGRect {
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    return CGRect(x: origin.x + b.minX, y: origin.y - b.maxY, width: b.width, height: b.height)
}

/// Alpha oracle: renders ONLY this token into a fresh alpha-only bitmap sized to the content area at `scale`
/// and returns the tight ink bounds (alpha >= threshold) in content points, or nil if nothing was painted.
func alphaInkBounds(_ line: CTLine, at origin: CGPoint, contentSize: CGSize, scale: Double, threshold: UInt8 = 24) -> CGRect? {
    let pw = Int((contentSize.width * scale).rounded(.up)), ph = Int((contentSize.height * scale).rounded(.up))
    guard pw > 0, ph > 0 else { return nil }
    var data = [UInt8](repeating: 255, count: pw * ph)   // gray bitmap, white background; ink = darkness
    let (minX, minY, maxX, maxY): (Int, Int, Int, Int) = data.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return (1, 1, 0, 0) }
        // Bitmap rows run bottom-up in CG; flip so that point (0,0) is the top-left like the view.
        ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        // Antialiasing and font smoothing are configured by the shared drawToken path.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        drawToken(line, at: origin, in: ctx)
        var x0 = pw, y0 = ph, x1 = -1, y1 = -1
        let p = raw.bindMemory(to: UInt8.self)
        for row in 0..<ph {
            // Memory row 0 is the TOP row of the image for a CGBitmapContext (y flipped by the CTM already applied).
            for col in 0..<pw where 255 - p[row * pw + col] >= threshold {
                if col < x0 { x0 = col }; if col > x1 { x1 = col }
                if row < y0 { y0 = row }; if row > y1 { y1 = row }
            }
        }
        return (x0, y0, x1, y1)
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let s = CGFloat(scale)
    return CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s, width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
}

final class GlyphView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var specs: [TokenSpec] = []
    var texts: [String: String] = [:]
    var lines: [String: CTLine] = [:]
    var inkBounds: [CGRect] = []
    var decorations: [CGRect] = []
    var caret: CGRect?
    var counts = GlyphObserverCounts()
    var onChange: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill(); bounds.fill()
        ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
        for r in decorations { ctx.fill(r) }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for t in specs {
            if let line = lines[t.id] { drawToken(line, at: t.origin, in: ctx) }
        }
        if let c = caret { ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(c) }
    }
    private func zone(_ e: NSEvent) -> String {
        let p = convert(e.locationInWindow, from: nil)
        return inkBounds.contains { $0.contains(p) } ? "covered" : "uncovered"
    }
    private func bump(_ e: NSEvent, type: String) { counts.zones["\(type).\(zone(e))", default: 0] += 1 }
    override func mouseDown(with event: NSEvent) { counts.mouseDown += 1; bump(event, type: "mouseDown"); onChange?() }
    override func scrollWheel(with event: NSEvent) { counts.scroll += 1; bump(event, type: "scroll"); onChange?() }
    // Only the event TYPE is counted: no characters, no key codes.
    override func keyDown(with event: NSEvent) { counts.keyDown += 1; counts.zones["keyDown.keyboard", default: 0] += 1; onChange?() }
}
