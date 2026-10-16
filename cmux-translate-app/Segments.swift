enum TranslationPiece {
    case literal(String)
    case prose(id: String, text: String)
}

struct TranslationPlan {
    let pieces: [TranslationPiece]
    let proseLineIndices: Set<Int>

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

        func literal(_ value: Substring) {
            guard !value.isEmpty else { return }
            result.append(.literal(String(value)))
        }
        func prose(_ value: Substring) {
            guard !value.isEmpty else { return }
            let leading = value.prefix(while: { $0.isWhitespace })
            let remainder = value.dropFirst(leading.count)
            let trailing = remainder.reversed().prefix(while: { $0.isWhitespace }).count
            let core = remainder.dropLast(trailing)
            literal(leading)
            if core.contains(where: { unicode ? $0.isLetter : ($0.isASCII && $0.isLetter) }) {
                result.append(.prose(id: "prose-\(nextID)", text: String(core)))
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
            if let active = fence {
                literal(line)
                if let marker, marker.character == active.character,
                   marker.count >= active.count, marker.tail.allSatisfy({ $0.isWhitespace }) {
                    fence = nil
                }
                previousWasProse = false
            } else if let marker {
                literal(line)
                fence = (marker.character, marker.count)
                previousWasProse = false
            } else if Self.isProse(trimmed, continuation: previousWasProse, unicode: unicode, diffRow: diffRow) {
                // Keep indentation and list decorations outside the request.
                let body = Self.proseBody(trimmed)
                literal(line[..<body.startIndex])
                var cursor = body.startIndex
                var fragmentStart = cursor
                while cursor < body.endIndex {
                    if body[cursor] == "`" {
                        prose(body[fragmentStart..<cursor])
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
                        literal(body[opening..<cursor])
                        fragmentStart = cursor
                        if !closed { break }
                    } else if !body[cursor].isWhitespace {
                        let tokenStart = cursor
                        while cursor < body.endIndex, !body[cursor].isWhitespace, body[cursor] != "`" {
                            cursor = body.index(after: cursor)
                        }
                        let token = body[tokenStart..<cursor]
                        if Self.isProtectedToken(token) {
                            prose(body[fragmentStart..<tokenStart])
                            literal(token)
                            fragmentStart = cursor
                        }
                    } else {
                        cursor = body.index(after: cursor)
                    }
                }
                prose(body[fragmentStart..<body.endIndex])
                previousWasProse = true
            } else {
                literal(line)
                previousWasProse = false
            }
            if result[pieceStart...].contains(where: { if case .prose = $0 { return true }; return false }) {
                proseLines.insert(lineIndex)
            }
            if visualContinuationLines.contains(lineIndex), result.count == pieceStart + 1,
               pieceStart >= 2,
               case .prose(_, let current) = result[pieceStart],
               case .literal(let separator) = result[pieceStart - 1],
               separator == "\n" || separator == "\r" || separator == "\r\n",
               case .prose(let id, let previous) = result[pieceStart - 2] {
                result.replaceSubrange((pieceStart - 2)...pieceStart,
                                       with: [.prose(id: id, text: previous + " " + current)])
            }
            literal(text[end..<next])
            start = next
            lineIndex += 1
        }
        pieces = result
        proseLineIndices = proseLines
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
        for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
            return line.dropFirst(prefix.count)
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return rest.dropFirst(2) }
        }
        return line
    }

    private static func isProtectedToken(_ token: Substring) -> Bool {
        // Deliberately overprotect slash-containing tokens: paths, URLs and
        // command options are more important to preserve than translating a/b.
        token.contains("/") || token.contains("\\") || token.contains("://") ||
        token.hasPrefix("~") || token.contains("@") ||
        token.contains("_") || token.hasPrefix("--") ||
        token.contains(".com") || token.contains(".org") || token.contains(".net") ||
        token.contains(".io") || token.contains(".dev") ||
        token.dropLast().contains(".")
    }

    private static func isProse(_ line: Substring, continuation: Bool, unicode: Bool = false, diffRow: Bool = false) -> Bool {
        guard !line.isEmpty else { return false }
        // This is intentionally a heuristic, not a shell/parser or language
        // detector. Unknown syntax stays original; ordinary indented English
        // is allowed because terminal wrapping often adds indentation.
        let codePrefixes = ["$", "%", ">", "#", "//", "/*", "* /", "@@", "---", "+++", "diff ",
                            "import ", "from ", "let ", "var ", "const ", "func ", "function ",
                            "class ", "struct ", "enum ", "def ", "return ", "if ", "else", "for ",
                            "while ", "switch ", "case ", "public ", "private ", "export ", "#!/"]
        if codePrefixes.contains(where: { line.hasPrefix($0) }) { return false }
        // A "- " row is a bullet only outside diff context (no hunk header, no opposite-marker neighbour) and only when
        // its body is itself prose. "+ " rows (diff additions), flags, numbers and anything else with +/- stay original.
        if line.hasPrefix("+") || line.hasPrefix("-") {
            guard !diffRow, line.hasPrefix("- ") else { return false }
            let body = line.dropFirst(2).drop(while: { $0 == " " || $0 == "\t" })
            return isProse(body, continuation: continuation, unicode: unicode, diffRow: true)
        }
        if line.contains("{") || line.contains("}") || line.contains(";") ||
           line.contains(" = ") || line.contains("=>") || line.contains("&&") ||
           line.contains("||") || line.contains(" | ") { return false }
        let first = line.prefix(while: { !$0.isWhitespace })
        let commands = ["sudo", "cd", "ls", "pwd", "cat", "echo", "printf", "git", "npm", "npx", "pnpm", "yarn",
                        "brew", "curl", "wget", "ssh", "scp", "chmod", "chown", "rm", "mv", "cp", "mkdir",
                        "python", "python3", "node", "swift", "swiftc", "go", "cargo", "make", "docker", "kubectl", "env"]
        if commands.contains(where: { first == $0 }) || first.contains("=") ||
           first.hasSuffix("$") || first.hasSuffix("%") || first.hasSuffix("#") { return false }
        let body = proseBody(line)
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
        if unicode {
            // Caseless scripts (CJK, Thai, ...) have no lowercase and no spaces: two letters is enough.
            return (hasLowercase || hasNonLatin) && (words >= 2 || (continuation && words == 1) || (hasNonLatin && letters >= 2))
        }
        // Single-word wrapped continuations are accepted only following prose.
        // Chinese-only rows and symbolic/status rows never become requests.
        return hasLowercase && (words >= 2 || (continuation && words == 1))
    }
}
