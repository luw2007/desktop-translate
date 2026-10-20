import Foundation
import NaturalLanguage

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

    private static func fenceMarker(_ line: Substring) -> (character: Character, count: Int, tail: Substring)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        return (first, run.count, line.dropFirst(run.count))
    }

    private static func proseBody(_ line: Substring) -> Substring {
        var line = line
        // Markdown heading / line-comment markers followed by a space stay outside the request.
        let marker = line.hasPrefix("#") ? line.prefix(while: { $0 == "#" }) : (line.hasPrefix("// ") ? line.prefix(2) : line.prefix(0))
        if !marker.isEmpty {
            let rest = line.dropFirst(marker.count)
            if rest.first == " " || rest.first == "\t" { line = rest.drop(while: { $0 == " " || $0 == "\t" }) }
        }
        // Leading decoration glyphs (TUI status marks, bullets, box drawing: whitespace-separated tokens made only of
        // non-ASCII symbols) stay outside the request so "✓ Complete" translates "Complete".
        while let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }), isDecoration(line[..<space]) {
            line = line[space...].drop(while: { $0 == " " || $0 == "\t" })
        }
        for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
            return line.dropFirst(prefix.count)
        }
        // OCR often glues the bullet dash to CJK text ("-两个译文"): still a bullet marker.
        if hasGluedBulletDash(line) { return line.dropFirst() }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return rest.dropFirst(2) }
        }
        return line
    }

    /// At least `minimum` non-ASCII letters (CJK, kana, Hangul, ...) that make up at least half of all letters.
    private static func isNonASCIIProse(_ line: Substring, minimum: Int) -> Bool {
        var nonASCII = 0, letters = 0
        for c in line where c.isLetter {
            letters += 1
            if !c.isASCII { nonASCII += 1 }
        }
        return nonASCII >= minimum && nonASCII * 2 >= letters
    }

    /// "-" glued to the text of a non-ASCII prose line ("-两个译文不会叠在一起画。", "-6pt 见方的块"): a bullet, not a flag or number.
    static func hasGluedBulletDash(_ line: Substring) -> Bool {
        guard line.hasPrefix("-"), !line.hasPrefix("--"), !line.hasPrefix("- "), line.count > 1 else { return false }
        return isNonASCIIProse(line, minimum: 2)
    }

    /// A prose line that starts a list item ("- ", "* ", "• ", "+ ", "1. ", glued "-中文"): it never continues the previous line.
    static func startsListItem(_ text: String) -> Bool {
        let line = Substring(text.trimmingCharacters(in: .whitespaces))
        if ["- ", "* ", "• ", "+ "].contains(where: { line.hasPrefix($0) }) { return true }
        if hasGluedBulletDash(line) { return true }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        return !digits.isEmpty && (line.dropFirst(digits.count).hasPrefix(". ") || line.dropFirst(digits.count).hasPrefix(") "))
    }

    /// "❯ git status" inside a sentence: the prompt glyph, the command word and its ASCII-only arguments form one
    /// protected fragment. Returns the end of that fragment, or nil when `start` is not such a prompt.
    private static func promptCommandEnd(_ body: Substring, from start: Substring.Index) -> Substring.Index? {
        guard "❯➜›$".contains(body[start]) else { return nil }
        var cursor = body.index(after: start)
        guard cursor < body.endIndex, isWhitespaceOrTab(body[cursor]) else { return nil }
        var end: Substring.Index?
        var isFirstWord = true
        while true {
            while cursor < body.endIndex, isWhitespaceOrTab(body[cursor]) { cursor = body.index(after: cursor) }
            let wordStart = cursor
            while cursor < body.endIndex, body[cursor].isASCII, !body[cursor].isWhitespace, body[cursor] != "`" {
                cursor = body.index(after: cursor)
            }
            guard wordStart < cursor else { break }
            if isFirstWord {
                guard commandWords.contains(String(body[wordStart..<cursor])) else { return nil }
                isFirstWord = false
            }
            end = cursor
            if cursor < body.endIndex, !body[cursor].isWhitespace { break }
        }
        return end
    }

    private static func isDecoration(_ token: Substring) -> Bool {
        !token.isEmpty && token.allSatisfy { !$0.isASCII && !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
    }

    /// The rule behind a prose line whose fragments are all protected tokens (or already in the target language).
    private static func protectedReason(_ body: Substring, target: String?) -> SkipReason {
        for token in body.split(whereSeparator: { $0.isWhitespace }) where isProtectedToken(token) { return SkipReason.token(token) }
        if TargetLanguage.covers(String(body), target: target) { return .target }
        return body.contains(where: { $0.isNumber }) ? .number : .symbols
    }

    /// Protected ASCII technical tokens (identifiers, paths, URLs, files, numbers with units) inside a whitespace-free
    /// chunk that also holds non-ASCII text. A token is a maximal ASCII run (non-ASCII characters inside `<…>` placeholders
    /// stay in it) minus surrounding punctuation; it never swallows adjacent CJK letters or CJK punctuation.
    static func asciiTokenRanges(in chunk: Substring) -> [Range<Substring.Index>] {
        var ranges: [Range<Substring.Index>] = []
        var index = chunk.startIndex
        while index < chunk.endIndex {
            guard chunk[index].isASCII else { index = chunk.index(after: index); continue }
            let start = index
            var open = false
            while index < chunk.endIndex {
                let c = chunk[index]
                if c.isASCII {
                    if c == "<" { open = true } else if c == ">" { open = false }
                } else if !(open && chunk[index...].contains(">")) {
                    break
                }
                index = chunk.index(after: index)
            }
            var lower = start, upper = index
            while lower < upper, "([{'\"".contains(chunk[lower]) { lower = chunk.index(after: lower) }
            while lower < upper, ".,;:!?)]}'\"".contains(chunk[chunk.index(before: upper)]) { upper = chunk.index(before: upper) }
            let core = chunk[lower..<upper]
            if core.contains(where: { $0.isLetter || $0.isNumber }), isProtectedToken(core) { ranges.append(lower..<upper) }
        }
        return ranges
    }

    fileprivate static func isProtectedToken(_ token: Substring) -> Bool {
        // Deliberately overprotect slash-containing tokens: paths, URLs and
        // command options are more important to preserve than translating a/b.
        token.contains("/") || token.contains("\\") || token.contains("://") ||
        token.hasPrefix("~") || token.contains("@") ||
        token.contains("_") || token.hasPrefix("--") ||
        token.contains(".com") || token.contains(".org") || token.contains(".net") ||
        token.contains(".io") || token.contains(".dev") ||
        token.dropLast().contains(".") || isNumberWithUnit(token) || isCamelCase(token)
    }

    /// "fooBar", "parseHTTPResponse": an ASCII lowercase letter directly followed by an uppercase one.
    fileprivate static func isCamelCase(_ token: Substring) -> Bool {
        let chars = Array(token)
        return zip(chars, chars.dropFirst()).contains { $0.isASCII && $0.isLowercase && $1.isASCII && $1.isUppercase }
    }

    private static let units: Set<String> = ["pt", "px", "em", "rem", "ms", "s", "kb", "mb", "gb", "tb", "kib", "mib", "gib",
                                             "hz", "khz", "mhz", "ghz", "fps", "x", "dpi", "pct"]

    /// "6pt", "9pt", "12px", "100ms", "16GB": a number with a unit stays verbatim inside a sentence.
    fileprivate static func isNumberWithUnit(_ token: Substring) -> Bool {
        let digits = token.prefix(while: { $0.isASCII && ($0.isNumber || $0 == ".") })
        guard !digits.isEmpty, digits.contains(where: { $0.isNumber }) else { return false }
        var suffix = token.dropFirst(digits.count)
        while let last = suffix.last, ",;:!?)]".contains(last) { suffix = suffix.dropLast() }
        return units.contains(suffix.lowercased())
    }

    /// "v1.2.3", "2.0", "1.2.3": a dotted version number.
    fileprivate static func isVersion(_ core: Substring) -> Bool {
        var rest = core
        if let first = rest.first, first == "v" || first == "V", rest.dropFirst().first?.isNumber == true { rest = rest.dropFirst() }
        return rest.contains(where: { $0.isNumber }) && rest.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
    }

    /// An English sentence that happens to start with a command word ("curl is a tool for transferring data."):
    /// six or more plain words, no flags/paths/assignments, sentence-final punctuation.
    private static func readsAsSentence(_ line: Substring) -> Bool {
        let tokens = line.split(whereSeparator: isWhitespaceOrTab)
        guard tokens.count >= 6, let last = line.last, ".!?。！？".contains(last) else { return false }
        return tokens.allSatisfy { token in
            let core = String(token).trimmingCharacters(in: .punctuationCharacters)
            return !token.hasPrefix("-") && !core.isEmpty && core.allSatisfy { $0.isLetter || "'’-".contains($0) }
        }
    }

    private static let commandWords = ["sudo", "cd", "ls", "pwd", "cat", "echo", "printf", "git", "npm", "npx", "pnpm", "yarn",
                                       "brew", "curl", "wget", "ssh", "scp", "chmod", "chown", "rm", "mv", "cp", "mkdir",
                                       "python", "python3", "node", "swift", "swiftc", "go", "cargo", "make", "docker", "kubectl", "env"]
    /// Command names that are also ordinary English words: a command only when the next word looks like an argument.
    private static let ambiguousCommandWords = ["go", "make", "cat", "env"]
    private static let hardKeywords = ["import ", "let ", "var ", "const ", "func ", "function ", "class ", "struct ", "enum ",
                                       "def ", "public ", "private ", "export "]
    /// Keywords that also start ordinary sentences ("for more details", "if you want"): code only with code punctuation
    /// or as a short line that does not continue prose.
    private static let softKeywords = ["return ", "if ", "for ", "while ", "switch ", "case ", "from "]

    private static func isWhitespaceOrTab(_ c: Character) -> Bool { c == " " || c == "\t" }

    private static func hasCodeSignal(_ line: Substring) -> Bool {
        line.contains(where: { "(){}[]<>=*$".contains($0) }) || line.hasSuffix(":") || line.contains(" import ")
    }

    private static func looksLikeCommandArguments(_ rest: Substring) -> Bool {
        let second = rest.drop(while: isWhitespaceOrTab).prefix(while: { !isWhitespaceOrTab($0) })
        if second.isEmpty { return false }
        if second.hasPrefix("-") || second.dropLast().contains(".") { return true }
        if second.contains(where: { "/=~".contains($0) }) { return true }
        return ["build", "test", "run", "install", "clean", "get", "mod", "fmt", "vet", "version", "all", "help", "list", "tidy"]
            .contains(String(second))
    }

    /// Single whitespace-free token that is an identifier/hash/path/number rather than a word.
    private static func opaqueTokenReason(_ token: Substring) -> SkipReason? {
        if isProtectedToken(token) { return SkipReason.token(token) }
        let ascii = token.filter { $0.isASCII }
        let hasNonASCIILetter = token.contains { !$0.isASCII && $0.isLetter }
        if !hasNonASCIILetter, ascii.contains(where: { $0.isNumber }), ascii.contains(where: { $0.isLetter }) { return SkipReason.token(token) }
        let chars = Array(token)
        for i in chars.indices.dropLast() where chars[i].isLowercase && chars[i + 1].isUppercase { return .identifier }
        return nil
    }

    /// nil when `line` is prose (becomes a request); otherwise the rule that rejected it. This is intentionally a
    /// heuristic, not a shell/parser or language detector. Unknown syntax stays original; ordinary indented English
    /// is allowed because terminal wrapping often adds indentation.
    private static func verdict(_ line: Substring, continuation: Bool, unicode: Bool = false, diffRow: Bool = false, target: String? = nil) -> SkipReason? {
        // Predominantly non-ASCII prose (CJK, kana, Hangul, ...) under a non-English source: judged as a sentence,
        // unless it opens with an ASCII command word or code token ("echo 你好", "x = 中文").
        let leadWord = line.prefix(while: { !isWhitespaceOrTab($0) })
        // Technical tokens (paths, filenames, identifiers) do not count towards the script share: they are protected inside
        // the request, so a long path next to a few CJK words is still a sentence.
        let cjkProse = unicode && isNonASCIIProse(withoutProtectedTokens(line), minimum: 2) && !commandWords.contains(where: { leadWord == $0 })
            && !leadWord.contains(where: { "=({[;".contains($0) }) && !hardKeywords.contains(where: { line.hasPrefix($0) })
        guard !line.isEmpty else { return .empty }
        if ["$", "%", ">"].contains(where: { line.hasPrefix($0) }) { return .prompt }
        if ["/*", "* /", "#!/"].contains(where: { line.hasPrefix($0) }) { return .code }
        if line.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return .symbols }
        if ["@@", "---", "+++", "diff "].contains(where: { line.hasPrefix($0) }) { return .diff }
        if line.hasPrefix("#") || line.hasPrefix("//") {
            // "# note", "## Title", "// note": prose when the body is; "#include", "#123" stay original.
            let marker = line.hasPrefix("#") ? line.prefix(while: { $0 == "#" }) : line.prefix(2)
            let rest = line.dropFirst(marker.count)
            guard let separator = rest.first, isWhitespaceOrTab(separator) else { return .code }
            return verdict(rest.drop(while: isWhitespaceOrTab), continuation: continuation, unicode: unicode, diffRow: true, target: target)
        }
        if hardKeywords.contains(where: { line.hasPrefix($0) }) { return .code }
        let isElse = line == "else" || line.hasPrefix("else ") || line.hasPrefix("else{") || line.hasPrefix("else:")
        if !cjkProse, isElse || softKeywords.contains(where: { line.hasPrefix($0) }) {
            let tokens = line.split(whereSeparator: isWhitespaceOrTab).count
            if hasCodeSignal(line) || !(continuation || tokens >= 4) { return .code }
        }
        // A "- " row is a bullet only outside diff context (no hunk header, no opposite-marker neighbour) and only when
        // its body is itself prose. "+ " rows (diff additions), flags, numbers and anything else with +/- stay original.
        if line.hasPrefix("+") || line.hasPrefix("-") {
            if line.hasPrefix("- "), !diffRow {
                let body = line.dropFirst(2).drop(while: isWhitespaceOrTab)
                return verdict(body, continuation: continuation, unicode: unicode, diffRow: true, target: target)
            }
            // OCR glues the dash to CJK text: "-两个译文…" is a bullet whose body is judged on its own.
            if unicode, !diffRow, hasGluedBulletDash(line) {
                return verdict(line.dropFirst().drop(while: isWhitespaceOrTab), continuation: continuation, unicode: unicode, diffRow: true, target: target)
            }
            if line.hasPrefix("+") || diffRow { return .diff }
            return SkipReason.token(line.prefix(while: { !isWhitespaceOrTab($0) }))
        }
        // A line that is predominantly non-ASCII prose is prose even when it quotes code words, flags, numbers with
        // units or commands; those tokens are protected inside the request instead of rejecting the whole line.
        if cjkProse { return TargetLanguage.covers(String(line), target: target) ? .target : nil }
        if line.contains("{") || line.contains("}") || line.contains(" = ") || line.contains("=>") ||
           line.contains("&&") || line.contains("||") { return .code }
        let tokenCount = line.split(whereSeparator: isWhitespaceOrTab).count
        if line.contains(";") {
            // Prose may contain "; " between clauses; statements end with ";" or glue it to the next token.
            let afterSemicolons = line.split(separator: ";", omittingEmptySubsequences: false).dropFirst()
            if line.hasSuffix(";") || tokenCount < 4 || !afterSemicolons.allSatisfy({ $0.first.map(isWhitespaceOrTab) ?? false }) { return .code }
        }
        let first = line.prefix(while: { !isWhitespaceOrTab($0) && !$0.isNewline })
        if line.contains(" | ") {
            // A pipeline feeds a command; a status separator ("main | 3 files changed") does not.
            let stages = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst()
            if stages.contains(where: { stage in
                let word = stage.drop(while: isWhitespaceOrTab).prefix(while: { !isWhitespaceOrTab($0) })
                return commandWords.contains(where: { word == $0 })
            }) { return .command }
        }
        if commandWords.contains(where: { first == $0 }), !readsAsSentence(line) {
            if !ambiguousCommandWords.contains(where: { first == $0 }) || looksLikeCommandArguments(line.dropFirst(first.count)) { return .command }
        }
        if first.contains("=") { return .code }
        if first.hasSuffix("$") || first.hasSuffix("%") || first.hasSuffix("#") { return .prompt }
        let body = proseBody(line)
        // A decorated prompt ("❯ git status") is still a command.
        let bodyFirst = body.prefix(while: { !isWhitespaceOrTab($0) })
        if body.startIndex != line.startIndex, commandWords.contains(where: { bodyFirst == $0 }),
           !ambiguousCommandWords.contains(where: { bodyFirst == $0 }) || looksLikeCommandArguments(body.dropFirst(bodyFirst.count)) { return .command }
        if !body.contains(where: { $0.isWhitespace }), let opaque = opaqueTokenReason(body) { return opaque }
        // Every recognized text that is not machine text and not already in the target language is translated, however
        // short: labels, titles, single words, status text, sidebar entries, fragments.
        guard body.contains(where: { $0.isLetter }) else { return body.contains(where: { $0.isNumber }) ? .number : .symbols }
        return TargetLanguage.covers(String(body), target: target) ? .target : nil
    }
}

