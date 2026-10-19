import Foundation

/// Why a recognized line/region was not turned into a translation request. Counts only ever leave the process (never text).
/// Informational: `TranslationPlan.verdict` decides; this names the rule that fired.
enum SkipReason: String, CaseIterable {
    case empty, symbols, short, prompt, command, diff, code, fence
    case path, url, hash, flag, identifier, number, host

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
    /// `unicode` selects the language-general heuristics (any letter is a word; no lowercase requirement) used when the
    /// source language is not English. The default is the original English-only behaviour, unchanged.
    init(text: String, visualContinuationLines: Set<Int> = [], unicode: Bool = false) {
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
            if core.contains(where: { unicode ? $0.isLetter : ($0.isASCII && $0.isLetter) }) {
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
            let lineVerdict = Self.verdict(trimmed, continuation: previousWasProse, unicode: unicode, diffRow: diffRow)
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
                        if Self.isProtectedToken(body[tokenStart..<cursor]) {
                            closeFragment(upTo: tokenStart)
                            frags.append((tokenStart..<cursor, true))
                            fragmentStart = cursor
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
                        && body[frags[index].range].contains(where: { unicode ? $0.isLetter : ($0.isASCII && $0.isLetter) })
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
                    skipReasons.append(Self.protectedReason(body))
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

    /// The rule behind a prose line whose fragments are all protected tokens.
    private static func protectedReason(_ body: Substring) -> SkipReason {
        for token in body.split(whereSeparator: { $0.isWhitespace }) where isProtectedToken(token) { return SkipReason.token(token) }
        return .short
    }

    private static func isProtectedToken(_ token: Substring) -> Bool {
        // Deliberately overprotect slash-containing tokens: paths, URLs and
        // command options are more important to preserve than translating a/b.
        token.contains("/") || token.contains("\\") || token.contains("://") ||
        token.hasPrefix("~") || token.contains("@") ||
        token.contains("_") || token.hasPrefix("--") ||
        token.contains(".com") || token.contains(".org") || token.contains(".net") ||
        token.contains(".io") || token.contains(".dev") ||
        token.dropLast().contains(".") || isNumberWithUnit(token)
    }

    private static let units: Set<String> = ["pt", "px", "em", "rem", "ms", "s", "kb", "mb", "gb", "tb", "kib", "mib", "gib",
                                             "hz", "khz", "mhz", "ghz", "fps", "x", "dpi", "pct"]

    /// "6pt", "9pt", "12px", "100ms", "16GB": a number with a unit stays verbatim inside a sentence.
    private static func isNumberWithUnit(_ token: Substring) -> Bool {
        let digits = token.prefix(while: { $0.isASCII && ($0.isNumber || $0 == ".") })
        guard !digits.isEmpty, digits.contains(where: { $0.isNumber }) else { return false }
        var suffix = token.dropFirst(digits.count)
        while let last = suffix.last, ",;:!?)]".contains(last) { suffix = suffix.dropLast() }
        return units.contains(suffix.lowercased())
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
        if second.isEmpty || second.hasPrefix("-") || second.dropLast().contains(".") { return true }
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

    /// One capitalised word (>= 3 letters, e.g. "Complete", "Settings", "Thinking…") with only numbers/symbols around it.
    private static func isTitleWord(_ body: Substring, unicode: Bool) -> Bool {
        func isLetter(_ c: Character) -> Bool { unicode ? c.isLetter : (c.isASCII && c.isLetter) }
        let wordTokens = body.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: isLetter) }
        guard wordTokens.count == 1 else { return false }
        let chars = Array(wordTokens[0])
        var lo = 0, hi = chars.count
        while lo < hi, !isLetter(chars[lo]) { lo += 1 }
        while hi > lo, !isLetter(chars[hi - 1]) { hi -= 1 }
        let core = chars[lo..<hi]
        return core.count >= 3 && core.allSatisfy(isLetter) && core.first!.isUppercase && core.dropFirst().allSatisfy { $0.isLowercase }
    }

    /// nil when `line` is prose (becomes a request); otherwise the rule that rejected it. This is intentionally a
    /// heuristic, not a shell/parser or language detector. Unknown syntax stays original; ordinary indented English
    /// is allowed because terminal wrapping often adds indentation.
    private static func verdict(_ line: Substring, continuation: Bool, unicode: Bool = false, diffRow: Bool = false) -> SkipReason? {
        // Predominantly non-ASCII prose (CJK, kana, Hangul, ...) under a non-English source: judged as a sentence,
        // unless it opens with an ASCII command word or code token ("echo 你好", "x = 中文").
        let leadWord = line.prefix(while: { !isWhitespaceOrTab($0) })
        let cjkProse = unicode && isNonASCIIProse(line, minimum: 2) && !commandWords.contains(where: { leadWord == $0 })
            && !leadWord.contains(where: { "=({[;".contains($0) }) && !hardKeywords.contains(where: { line.hasPrefix($0) })
        guard !line.isEmpty else { return .empty }
        if ["$", "%", ">"].contains(where: { line.hasPrefix($0) }) { return .prompt }
        if ["/*", "* /", "#!/"].contains(where: { line.hasPrefix($0) }) { return .code }
        if ["@@", "---", "+++", "diff "].contains(where: { line.hasPrefix($0) }) { return .diff }
        if line.hasPrefix("#") || line.hasPrefix("//") {
            // "# note", "## Title", "// note": prose when the body is; "#include", "#123" stay original.
            let marker = line.hasPrefix("#") ? line.prefix(while: { $0 == "#" }) : line.prefix(2)
            let rest = line.dropFirst(marker.count)
            guard let separator = rest.first, isWhitespaceOrTab(separator) else { return .code }
            return verdict(rest.drop(while: isWhitespaceOrTab), continuation: continuation, unicode: unicode, diffRow: true)
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
                return verdict(body, continuation: continuation, unicode: unicode, diffRow: true)
            }
            // OCR glues the dash to CJK text: "-两个译文…" is a bullet whose body is judged on its own.
            if unicode, !diffRow, hasGluedBulletDash(line) {
                return verdict(line.dropFirst().drop(while: isWhitespaceOrTab), continuation: continuation, unicode: unicode, diffRow: true)
            }
            if line.hasPrefix("+") || diffRow { return .diff }
            return SkipReason.token(line.prefix(while: { !isWhitespaceOrTab($0) }))
        }
        // A line that is predominantly non-ASCII prose is prose even when it quotes code words, flags, numbers with
        // units or commands; those tokens are protected inside the request instead of rejecting the whole line.
        if cjkProse { return nil }
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
        var words = 0
        var letters = 0
        var inWord = false
        var hasLowercase = false
        var hasNonLatin = false
        for character in body {
            let letter = unicode ? character.isLetter : (character.isASCII && character.isLetter)
            if letter && !inWord { words += 1 }
            if letter { letters += 1 }
            if letter && character.isLowercase { hasLowercase = true }
            if letter && !character.isLowercase && !character.isUppercase { hasNonLatin = true }   // caseless script (CJK, Thai, Arabic, ...)
            inWord = letter
        }
        var accepted: Bool
        if unicode {
            // Caseless scripts (CJK, Thai, ...) have no lowercase and no spaces: two letters is enough.
            accepted = (hasLowercase || hasNonLatin) && (words >= 2 || (continuation && words == 1) || (hasNonLatin && letters >= 2))
        } else {
            // Single-word wrapped continuations are accepted only following prose.
            accepted = hasLowercase && (words >= 2 || (continuation && words == 1))
        }
        // Titles and labels: one capitalised word ("Complete"), or an upper-case phrase ("BUILD SUCCEEDED").
        if !accepted { accepted = isTitleWord(body, unicode: unicode) }
        if !accepted, words >= 2, !hasLowercase, !hasNonLatin, letters >= 4,
           !body.contains(where: { $0.isNumber || $0 == "_" }) { accepted = true }
        if accepted { return nil }
        if letters == 0 { return body.contains(where: { $0.isNumber }) ? .number : .symbols }
        return .short
    }
}
