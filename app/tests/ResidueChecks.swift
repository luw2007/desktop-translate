import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: source-script residue (pure classification: English target, CJK-bearing source, mostly-CJK translation)

    /// Synthetic only: no capture, no model, no disk. Every region text is written here, never read from a screen.
    static func residueChecks() {
        // Threshold: strictly more than 30% of the LETTERS. Non-letters (digits, punctuation, spaces) never count.
        expect(!SourceResidue.isResidue(""), "Empty translation is not residue")
        expect(!SourceResidue.isResidue("1234 5678"), "No letters at all is not residue (no division by zero)")
        expect(!SourceResidue.isResidue("abcdefg 中中"), "2 of 9 letters is below the threshold: \(SourceResidue.letters("abcdefg 中中"))")
        expect(!SourceResidue.isResidue("abcdefg 中中中"), "Exactly 30% of the letters is not residue: \(SourceResidue.letters("abcdefg 中中中"))")
        expect(SourceResidue.isResidue("abcdef 中中中"), "3 of 9 letters is just over the threshold: \(SourceResidue.letters("abcdef 中中中"))")
        expect(!SourceResidue.isResidue("abc defg h"), "No CJK letters is not residue: \(SourceResidue.letters("abc defg h"))")
        expect(SourceResidue.isResidue("abc 中文"), "2 of 5 letters is residue: \(SourceResidue.letters("abc 中文"))")
        expect(SourceResidue.minimumPercent == 30 && SourceResidue.subreason == "source-language-residue", "Threshold and subreason are the documented ones")
        expect(SourceResidue.isResidue("これはテストです") && SourceResidue.isResidue("안녕하세요 여러분"),
               "Kana and Hangul are source-script residue under an English target")
        expect(!SourceResidue.containsCJK("Résumé naïve — 12.5%"), "Latin accents and punctuation are not CJK")

        // Language targeting: only `en` / `en-*`, case-insensitive; everything else is never residue.
        expect(SourceResidue.isEnglishTarget("en") && SourceResidue.isEnglishTarget("EN") && SourceResidue.isEnglishTarget("en-US")
               && SourceResidue.isEnglishTarget("en-GB") && SourceResidue.isEnglishTarget("EN-us"),
               "en and en-* are English targets, case-insensitively")
        expect(!SourceResidue.isEnglishTarget(nil) && !SourceResidue.isEnglishTarget("") && !SourceResidue.isEnglishTarget("zh-Hans")
               && !SourceResidue.isEnglishTarget("ja") && !SourceResidue.isEnglishTarget("fr") && !SourceResidue.isEnglishTarget("enx"),
               "nil, empty, other targets and en-prefixed non-tags are not English")
        let chinese = "这个设置面板用于配置翻译行为"
        expect(!SourceResidue.isResidue(translation: chinese, source: chinese, targetLanguage: "zh-Hans"),
               "A Chinese translation into a Chinese target is the intended result, never residue")
        expect(!SourceResidue.isResidue(translation: chinese, source: chinese, targetLanguage: nil),
               "No configured target is never treated as English")

        // Source gating: the captured source must itself carry CJK letters, so an English source never fires.
        expect(!SourceResidue.isResidue(translation: chinese, source: "Open the settings panel", targetLanguage: "en"),
               "An English source is not source-language residue")
        expect(!SourceResidue.isResidue(translation: chinese, source: "", targetLanguage: "en"), "An empty source never fires")
        expect(SourceResidue.isResidue(translation: chinese, source: "设置 Settings", targetLanguage: "en"),
               "A mixed CJK/English source does fire")
        expect(SourceResidue.isResidue(translation: "请先打开设置面板 Open", source: "设置面板", targetLanguage: "en-GB"),
               "A mostly-CJK translation with Latin words left over still fires")

        // Debug classification: a painted residue region is R with the subreason, never a silent T/S/V; paint is untouched.
        let white = NSColor.white
        let cjkSource = "配置面板"
        func region(_ id: String, _ order: Int, _ text: String, y: CGFloat) -> TextRegion {
            TextRegion(id: id, kind: .label, rect: rect(10, y, 120, 14), text: text, readingOrder: order)
        }
        let residueRegion = region("residue", 0, cjkSource, y: 10)
        let condensedResidue = region("condensedResidue", 1, cjkSource, y: 30)
        let coverResidue = region("coverResidue", 2, cjkSource, y: 50)
        let clean = region("clean", 3, cjkSource, y: 70)
        let englishSource = region("englishSource", 4, "Open the settings panel", y: 90)
        let skipped = region("skipped", 5, "...", y: 110)
        let snap = snapshot([residueRegion, condensedResidue, coverResidue, clean, englishSource, skipped])
        let plan = DesktopPlan(snapshot: snap)
        func item(_ r: TextRegion, _ text: String, _ outcome: OverlayItem.Outcome, extended: [CGRect] = []) -> OverlayItem {
            OverlayItem(regionID: r.id, readingOrder: r.readingOrder, text: text, protectedFragments: [],
                        occupied: [r.rect], clip: r.rect, extended: extended, cover: outcome == .paintedCover ? [r.rect] : [],
                        background: white, fontSize: 12, outcome: outcome)
        }
        let items = [item(residueRegion, "abc 中文", .painted),
                     item(condensedResidue, "配置面板仍未翻译", .paintedCondensed),
                     item(coverResidue, "仍然全是中文的译文内容", .paintedCover),
                     item(clean, "Settings panel", .painted),
                     item(englishSource, chinese, .painted)]
        let boxes = DebugRegions.boxes(snapshot: snap, plan: plan, items: items, marks: [], targetLanguage: "en")
        // Display indices are reading order + 1; look the box up by index so the code letter is not assumed.
        func box(_ id: String) -> DebugBox? { boxes.first { $0.index == snap.regions.first { $0.id == id }!.readingOrder + 1 } }
        expect(box("residue")?.code == .missing && box("residue")?.subreason == SourceResidue.subreason,
               "A painted residue region is R with the residue subreason: \(String(describing: box("residue")))")
        expect(box("residue")?.displayLabel == "R1:source-language-residue", "The residue subreason is visible in the label")
        expect(box("condensedResidue")?.code == .missing && box("coverResidue")?.code == .missing,
               "Residue replaces the condensed (S) and cover (V) success codes too")
        expect(box("clean")?.code == .painted && box("clean")?.subreason == nil, "An English translation keeps T with no subreason")
        expect(box("englishSource")?.code == .painted, "A CJK translation of an English source is not residue (source gating)")
        expect(box("skipped")?.code == .skipped && box("skipped")?.detail == .symbols,
               "Existing K/P classifications stay primary: \(String(describing: box("skipped")))")
        // Painting, masking and the recorded outcome are untouched: only the debug classification changes.
        expect(items[0].outcome == .painted && items[0].paintRects == [residueRegion.rect] && items[0].text == "abc 中文",
               "Residue never alters the item, its paint rectangles or its text")
        expect(OverlayItem.counts(items).painted == 5, "Residue regions stay counted as painted (HUD counts unchanged)")
        // Non-English target: the same items are classified by outcome only.
        let chineseTargetBoxes = DebugRegions.boxes(snapshot: snap, plan: plan, items: items, marks: [], targetLanguage: "zh-Hans")
        expect(chineseTargetBoxes.filter { $0.subreason == SourceResidue.subreason }.isEmpty,
               "A non-English target never produces the residue subreason")
        // Existing failure/mask classifications stay primary: only the success codes T/E/S/V can become R.
        let overflowRegion = region("overflowResidue", 0, cjkSource, y: 10)
        let collisionRegion = region("collisionResidue", 1, cjkSource, y: 30)
        let failureSnap = snapshot([overflowRegion, collisionRegion])
        let failureItems = [item(overflowRegion, "完全未翻译的中文", .fitOverflow),
                            item(collisionRegion, "仍然全是中文", .collisionUnavailable)]
        let failureBoxes = DebugRegions.boxes(snapshot: failureSnap, plan: DesktopPlan(snapshot: failureSnap),
                                              items: failureItems, marks: [], targetLanguage: "en")
        expect(failureBoxes.map(\.code) == [.overflow, .collision], "O and C stay primary, never R: \(failureBoxes.map(\.code))")
        expect(SourceResidue.count(snapshot: failureSnap, items: failureItems, targetLanguage: "en") == 0,
               "Only painted items can be residue")
        expect(SourceResidue.regions(snapshot: snap, items: items, targetLanguage: "en") == Set(["residue", "condensedResidue", "coverResidue"]),
               "Residue is reported as the painted region ids")
        let orphan = region("orphan", 9, cjkSource, y: 300)
        let orphanItem = item(orphan, "仍然全是中文", .painted)
        expect(SourceResidue.count(snapshot: snap, items: [orphanItem], targetLanguage: "en") == 0,
               "An item whose region is not in the snapshot has no source text to pair, so it is never residue")
        expect(DebugRegions.counts(boxes).first { $0.code == .missing }?.count == 3, "Residue regions count as R in the legend")

        // Count + aggregate log line: counts only, never text.
        expect(SourceResidue.count(snapshot: snap, items: items, targetLanguage: "en") == 3,
               "Count matches the classified residue regions")
        expect(SourceResidue.count(snapshot: snap, items: items, targetLanguage: "zh-Hans") == 0, "Non-English target counts zero")
        expect(SourceResidue.count(snapshot: nil, items: items, targetLanguage: "en") == 0, "No snapshot pairs no source text")
        expect(SourceResidue.count(snapshot: snap, items: [], targetLanguage: "en") == 0, "No items, no residue")
        let line = SourceResidue.logLine(3)
        expect(line.contains("3") && line.contains("译文仍含源语言字符") && !line.contains(cjkSource) && !line.contains("abc"),
               "Aggregate log line is counts only: \(line)")

        // Export: the same classifier, including the subreason and the untouched paint evidence.
        var settings = TranslationSettings.defaults
        settings.targetLanguage = "en"
        let export = DebugSessionExport.make(settings: settings, target: snap.target, snapshot: snap, plan: plan,
                                             items: items, marks: [], phase: "presented", captureCounts: [:])
        expect(export.regions.map(\.code) == ["R", "R", "R", "T", "T", "K"],
               "Export codes match the drawn residue classification: \(export.regions.map(\.code))")
        expect(export.regions[0].subreason == SourceResidue.subreason && export.regions[1].subreason == SourceResidue.subreason,
               "Export retains the residue subreason")
        expect(export.regions[3].subreason == nil && export.regions[5].subreason == "symbols",
               "Export keeps K subreasons and leaves clean successes empty")
        expect(export.regions[0].outcome == "painted" && export.regions[0].paintRects == [DebugSessionExport.Rect(residueRegion.rect)],
               "Export still records the real outcome and paint rectangles for a residue region")
        expect(export.legendCounts["R"] == 3 && export.legendCounts["T"] == 2, "Exported legend counts the residue regions as R")
        do {
            let data = try JSONEncoder().encode(export)
            expect(try JSONDecoder().decode(DebugSessionExport.self, from: data) == export, "Residue export JSON roundtrip")
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let regionsJSON = json["regions"] as! [[String: Any]]
            expect(regionsJSON[0]["subreason"] as? String == SourceResidue.subreason, "Residue subreason is in the JSON")
        } catch { expect(false, "Residue export JSON failed: \(error)") }
    }
}
