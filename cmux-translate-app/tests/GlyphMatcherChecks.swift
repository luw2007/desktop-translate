// Pure checks for fixtures/GlyphSceneManifest.swift (not run by the author).
// swiftc fixtures/GlyphSceneManifest.swift cmux-translate-app/tests/GlyphMatcherChecks.swift -o /tmp/glyph-matcher-checks
import CoreGraphics
import Foundation

@main
struct GlyphMatcherChecks {
    static func main() {
        func expect(_ c: Bool, _ m: String) { precondition(c, m) }
        func tok(_ id: String, _ text: String, _ order: Int, _ r: CGRect) -> GlyphToken {
            GlyphToken(id: id, group: "t", text: text, order: order, line: 0, container: GlyphRect(r.insetBy(dx: -4, dy: -4)),
                       glyph: GlyphRect(r), ink: GlyphRect(r), mutates: false)
        }
        let a = tok("a", "Alpha", 0, CGRect(x: 10, y: 10, width: 40, height: 12))
        let b = tok("b", "Beta", 1, CGRect(x: 60, y: 10, width: 30, height: 12))
        let ok = GlyphMatcher.match(expected: [a, b],
                                    observed: [GlyphObservedBox(text: "Beta", rect: CGRect(x: 59, y: 9, width: 32, height: 14)),
                                               GlyphObservedBox(text: "Alpha", rect: CGRect(x: 9, y: 9, width: 42, height: 14))],
                                    tolerance: 0.5, maxInflation: 2)
        expect(ok.passed && ok.pairs.count == 2, "Unordered observation of exact tokens matches 1:1: \(ok.failures)")
        expect((ok.maxAbsError ?? 99) <= 1.0 + 1e-9, "Edge errors are one point")

        let normalized = GlyphMatcher.match(expected: [a], observed: [GlyphObservedBox(text: "\tAlpha  ", rect: a.glyph.cg)],
                                            tolerance: 0, maxInflation: 0)
        expect(normalized.passed, "Normalized whitespace retains exact source identity")
        let wrongText = GlyphMatcher.match(expected: [a], observed: [GlyphObservedBox(text: "Alpba", rect: a.glyph.cg)],
                                           tolerance: 100, maxInflation: 100)
        expect(wrongText.failures == [.unmatchedExpected("a"), .unmatchedObserved(0)],
               "Nearby geometry never substitutes for source text identity")

        let miss = GlyphMatcher.match(expected: [a, b], observed: [GlyphObservedBox(text: "Alpha", rect: a.glyph.cg)], tolerance: 0.5, maxInflation: 2)
        expect(!miss.passed && miss.failures.contains(.unmatchedExpected("b")), "Missing token fails")

        let extra = GlyphMatcher.match(expected: [a], observed: [GlyphObservedBox(text: "Alpha", rect: a.glyph.cg),
                                                                  GlyphObservedBox(text: "Stray", rect: CGRect(x: 200, y: 200, width: 5, height: 5))],
                                       tolerance: 0.5, maxInflation: 2)
        expect(extra.failures == [.unmatchedObserved(1)], "Unmatched observed box fails")

        let duplicate = GlyphMatcher.match(expected: [a], observed: [GlyphObservedBox(text: "Alpha", rect: a.glyph.cg),
                                                                       GlyphObservedBox(text: "Alpha", rect: a.glyph.cg)],
                                           tolerance: 0, maxInflation: 0)
        expect(duplicate.failures == [.ambiguousExpected("a", 2)], "Two boxes for one token fail rather than select nearest")

        let twin1 = tok("c1", "Cancel", 0, CGRect(x: 10, y: 10, width: 40, height: 12))
        let twin2 = tok("c2", "Cancel", 1, CGRect(x: 100, y: 10, width: 40, height: 12))
        let merged = GlyphMatcher.match(expected: [twin1, twin2], observed: [GlyphObservedBox(text: "Cancel", rect: CGRect(x: 5, y: 5, width: 140, height: 20))],
                                        tolerance: 0.5, maxInflation: 200)
        expect(!merged.passed, "One observed box covering two identical tokens is ambiguous and fails")
        expect(merged.failures.contains(.ambiguousObserved(0, ["c1", "c2"])), "Shared box cannot satisfy two identical tokens")

        let cut = GlyphMatcher.match(expected: [a], observed: [GlyphObservedBox(text: "Alpha", rect: CGRect(x: 14, y: 10, width: 36, height: 12))], tolerance: 1, maxInflation: 2)
        expect(cut.failures == [.notContained("a", 4)], "Clipped glyph fails containment")
        let fat = GlyphMatcher.match(expected: [a], observed: [GlyphObservedBox(text: "Alpha", rect: CGRect(x: 0, y: 10, width: 50, height: 12))], tolerance: 1, maxInflation: 2)
        expect(fat.failures == [.excessInflation("a", 10)], "Over-wide box fails inflation")

        let swapped = GlyphMatcher.match(expected: [twin1, twin2], observed: [GlyphObservedBox(text: "Cancel", rect: twin1.glyph.cg),
                                                                               GlyphObservedBox(text: "Cancel", rect: twin2.glyph.cg)], tolerance: 0.5, maxInflation: 1)
        expect(swapped.passed, "Identical text at distinct places matches by containment, not nearest edge")

        let reversedOrder = GlyphMatcher.match(expected: [tok("first", "First", 0, twin2.glyph.cg),
                                                          tok("second", "Second", 1, twin1.glyph.cg)],
                                               observed: [GlyphObservedBox(text: "First", rect: twin2.glyph.cg),
                                                          GlyphObservedBox(text: "Second", rect: twin1.glyph.cg)],
                                               tolerance: 0, maxInflation: 0)
        expect(reversedOrder.failures == [.outOfOrder("second")], "Expected reading order is enforced")

        let q = GlyphGeometry.quartz(fromAppKit: CGRect(x: 10, y: 100, width: 50, height: 20), primaryScreenHeight: 200)
        expect(q == CGRect(x: 10, y: 80, width: 50, height: 20), "AppKit to Quartz flip")
        let snapped = GlyphGeometry.pixelSnapped(CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), scale: 2)
        expect(snapped == CGRect(x: 0, y: 0, width: 1, height: 1), "Outward pixel snapping at 2x")
        expect(!GlyphMatcher.oracleAgrees(GlyphToken(id: "n", group: "t", text: " ", order: 0, line: 0, container: a.container, glyph: a.glyph, ink: nil, mutates: false),
                                          tolerance: 1, maxSlack: 1), "No ink never agrees")

