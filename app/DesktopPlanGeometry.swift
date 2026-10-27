import CoreGraphics
import Foundation

/// Single definition of the rectangles a translation occupies, shared by the overlay painter (`OverlayOccupancy`)
/// and the relevant-area content signature so they can never disagree. Exact selection (no validation tolerance),
/// window bounds and parent clipping; slivers of 1pt or less are dropped; output sorted top-to-bottom, left-to-right.
enum OccupiedGeometry {
    static func rects(source: [CGRect], parent: CGRect?, bounds: CGRect, selection: CGRect) -> [CGRect] {
        source.compactMap { sourceRect in
            var rect = sourceRect.intersection(bounds).intersection(selection)
            if let parent { rect = rect.intersection(parent) }
            guard !rect.isNull, !rect.isInfinite, rect.width > 1, rect.height > 1 else { return nil }
            return rect
        }.sorted { a, b in a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY }
    }
}

/// Proof of free space to the RIGHT of a source line, used only when a translation does not fit the exact source
/// lines. Pure geometry: the strip `[line.maxX, line.maxX + room] x [line.minY, line.maxY]` is bounded by the window,
/// the exact selection, the verified parent container, and the nearest recognized rectangle (ANY region: translatable,
/// protected or untranslated, and the region's own other lines) that shares rows with the line, minus a safety gap.
/// A rectangle that vertically overlaps the line (beyond float noise) and starts left of the strip's far end but is not
/// entirely left of the line forces room 0. The captured-pixel half of the proof (`FlatStrip`) is applied at capture.
enum FreeSpace {
    static let gap: CGFloat = 4
    static let verticalNoise: CGFloat = 0.01

    static func room(line: CGRect, obstacles: [CGRect], limitX: CGFloat) -> CGFloat {
        guard line.width > 0, line.height > 0, [line.minX, line.maxX, line.minY, line.maxY, limitX].allSatisfy({ $0.isFinite }) else { return 0 }
        var limit = limitX
        for r in obstacles {
            guard r.width > 0, r.height > 0, min(line.maxY, r.maxY + gap) - max(line.minY, r.minY - gap) > verticalNoise else { continue }
            if r.maxX <= line.maxX { continue }          // entirely at or left of the line's right edge: not to its right
            if r.minX < line.maxX { return 0 }           // straddles the line's right edge: nothing is proven
            limit = min(limit, r.minX - gap)
        }
        return max(0, limit - line.maxX)
    }

    /// Every recognized line rectangle of `regions`, except the exact `line` of region `ownerID`.
    static func obstacles(excluding line: CGRect, ownerID: String, regions: [TextRegion]) -> [CGRect] {
        regions.flatMap { region -> [CGRect] in
            let rects = region.paintSourceRects
            return (region.id == ownerID ? rects.filter { $0 != line } : rects) + region.extensionObstacles
        }
    }

    /// Window / selection / parent right edge for the extension.
    static func limitX(parent: CGRect?, bounds: CGRect, selection: CGRect) -> CGFloat {
        var limit = min(bounds.maxX, selection.maxX)
        if let parent { limit = min(limit, parent.maxX) }
        return limit
    }
    static func roomDown(line: CGRect, obstacles: [CGRect], limitY: CGFloat) -> CGFloat {
        let transposed = CGRect(x: line.minY, y: line.minX, width: line.height, height: line.width)
        return room(line: transposed, obstacles: obstacles.map {
            CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width)
        }, limitX: limitY)
    }

    static func limitY(parent: CGRect?, bounds: CGRect, selection: CGRect) -> CGFloat {
        min(bounds.maxY, selection.maxY, parent?.maxY ?? bounds.maxY)
    }
    /// Re-clamped at paint and signature time; down proof includes the full right-extended width.
    static func extended(line: CGRect, index: Int, owner: TextRegion, parent: CGRect?, bounds: CGRect,
                         selection: CGRect, regions: [TextRegion]) -> CGRect {
        let original = owner.paintSourceRects.indices.contains(index) ? owner.paintSourceRects[index] : line
        let obstacles = obstacles(excluding: original, ownerID: owner.id, regions: regions)
        let proofRight = owner.freeRight.indices.contains(index) ? owner.freeRight[index] : 0
        let right = proofRight.isFinite && proofRight > 0 ? min(proofRight, room(line: line, obstacles: obstacles, limitX: limitX(parent: parent, bounds: bounds, selection: selection))) : 0
        var result = CGRect(x: line.minX, y: line.minY, width: line.width + right, height: line.height)
        let proofDown = owner.freeDown.indices.contains(index) ? owner.freeDown[index] : 0
        let down = proofDown.isFinite && proofDown > 0 ? min(proofDown, roomDown(line: result, obstacles: obstacles, limitY: limitY(parent: parent, bounds: bounds, selection: selection))) : 0
        result.size.height += down
        return result
    }
}

/// Pixel half of the free-space proof, on the held ORIGINAL capture only (no recapture).
enum FlatStrip {
    static let tolerance = 12            // per 8-bit channel, against the region's own sampled background
    static let maxColumns = 4096