/// Confident "this text is already entirely in the target language" test. Non-Latin targets are judged by script;
/// Latin-script targets need letters only in Latin ranges and a language-recognizer top hypothesis equal to the target
/// with probability of at least 0.9 (single words included: skipped only when the recognizer is that confident). Tokens
/// that stay verbatim anyway (inline code, paths, URLs, identifiers, units) are
/// ignored. `nil` target (unknown) never covers anything.
enum TargetLanguage {
    static func covers(_ text: String, target: String?) -> Bool {
        guard let target else { return false }
        let kept = visible(text)
        let letters = kept.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        func all(_ ranges: [ClosedRange<UInt32>]) -> Bool {
            letters.allSatisfy { c in c.unicodeScalars.allSatisfy { s in ranges.contains { $0.contains(s.value) } } }
        }
        func any(_ ranges: [ClosedRange<UInt32>]) -> Bool {
            letters.contains { c in c.unicodeScalars.contains { s in ranges.contains { $0.contains(s.value) } } }
        }
        let han: [ClosedRange<UInt32>] = [0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F]
        let kana: [ClosedRange<UInt32>] = [0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F]
        switch target {
        case "zh-Hans", "zh-Hant": return all(han)
        case "ja": return all(han + kana) && any(kana)
        case "ko": return all([0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF])
        case "ru", "uk": return all([0x0400...0x052F])
        case "ar": return all([0x0600...0x06FF, 0x0750...0x077F])
        case "hi": return all([0x0900...0x097F])
        case "th": return all([0x0E00...0x0E7F])
        default:
            guard all([0x41...0x24F, 0x300...0x36F, 0x1E00...0x1EFF]) else { return false }
            guard kept.contains(where: { $0.isLetter }) else { return false }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(kept)
            guard let best = recognizer.languageHypotheses(withMaximum: 1).first else { return false }
            return best.key.rawValue == target && best.value >= 0.9
        }
    }

