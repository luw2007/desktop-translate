import CoreGraphics
import Foundation

// MARK: - OCR grouping

/// One whitespace-delimited token of an OCR line, Vision-normalized like its parent line.
struct OCRWord: Equatable, Sendable {
    var text: String
    var normalizedBox: CGRect
    init(text: String, normalizedBox: CGRect) { self.text = text; self.normalizedBox = normalizedBox }
}

struct OCRObservation: Equatable, Sendable {
    var text: String
    var confidence: Double
    /// Vision convention: normalized to the cropped image, origin bottom-left.
    var normalizedBox: CGRect
    /// Optional per-word boxes. A Vision line spanning a wide horizontal gap (table columns, button
    /// rows) is split at the gap so unrelated controls never become one region.
    var words: [OCRWord]

    init(text: String, confidence: Double, normalizedBox: CGRect, words: [OCRWord] = []) {
        self.text = text; self.confidence = confidence; self.normalizedBox = normalizedBox; self.words = words
    }
}

enum OCRGrouper {
    static let minimumConfidence = 0.3

    private struct Line {
        var text: String
        var rect: CGRect
        var confidence: Double
        var parent: String?
        var words: Int
        var syntaxIndex: Int = -1
        /// Measured width (points) of the first word, when complete word evidence exists.
        var firstWord: CGFloat? = nil
        /// Smallest measured gap (points) between adjacent words of this line: the measured space width.
        var space: CGFloat? = nil
    }

    private struct Paragraph {
        var lines: [Line]
        var maxWidth: CGFloat
        var left: CGFloat
    }

    /// Turn raw Vision lines into regions. Wrapped lines of one paragraph (same parent, adjacent, aligned,
    /// equal height, previous line full and not sentence-final) become one `.prose` region; short isolated
    /// lines stay separate `.label` regions so controls are never merged with neighbours or across parents.
    /// Regions plus the count of observations withheld because they straddle a reliable boundary without
    /// complete measured word evidence. The capture owner surfaces `Self.straddleWarning` when non-zero.
    struct GroupedOCR: Equatable {
        var regions: [TextRegion]
        var omittedObservations: Int
    }
    static let straddleWarning = "部分文字跨越窗格或控件边界且无法逐词确认，未覆盖这些文字。"

    static func group(_ observations: [OCRObservation], crop: CGRect, target: CaptureTarget,
                      layout: [LayoutRegion] = []) -> [TextRegion] {
        grouped(observations, crop: crop, target: target, layout: layout).regions
    }

