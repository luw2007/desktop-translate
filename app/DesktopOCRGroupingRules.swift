import CoreGraphics
import Foundation

extension OCRGrouper {
    /// Split a grouped paragraph from a terminal into blocks. A line is prose only when the conservative
    /// `TranslationPlan` yields a new request for it (given the preceding prose line as context); prose runs
    /// become `.log` (terminal category, so the same plan is used at translation time) and every other line
    /// stays a separate protected-by-plan block (`.prompt`/`.diff`/`.path`/`.code`) that is left original.
    static func terminalBlocks(_ lines: [Line], proseLines: Set<Int>) -> [(lines: [Line], kind: RegionKind)] {
        var blocks: [(lines: [Line], kind: RegionKind)] = []
        var run: [Line] = []
        func flush() { if !run.isEmpty { blocks.append((run, .log)); run = [] } }
        for line in lines {
            if proseLines.contains(line.syntaxIndex) {
                run.append(line)
            } else {
                flush()
                blocks.append(([line], codeKind(line.text)))
            }
        }
        flush()
        return blocks
    }

    private static func codeKind(_ text: String) -> RegionKind {
        if !text.contains(where: { $0.isWhitespace }) && (text.hasPrefix("/") || text.hasPrefix("~") || text.contains("://")) { return .path }
        if ["$", "%", ">", "#"].contains(where: { text.hasPrefix($0) }) || ["$", "%", "#", ">"].contains(where: { text.hasSuffix($0) }) { return .prompt }
        if ["+", "-", "@@", "diff "].contains(where: { text.hasPrefix($0) }) { return .diff }
        return .code
    }

    /// Missing/mismatched boxes are not evidence of a visual wrap. Reuse the OCR paragraph rules
    /// for every boundary, including native regions that supply independently measured line boxes.
    static func visualContinuationLines(text: String, rects: [CGRect]) -> Set<Int> {
        let texts = text.components(separatedBy: .newlines)
        guard texts.count == rects.count, !texts.isEmpty,
              rects.allSatisfy({ $0.width > 0 && $0.height > 0 &&
                  [$0.minX, $0.minY, $0.width, $0.height].allSatisfy { $0.isFinite } }) else { return [] }
        let lines = zip(texts, rects).enumerated().map { index, pair in
            Line(text: pair.0, rect: pair.1, confidence: 1, parent: nil, words: asciiWordCount(pair.0), syntaxIndex: index)
        }
        let ctx = JoinContext(lines: lines, containers: [], terminal: true)
        var paragraph = Paragraph(lines: [lines[0]], maxWidth: lines[0].rect.width, left: lines[0].rect.minX)
        var boundaries = Set<Int>()
        for index in lines.indices.dropFirst() {
            let line = lines[index]
            if joinGap(paragraph, line, ctx) != nil {
                boundaries.insert(index)
                paragraph.lines.append(line)
                paragraph.maxWidth = max(paragraph.maxWidth, line.rect.width)
                paragraph.left = min(paragraph.left, line.rect.minX)
            } else {
                paragraph = Paragraph(lines: [line], maxWidth: line.rect.width, left: line.rect.minX)
            }
        }
        return boundaries
    }
    /// Everything `joinGap` needs besides the two lines: all measured lines (to detect rows, columns and bypassed
    /// neighbours), verified containers, and the evidence available for first-line fullness.
    struct JoinContext {
        var lines: [Line]
        var containers: [LayoutRegion] = []
        var terminal: Bool
        /// Selection crop; a container equal to it (or a window) is not a measured text boundary.
        var crop: CGRect? = nil

        func boundary(_ id: String?) -> CGRect? {
            guard let id, let c = containers.first(where: { $0.id == id }), c.role != .window else { return nil }
            if let crop, abs(c.rect.minX - crop.minX) < 1, abs(c.rect.maxX - crop.maxX) < 1,
               abs(c.rect.minY - crop.minY) < 1, abs(c.rect.maxY - crop.maxY) < 1 { return nil }
            return c.rect
        }
    }

