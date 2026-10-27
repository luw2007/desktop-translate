import AppKit

extension OverlayItem {
    static func make(from translations: [RegionTranslation], snapshot: CaptureSnapshot, selection: CGRect) -> [OverlayItem] {
        let bounds = CGRect(origin: .zero, size: snapshot.target.frame.size)
        let parents = Dictionary(snapshot.layout.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        let originals = Dictionary(snapshot.regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func occupiedRects(_ t: RegionTranslation) -> [CGRect] {
            OverlayOccupancy.rects(source: t.rects.isEmpty ? [t.unionRect] : t.rects, parent: t.parentID.flatMap { parents[$0] },
                                   bounds: bounds, selection: selection)
        }
        // Presented translations that own paintable source rectangles; overlap priority = reading order, then id.
        let peers = translations.filter { !occupiedRects($0).isEmpty }.map { (id: $0.regionID, order: $0.readingOrder) }
        var items: [OverlayItem] = translations.map { t in
            let duplicate = translations.reduce(0, { $0 + ($1.regionID == t.regionID ? 1 : 0) }) != 1
            let full = occupiedRects(t)
            let others = duplicate ? [] : peers.filter { $0.id != t.regionID }
            let lowerIDs = Set(others.filter { ($0.order, $0.id) > (t.readingOrder, t.regionID) }.map(\.id))
            let cuts = others.filter { ($0.order, $0.id) < (t.readingOrder, t.regionID) }.flatMap { originals[$0.id]?.paintSourceRects ?? [] }
            // Untranslated neighbours (protected, skipped) that merely share an OCR edge with a row are trimmed around,
            // never painted over; real overlaps still count as a collision below.
            let peerIDs = Set(peers.map(\.id))
            let edgeCuts = duplicate ? [] : snapshot.regions.filter { $0.id != t.regionID && !peerIDs.contains($0.id) }.flatMap(\.paintSourceRects)
            let clipped = full.compactMap { (rect: CGRect) -> CGRect? in
                var current: CGRect? = rect
                for cut in cuts { guard let c = current else { break }; current = OverlayOccupancy.subtract(c, cut: cut) }
                for cut in edgeCuts {
                    guard let c = current else { break }
                    if let trimmed = OverlayOccupancy.trimmedToEdge(c, cut: cut) { current = trimmed }
                }
                return current
            }
            // A line fully swallowed by a higher-priority neighbour cannot be clipped: its original would stay half visible.
            let unresolvable = !full.isEmpty && clipped.count != full.count
            let occupied = unresolvable ? full : clipped
            let color: NSColor
            if let b = originals[t.regionID]?.background {
                color = NSColor(srgbRed: b.red, green: b.green, blue: b.blue, alpha: b.verified ? 1 : max(0.92, b.alpha))
            } else {
                color = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
            }
            guard let first = occupied.first else {
                return OverlayItem(regionID: t.regionID, readingOrder: t.readingOrder, text: t.text,
                                   protectedFragments: t.protectedFragments, occupied: [], clip: .zero,
                                   background: color, fontSize: minimumFontSize, outcome: .noOccupancy)
            }
            let clip = occupied.dropFirst().reduce(first) { $0.union($1) }
            let minHeight = originals[t.regionID]?.lineRects.map(\.height).min() ?? occupied.map(\.height).min() ?? first.height
            let collision = duplicate || unresolvable
                || OverlayOccupancy.collides(occupied: occupied, regionID: t.regionID, regions: snapshot.regions, ignoring: lowerIDs)
            let startSize = max(minimumFontSize, min(28, minHeight * 0.78))
            let parent = t.parentID.flatMap { parents[$0] }
            var size = startSize
            var fits = !collision && OverlayTextLayout(text: t.text, rects: occupied, size: size, color: .black).fits
            while !collision && !fits && size > minimumFontSize {
                size = max(minimumFontSize, size - 1)
                fits = OverlayTextLayout(text: t.text, rects: occupied, size: size, color: .black).fits
            }
            let regularSize = size
            var extended: [CGRect] = []
            var wide: [CGRect]?
            if !collision && !fits,
               let candidate = extendedRects(for: t, original: originals[t.regionID], parent: parent,
                                             bounds: bounds, selection: selection, regions: snapshot.regions, expected: occupied),
               !OverlayOccupancy.collides(occupied: candidate, regionID: t.regionID, regions: snapshot.regions) {
                wide = candidate
                var wideSize = startSize
                var wideFits = OverlayTextLayout(text: t.text, rects: candidate, size: wideSize, color: .black).fits
                while !wideFits && wideSize > minimumFontSize {
                    wideSize = max(minimumFontSize, wideSize - 1)
                    wideFits = OverlayTextLayout(text: t.text, rects: candidate, size: wideSize, color: .black).fits
                }
                if wideFits { extended = candidate; fits = true; size = wideSize }
            }
            // Fallback 1: narrow font at the current size, then shrinking to `shrinkFloorFontSize`; same two areas only.
            var condensed = false
            if !collision && !fits {
                var narrowSize = startSize
                search: while true {
                    if OverlayTextLayout(text: t.text, rects: occupied, size: narrowSize, color: .black, narrow: true).fits {
                        fits = true; condensed = true; size = narrowSize; break search
                    }
                    if let wide, OverlayTextLayout(text: t.text, rects: wide, size: narrowSize, color: .black, narrow: true).fits {
                        extended = wide; fits = true; condensed = true; size = narrowSize; break search
                    }
                    if narrowSize <= shrinkFloorFontSize { break search }
                    narrowSize = max(shrinkFloorFontSize, narrowSize - 1)
                }
            }
            return OverlayItem(regionID: t.regionID, readingOrder: t.readingOrder, text: t.text,
                               protectedFragments: t.protectedFragments, occupied: occupied, clip: clip, extended: extended,
                               background: color, fontSize: fits ? size : regularSize,
                               outcome: collision ? .collisionUnavailable : (fits ? (condensed ? .paintedCondensed : .painted) : .fitOverflow))
        }
        // Fallback 2 (user-accepted last resort): a translucent cover. Placed in reading order; each cover avoids the
        // source/extension rectangles of every other captured translation that is not collision/no-occupancy, and every
        // cover placed before it, so covers never overlap another translation item's paint.
        let limit = bounds.intersection(selection)
        var placed: [CGRect] = []
        for index in items.indices.filter({ items[$0].outcome == .fitOverflow }).sorted(by: { items[$0].readingOrder < items[$1].readingOrder }) {
            var obstacles = placed
            for (other, item) in items.enumerated() where other != index && !item.occupancyUnavailable {
                obstacles += item.occupied + item.extended
            }
            guard let rows = coverRows(text: items[index].text, occupied: items[index].occupied, obstacles: obstacles, limit: limit) else { continue }
            items[index].cover = rows
            items[index].fontSize = minimumFontSize
            items[index].outcome = .paintedCover
            placed += rows
        }
        return items
    }

    /// Row rectangles (stacked containers, same x/width) of a cover for `text` at `minimumFontSize` in the narrow font.
    /// The block starts at the bounding box of the source lines and grows right (to the nearest obstacle on its rows
    /// or `limit`) before it grows down; the narrowest width that fits at the first workable height is chosen. nil when
    /// no block inside `limit` that avoids every obstacle fits the text.
    static func coverRows(text: String, occupied: [CGRect], obstacles: [CGRect], limit: CGRect) -> [CGRect]? {
        guard let first = occupied.first else { return nil }
        let clip = occupied.dropFirst().reduce(first) { $0.union($1) }
        guard limit.insetBy(dx: -0.001, dy: -0.001).contains(clip) else { return nil }
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
            let i = a.intersection(b)
            return !i.isNull && i.width > 0 && i.height > 0
        }
        let rowMin = ceil(font(size: minimumFontSize, narrow: true).boundingRectForFont.height)
        var rows = max(1, Int(floor(clip.height / rowMin)))
        while true {
            let height = max(clip.height, CGFloat(rows) * rowMin)
            guard clip.minY + height <= limit.maxY + 0.001 else { return nil }
            let span = CGRect(x: clip.minX, y: clip.minY, width: clip.width, height: height)
            guard !obstacles.contains(where: { overlaps(span, $0) }) else { return nil }
            var maxX = limit.maxX
            for o in obstacles where o.minX >= span.maxX - 0.001 && o.minY < span.maxY && o.maxY > span.minY { maxX = min(maxX, o.minX) }
            let full = maxX - clip.minX
            func rects(_ width: CGFloat) -> [CGRect] {
                (0..<rows).map { CGRect(x: clip.minX, y: clip.minY + CGFloat($0) * height / CGFloat(rows), width: width, height: height / CGFloat(rows)) }
            }
            func fits(_ width: CGFloat) -> Bool {
                OverlayTextLayout(text: text, rects: rects(width), size: minimumFontSize, color: .black, narrow: true).fits
            }
            if full >= clip.width, fits(full) {
                var lo = clip.width, hi = full
                if fits(lo) { hi = lo } else {
                    while hi - lo > 1 {
                        let mid = (lo + hi) / 2
                        if fits(mid) { hi = mid } else { lo = mid }
                    }
                }
                return rects(hi)
            }
            rows += 1
        }
    }

    /// The source lines widened to the right by the proven free width, in `occupied` order; nil when no line gains
    /// room. Room = min(capture-time pixel-flat width, geometric room re-derived here from the same snapshot), so a
    /// stale or inconsistent `freeRight` can never extend past a recognized neighbour, parent, selection or window.
    private static func extendedRects(for t: RegionTranslation, original: TextRegion?, parent: CGRect?, bounds: CGRect,
                                      selection: CGRect, regions: [TextRegion], expected: [CGRect]) -> [CGRect]? {
        guard let original, original.kind.category != .protected else { return nil }
        let lines = original.paintSourceRects
        let source = t.rects.isEmpty ? [t.unionRect] : t.rects
        guard lines == source else { return nil }
        var pairs: [(base: CGRect, wide: CGRect)] = []
        var gained = false
        for (index, line) in lines.enumerated() {
            guard let base = OccupiedGeometry.rects(source: [line], parent: parent, bounds: bounds, selection: selection).first else { continue }
            let wide = FreeSpace.extended(line: base, index: index, owner: original, parent: parent,
                                          bounds: bounds, selection: selection, regions: regions)
            if wide != base { gained = true }
            pairs.append((base, wide))
        }
        guard gained else { return nil }
        let sorted = pairs.sorted { a, b in a.base.minY == b.base.minY ? a.base.minX < b.base.minX : a.base.minY < b.base.minY }
        guard sorted.map(\.base) == expected else { return nil }
        return sorted.map(\.wide)
    }
}
