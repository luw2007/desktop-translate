import CoreGraphics
import Foundation

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
    /// Rule that rejected a "nothing to translate" region (counts only; never text). nil for protected/duplicate skips.
    var detail: SkipReason? = nil
    /// Protected strings retained from the plan's pieces (see `DesktopPlan.plannedProtectedFragments`); empty for
    /// protected-kind and duplicate-id skips, whose pieces are never built.
    var protectedFragments: [String] = []
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
        /// `tokens`: protected fragments that sit inside `text` (inline code, paths, units) and must stay verbatim.
        case request(key: String, text: String, tokens: [String])
    }

    private struct Planned {
        var region: TextRegion
        var parts: [Part]
    }

    /// Prefix of `SkippedRegion.reason` for regions of a protected kind (counted separately in logs and the debug overlay).
    static let protectedReasonPrefix = "protected kind "

    let snapshotID: UUID
    let skipped: [SkippedRegion]
    private let planned: [Planned]

    /// Read-only: per PLANNED region id, the protected strings retained by the plan before any translation exists
    /// (verbatim protected pieces plus tokens embedded in requests), in text order, trimmed, empties dropped. No
    /// reclassification. Skipped regions carry theirs in `SkippedRegion.protectedFragments`.
    var plannedProtectedFragments: [String: [String]] {
        Dictionary(uniqueKeysWithValues: planned.map { ($0.region.id, Self.retainedFragments($0.parts)) })
    }

    private static func retainedFragments(_ parts: [Part]) -> [String] {
        parts.flatMap { part -> [String] in
            switch part {
            case .protected(let s): return [s]
            case .request(_, _, let tokens): return tokens
            case .literal: return []
            }
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Request id: `<escaped regionID>/<pieceKey>`. Escaping makes the mapping injective.
    static func requestID(region: String, piece: String) -> String {
        let escaped = region.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
        return "\(escaped)/\(piece)"
    }

    /// `unicode`: language-general segmentation for non-English sources (see `TranslationPlan`). Must be the same value
    /// everywhere one snapshot is planned (translation and freshness areas). `target`: the target language code; text
    /// already confidently entirely in it is not requested (skip reason `.target`). `nil` never skips for that reason.
    init(snapshot: CaptureSnapshot, unicode: Bool = false, target: String? = nil) {
        snapshotID = snapshot.id
        var planned: [Planned] = []
        var skipped: [SkippedRegion] = []
        var terminalReason: SkipReason?
        var embeddedTokens: [String: [String]] = [:]
        var seen = Set<String>()
        for region in snapshot.regions.sorted(by: { $0.readingOrder < $1.readingOrder }) {
            guard seen.insert(region.id).inserted else {
                skipped.append(SkippedRegion(regionID: region.id, reason: "duplicate region id")); continue
            }
            var parts: [Part] = []
            terminalReason = nil
            switch region.kind.category {
            case .protected:
                skipped.append(SkippedRegion(regionID: region.id, reason: "\(Self.protectedReasonPrefix)\(region.kind.rawValue)"))
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
                        if TargetLanguage.covers(s, target: target) { parts.append(.literal(s)); continue }
                        parts.append(.request(key: "t\(n)", text: s, tokens: [])); n += 1
                    }
                }
            case .terminal:
                let continuations = OCRGrouper.visualContinuationLines(text: region.text, rects: region.lineRects)
                let terminalPlan = TranslationPlan(text: region.text, visualContinuationLines: continuations, unicode: unicode, target: target)
                terminalReason = terminalPlan.skipReason
                embeddedTokens = terminalPlan.embeddedTokens
                for piece in terminalPlan.pieces {
                    switch piece {
                    case .literal(let s):
                        parts.append(s.allSatisfy { $0.isWhitespace } ? .literal(s) : .protected(s))
                    case .prose(let id, let text): parts.append(.request(key: id, text: text, tokens: embeddedTokens[id] ?? []))
                    }
                }
            }
            guard parts.contains(where: { if case .request = $0 { return true } else { return false } }) else {
                let detail = terminalReason ?? Self.uiSkipReason(region.text, target: target)
                // K = nothing to translate; code, commands, flags, identifiers, hosts are protected originals (P).
                skipped.append(SkippedRegion(regionID: region.id,
                                             reason: detail.isNothingToTranslate ? "nothing to translate" : "\(Self.protectedReasonPrefix)\(detail.rawValue)",
                                             detail: detail, protectedFragments: Self.retainedFragments(parts))); continue
            }
            planned.append(Planned(region: region, parts: parts))
        }
        self.planned = planned
        self.skipped = skipped
    }

    /// Why a UI/prose region (no terminal plan) produced no word run: already in the target language, every token was
    /// protected, or nothing but non-letters.
    private static func uiSkipReason(_ text: String, target: String?) -> SkipReason {
        if TargetLanguage.covers(text, target: target) { return .target }
        for piece in UITextSegmenter.segment(text) {
            if case .protected(let s) = piece { return SkipReason.token(Substring(s)) }
        }
        return text.contains(where: { $0.isNumber }) ? .number : .symbols
    }

    var requests: [(id: String, text: String)] {
        planned.flatMap { p in
            if p.region.isParagraphBlock {
                return [(Self.requestID(region: p.region.id, piece: "whole"), p.region.text.replacingOccurrences(of: "\n", with: " "))]
            }
            return p.parts.compactMap { part -> (id: String, text: String)? in
                if case .request(let key, let text, _) = part { return (Self.requestID(region: p.region.id, piece: key), text) }
                return nil
            }
        }
    }

    /// Original on-screen rectangles (window-local points) this plan can paint over: exactly the occupied
    /// rectangles `OverlayItem.make` would use for every planned (translatable) region, computed from OCR line
    /// rectangles only, PLUS each line's pixel-proven free strip to its right (`TextRegion.freeRight`, measured on the
    /// same held original at capture). The strips are part of the one immutable baseline taken from that original, so
    /// every pixel an extended translation may cover is freshness-verified exactly like the source lines; nothing is
    /// ever added to the baseline afterwards. Protected/skipped regions are absent. Per-line rectangles stay separate
    /// (no union, no gap fill). Overflowing items are included: whether a translation fits is unknown before translation.
    func replacedSourceRects(snapshot: CaptureSnapshot, selection: CGRect) -> [CGRect] {
        guard snapshot.id == snapshotID else { return [] }
        let bounds = CGRect(origin: .zero, size: snapshot.target.frame.size)
        let parents = Dictionary(snapshot.layout.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        return planned.flatMap { p -> [CGRect] in
            let source = p.region.paintSourceRects
            let parent = p.region.parentID.flatMap { parents[$0] }
            return source.enumerated().compactMap { index, line in
                guard let base = OccupiedGeometry.rects(source: [line], parent: parent, bounds: bounds, selection: selection).first else { return nil }
                return FreeSpace.extended(line: base, index: index, owner: p.region, parent: parent, bounds: bounds,
                                          selection: selection, regions: snapshot.regions)
            }
        }
    }

    func rendered(translations: [String: String]) throws -> [RegionTranslation] {
        try render(translations, duplicates: [])
    }

    /// Image mode: the model translated each WHOLE region. Every planned region must have a nonempty translation, and
    /// every protected fragment (code, paths, identifiers found by the same local segmentation as OCR mode) must appear
    /// verbatim in it; otherwise the region set is refused (never repaired or partially shown). Translations of
    /// regions the plan skipped (protected kinds, nothing to translate) are ignored: those stay untouched.
    func renderedWhole(translations: [String: String]) throws -> [RegionTranslation] {
        let ids = planned.map(\.region.id)
        let missing = ids.filter { translations[$0] == nil }
        if !missing.isEmpty { throw DesktopPlanError.missing(missing.sorted()) }
        let empty = ids.filter { translations[$0]!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !empty.isEmpty { throw DesktopPlanError.empty(empty.sorted()) }
        return try planned.map { p in
            let text = translations[p.region.id]!
            let fragments = try Self.protectedFragments(p, in: text)
            let rects = p.region.paintSourceRects
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            return RegionTranslation(regionID: p.region.id, parentID: p.region.parentID, kind: p.region.kind,
                                     readingOrder: p.region.readingOrder, original: p.region.text, text: text,
                                     rects: rects, unionRect: union, protectedFragments: fragments)
        }
    }

    private static func protectedFragments(_ p: Planned, in text: String) throws -> [String] {
        try p.parts.flatMap { part -> [String] in
            let candidates: [String]
            switch part {
            case .protected(let s): candidates = [s]
            case .request(_, _, let tokens): candidates = tokens
            case .literal: candidates = []
            }
            return try candidates.compactMap { s in
                let fragment = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fragment.isEmpty else { return nil }
                guard text.contains(fragment) else { throw DesktopPlanError.missing([p.region.id]) }
                return fragment
            }
        }
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

        return try planned.map { p in
            var text = ""
            var fragments: [String] = []
            if p.region.isParagraphBlock {
                text = translations[Self.requestID(region: p.region.id, piece: "whole")]!
                fragments = try Self.protectedFragments(p, in: text)
            } else { for part in p.parts {
                switch part {
                case .literal(let s): text += s
                case .protected(let s):
                    text += s
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { fragments.append(trimmed) }
                case .request(let key, _, let tokens):
                    let translated = translations[Self.requestID(region: p.region.id, piece: key)] ?? ""
                    text += translated
                    // Embedded tokens that the translation kept verbatim are reported as protected fragments.
                    fragments += tokens.filter { !$0.isEmpty && translated.contains($0) }
                }
            } }
            let rects = p.region.paintSourceRects
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            return RegionTranslation(regionID: p.region.id, parentID: p.region.parentID, kind: p.region.kind,
                                     readingOrder: p.region.readingOrder, original: p.region.text, text: text,
                                     rects: rects, unionRect: union, protectedFragments: fragments)
        }
    }
}