    static func grouped(_ observations: [OCRObservation], crop: CGRect, target: CaptureTarget,
                        layout: [LayoutRegion] = []) -> GroupedOCR {
        let bounds = CGRect(origin: .zero, size: target.frame.size)
        let containers = layout.sorted { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        var lines: [Line] = []
        var omitted = 0
        func holds(_ c: CGRect, _ r: CGRect) -> Bool { c.insetBy(dx: -1, dy: -1).contains(r) }
        func straddles(_ r: CGRect) -> Bool {
            containers.contains { c in
                guard !holds(c.rect, r) else { return false }
                let i = c.rect.intersection(r)
                return !i.isNull && i.width > 1 && i.height > 1
            }
        }
        /// Smallest verified container that FULLY contains the rectangle (never center membership).
        func owner(_ r: CGRect) -> String? { containers.first { holds($0.rect, r) }?.id }
        func append(_ text: String, _ local: CGRect, _ confidence: Double, _ ws: [OCRWord]) {
            let sorted = ws.sorted { $0.normalizedBox.minX < $1.normalizedBox.minX }
            let gaps = zip(sorted, sorted.dropFirst()).map { ($1.normalizedBox.minX - $0.normalizedBox.maxX) * crop.width }
            lines.append(Line(text: text, rect: local, confidence: confidence, parent: owner(local),
                              words: asciiWordCount(text), firstWord: sorted.first.map { $0.normalizedBox.width * crop.width },
                              space: gaps.min().map { max(0, $0) }))
        }
        func addLine(_ rawText: String, _ n: CGRect, _ confidence: Double, words: [OCRWord] = []) {
            let text = rawText.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, [n.minX, n.minY, n.width, n.height].allSatisfy({ $0.isFinite }), n.width > 0, n.height > 0
            else { return }
            let local = CoordinateMapper.visionToLocal(n, crop: crop).intersection(bounds)
            guard !local.isNull, local.width > 0, local.height > 0 else { return }
            guard straddles(local) else { append(text, local, confidence, words); return }
            // The observation spans a reliable boundary: split only on complete measured tokens, else omit it.
            guard !words.isEmpty else { omitted += 1; return }
            var runs: [(words: [OCRWord], rect: CGRect)] = []
            var runOwner: [String?] = []
            for w in words {
                let wl = CoordinateMapper.visionToLocal(w.normalizedBox, crop: crop).intersection(bounds)
                guard !wl.isNull, wl.width > 0, wl.height > 0, !straddles(wl) else { omitted += 1; return }
                let who = owner(wl)
                if let last = runOwner.last, last == who, !runs.isEmpty {
                    runs[runs.count - 1].words.append(w)
                    runs[runs.count - 1].rect = runs[runs.count - 1].rect.union(wl)
                } else {
                    runs.append(([w], wl)); runOwner.append(who)
                }
            }
            for run in runs {
                let box = CGRect(x: run.rect.minX, y: local.minY, width: run.rect.width, height: local.height)
                append(run.words.map { $0.text }.joined(separator: " "), box, confidence, run.words)
            }
        }
        for o in observations {
            guard o.confidence.isFinite, o.confidence >= minimumConfidence else { continue }
            // Split one Vision line at wide horizontal gaps (table columns, button rows): Vision happily
            // returns "Name      Value" or "Cancel Settings OK" as ONE line spanning unrelated cells.
            // Gap threshold is two line heights; ordinary word spacing is far below that.
            // Split only on complete, measured evidence: the word texts must reproduce the line's own
            // whitespace tokens and every box must be valid. Otherwise dropping a word would silently lose text.
            let tokens = o.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let complete = o.words.count == tokens.count && o.words.map { $0.text } == tokens
                && o.words.allSatisfy { $0.normalizedBox.width > 0 && $0.normalizedBox.height > 0
                    && [$0.normalizedBox.minX, $0.normalizedBox.minY, $0.normalizedBox.width, $0.normalizedBox.height].allSatisfy { $0.isFinite } }
            let words = o.words.sorted { $0.normalizedBox.minX < $1.normalizedBox.minX }
            guard complete, words.count >= 2, o.normalizedBox.width > 0, o.normalizedBox.height > 0 else {
                addLine(o.text, o.normalizedBox, o.confidence); continue
            }
            let lineHeightPoints = o.normalizedBox.height * crop.height
            var segment: [OCRWord] = [words[0]]
            var segments: [[OCRWord]] = []
            for w in words.dropFirst() {
                let gapPoints = (w.normalizedBox.minX - segment[segment.count - 1].normalizedBox.maxX) * crop.width
                if gapPoints > 2 * lineHeightPoints { segments.append(segment); segment = [w] } else { segment.append(w) }
            }
            segments.append(segment)
            let sizedComplete = complete ? words : []
            if segments.count == 1 { addLine(o.text, o.normalizedBox, o.confidence, words: sizedComplete); continue }
            for s in segments {
                let box = s.dropFirst().reduce(s[0].normalizedBox) { $0.union($1.normalizedBox) }
                // Keep the line's vertical extent so segments of one row stay aligned.
                let merged = CGRect(x: box.minX, y: o.normalizedBox.minY, width: box.width, height: o.normalizedBox.height)
                addLine(s.map { $0.text }.joined(separator: " "), merged, o.confidence, words: s)
            }
        }
        lines.sort { $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        for index in lines.indices { lines[index].syntaxIndex = index }

        let terminal = terminalBundleIDs.contains(target.bundleID ?? "")
        let ctx = JoinContext(lines: lines, containers: containers, terminal: terminal, crop: crop)
        var paragraphs: [Paragraph] = []
        for line in lines {
            var best: Int?
            var bestGap = CGFloat.infinity
            for (i, p) in paragraphs.enumerated() {
                guard let gap = joinGap(p, line, ctx), gap < bestGap else { continue }
                best = i; bestGap = gap
            }
            if let best {
                paragraphs[best].lines.append(line)
                paragraphs[best].maxWidth = max(paragraphs[best].maxWidth, line.rect.width)
                paragraphs[best].left = min(paragraphs[best].left, line.rect.minX)
            } else {
                paragraphs.append(Paragraph(lines: [line], maxWidth: line.rect.width, left: line.rect.minX))
            }
        }
        paragraphs.sort {
            let a = $0.lines[0].rect, b = $1.lines[0].rect
            return a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
        }

        // Single measured lines stay `.label`: typography alone never establishes prose, button or cell identity.
        var blocks: [(lines: [Line], kind: RegionKind)] = []
        let proseLines = terminal ? TranslationPlan(text: lines.map { $0.text }.joined(separator: "\n")).proseLineIndices : []
        // Syntax classification is performed once across all rows so fences retain their scope.
        for p in paragraphs {
            if terminal {
                blocks.append(contentsOf: terminalBlocks(p.lines, proseLines: proseLines))
            } else {
                let text = p.lines.map { $0.text }.joined(separator: "\n")
                let kind: RegionKind
                if p.lines.count > 1 {
                    kind = .prose
                } else if !text.contains(where: { $0.isWhitespace }) && (text.hasPrefix("/") || text.hasPrefix("~") || text.contains("://")) {
                    kind = .path
                } else {
                    kind = .label
                }
                blocks.append((p.lines, kind))
            }
        }
        let regions = blocks.enumerated().map { index, b -> TextRegion in
            let rects = b.lines.map { $0.rect }
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let text = b.lines.map { $0.text }.joined(separator: "\n")
            let confidence = b.lines.reduce(0) { $0 + $1.confidence } / Double(b.lines.count)
            return TextRegion(id: "ocr-\(index)", parentID: b.lines[0].parent, kind: b.kind, source: .ocr,
                              rect: union, text: text, confidence: min(1, max(0, confidence)),
                              lineRects: rects, readingOrder: index)
        }
        return GroupedOCR(regions: regions, omittedObservations: omitted)
    }

    /// The five terminal apps (exact bundle IDs). Their OCR text is never treated as UI labels.
    static let terminalBundleIDs: Set<String> = ["com.cmuxterm.app", "com.googlecode.iterm2", "com.apple.Terminal",
                                                 "com.mitchellh.ghostty", "fun.tw93.kaku"]

    /// Split a grouped paragraph from a terminal into blocks. A line is prose only when the conservative
    /// `TranslationPlan` yields a new request for it (given the preceding prose line as context); prose runs
    /// become `.log` (terminal category, so the same plan is used at translation time) and every other line
    /// stays a separate protected-by-plan block (`.prompt`/`.diff`/`.path`/`.code`) that is left original.
    private static func terminalBlocks(_ lines: [Line], proseLines: Set<Int>) -> [(lines: [Line], kind: RegionKind)] {
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
    private struct JoinContext {
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

    /// Vertical gap if `line` continues paragraph `p`, else nil. Rejects joins that cross or bypass any other
    /// measured line or container boundary, and joins whose first line is not shown to be full by measurement.
    private static func joinGap(_ p: Paragraph, _ line: Line, _ ctx: JoinContext) -> CGFloat? {
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
        guard !endsSentence(a.text) else { return nil }
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

    private static func asciiWordCount(_ s: String) -> Int {
        var words = 0, inWord = false
        for c in s {
            let letter = c.isASCII && c.isLetter
            if letter && !inWord { words += 1 }
            inWord = letter
        }
        return words
    }
}

// MARK: - Desktop UI segmentation

enum UITextSegmenter {
    enum Piece: Equatable {
        /// Whitespace and bare punctuation/numbers outside translatable runs.
        case literal(String)
        /// A token that must reach the output byte-for-byte (URL, path, snake_case, camelCase, alphanumeric...).
        case protected(String)
        /// A run of ASCII words to translate.
        case text(String)
    }

    private enum Kind { case space, word, neutral, protected }

    /// Concatenating all pieces reproduces `string` exactly.
    static func segment(_ string: String) -> [Piece] {
        var tokens: [(text: String, kind: Kind)] = []
        var current = ""
        var currentIsSpace: Bool?
        func close() {
            guard let space = currentIsSpace else { return }
            tokens.append((current, space ? .space : classify(current)))
            current = ""
        }
        for c in string {
            let space = c.isWhitespace
            if currentIsSpace != space { close(); currentIsSpace = space }
            current.append(c)
        }
        close()

        var pieces: [Piece] = []
        func literal(_ s: String) {
            guard !s.isEmpty else { return }
            if case .literal(let prev)? = pieces.last {
                pieces[pieces.count - 1] = .literal(prev + s)
            } else {
                pieces.append(.literal(s))
            }
        }
        var run: [(text: String, kind: Kind)] = []
        func flush() {
            defer { run.removeAll() }
            var lo = 0, hi = run.count
            while lo < hi, run[lo].kind != .word { lo += 1 }
            while hi > lo, run[hi - 1].kind != .word { hi -= 1 }
            if lo == hi { literal(run.map { $0.text }.joined()); return }
            literal(run[..<lo].map { $0.text }.joined())
            let body = run[lo..<hi].map { $0.text }.joined()
            pieces.append(.text(body))
            literal(run[hi...].map { $0.text }.joined())
        }
        for t in tokens {
            if t.kind == .protected {
                flush()
                pieces.append(.protected(t.text))
            } else {
                run.append(t)
            }
        }
        flush()
        return pieces
    }


    private static func classify(_ token: String) -> Kind {
        if token.contains("/") || token.contains("\\") || token.contains("@") || token.contains("_") ||
            token.hasPrefix("~") || token.hasPrefix("--") || token.hasPrefix("#") { return .protected }
        let chars = Array(token)
        if chars.count > 1, chars[0] == "-", chars[1].isASCII, chars[1].isLetter { return .protected }
        var lo = 0, hi = chars.count
        while lo < hi, !(chars[lo].isLetter || chars[lo].isNumber) { lo += 1 }
        while hi > lo, !(chars[hi - 1].isLetter || chars[hi - 1].isNumber) { hi -= 1 }
        if lo == hi { return .neutral }
        let core = Array(chars[lo..<hi])
        if core.contains(where: { $0.isNumber }),
           core.allSatisfy({ ($0.isASCII && $0.isNumber) || ".,:-+%".contains($0) }) { return .neutral }
        if core.contains(".") { return .protected }
        for (i, c) in core.enumerated() {
            if c.isASCII && c.isLetter {
                if i + 1 < core.count, c.isLowercase, core[i + 1].isASCII, core[i + 1].isUppercase { return .protected }
            } else if !"'’-".contains(c) {
                return .protected
            }
        }
        return .word
    }
}

// MARK: - Plan

struct RegionTranslation: Equatable, Sendable {
    var regionID: String
    var parentID: String?
    var kind: RegionKind
    var readingOrder: Int
    var original: String
    var text: String
    /// Original rects (per visual line when known) in window-local points.
    var rects: [CGRect]
    var unionRect: CGRect
    /// Fragments reproduced verbatim (URLs, paths, code, identifiers).
    var protectedFragments: [String]
}

struct SkippedRegion: Equatable, Sendable {
    var regionID: String
    var reason: String
}

enum DesktopPlanError: Error, Equatable, CustomStringConvertible {
    case missing([String]), unexpected([String]), duplicate([String]), empty([String])

    var description: String {
        switch self {
        case .missing(let ids): return "missing translations: \(ids.joined(separator: ", "))"
        case .unexpected(let ids): return "unexpected translations: \(ids.joined(separator: ", "))"
        case .duplicate(let ids): return "duplicate translations: \(ids.joined(separator: ", "))"
        case .empty(let ids): return "empty translations: \(ids.joined(separator: ", "))"
        }
    }
}

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

struct DesktopPlan {
    private enum Part {
        case literal(String)
        case protected(String)
        case request(key: String, text: String)
    }

    private struct Planned {
        var region: TextRegion
        var parts: [Part]
    }

    let snapshotID: UUID
    let skipped: [SkippedRegion]
    private let planned: [Planned]

    /// Request id: `<escaped regionID>/<pieceKey>`. Escaping makes the mapping injective.
    static func requestID(region: String, piece: String) -> String {
        let escaped = region.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
        return "\(escaped)/\(piece)"
    }

    init(snapshot: CaptureSnapshot) {
        snapshotID = snapshot.id
        var planned: [Planned] = []
        var skipped: [SkippedRegion] = []
        var seen = Set<String>()
        for region in snapshot.regions.sorted(by: { $0.readingOrder < $1.readingOrder }) {
            guard seen.insert(region.id).inserted else {
                skipped.append(SkippedRegion(regionID: region.id, reason: "duplicate region id")); continue
            }
            var parts: [Part] = []
            switch region.kind.category {
            case .protected:
                skipped.append(SkippedRegion(regionID: region.id, reason: "protected kind \(region.kind.rawValue)"))
                continue
            case .ui, .prose:
                let joined = region.text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
                var n = 0
                for piece in UITextSegmenter.segment(joined) {
                    switch piece {
                    case .literal(let s): parts.append(.literal(s))
                    case .protected(let s): parts.append(.protected(s))
                    case .text(let s):
                        parts.append(.request(key: "t\(n)", text: s)); n += 1
                    }
                }
            case .terminal:
                let continuations = OCRGrouper.visualContinuationLines(text: region.text, rects: region.lineRects)
                for piece in TranslationPlan(text: region.text, visualContinuationLines: continuations).pieces {
                    switch piece {
                    case .literal(let s):
                        parts.append(s.allSatisfy { $0.isWhitespace } ? .literal(s) : .protected(s))
                    case .prose(let id, let text): parts.append(.request(key: id, text: text))
                    }
                }
            }
            guard parts.contains(where: { if case .request = $0 { return true } else { return false } }) else {
                skipped.append(SkippedRegion(regionID: region.id, reason: "nothing to translate")); continue
            }
            planned.append(Planned(region: region, parts: parts))
        }
        self.planned = planned
        self.skipped = skipped
    }

    var requests: [(id: String, text: String)] {
        planned.flatMap { p in
            p.parts.compactMap { part -> (id: String, text: String)? in
                if case .request(let key, let text) = part { return (Self.requestID(region: p.region.id, piece: key), text) }
                return nil
            }
        }
    }

    /// Original on-screen rectangles (window-local points) this plan can paint over: exactly the occupied
    /// rectangles `OverlayItem.make` would use for every planned (translatable) region, computed from OCR line
    /// rectangles only. Protected/skipped regions are absent. Per-line rectangles stay separate (no union, no gap fill).
    /// Overflowing items are included: whether a translation fits is unknown before translation, so this is a superset.
    func replacedSourceRects(snapshot: CaptureSnapshot, selection: CGRect) -> [CGRect] {
        guard snapshot.id == snapshotID else { return [] }
        let bounds = CGRect(origin: .zero, size: snapshot.target.frame.size)
        let parents = Dictionary(snapshot.layout.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        return planned.flatMap { p -> [CGRect] in
            let source = p.region.lineRects.isEmpty ? [p.region.rect] : p.region.lineRects
            return OccupiedGeometry.rects(source: source, parent: p.region.parentID.flatMap { parents[$0] }, bounds: bounds, selection: selection)
        }
    }

    func rendered(translations: [String: String]) throws -> [RegionTranslation] {
        try render(translations, duplicates: [])
    }

    /// Same as the dictionary form but reports ids that appear more than once.
    func rendered(pairs: [(id: String, text: String)]) throws -> [RegionTranslation] {
        var dict: [String: String] = [:]
        var duplicates: [String] = []
        for p in pairs {
            if dict.updateValue(p.text, forKey: p.id) != nil { duplicates.append(p.id) }
        }
        return try render(dict, duplicates: duplicates)
    }

    private func render(_ translations: [String: String], duplicates: [String]) throws -> [RegionTranslation] {
        if !duplicates.isEmpty { throw DesktopPlanError.duplicate(Array(Set(duplicates)).sorted()) }
        let expected = Set(requests.map { $0.id })
        let extra = Set(translations.keys).subtracting(expected)
        if !extra.isEmpty { throw DesktopPlanError.unexpected(extra.sorted()) }
        let missing = expected.subtracting(translations.keys)
        if !missing.isEmpty { throw DesktopPlanError.missing(missing.sorted()) }
        let empty = translations.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.keys
        if !empty.isEmpty { throw DesktopPlanError.empty(empty.sorted()) }

        return planned.map { p in
            var text = ""
            var fragments: [String] = []
            for part in p.parts {
                switch part {
                case .literal(let s): text += s
                case .protected(let s):
                    text += s
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { fragments.append(trimmed) }
                case .request(let key, _):
                    text += translations[Self.requestID(region: p.region.id, piece: key)] ?? ""
                }
            }
            let rects = p.region.lineRects.isEmpty ? [p.region.rect] : p.region.lineRects
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            return RegionTranslation(regionID: p.region.id, parentID: p.region.parentID, kind: p.region.kind,
                                     readingOrder: p.region.readingOrder, original: p.region.text, text: text,
                                     rects: rects, unionRect: union, protectedFragments: fragments)
        }
    }
}
