import Foundation

extension TranslationPlan {
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

    static let commandWords = ["sudo", "cd", "ls", "pwd", "cat", "echo", "printf", "git", "npm", "npx", "pnpm", "yarn",
                                       "brew", "curl", "wget", "ssh", "scp", "chmod", "chown", "rm", "mv", "cp", "mkdir",
                                       "python", "python3", "node", "swift", "swiftc", "go", "cargo", "make", "docker", "kubectl", "env"]
    /// Command names that are also ordinary English words: a command only when the next word looks like an argument.
    private static let ambiguousCommandWords = ["go", "make", "cat", "env"]
    private static let hardKeywords = ["import ", "let ", "var ", "const ", "func ", "function ", "class ", "struct ", "enum ",
                                       "def ", "public ", "private ", "export "]
    /// Keywords that also start ordinary sentences ("for more details", "if you want"): code only with code punctuation
    /// or as a short line that does not continue prose.
    private static let softKeywords = ["return ", "if ", "for ", "while ", "switch ", "case ", "from "]

    static func isWhitespaceOrTab(_ c: Character) -> Bool { c == " " || c == "\t" }

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
    static func verdict(_ line: Substring, continuation: Bool, unicode: Bool = false, diffRow: Bool = false, target: String? = nil) -> SkipReason? {
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
