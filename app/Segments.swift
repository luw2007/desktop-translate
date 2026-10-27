import Foundation

/// Why a recognized line/region was not turned into a translation request. Counts only ever leave the process (never text).
/// Informational: `TranslationPlan.verdict` decides; this names the rule that fired.
enum SkipReason: String, CaseIterable {
    case empty, symbols, prompt, command, diff, code, fence
    case path, url, hash, flag, identifier, number, host
    /// Already entirely in the target language (`TargetLanguage.covers`). Also used for text that has no letters of the
    /// English source (e.g. a pure Chinese line when the source is English), which can never be translated from it.
    case target

    /// `true` for the "nothing to translate" (K) rules: empty, symbols, numbers/times/units/versions, a pure URL, a pure
    /// filesystem path, a pure hash, or text already in the target language. Every other rule (code, commands, prompts,
    /// diffs, fences, flags, identifiers, hosts) protects the original (P).
    var isNothingToTranslate: Bool {
        switch self {
        case .empty, .symbols, .number, .url, .path, .hash, .target: return true
        case .prompt, .command, .diff, .code, .fence, .flag, .identifier, .host: return false
        }
    }

    /// Classifies one whitespace-free token that is not natural-language text.
    static func token(_ token: Substring) -> SkipReason {
        let s = String(token)
        if s.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return .symbols }
        if s.contains("://") || s.hasPrefix("www.") { return .url }
        if s.contains("/") || s.contains("\\") || s.hasPrefix("~") { return .path }
        var core = Substring(s)
        while let f = core.first, !f.isLetter && !f.isNumber { core = core.dropFirst() }
        while let l = core.last, !l.isLetter && !l.isNumber { core = core.dropLast() }
        if s.hasPrefix("-"), let second = s.dropFirst().first {
            if second.isNumber { return .number }
            if second.isLetter || second == "-" { return .flag }
        }
        if s.contains("@") { return .host }
        let dotted = s.split(separator: ".", omittingEmptySubsequences: false)
        if dotted.count == 4, dotted.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) { return .host }
        if [".com", ".org", ".net", ".io", ".dev", ".local"].contains(where: { s.contains($0) }) { return .host }
        if core.contains(where: { $0.isNumber }), core.allSatisfy({ ($0.isASCII && $0.isNumber) || ".,:-+%".contains($0) }) { return .number }
        if TranslationPlan.isNumberWithUnit(Substring(s)) || TranslationPlan.isVersion(core) { return .number }
        if core.count >= 7, core.allSatisfy({ $0.isHexDigit }), core.contains(where: { $0.isNumber }) { return .hash }
        return .identifier
    }
}

enum TranslationPiece {
    case literal(String)
    case prose(id: String, text: String)
}

struct TranslationPlan {
    let pieces: [TranslationPiece]
    let proseLineIndices: Set<Int>
    /// Rule that rejected each non-blank non-prose line (and each prose line whose content is entirely protected).
    let skipReasons: [SkipReason]
    /// Protected tokens (inline code, paths, URLs, identifiers, units, `❯ cmd`) that sit INSIDE the request of a prose
    /// piece, keyed by piece id. The translation must keep each verbatim.
    let embeddedTokens: [String: [String]]

