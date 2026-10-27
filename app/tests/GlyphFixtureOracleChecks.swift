// Offscreen, no-GUI source-backed fixture check.
// Compile GlyphSceneManifest.swift, GlyphSceneFixtureApp.swift, GlyphSceneFixtureDrawing.swift and
// GlyphSceneFixtureDelegate.swift as an @testable module,
// link this executable against it, and run only after Main's explicit source-ready gate.
import AppKit
import CoreText
@testable import FixtureOracle

@main
struct GlyphFixtureOracleChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    // Scan a fresh independently allocated bitmap of the ACTUAL drawToken output; the
    // fixture's alphaInkBounds must match this result rather than a scene/container guess.
    static func paintedInk(_ line: CTLine, at origin: CGPoint, size: CGSize, scale: CGFloat) -> CGRect? {
        let w = Int((size.width * scale).rounded(.up))
        let h = Int((size.height * scale).rounded(.up))
        var bytes = [UInt8](repeating: 255, count: w * h)
        return bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: scale, y: -scale)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            drawToken(line, at: origin, in: context)
            let pixels = raw.bindMemory(to: UInt8.self)
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                for x in 0..<w where 255 - Int(pixels[y * w + x]) >= 24 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard minX <= maxX, minY <= maxY else { return nil }
            return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                          width: CGFloat(maxX - minX + 1) / scale,
                          height: CGFloat(maxY - minY + 1) / scale)
        }
    }

    static func main() {
        let size = CGSize(width: 640, height: 400)
        var tokenCount = 0
        for scale: CGFloat in [1, 2] {
            for name in ["boundary", "collision", "icon", "code", "cjk", "prose"] {
                guard let scene = sceneSpecs(name, size: size) else { preconditionFailure("Missing scene: \(name)") }
                expect(!scene.specs.isEmpty, "Scene must contain painted tokens: \(name)")
                let ids = scene.specs.map(\.id)
                expect(Set(ids).count == ids.count, "One identity per drawn token: \(name)")
                for token in scene.specs {
                    for text in [token.text, token.alt].compactMap({ $0 }) {
                        let line = makeLine(text, font: token.font)
                        let measured = alphaInkBounds(line, at: token.origin, contentSize: size, scale: Double(scale))
                        let independent = paintedInk(line, at: token.origin, size: size, scale: scale)
                        expect(measured == independent, "Alpha oracle must enclose exactly drawn ink: \(token.id) \(scale)x")
                        guard let measured else {
                            expect(text.allSatisfy(\.isWhitespace), "Visible token has no actual ink: \(token.id) \(scale)x")
                            continue
                        }
                        let typed = glyphBounds(line, at: token.origin)
                        let record = GlyphToken(id: token.id, group: token.group, text: text,
                                                order: 0, line: token.line, container: GlyphRect(token.container),
                                                glyph: GlyphRect(typed), ink: GlyphRect(measured),
                                                mutates: token.alt != nil)
                        let errors = GlyphGeometry.edgeErrors(observed: typed, truth: measured)
                        expect(GlyphMatcher.oracleConsistent(record, scale: Double(scale)),
                               "Actual type and ink disagree: \(token.id) \(scale)x glyph=\(typed) ink=\(measured) edge=\(errors)")
                        tokenCount += 1
                    }
                }
            }
        }
        print("Glyph fixture offscreen ink checks passed (\(tokenCount) draws)")
    }
}
