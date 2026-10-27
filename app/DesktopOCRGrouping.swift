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

    struct Line {
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

    struct Paragraph {
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
        /// Geometry of lines that never became regions (low confidence, straddle-omitted). Debug display only.
        var marks: [DebugMark] = []
    }
    static let straddleWarning = "部分文字跨越窗格或控件边界且无法逐词确认，未覆盖这些文字。"

    static func group(_ observations: [OCRObservation], crop: CGRect, target: CaptureTarget,
                      layout: [LayoutRegion] = [], unicode: Bool = false) -> [TextRegion] {
        grouped(observations, crop: crop, target: target, layout: layout, unicode: unicode).regions
    }

    static func grouped(_ observations: [OCRObservation], crop: CGRect, target: CaptureTarget,
                        layout: [LayoutRegion] = [], unicode: Bool = false) -> GroupedOCR {
        let bounds = CGRect(origin: .zero, size: target.frame.size)
        let containers = layout.sorted { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        var lines: [Line] = []
        var omitted = 0
        var marks: [DebugMark] = []
        func mark(_ kind: DebugMark.Kind, _ n: CGRect) {
            guard [n.minX, n.minY, n.width, n.height].allSatisfy({ $0.isFinite }), n.width > 0, n.height > 0 else { return }
            let local = CoordinateMapper.visionToLocal(n, crop: crop).intersection(bounds)
            guard !local.isNull, local.width > 0, local.height > 0 else { return }
            marks.append(DebugMark(kind: kind, rects: [local]))
        }
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
            guard !words.isEmpty else { omitted += 1; marks.append(DebugMark(kind: .straddleOmitted, rects: [local])); return }
            var runs: [(words: [OCRWord], rect: CGRect)] = []
            var runOwner: [String?] = []
            for w in words {
                let wl = CoordinateMapper.visionToLocal(w.normalizedBox, crop: crop).intersection(bounds)
                guard !wl.isNull, wl.width > 0, wl.height > 0, !straddles(wl) else {
                    omitted += 1; marks.append(DebugMark(kind: .straddleOmitted, rects: [local])); return
                }
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
            guard o.confidence.isFinite, o.confidence >= minimumConfidence else { mark(.lowConfidence, o.normalizedBox); continue }
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
                let candidate = terminal ? joinGap(p, line, ctx) : paragraphGap(p, line, ctx, omitted: marks.flatMap(\.rects), unicode: unicode)
                guard let gap = candidate, gap < bestGap else { continue }
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
        let proseLines = terminal ? TranslationPlan(text: lines.map { $0.text }.joined(separator: "\n"), unicode: unicode).proseLineIndices : []
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
                              lineRects: rects, readingOrder: index, isParagraphBlock: !terminal && b.lines.count > 1)
        }
        return GroupedOCR(regions: regions, omittedObservations: omitted, marks: marks)
    }

    /// The five terminal apps (exact bundle IDs). Their OCR text is never treated as UI labels.
    static let terminalBundleIDs: Set<String> = ["com.cmuxterm.app", "com.googlecode.iterm2", "com.apple.Terminal",
                                                 "com.mitchellh.ghostty", "fun.tw93.kaku"]

}