    /// Width (points) of the leading run of `strip` (window-local) whose every pixel lying FULLY inside the strip is
    /// within `tolerance` of `background`. 0 when nothing is proven (image/crop mismatch, empty, non-flat first column).
    static func width(image: CGImage, crop: CGRect, strip: CGRect, background: RegionBackgroundEvidence) -> CGFloat {
        scan(image: image, crop: crop, strip: strip, background: background, down: false)
    }

    static func height(image: CGImage, crop: CGRect, strip: CGRect, background: RegionBackgroundEvidence) -> CGFloat {
        scan(image: image, crop: crop, strip: strip, background: background, down: true)
    }

    private static func scan(image: CGImage, crop: CGRect, strip: CGRect, background: RegionBackgroundEvidence, down: Bool) -> CGFloat {
        guard crop.width > 0, crop.height > 0, strip.width > 0, strip.height > 0, image.width > 0, image.height > 0 else { return 0 }
        let sx = CGFloat(image.width) / crop.width, sy = CGFloat(image.height) / crop.height
        let relMinX = strip.minX - crop.minX
        let px0 = max(0, Int((relMinX * sx).rounded(.up)))
        var px1 = min(image.width, Int(((strip.maxX - crop.minX) * sx).rounded(.down)))
        let py0 = max(0, Int(((strip.minY - crop.minY) * sy).rounded(.up)))
        var py1 = min(image.height, Int(((strip.maxY - crop.minY) * sy).rounded(.down)))
        if down { py1 = min(py1, py0 + maxColumns) } else { px1 = min(px1, px0 + maxColumns) }
        guard px1 > px0, py1 > py0 else { return 0 }
        let w = px1 - px0, h = py1 - py0
        guard let part = image.cropping(to: CGRect(x: px0, y: py0, width: w, height: h)) else { return 0 }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            // Memory row 0 is the image's TOP row for an upright draw; no flip, or vertical scans read rows reversed.
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return 0 }
        let target = [background.red, background.green, background.blue].map { Int(($0 * 255).rounded()) }
        var flat = 0
        leading: for major in 0..<(down ? h : w) {
            for minor in 0..<(down ? w : h) {
                let x = down ? minor : major, y = down ? major : minor
                let i = (y * w + x) * 4
                for c in 0..<3 where abs(Int(rgba[i + c]) - target[c]) > tolerance { break leading }
            }
            flat += 1
        }
        guard flat > 0 else { return 0 }
        if down { return min(strip.height, CGFloat(py0 + flat) / sy - (strip.minY - crop.minY)) }
        return min(strip.width, (CGFloat(px0 + flat) / sx) - relMinX)
    }
}

extension FreeSpace {
    static let minimumUsefulRoom: CGFloat = 8

    /// Capture-time attachment of `TextRegion.freeRight` for every translatable region: geometric room (nearest
    /// recognized rectangle in the same rows, parent, selection, window) capped by the pixel-flat width measured on
    /// the held original. Protected regions and regions without sampled background get none.
    static func attach(to regions: inout [TextRegion], image: CGImage, crop: CGRect, bounds: CGRect, containers: [String: CGRect], omitted: [CGRect] = []) {
        let all = regions
        for index in regions.indices {
            let region = all[index]
            regions[index].freeRight = []; regions[index].freeDown = []
            regions[index].extensionObstacles = omitted
            guard region.kind.category != .protected, let background = region.background else { continue }
            let lines = region.paintSourceRects
            let parent = region.parentID.flatMap { containers[$0] }
            let limit = limitX(parent: parent, bounds: bounds, selection: crop)
            regions[index].freeRight = lines.map { line in
                guard let clipped = OccupiedGeometry.rects(source: [line], parent: parent, bounds: bounds, selection: crop).first else { return 0 }
                let room = Self.room(line: clipped, obstacles: obstacles(excluding: line, ownerID: region.id, regions: all) + omitted, limitX: limit)
                guard room >= minimumUsefulRoom else { return 0 }
                let strip = CGRect(x: clipped.maxX, y: clipped.minY, width: room, height: clipped.height)
                let flat = FlatStrip.width(image: image, crop: crop, strip: strip, background: background)
                return flat >= minimumUsefulRoom ? flat : 0
            }
            regions[index].freeDown = lines.enumerated().map { i, line in
                guard let clipped = OccupiedGeometry.rects(source: [line], parent: parent, bounds: bounds, selection: crop).first else { return 0 }
                let wide = CGRect(x: clipped.minX, y: clipped.minY, width: clipped.width + regions[index].freeRight[i], height: clipped.height)
                let room = roomDown(line: wide, obstacles: obstacles(excluding: line, ownerID: region.id, regions: all) + omitted,
                                    limitY: limitY(parent: parent, bounds: bounds, selection: crop))
                guard room >= minimumUsefulRoom else { return 0 }
                let strip = CGRect(x: wide.minX, y: wide.maxY, width: wide.width, height: room)
                let flat = FlatStrip.height(image: image, crop: crop, strip: strip, background: background)
                return flat >= minimumUsefulRoom ? flat : 0
            }
        }
    }
}
