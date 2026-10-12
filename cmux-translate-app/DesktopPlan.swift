import CoreGraphics
import Foundation

// MARK: - OCR grouping

struct OCRObservation: Equatable, Sendable {
    var text: String
    var confidence: Double
    /// Vision convention: normalized to the cropped image, origin bottom-left.
    var normalizedBox: CGRect

    init(text: String, confidence: Double, normalizedBox: CGRect) {
        self.text = text; self.confidence = confidence; self.normalizedBox = normalizedBox
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
    }

    private struct Paragraph {
        var lines: [Line]
        var maxWidth: CGFloat
        var left: CGFloat
    }

    /// Turn raw Vision lines into regions. Wrapped lines of one paragraph (same parent, adjacent, aligned,
    /// equal height, previous line full and not sentence-final) become one `.prose` region; short isolated
    /// lines stay separate `.label` regions so controls are never merged with neighbours or across parents.
    static func group(_ observations: [OCRObservation], crop: CGRect, target: CaptureTarget,
                      layout: [LayoutRegion] = []) -> [TextRegion] {
        let bounds = CGRect(origin: .zero, size: target.frame.size)
        let containers = layout.sorted { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        var lines: [Line] = []
        for o in observations {
            let text = o.text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let n = o.normalizedBox
            guard !text.isEmpty, o.confidence.isFinite, o.confidence >= minimumConfidence,
                  [n.minX, n.minY, n.width, n.height].allSatisfy({ $0.isFinite }), n.width > 0, n.height > 0
            else { continue }
            let local = CoordinateMapper.visionToLocal(n, crop: crop).intersection(bounds)
            guard !local.isNull, local.width > 0, local.height > 0 else { continue }
            let center = CGPoint(x: local.midX, y: local.midY)
            let parent = containers.first { $0.rect.contains(center) }?.id
            lines.append(Line(text: text, rect: local, confidence: o.confidence, parent: parent, words: asciiWordCount(text)))
        }
        lines.sort { $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }

        var paragraphs: [Paragraph] = []
        for line in lines {
            var best: Int?
            var bestGap = CGFloat.infinity
            for (i, p) in paragraphs.enumerated() {
                guard let gap = joinGap(p, line), gap < bestGap else { continue }
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

        return paragraphs.enumerated().map { index, p in
            let rects = p.lines.map { $0.rect }
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let text = p.lines.map { $0.text }.joined(separator: "\n")
            let confidence = p.lines.reduce(0) { $0 + $1.confidence } / Double(p.lines.count)
            let kind: RegionKind
            if p.lines.count > 1 || p.lines[0].words >= 4 {
                kind = .prose
            } else if !text.contains(where: { $0.isWhitespace }) && (text.hasPrefix("/") || text.hasPrefix("~") || text.contains("://")) {
                kind = .path
            } else {
                kind = .label
            }
            return TextRegion(id: "ocr-\(index)", parentID: p.lines[0].parent, kind: kind, source: .ocr,
                              rect: union, text: text, confidence: min(1, max(0, confidence)),
                              lineRects: rects, readingOrder: index)
        }
    }

    /// Vertical gap if `line` continues paragraph `p`, else nil.
    private static func joinGap(_ p: Paragraph, _ line: Line) -> CGFloat? {
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
        if p.lines.count == 1 {
            guard a.words >= 4 else { return nil }
        } else {
            guard a.rect.width >= 0.75 * p.maxWidth else { return nil }
        }
        return gap
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
            let hasRealWord = run[lo..<hi].contains { $0.kind == .word && letterCount($0.text) >= 2 }
            if hasRealWord { pieces.append(.text(body)) } else { literal(body) }
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

    private static func letterCount(_ s: String) -> Int { s.filter { $0.isASCII && $0.isLetter }.count }

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
                for piece in TranslationPlan(text: region.text).pieces {
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