    /// `text` without backtick code spans and without whitespace-separated protected tokens.
    private static func visible(_ text: String) -> String {
        var words: [Substring] = []
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() where index % 2 == 0 {
            words += part.split(whereSeparator: { $0.isWhitespace }).filter { !TranslationPlan.isProtectedToken($0) && !TranslationPlan.isNumberWithUnit($0) }
        }
        return words.joined(separator: " ")
    }
}

extension TranslationPlan {
    /// `line` without its protected technical tokens (paths, identifiers, files, URLs, units): what is left is the prose
    /// whose script decides whether the line is a sentence. A path or filename must not outvote the CJK words around it.
    fileprivate static func withoutProtectedTokens(_ line: Substring) -> Substring {
        var kept: [Substring] = []
        for chunk in line.split(whereSeparator: { $0.isWhitespace }) {
            if chunk.allSatisfy({ $0.isASCII }) {
                if !isProtectedToken(chunk) { kept.append(chunk) }
                continue
            }
            var cursor = chunk.startIndex
            for range in asciiTokenRanges(in: chunk) {
                if cursor < range.lowerBound { kept.append(chunk[cursor..<range.lowerBound]) }
                cursor = range.upperBound
            }
            if cursor < chunk.endIndex { kept.append(chunk[cursor...]) }
        }
        return Substring(kept.joined(separator: " "))
    }
}
