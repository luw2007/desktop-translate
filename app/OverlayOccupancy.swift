import AppKit

/// Painting uses exact selection boundaries, independently of coordinate-validation tolerance.
/// Only measured text occupancy is known here; this does not establish icon/nontext avoidance.
enum OverlayOccupancy {
    static func rects(source: [CGRect], parent: CGRect?, bounds: CGRect, selection: CGRect) -> [CGRect] {
        OccupiedGeometry.rects(source: source, parent: parent, bounds: bounds, selection: selection)
    }

    /// Edge contact is not overlap. Duplicate/missing identities cannot safely identify self. `ignoring` names OTHER
    /// regions whose source rectangles may be overlapped (lower-priority translated items that clip themselves around
    /// this one); their extension obstacles still count.
    static func collides(occupied: [CGRect], regionID: String, regions: [TextRegion], ignoring: Set<String> = []) -> Bool {
        guard regions.reduce(0, { $0 + ($1.id == regionID ? 1 : 0) }) == 1 else { return true }
        return regions.contains { region in
            let source = (region.id == regionID || ignoring.contains(region.id)) ? [] : region.paintSourceRects
            let measured = source + region.extensionObstacles
            return occupied.contains { paint in
                measured.contains { source in
                    let overlap = paint.intersection(source)
                    return !overlap.isNull && overlap.width > 0 && overlap.height > 0
                }
            }
        }
    }

    /// Smallest piece worth painting text into after removing a higher-priority neighbour's source rectangle.
    static let minimumClippedSide: CGFloat = 6

    /// OCR boxes of adjacent terminal rows overlap by a point or two. A vertical overlap up to this size (and at most
    /// 30% of the row) is a shared edge, not a collision: the row is trimmed to the neighbour's edge, keeping full width.
    static let sliverOverlap: CGFloat = 4

    /// Edge trim for a sliver overlap: `rect` without the overlapping strip at its top or bottom, nil when the overlap
    /// is not a sliver (or would leave less than `minimumClippedSide`).
    static func trimmedToEdge(_ rect: CGRect, cut: CGRect) -> CGRect? {
        let overlap = rect.intersection(cut)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0,
              overlap.height <= sliverOverlap, overlap.height <= 0.3 * rect.height else { return nil }
        let trimmed: CGRect
        if overlap.minY <= rect.minY + 0.001 {
            trimmed = CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY)
        } else if overlap.maxY >= rect.maxY - 0.001 {
            trimmed = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY)
        } else {
            return nil
        }
        return trimmed.width >= minimumClippedSide && trimmed.height >= minimumClippedSide ? trimmed : nil
    }

    /// `rect` without `cut`: the whole rectangle when they do not overlap; a sliver overlap along the top/bottom edge
    /// trims only that strip; otherwise the largest remaining side piece (left/right/top/bottom of the cut) when it is
    /// at least `minimumClippedSide` in both directions, else nil.
    static func subtract(_ rect: CGRect, cut: CGRect) -> CGRect? {
        let overlap = rect.intersection(cut)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return rect }
        if let trimmed = trimmedToEdge(rect, cut: cut) { return trimmed }
        let pieces = [
            CGRect(x: rect.minX, y: rect.minY, width: overlap.minX - rect.minX, height: rect.height),
            CGRect(x: overlap.maxX, y: rect.minY, width: rect.maxX - overlap.maxX, height: rect.height),
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
        ].filter { $0.width >= minimumClippedSide && $0.height >= minimumClippedSide }
        return pieces.max { $0.width * $0.height < $1.width * $1.height }
    }
}