    /// Nonterminal prose blocks use tight geometry, not a guessed container right edge. Every observation,
    /// including withheld observations, participates in the exclusion proof for the entire bounding union.
    static func paragraphGap(_ p: Paragraph, _ line: Line, _ ctx: JoinContext,
                                     omitted: [CGRect], unicode: Bool) -> CGFloat? {
        let a = p.lines[p.lines.count - 1], first = p.lines[0]
        let h = first.rect.height
        func translatable(_ l: Line) -> Bool {
            let text = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.hasPrefix("```"), !text.hasPrefix("~~~"),
                  !["$ ", "% ", "> ", "# ", "diff ", "@@"].contains(where: text.hasPrefix) else { return false }
            return UITextSegmenter.segment(text).contains { if case .text = $0 { return true }; return false }
        }
        guard h > 0, a.parent == line.parent, translatable(line), p.lines.allSatisfy(translatable),
              abs(line.rect.minX - first.rect.minX) <= max(2, h * 0.18),
              abs(line.rect.height - h) <= max(1, h * 0.15) else { return nil }
        let gap = line.rect.minY - a.rect.maxY
        guard gap >= 0, gap <= h * 0.65 else { return nil }
        if p.lines.count > 1 {
            let previous = p.lines[1].rect.minY - first.rect.maxY
            guard abs(gap - previous) <= max(1.5, h * 0.15) else { return nil }
        }
        let union = p.lines.reduce(line.rect) { $0.union($1.rect) }
        let others = ctx.lines.filter { other in
            other.syntaxIndex != line.syntaxIndex && !p.lines.contains { $0.syntaxIndex == other.syntaxIndex }
        }.map(\.rect) + omitted
        for rect in others {
            let intersection = union.intersection(rect)
            if !intersection.isNull && intersection.width > 0 && intersection.height > 0 { return nil }
            // Adjacent same-row controls/columns are not prose paragraphs.
            for mate in [a.rect, line.rect] where min(rect.maxY, mate.maxY) > max(rect.minY, mate.minY) {
                if max(rect.minX - mate.maxX, mate.minX - rect.maxX) < h { return nil }
            }
        }
        for container in ctx.containers where !container.rect.contains(union) {
            let intersection = container.rect.intersection(union)
            if !intersection.isNull && intersection.width > 0 && intersection.height > 0 { return nil }
        }
        return gap
    }
    /// Vertical gap if `line` continues paragraph `p`, else nil. Rejects joins that cross or bypass any other
    /// measured line or container boundary, and joins whose first line is not shown to be full by measurement.
    static func joinGap(_ p: Paragraph, _ line: Line, _ ctx: JoinContext) -> CGFloat? {
        let a = p.lines[p.lines.count - 1]
        guard a.parent == line.parent else { return nil }
        let h = a.rect.height
        guard h > 0 else { return nil }
        let ratio = line.rect.height / h
        guard ratio >= 0.75, ratio <= 1.34 else { return nil }
        let gap = line.rect.minY - a.rect.maxY
        guard gap >= -0.3 * h, gap <= 0.9 * h else { return nil }
        guard abs(line.rect.minX - p.left) <= 2.5 * h,
              line.rect.minX < a.rect.maxX, a.rect.minX < line.rect.maxX else { return nil }
        guard !endsSentence(a.text), !TranslationPlan.startsListItem(line.text) else { return nil }
        let bridge = a.rect.union(line.rect)
        for other in ctx.lines where other.syntaxIndex != line.syntaxIndex
            && !p.lines.contains(where: { $0.syntaxIndex == other.syntaxIndex }) {
            // Another measured row/column sits between or across the two lines.
            let overlap = other.rect.intersection(bridge)
            if !overlap.isNull, overlap.width > 1, overlap.height > 0.35 * other.rect.height { return nil }
            // Touching or adjacent sibling in the same row band: cells/controls, not prose.
            for mate in [a, line] {
                let band = min(other.rect.maxY, mate.rect.maxY) - max(other.rect.minY, mate.rect.minY)
                guard band >= 0.5 * min(other.rect.height, mate.rect.height) else { continue }
                let side = max(other.rect.minX - mate.rect.maxX, mate.rect.minX - other.rect.maxX)
                if side <= 2 * h { return nil }
            }
        }
        // A container boundary (pane/cell) that cuts through the span is never crossed.
        for c in ctx.containers where !c.rect.insetBy(dx: -1, dy: -1).contains(bridge) {
            let i = c.rect.intersection(bridge)
            if !i.isNull, i.width > 1, i.height > 1 { return nil }
        }
        if p.lines.count == 1 {
            guard firstLineIsFull(a, line, ctx) else { return nil }
        } else {
            guard a.rect.width >= 0.75 * p.maxWidth else { return nil }
        }
        return gap
    }

    /// Actual evidence that the first line ended because the next word did not fit, not a word-count guess.
    /// Terminal grids: the line reaches the right extent of every measured line of its parent and the
    /// continuation is not wider. Other UI text: a measured non-window, non-selection container boundary plus the
    /// measured first word of the next line must show that word could not have fit. No such evidence -> not full.
    private static func firstLineIsFull(_ a: Line, _ line: Line, _ ctx: JoinContext) -> Bool {
        let h = a.rect.height
        if ctx.terminal {
            let right = ctx.lines.filter { $0.parent == a.parent }.map { $0.rect.maxX }.max() ?? a.rect.maxX
            return a.rect.maxX >= right - 1.2 * h && line.rect.maxX <= a.rect.maxX + 0.6 * h
        }
        // Full only when the next line's measured first word plus the measured inter-word space cannot fit in the
        // remaining width of the verified container. No tolerance: a word that fits proves the break was not forced.
        guard let first = line.firstWord, first > 0, let space = a.space, let boundary = ctx.boundary(a.parent),
              a.rect.maxX <= boundary.maxX + 1 else { return false }
        return a.rect.maxX + space + first > boundary.maxX
    }

    private static func endsSentence(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return ".!?:;。！？：；".contains(last)
    }

    static func asciiWordCount(_ s: String) -> Int {
        var words = 0, inWord = false
        for c in s {
            let letter = c.isLetter
            if letter && !inWord { words += 1 }
            inWord = letter
        }
        return words
    }
}
