import CoreGraphics
import Foundation

// Pure, screen-free content signature of the RELEVANT source areas of a capture (the occupied original
// rectangles a translation can replace), not of the whole crop. Depends only on CoreGraphics/Foundation and
// `CoordinateMapper`, so an in-memory CGImage plus a rect set exercises exactly the production code.

enum SignatureError: Error, Equatable {
    /// No valid relevant area (empty, non-finite, outside the crop, or too many): never silently widened to the whole crop.
    case invalidAreas
    /// Image does not match the crop / area geometry, or the pixel layout cannot be hashed.
    case wrongSize
    /// Whole image is near-black (protected content).
    case black
}

struct PixelRect: Hashable, Comparable, Sendable {
    let x: Int, y: Int, width: Int, height: Int
    static func < (a: PixelRect, b: PixelRect) -> Bool {
        (a.y, a.x, a.height, a.width) < (b.y, b.x, b.height, b.width)
    }
}

/// Immutable, validated set of window-local rectangles (points) that define what content is relevant.
/// Each rectangle stays separate: no union, no gap fill, so pixels between lines are never part of the signature.
struct RelevantAreas: Equatable, Sendable {
    static let maxRects = 4096
    let crop: CGRect
    /// Clipped to `crop`, non-empty, de-duplicated, sorted (y, x, h, w).
    let rects: [CGRect]

    /// Fails closed (nil) when the crop is invalid, any rect is non-finite, nothing relevant remains after
    /// clipping to `crop`, or the bounded rect count would be exceeded.
    init?(rects input: [CGRect], crop: CGRect) {
        func finite(_ r: CGRect) -> Bool { [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy { $0.isFinite } }
        guard finite(crop), crop.width > 0, crop.height > 0 else { return nil }
        var clipped: [CGRect] = []
        for raw in input {
            guard finite(raw) else { return nil }
            let r = raw.standardized.intersection(crop)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            clipped.append(r)
        }
        var seen = Set<[CGFloat]>()
        clipped = clipped.filter { seen.insert([$0.minX, $0.minY, $0.width, $0.height]).inserted }
        clipped.sort { ($0.minY, $0.minX, $0.height, $0.width) < ($1.minY, $1.minX, $1.height, $1.width) }
        guard !clipped.isEmpty, clipped.count <= Self.maxRects else { return nil }
        self.crop = crop; self.rects = clipped
    }

    /// Outward-rounded, de-duplicated pixel rectangles inside an image of `size` pixels covering `crop`.
    func pixelRects(imageSize size: CGSize) throws -> [PixelRect] {
        var out = Set<PixelRect>()
        for r in rects {
            guard let p = CoordinateMapper.cropPixelRect(local: r.offsetBy(dx: -crop.minX, dy: -crop.minY),
                                                          windowSize: crop.size, imageSize: size) else { throw SignatureError.wrongSize }
            out.insert(PixelRect(x: Int(p.minX), y: Int(p.minY), width: Int(p.width), height: Int(p.height)))
        }
        return out.sorted()
    }
}

/// Signature of the relevant areas of one image: image pixel size, crop, the immutable area set (points and the
/// exact pixel rectangles), pixel format, and one 64-bit hash per rectangle over its full-resolution raw pixels.
/// Size is bounded by `RelevantAreas.maxRects` hashes; no pixels are kept. No tolerance: a one-pixel glyph change
/// inside a rectangle changes its hash; changes outside every rectangle (line gaps, other panes) do not.
/// A rendered text caret inside a relevant rectangle IS a change (no independent caret geometry exists).
struct RegionSignature: Equatable, Sendable {
    let width: Int
    let height: Int
    let crop: CGRect
    let areas: RelevantAreas
    let pixelRects: [PixelRect]
    let format: UInt32
    let hashes: [UInt64]
    func differs(from baseline: RegionSignature) -> Bool { self != baseline || hashes.isEmpty || hashes.count != pixelRects.count }
}

/// Two-consecutive-change policy shared by `TargetMonitor` and `DesktopCapture.verifyFreshness`.
/// The baseline is immutable: an unchanged sample resets the streak, a changed one extends it, and
/// `observe` returns true only once two consecutive samples differ.
struct FreshnessTracker: Sendable {
    let baseline: RegionSignature
    private(set) var changedSamples = 0
    init(baseline: RegionSignature) { self.baseline = baseline }
    mutating func observe(_ sample: RegionSignature) -> Bool {
        changedSamples = sample.differs(from: baseline) ? changedSamples + 1 : 0
        return changedSamples >= 2
    }
}

enum ContentSignature {
    private static let seed: UInt64 = 0xcbf29ce484222325
    private static let prime: UInt64 = 0x100000001b3
    private static let bandRows = 32

