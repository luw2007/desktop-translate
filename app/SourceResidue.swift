import Foundation

/// A rendered translation that still carries the SOURCE script: a partial translation failure that the paint outcome
/// alone reports as a plain success. Detection is deliberately narrow and evidence-based:
/// - the TARGET must be English (`en` or any `en-*`, case-insensitive BCP-47 primary subtag);
/// - strictly more than `minimumPercent`% of the LETTERS of the presented translation must be CJK (Han, kana, Hangul);
/// - the captured SOURCE text of the same region must itself contain CJK letters.
/// The configured source language is never consulted, so `auto` and a fixed code behave identically: the gate is the
/// captured source text. An English source therefore never fires, and a Chinese source with an English target fires
/// only when the model returned mostly Chinese.
///
/// Pure diagnostic. It changes neither planning, painting, masking, protection nor freshness: a residue region keeps
/// its real `OverlayItem.Outcome` and is painted exactly as before; only the debug classification (`R` with
/// `subreason`), the explicit JSON export and the aggregate (count-only) log line change.
enum SourceResidue {
    /// Subreason recorded on the debug `R` box and in the explicit JSON export.
    static let subreason = "source-language-residue"
    /// Strictly more than this percentage of the letters must be CJK. Integer arithmetic keeps the boundary exact:
    /// 3 of 10 letters is exactly 30% and therefore not residue, 4 of 10 is.
    static let minimumPercent = 30
    /// Han, kana and Hangul letters: under an English target any of them is source-script residue.
    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,   // Han
        0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,                                        // kana
        0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF,                                        // Hangul
    ]

    /// `en` and every `en-*` (BCP-47 primary subtag), case-insensitive. nil, empty and every other target: never residue.
    static func isEnglishTarget(_ target: String?) -> Bool {
        guard let target else { return false }
        return target.split(separator: "-").first?.lowercased() == "en"
    }

    /// CJK letters and all letters of `text`. Letters only: digits, punctuation and whitespace are ignored.
    static func letters(_ text: String) -> (cjk: Int, total: Int) {
        var cjk = 0, total = 0
        for character in text where character.isLetter {
            total += 1
            if character.unicodeScalars.contains(where: { scalar in cjkRanges.contains { $0.contains(scalar.value) } }) { cjk += 1 }
        }
        return (cjk, total)
    }

    /// `true` when `text` contains at least one CJK letter.
    static func containsCJK(_ text: String) -> Bool { letters(text).cjk > 0 }

    /// `true` when strictly more than `minimumPercent`% of the letters of `text` are CJK.
    static func isResidue(_ text: String) -> Bool {
        let (cjk, total) = letters(text)
        return total > 0 && cjk * 100 > total * minimumPercent
    }

    /// Full gate for one region: English target, CJK-bearing source, mostly-CJK translation.
    static func isResidue(translation: String, source: String, targetLanguage: String?) -> Bool {
        isEnglishTarget(targetLanguage) && containsCJK(source) && isResidue(translation)
    }

    /// Ids of presented items whose translation is residue (see the type doc). Each item is paired with the captured
    /// text of its own source region: an item without a matching region, or without paint, is never residue, and the
    /// classification is skipped entirely for a non-English target.
    static func regions(snapshot: CaptureSnapshot?, items: [OverlayItem], targetLanguage: String?) -> Set<String> {
        guard isEnglishTarget(targetLanguage) else { return [] }
        var source: [String: String] = [:]
        for region in snapshot?.regions ?? [] where source[region.id] == nil { source[region.id] = region.text }
        var out: Set<String> = []
        for item in items where item.isPainted {
            guard let text = source[item.regionID], containsCJK(text), isResidue(item.text) else { continue }
            out.insert(item.regionID)
        }
        return out
    }

    /// How many presented items are residue. Same rule as `regions`.
    static func count(snapshot: CaptureSnapshot?, items: [OverlayItem], targetLanguage: String?) -> Int {
        regions(snapshot: snapshot, items: items, targetLanguage: targetLanguage).count
    }

    /// Counts only, never text or coordinates.
    static func logLine(_ count: Int) -> String {
        "译文仍含源语言字符：\(count) 个区域（已绘制，但译文超过 \(minimumPercent)% 的字母仍是源语言字符）"
    }
}
