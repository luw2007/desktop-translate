import Foundation

extension TranslationPlan {
    static func fenceMarker(_ line: Substring) -> (character: Character, count: Int, tail: Substring)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        return (first, run.count, line.dropFirst(run.count))
    }

    static func proseBody(_ line: Substring) -> Substring {
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
    static func isNonASCIIProse(_ line: Substring, minimum: Int) -> Bool {
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
    static func promptCommandEnd(_ body: Substring, from start: Substring.Index) -> Substring.Index? {
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
    static func protectedReason(_ body: Substring, target: String?) -> SkipReason {
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

    static func isProtectedToken(_ token: Substring) -> Bool {
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
    private static func isCamelCase(_ token: Substring) -> Bool {
        let chars = Array(token)
        return zip(chars, chars.dropFirst()).contains { $0.isASCII && $0.isLowercase && $1.isASCII && $1.isUppercase }
    }

    private static let units: Set<String> = ["pt", "px", "em", "rem", "ms", "s", "kb", "mb", "gb", "tb", "kib", "mib", "gib",
                                             "hz", "khz", "mhz", "ghz", "fps", "x", "dpi", "pct"]

    /// "6pt", "9pt", "12px", "100ms", "16GB": a number with a unit stays verbatim inside a sentence.
    static func isNumberWithUnit(_ token: Substring) -> Bool {
        let digits = token.prefix(while: { $0.isASCII && ($0.isNumber || $0 == ".") })
        guard !digits.isEmpty, digits.contains(where: { $0.isNumber }) else { return false }
        var suffix = token.dropFirst(digits.count)
        while let last = suffix.last, ",;:!?)]".contains(last) { suffix = suffix.dropLast() }
        return units.contains(suffix.lowercased())
    }

    /// "v1.2.3", "2.0", "1.2.3": a dotted version number.
    static func isVersion(_ core: Substring) -> Bool {
        var rest = core
        if let first = rest.first, first == "v" || first == "V", rest.dropFirst().first?.isNumber == true { rest = rest.dropFirst() }
        return rest.contains(where: { $0.isNumber }) && rest.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
    }
}

extension TranslationPlan {
    /// `line` without its protected technical tokens (paths, identifiers, files, URLs, units): what is left is the prose
    /// whose script decides whether the line is a sentence. A path or filename must not outvote the CJK words around it.
    static func withoutProtectedTokens(_ line: Substring) -> Substring {
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