        expect(GlyphMatcher.oracleAgrees(a, tolerance: 0, maxSlack: 0), "Coincident ink and glyph bounds agree")
        let shiftedInk = GlyphToken(id: "shifted", group: "t", text: "Alpha", order: 0, line: 0, container: a.container,
                                    glyph: a.glyph, ink: GlyphRect(a.ink!.cg.offsetBy(dx: 5, dy: 0)), mutates: false)
        expect(!GlyphMatcher.oracleAgrees(shiftedInk, tolerance: 1, maxSlack: 1), "Oracle rejects shifted ink")

        let scene = GlyphScene(sceneID: "boundary", runRevision: 7, phase: "stable", caretVisible: false, sequence: 9,
                               pid: 42, bundleID: "local.desktop-translate.glyph-fixture.desktop-plugins-ocr", windowID: 99,
                               frameQuartz: GlyphRect(x: 80, y: 80, w: 640, h: 400), contentTopInset: 28,
                               backingScale: 2, displayID: 1, displayFrameQuartz: GlyphRect(x: 0, y: 0, w: 1440, h: 900),
                               displayScale: 2, isActive: true, tokens: [a], decorations: [], observer: GlyphObserverCounts())
        let observed = [GlyphObservedBox(text: "Alpha", rect: a.glyph.cg)]
        let measured = GlyphMetric.measure(scene: scene, revisionBefore: 7, revisionAfter: 7, stage: "mask",
                                           observed: observed, tolerance: 4, maxInflation: 4, expectedPID: 42)
        expect(measured.passed && measured.pairs.count == 1 && measured.pairs[0].tokenID == "a" &&
               measured.expectedCount == 1 && measured.observedCount == 1 && measured.maxAbsErrorPoints == 0,
               "Owned, unchanged fixture yields exact paired metric")
        let changed = GlyphMetric.measure(scene: scene, revisionBefore: 6, revisionAfter: 7, stage: "ocr",
                                          observed: observed, tolerance: 4, maxInflation: 4, expectedPID: 42)
        expect(!changed.passed && changed.failures == ["runRevisionChanged"] && changed.pairs.isEmpty &&
               changed.maxAbsErrorPoints == nil, "Revision change fails before measuring stale scene")
        let foreign = GlyphMetric.measure(scene: scene, revisionBefore: 7, revisionAfter: 7, stage: "ocr",
                                          observed: observed, tolerance: 4, maxInflation: 4, expectedPID: 43)
        expect(!foreign.passed && foreign.failures == ["notOwnedScene"] && foreign.pairs.isEmpty,
               "Wrong owning PID fails before measuring unrelated window")
        let empty = GlyphMetric.measure(scene: scene, revisionBefore: 7, revisionAfter: 7, stage: "ocr",
                                        observed: [], tolerance: 4, maxInflation: 4, expectedPID: 42)
        expect(!empty.passed && empty.failures == ["unmatchedExpected:a"] && empty.maxAbsErrorPoints == nil,
               "Missing observed boxes never invent a zero edge error")
        print("Glyph matcher checks passed")
    }
}
