import Foundation
import NaturalLanguage

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
