import Foundation

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
            if space {
                tokens.append((current, .space))
            } else if !current.allSatisfy({ $0.isASCII }) {
                // Mixed CJK/ASCII chunk: protect only the ASCII technical tokens, classify the rest on its own.
                let chunk = Substring(current)
                var cursor = chunk.startIndex
                for range in TranslationPlan.asciiTokenRanges(in: chunk) {
                    if cursor < range.lowerBound { let t = String(chunk[cursor..<range.lowerBound]); tokens.append((t, classify(t))) }
                    tokens.append((String(chunk[range]), .protected))
                    cursor = range.upperBound
                }
                if cursor < chunk.endIndex { let t = String(chunk[cursor...]); tokens.append((t, classify(t))) }
            } else {
                tokens.append((current, classify(current)))
            }
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
        if token.hasPrefix("`"), token.hasSuffix("`"), token.count > 1 { return .protected }
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
            if c.isLetter {
                if i + 1 < core.count, c.isLowercase, core[i + 1].isUppercase { return .protected }
            } else if !"'’-".contains(c) {
                return .protected
            }
        }
        return .word
    }
}
