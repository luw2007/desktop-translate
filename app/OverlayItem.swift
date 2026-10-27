import AppKit

/// One translated region. Masks are painted ONLY on `occupied` (independently measured source line rectangles clipped
/// to window, selection and verified parent container) - never on the union of a paragraph, whose gaps may hold
/// neighbouring content - except `.paintedCover`, the user-chosen last resort. Every translated region yields exactly
/// one item with one truthful `outcome`; items are never dropped, so full text stays available through the expansion
/// panel (deliberate overflow access, not positioning). Fallback order when the text does not fit:
/// regular font >= `minimumFontSize` on the source lines, then in proven-free extension; then a narrow (condensed,
/// tighter tracking) font from 12pt down to `shrinkFloorFontSize` on the same two areas; then a translucent cover;
/// then an orange marker.
/// - `.painted`: mask + text drawn on the exact source lines (or their proven-free extension), regular font >= 12pt.
/// - `.paintedCondensed`: same areas, narrow font, possibly below 12pt (never below `shrinkFloorFontSize`).
/// - `.paintedCover`: user-accepted last resort. Narrow 12pt text on a cover that grows right then down from the
///   source, clamped to window/selection, never overlapping another item's paint or marker. The part outside the
///   source/proven-free area is translucent (`coverAlpha`), bordered, and NOT part of the freshness baseline.
/// - `.fitOverflow`: occupancy known and collision-free, but nothing above fits; nothing is painted over the source,
///   an orange marker is shown.
/// - `.collisionUnavailable`: the source rectangles overlap another captured region that cannot be clipped around
///   (protected/untranslated text, an extension obstacle, ambiguous identities, or nothing left after clipping), so
///   nothing is painted over the source; an orange marker is shown (expandable like fit overflow). Two translated
///   items that merely overlap are resolved first: the lower-priority one (later reading order) is clipped to exclude
///   the other's source rectangle and then fitted by the normal chain.
/// - `.noOccupancy`: exact clipping (window/selection/parent) left no source rectangle; nothing drawn.
struct OverlayItem: Equatable {
    enum Outcome: Equatable { case painted, paintedCondensed, paintedCover, fitOverflow, collisionUnavailable, noOccupancy }

    var regionID: String
    var readingOrder: Int
    var text: String
    var protectedFragments: [String]
    var occupied: [CGRect]          // window-local points, drawing order (empty only for `.noOccupancy`)
    var clip: CGRect                // bounding box of `occupied`; informational, NEVER painted (`.zero` if none)
    /// Non-empty only for a `.painted` item whose text did not fit the exact source lines: the SAME lines (same order,
    /// same y/height/x origin) widened to the right into space proven free (see `FreeSpace`, `FlatStrip`).
    var extended: [CGRect] = []
    /// Non-empty only for `.paintedCover`: the full cover rectangles (one per container, each containing the matching
    /// opaque base = `extended` when non-empty, else `occupied`).
    var cover: [CGRect] = []
    var background: NSColor
    var fontSize: CGFloat
    var outcome: Outcome

    static let minimumFontSize: CGFloat = 12
    /// Lowest size the narrow-font fallback may reach.
    static let shrinkFloorFontSize: CGFloat = 9
    /// Opacity of the cover outside the source/proven-free area: covered content stays faintly visible.
    static let coverAlpha: CGFloat = 0.85

    /// True for every outcome that paints a translation over the screen.
    var isPainted: Bool { outcome == .painted || outcome == .paintedCondensed || outcome == .paintedCover }
    /// Painted with the narrow font (condensed, shrunk, or cover).
    var narrow: Bool { outcome == .paintedCondensed || outcome == .paintedCover }
    /// Size policy: regular text >= 12pt, narrow text >= `shrinkFloorFontSize`, cover text exactly 12pt.
    var fontSizeAllowed: Bool {
        switch outcome {
        case .painted: return fontSize >= Self.minimumFontSize
        case .paintedCondensed: return fontSize >= Self.shrinkFloorFontSize
        case .paintedCover: return fontSize == Self.minimumFontSize
        default: return true
        }
    }

    /// True for every outcome that paints nothing over the source (fit overflow, collision, no occupancy).
    var overflow: Bool { !isPainted }
    /// True when no paint AND no marker exist for this item (no occupancy only; collisions show the marker).
    var occupancyUnavailable: Bool { outcome == .noOccupancy }

    /// Rectangles that receive paint (empty unless painted): the cover, else the extended lines, else the source lines.
    var paintRects: [CGRect] {
        switch outcome {
        case .painted, .paintedCondensed: return extended.isEmpty ? occupied : extended
        case .paintedCover: return cover
        default: return []
        }
    }
    /// Opaque mask areas: the source lines (or their proven-free extension), baselined at capture.
    var baseRects: [CGRect] { isPainted ? (extended.isEmpty ? occupied : extended) : [] }
    var isExtended: Bool { (outcome == .painted || outcome == .paintedCondensed) && !extended.isEmpty }
    var isExtendedRight: Bool { isExtended && zip(occupied, extended).contains { $0.1.maxX > $0.0.maxX } }
    var isExtendedDown: Bool { isExtended && zip(occupied, extended).contains { $0.1.maxY > $0.0.maxY } }

    /// Per-outcome totals over a presented set; they always sum to `items.count`.
    struct Counts: Equatable {
        /// Every outcome that paints (regular, condensed and cover).
        var painted = 0, fitOverflow = 0, collisionUnavailable = 0, noOccupancy = 0
        /// Subsets of `painted`.
        var condensed = 0, cover = 0
        /// Subset of regular/condensed `painted` that needed proven-free space beyond the source lines.
        var extended = 0
        var extendedRight = 0, extendedDown = 0
        var total: Int { painted + fitOverflow + collisionUnavailable + noOccupancy }
    }

    static func counts(_ items: [OverlayItem]) -> Counts {
        var c = Counts()
        for item in items {
            switch item.outcome {
            case .painted, .paintedCondensed, .paintedCover:
                c.painted += 1
                if item.outcome == .paintedCondensed { c.condensed += 1 }
                if item.outcome == .paintedCover { c.cover += 1 }
                if item.isExtended { c.extended += 1 }
                if item.isExtendedRight { c.extendedRight += 1 }
                if item.isExtendedDown { c.extendedDown += 1 }
            case .fitOverflow: c.fitOverflow += 1
            case .collisionUnavailable: c.collisionUnavailable += 1
            case .noOccupancy: c.noOccupancy += 1
            }
        }
        return c
    }

    static func font(size: CGFloat, narrow: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard narrow else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: -0.2]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func attributes(size: CGFloat, color: NSColor, lineHeight: CGFloat, narrow: Bool = false) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        var attributes: [NSAttributedString.Key: Any] = [.font: font(size: size, narrow: narrow), .foregroundColor: color, .paragraphStyle: paragraph]
        if narrow { attributes[.kern] = -size * 0.03 }
        return attributes
    }

    static func attributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    var textColor: NSColor {
        let rgb = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance < 0.5 ? .white : .black
    }

    /// Marker sits inside the last occupied rectangle (bottom-right), shrunk to fit it.
    var markerRect: CGRect {
        let rect = occupied.last ?? clip
        let side = min(14, rect.width, rect.height)
        return CGRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side)
    }
}