    /// Hash the relevant areas of `image` (which covers `crop`). Throws `.black` if the whole image is near-black.
    /// Callers sample with the baseline's own `areas`, so every monitor/presentation sample uses the same definition.
    static func sample(image: CGImage, crop: CGRect, areas: RelevantAreas) throws -> (signature: RegionSignature, translucent: Bool) {
        guard areas.crop == crop else { throw SignatureError.invalidAreas }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { throw SignatureError.wrongSize }
        let pixelRects = try areas.pixelRects(imageSize: CGSize(width: w, height: h))
        let scan = try scan(image, pixelRects: pixelRects)
        guard !scan.black else { throw SignatureError.black }
        return (RegionSignature(width: w, height: h, crop: crop, areas: areas, pixelRects: pixelRects, format: scan.mode, hashes: scan.hashes), scan.translucent)
    }

    /// Protected-content / transparency flags of the whole image, no hashing.
    static func inspect(_ image: CGImage) throws -> (black: Bool, translucent: Bool) {
        guard image.width > 0, image.height > 0 else { throw SignatureError.wrongSize }
        let s = try scan(image, pixelRects: [])
        return (s.black, s.translucent)
    }

    private static func scan(_ image: CGImage, pixelRects: [PixelRect]) throws -> (black: Bool, translucent: Bool, mode: UInt32, hashes: [UInt64]) {
        let w = image.width, h = image.height
        var hashes = [UInt64](repeating: seed, count: pixelRects.count)
        var black = true, translucent = false

        func flags(_ row: UnsafeRawPointer, hasAlpha: Bool) {
            for x in 0..<w {
                let px = row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
                if px & 0x00FCFCFC != 0 { black = false }
                if hasAlpha, px >> 24 < 250 { translucent = true }
            }
        }
        func hashRow(_ row: UnsafeRawPointer, rect i: Int, mask: UInt32) {
            let r = pixelRects[i]
            var hv = hashes[i]
            for x in r.x..<(r.x + r.width) {
                hv = (hv ^ UInt64(row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) & mask)) &* prime
            }
            hashes[i] = hv
        }

        let info = image.bitmapInfo
        let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let nativeLayout = image.bitsPerPixel == 32 && image.bitsPerComponent == 8
            && info.intersection(.byteOrderMask) == .byteOrder32Little
            && (alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst)
        var mode: UInt32 = 1
        if nativeLayout, let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * (h - 1) + w * 4 {
            // Hash the provider's own bytes in place: no second full-resolution image is allocated.
            mode = 0
            let hasAlpha = alpha != .noneSkipFirst
            let mask: UInt32 = hasAlpha ? 0xFFFFFFFF : 0x00FFFFFF
            for y in 0..<h { flags(UnsafeRawPointer(base) + y * image.bytesPerRow, hasAlpha: hasAlpha) }
            for (i, r) in pixelRects.enumerated() {
                for y in r.y..<(r.y + r.height) { hashRow(UnsafeRawPointer(base) + y * image.bytesPerRow, rect: i, mask: mask) }
            }
            mode |= info.rawValue << 1
        } else {
            // Unknown native layout: convert one fixed-height band at a time into the canonical layout
            // (memory bounded by width * bandRows * 4), never the whole image. Rect hashes accumulate row-major
            // across bands, identical to the in-place path.
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw SignatureError.wrongSize }
            let bandInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            var band = [UInt8](repeating: 0, count: w * 4 * bandRows)
            let ok = band.withUnsafeMutableBytes { bytes -> Bool in
                guard let base = bytes.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: bandRows, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: bandInfo) else { return false }
                ctx.interpolationQuality = .none
                var y0 = 0
                while y0 < h {
                    let n = min(bandRows, h - y0)
                    ctx.clear(CGRect(x: 0, y: 0, width: w, height: bandRows))
                    ctx.draw(image, in: CGRect(x: 0, y: bandRows + y0 - h, width: w, height: h))
                    for r in 0..<n { flags(UnsafeRawPointer(base) + r * w * 4, hasAlpha: true) }
                    for (i, rect) in pixelRects.enumerated() where rect.y < y0 + n && rect.y + rect.height > y0 {
                        for y in max(rect.y, y0)..<min(rect.y + rect.height, y0 + n) {
                            hashRow(UnsafeRawPointer(base) + (y - y0) * w * 4, rect: i, mask: 0xFFFFFFFF)
                        }
                    }
                    y0 += n
                }
                return true
            }
            guard ok else { throw SignatureError.wrongSize }
        }
        return (black, translucent, mode, hashes)
    }
}
