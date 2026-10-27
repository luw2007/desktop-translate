import AppKit
import CoreText

/// Multi-container TextKit layout: one container per measured occupied rectangle. Measurement (`fits`) and drawing
/// use this same object (same font, fixed line height, padding, containers, ink shifts), so they cannot disagree.
///
/// A source OCR rectangle bounds glyph INK, not a typographic line box: a 12pt CJK fallback line is taller than a
/// tight English OCR box. Lines are therefore laid out with a fixed line height no taller than the smallest
/// container, then the real drawable glyph ink (CoreText path bounds of the actual fallback-resolved runs, placed at
/// the layout manager's baseline) is measured per container. Fit requires that ink - after a vertical shift inside
/// the container, never beyond it - to lie within the exact source rectangle; the same shift is applied when drawing.
final class OverlayTextLayout {
    let manager = NSLayoutManager()
    let storage: NSTextStorage
    private(set) var containers: [NSTextContainer] = []
    private var measured: (fits: Bool, shifts: [CGFloat])?

    init(text: String, rects: [CGRect], size: CGFloat, color: NSColor, narrow: Bool = false) {
        let natural = OverlayItem.font(size: size, narrow: narrow).boundingRectForFont.height
        let line = min(natural, rects.map(\.height).min() ?? natural)
        storage = NSTextStorage(string: text, attributes: OverlayItem.attributes(size: size, color: color, lineHeight: line, narrow: narrow))
        manager.usesFontLeading = false
        storage.addLayoutManager(manager)
        for rect in rects {
            let container = NSTextContainer(size: rect.size)
            container.lineFragmentPadding = 1
            container.lineBreakMode = .byWordWrapping
            container.maximumNumberOfLines = 0
            manager.addTextContainer(container)
            containers.append(container)
        }
    }

    /// True only if every glyph is laid out inside the containers, its measured ink lies inside each exact
    /// container (width and height), and no whitespace-free non-CJK token (URL, path, identifier, protected
    /// fragment) had to be split across lines/containers.
    var fits: Bool { measure().fits }

    /// Vertical ink shift applied to a container when drawing (0 when the typographic baseline already fits).
    func verticalShift(containerIndex: Int) -> CGFloat {
        let shifts = measure().shifts
        return shifts.indices.contains(containerIndex) ? shifts[containerIndex] : 0
    }

    private func measure() -> (fits: Bool, shifts: [CGFloat]) {
        if let measured { return measured }
        let none = (fits: false, shifts: [CGFloat](repeating: 0, count: containers.count))
        guard let last = containers.last else { return (storage.length == 0, []) }
        let total = manager.numberOfGlyphs
        if total == 0 { return (true, none.shifts) }
        manager.ensureLayout(for: last)
        guard manager.textContainer(forGlyphAt: total - 1, effectiveRange: nil) != nil else { measured = none; return none }

        var shifts = none.shifts
        var inside = true
        for (index, container) in containers.enumerated() {
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            let range = manager.glyphRange(for: container)
            manager.enumerateLineFragments(forGlyphRange: range) { fragment, used, _, glyphs, _ in
                if used.maxX > container.size.width + 0.5 { inside = false }
                let chars = self.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let line = CTLineCreateWithAttributedString(self.storage.attributedSubstring(from: chars))
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                guard !ink.isNull, ink.width > 0 || ink.height > 0 else { return }
                let location = self.manager.location(forGlyphAt: glyphs.location)
                let baseline = fragment.minY + location.y
                let originX = fragment.minX + location.x
                if originX + ink.minX < -0.5 || originX + ink.maxX > container.size.width + 0.5 { inside = false }
                top = min(top, baseline - ink.maxY)
                bottom = max(bottom, baseline - ink.minY)
            }
            guard top <= bottom else { continue }
            let low = -top, high = container.size.height - bottom
            if low > high + 0.5 { inside = false; continue }
            shifts[index] = min(max(0, low), max(high, low))
        }
        guard inside else { measured = (false, shifts); return measured! }

        let ns = storage.string as NSString
        guard let regex = try? NSRegularExpression(pattern: "\\S+") else { measured = (false, shifts); return measured! }
        var unbroken = true
        regex.enumerateMatches(in: storage.string, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let range = match?.range else { return }
            let token = ns.substring(with: range)
            if token.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 1 else { return }
            let tail = glyphs.location + glyphs.length - 1
            let a = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let b = manager.lineFragmentRect(forGlyphAt: tail, effectiveRange: nil)
            let ca = manager.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
            let cb = manager.textContainer(forGlyphAt: tail, effectiveRange: nil)
            if a != b || ca !== cb { unbroken = false; stop.pointee = true }
        }
        measured = (unbroken, shifts)
        return measured!
    }

    func draw(containerIndex: Int, at origin: CGPoint) {
        guard containers.indices.contains(containerIndex) else { return }
        let range = manager.glyphRange(for: containers[containerIndex])
        guard range.length > 0 else { return }
        manager.drawGlyphs(forGlyphRange: range, at: CGPoint(x: origin.x, y: origin.y + verticalShift(containerIndex: containerIndex)))
    }
}