    /// Indices of visual lines whose boundary with the preceding line is independently measured.
    /// Only whole, undecorated prose lines can merge; protected fragments and syntax remain literal.
    /// `unicode` is accepted for source compatibility and ignored: the language-general heuristics (any letter is a word;
    /// no lowercase requirement) always apply, whatever the source language. `target` is the target language code;
    /// text confidently entirely in it is not requested (skip reason `.target`).
    init(text: String, visualContinuationLines: Set<Int> = [], unicode _: Bool = false, target: String? = nil) {
        let unicode = true
        var result: [TranslationPiece] = []
        var nextID = 0
        var fence: (character: Character, count: Int)?
        var previousWasProse = false
        var inDiff = false
        let rowMarkers: [Character?] = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map { row in
            let t = row.drop(while: { $0 == " " || $0 == "\t" })
            return (t.hasPrefix("- ") || t.hasPrefix("+ ")) ? t.first : nil
        }
        var lineIndex = 0
        var proseLines = Set<Int>()
        var skipReasons: [SkipReason] = []
        var embedded: [String: [String]] = [:]

        func literal(_ value: Substring) {
            guard !value.isEmpty else { return }
            result.append(.literal(String(value)))
        }
        func prose(_ value: Substring, embeddedTokens tokens: [String] = []) {
            guard !value.isEmpty else { return }
            let leading = value.prefix(while: { $0.isWhitespace })
            let remainder = value.dropFirst(leading.count)
            let trailing = remainder.reversed().prefix(while: { $0.isWhitespace }).count
            let core = remainder.dropLast(trailing)
            literal(leading)
            if core.contains(where: { $0.isLetter }), !TargetLanguage.covers(String(core), target: target) {
                let id = "prose-\(nextID)"
                result.append(.prose(id: id, text: String(core)))
                if !tokens.isEmpty { embedded[id] = tokens }
                nextID += 1
            } else {
                literal(core)
            }
            literal(remainder.suffix(trailing))
        }

        // Scan rather than split: CRLF, lone CR, trailing newlines and empty
        // lines must survive reconstruction byte-for-byte.
        var start = text.startIndex
        while start < text.endIndex {
            var end = start
            while end < text.endIndex && text[end] != "\n" && text[end] != "\r" && text[end] != "\r\n" {
                end = text.index(after: end)
            }
            let line = text[start..<end]
            var next = end
            if next < text.endIndex {
                let separator = text[next]
                next = text.index(after: next)
                if separator == "\r", next < text.endIndex, text[next] == "\n" {
                    next = text.index(after: next)
                }
            }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if ["diff ", "@@", "+++ ", "--- ", "index "].contains(where: { trimmed.hasPrefix($0) }) { inDiff = true }
            else if trimmed.isEmpty || ["$", "%", ">"].contains(where: { trimmed.hasPrefix($0) }) { inDiff = false }
            // A "- "/"+ " row is a diff row, not a bullet, inside a diff hunk or next to an opposite-marker row.
            var diffRow = inDiff
            if let m = lineIndex < rowMarkers.count ? rowMarkers[lineIndex] : nil {
                for n in [lineIndex - 1, lineIndex + 1] where n >= 0 && n < rowMarkers.count {
                    if let o = rowMarkers[n], o != m { diffRow = true }
                }
            }
            let pieceStart = result.count
            let marker = Self.fenceMarker(trimmed)
            let lineVerdict = Self.verdict(trimmed, continuation: previousWasProse, unicode: unicode, diffRow: diffRow, target: target)
            if let active = fence {
                literal(line)
                if !trimmed.isEmpty { skipReasons.append(.fence) }
                if let marker, marker.character == active.character,
                   marker.count >= active.count, marker.tail.allSatisfy({ $0.isWhitespace }) {
                    fence = nil
                }
                previousWasProse = false
            } else if let marker {
                literal(line)
                fence = (marker.character, marker.count)
                previousWasProse = false
            } else if lineVerdict == nil {
                // Keep indentation and list decorations outside the request.
                let body = Self.proseBody(trimmed)
                let mergeAround = unicode
                literal(line[..<body.startIndex])
                // Fragments of the body: plain text or a protected token (inline code, path, URL, identifier, unit, `❯ cmd`).
                var frags: [(range: Range<Substring.Index>, isProtected: Bool)] = []
                var cursor = body.startIndex
                var fragmentStart = cursor
                func closeFragment(upTo end: Substring.Index) {
                    if fragmentStart < end { frags.append((fragmentStart..<end, false)) }
                }
                while cursor < body.endIndex {
                    if body[cursor] == "`" {
                        closeFragment(upTo: cursor)
                        let opening = cursor
                        var count = 0
                        while cursor < body.endIndex, body[cursor] == "`" {
                            count += 1
                            cursor = body.index(after: cursor)
                        }
                        var closed = false
                        while cursor < body.endIndex {
                            if body[cursor] == "`" {
                                let runStart = cursor
                                var run = 0
                                while cursor < body.endIndex, body[cursor] == "`" {
                                    run += 1
                                    cursor = body.index(after: cursor)
                                }
                                if run == count { closed = true; break }
                                if runStart == cursor { break }
                            } else {
                                cursor = body.index(after: cursor)
                            }
                        }
                        // An unmatched backtick protects the remainder, not a
                        // synthetic placeholder that the translator might alter.
                        frags.append((opening..<cursor, true))
                        fragmentStart = cursor
                        if !closed { break }
                    } else if !body[cursor].isWhitespace {
                        let tokenStart = cursor
                        if let end = Self.promptCommandEnd(body, from: tokenStart) {
                            closeFragment(upTo: tokenStart)
                            frags.append((tokenStart..<end, true))
                            cursor = end
                            fragmentStart = end
                            continue
                        }
                        while cursor < body.endIndex, !body[cursor].isWhitespace, body[cursor] != "`" {
                            cursor = body.index(after: cursor)
                        }
                        let chunk = body[tokenStart..<cursor]
                        if chunk.allSatisfy({ $0.isASCII }) {
                            if Self.isProtectedToken(chunk) {
                                closeFragment(upTo: tokenStart)
                                frags.append((tokenStart..<cursor, true))
                                fragmentStart = cursor
                            }
                        } else {
                            // Mixed CJK/ASCII chunk: only the ASCII technical tokens are protected, never their CJK neighbours.
                            for range in Self.asciiTokenRanges(in: chunk) {
                                closeFragment(upTo: range.lowerBound)
                                frags.append((range, true))
                                fragmentStart = range.upperBound
                            }
                        }
                    } else {
                        cursor = body.index(after: cursor)
                    }
                }
                closeFragment(upTo: body.endIndex)
                // Non-ASCII prose (CJK, ...) that merely CONTAINS technical tokens is translated as one request (tokens stay
                // verbatim inside it, reported via `embeddedTokens`). Other lines keep one request per text fragment.
                let textFragments = frags.indices.filter { index in
                    !frags[index].isProtected
                        && body[frags[index].range].contains(where: { $0.isLetter })
                }
                // Predominance is judged on the text fragments only: tokens inside `git status` / URLs do not outvote the prose.
                let proseText = Substring(textFragments.map { String(body[frags[$0].range]) }.joined(separator: " "))
                if mergeAround, !textFragments.isEmpty, Self.isNonASCIIProse(proseText, minimum: 2) {
                    // The whole body is the request: word order differs across languages, so tokens at either end stay inside.
                    let tokens = frags.filter { $0.isProtected }.map { String(body[$0.range]).trimmingCharacters(in: .whitespacesAndNewlines) }
                    prose(body, embeddedTokens: tokens)
                } else {
                    for fragment in frags {
                        if fragment.isProtected { literal(body[fragment.range]) } else { prose(body[fragment.range]) }
                    }
                }
                if !result[pieceStart...].contains(where: { if case .prose = $0 { return true }; return false }) {
                    skipReasons.append(Self.protectedReason(body, target: target))
                }
                previousWasProse = true
            } else {
                literal(line)
                if let lineVerdict, lineVerdict != .empty { skipReasons.append(lineVerdict) }
                previousWasProse = false
            }
            if result[pieceStart...].contains(where: { if case .prose = $0 { return true }; return false }) {
                proseLines.insert(lineIndex)
            }
            // A visual wrap continues the previous prose; an indented continuation (whitespace-only literal first) joins too.
            if visualContinuationLines.contains(lineIndex), pieceStart >= 2 {
                var tail = pieceStart
                if case .literal(let indent) = result[tail], indent.allSatisfy({ $0 == " " || $0 == "\t" }), result.count > tail + 1 { tail += 1 }
                if result.count == tail + 1,
                   case .prose(let currentID, let current) = result[tail],
                   case .literal(let separator) = result[pieceStart - 1],
                   separator == "\n" || separator == "\r" || separator == "\r\n",
                   case .prose(let id, let previous) = result[pieceStart - 2] {
                    result.replaceSubrange((pieceStart - 2)...tail, with: [.prose(id: id, text: previous + " " + current)])
                    if let more = embedded.removeValue(forKey: currentID) { embedded[id, default: []] += more }
                }
            }
            literal(text[end..<next])
            start = next
            lineIndex += 1
        }
        pieces = result
        proseLineIndices = proseLines
        self.skipReasons = skipReasons
        embeddedTokens = embedded
    }

    /// The most frequent rule that rejected a line of this plan (first seen wins ties); `.empty` when none did.
    var skipReason: SkipReason {
        var counts: [SkipReason: Int] = [:]
        var order: [SkipReason] = []
        for reason in skipReasons {
            if counts[reason] == nil { order.append(reason) }
            counts[reason, default: 0] += 1
        }
        var best: SkipReason = .empty
        var bestCount = 0
        for reason in order where counts[reason]! > bestCount { best = reason; bestCount = counts[reason]! }
        return best
    }

    var requests: [(id: String, text: String)] {
        pieces.compactMap {
            if case let .prose(id, text) = $0 { return (id: id, text: text) }
            return nil
        }
    }

    func rendered(translations: [String: String]) -> String {
        var output = ""
        for piece in pieces {
            switch piece {
            case let .literal(text): output.append(text)
            case let .prose(id, text): output.append(translations[id] ?? text)
            }
        }
        return output
    }
}
