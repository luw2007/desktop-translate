import CoreGraphics
import Foundation

// Pure (Foundation/CoreGraphics only) public glyph-scene manifest and strict 1:1 matching geometry.
// Written by the independent glyph fixture (fixtures/GlyphSceneFixtureApp.swift) and read by verifiers.
// Contains only fixed public sample text, stable token IDs, rectangles, scales and event-type counts:
// never images, pixel hashes, characters typed, key codes or private screen data.
//
// Coordinate space: every rectangle is WINDOW-LOCAL points, top-left origin, relative to the full window
// frame (title bar included) - the same space as PublicFixture's manifest and the translator's selection.

struct GlyphRect: Codable, Equatable, Sendable {
    var x: Double, y: Double, w: Double, h: Double
    init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    init(_ r: CGRect) { self.init(x: r.origin.x, y: r.origin.y, w: r.size.width, h: r.size.height) }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// One fixed drawn token (a run of glyphs on ONE line). `glyph` is the typographic glyph-bounds rectangle
/// (CoreText/TextKit); `ink` is the tight bound of pixels the in-memory alpha oracle actually painted for
/// this token (nil when the token has no visible ink, e.g. a space-only token).
struct GlyphToken: Codable, Equatable, Sendable {
    var id: String            // stable across runs and revisions, e.g. "boundary.left.1"
    var group: String         // scenario family: boundary | collision | icon | code | cjk | prose | caret
    var text: String
    var order: Int            // expected reading order (top-to-bottom, left-to-right) among all tokens
    var line: Int             // line index inside its container
    var container: GlyphRect  // the box the token is laid out in (never a precision claim)
    var glyph: GlyphRect      // CoreText/TextKit drawn glyph bounds
    var ink: GlyphRect?       // alpha-oracle ink bounds measured from an in-memory render of the same drawing
    var mutates: Bool         // true if this token's text changes between runRevisions
}

struct GlyphObserverCounts: Codable, Equatable, Sendable {
    var mouseDown = 0, scroll = 0, keyDown = 0, resignActive = 0, becomeActive = 0
    /// Event-type counts by broad zone name only, e.g. "covered" / "uncovered". No coordinates.
    var zones: [String: Int] = [:]
}

struct GlyphScene: Codable, Equatable, Sendable {
    static let schema = 1
    var schema = GlyphScene.schema
    var sceneID: String            // stable scene identifier ("boundary", "collision", ...)
    var runRevision: Int           // increments only when drawn content changes (text mutate), not on caret blink
    var phase: String              // stable | mutate | caret
    var caretVisible: Bool         // caret phase only; independent of runRevision
    var sequence: Int              // increments on every manifest write
    var pid: Int32
    var bundleID: String
    var windowID: UInt32
    var frameQuartz: GlyphRect     // window frame, Quartz desktop points, top-left
    var contentTopInset: Double
    var backingScale: Double       // actual window backing scale
    var displayID: UInt32
    var displayFrameQuartz: GlyphRect  // actual display bounds from the real NSScreen, Quartz top-left points
    var displayScale: Double
    var isActive: Bool
    var tokens: [GlyphToken]
    var decorations: [GlyphRect]   // non-text drawn shapes (icons, container borders, caret); never tokens
    var observer: GlyphObserverCounts
}

enum GlyphGeometry {
    /// Convert an AppKit (bottom-left, global) rect to Quartz top-left global points using the primary screen height.
    static func quartz(fromAppKit r: CGRect, primaryScreenHeight: Double) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }
    /// Window-local (top-left) rect -> global Quartz rect.
    static func global(local r: CGRect, windowFrameQuartz f: CGRect) -> CGRect {
        r.offsetBy(dx: f.minX, dy: f.minY)
    }
    /// Global Quartz rect -> window-local rect.
    static func local(global r: CGRect, windowFrameQuartz f: CGRect) -> CGRect {
        r.offsetBy(dx: -f.minX, dy: -f.minY)
    }
    /// Outward pixel-aligned rect at `scale` (device pixels), converted back to points.
    static func pixelSnapped(_ r: CGRect, scale: Double) -> CGRect {
        guard scale > 0 else { return r }
        let x0 = (r.minX * scale).rounded(.down) / scale, y0 = (r.minY * scale).rounded(.down) / scale
        let x1 = (r.maxX * scale).rounded(.up) / scale, y1 = (r.maxY * scale).rounded(.up) / scale
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    /// Signed edge errors of `observed` against `truth`: positive = observed extends OUTSIDE truth, negative = cuts inside.
    static func edgeErrors(observed o: CGRect, truth t: CGRect) -> GlyphEdgeErrors {
        GlyphEdgeErrors(left: t.minX - o.minX, right: o.maxX - t.maxX, top: t.minY - o.minY, bottom: o.maxY - t.maxY)
    }
}

struct GlyphEdgeErrors: Equatable, Sendable {
    var left: Double, right: Double, top: Double, bottom: Double
    /// Largest absolute edge error in points.
    var maxAbs: Double { max(abs(left), abs(right), abs(top), abs(bottom)) }
    /// Largest amount the observed rect cuts INTO truth (0 when it fully contains truth).
    var maxCut: Double { max(0, -left, -right, -top, -bottom) }
}

struct GlyphObservedBox: Equatable, Sendable {
    var text: String
    var rect: CGRect          // window-local points, top-left
    init(text: String, rect: CGRect) { self.text = text; self.rect = rect }
}

enum GlyphMatchFailure: Equatable, Sendable {
    case unmatchedExpected(String)               // token id with no candidate
    case ambiguousExpected(String, Int)          // token id with >1 candidates
    case ambiguousObserved(Int, [String])        // observed index claimed by >1 tokens
    case unmatchedObserved(Int)                  // observed box that matches no token
    case outOfOrder(String)                      // token id whose matched box breaks expected reading order
    case notContained(String, Double)            // token id; amount the observed box cuts into truth (> tolerance)
    case excessInflation(String, Double)         // token id; amount the observed box exceeds truth (> maxInflation)
}

struct GlyphMatchedPair: Equatable, Sendable {
    var tokenID: String
    var observedIndex: Int
    var errors: GlyphEdgeErrors
}

struct GlyphMatchReport: Equatable, Sendable {
    var pairs: [GlyphMatchedPair]
    var failures: [GlyphMatchFailure]
    /// True only when the 1:1 assignment is complete and unambiguous AND no failure of any kind was recorded.
    var passed: Bool { failures.isEmpty && !pairs.isEmpty }
    /// Largest edge error across matched pairs; nil if nothing matched (never a fabricated 0).
    var maxAbsError: Double? { pairs.map { $0.errors.maxAbs }.max() }
}

enum GlyphMatcher {
    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Strict 1:1 matching of product-observed boxes against public expected tokens.
    /// Candidate = same normalized text AND the observed box overlaps the truth rect (center of truth inside the
    /// observed box inflated by `searchSlack`). Nearest-edge selection is never used. Ties/misses fail.
    /// - truth: `.ink` when available (alpha oracle), else `.glyph`.
    /// - tolerance: how far an observed edge may cut INTO truth before `notContained`.
    /// - maxInflation: how far an observed edge may exceed truth before `excessInflation`.
    static func match(expected: [GlyphToken], observed: [GlyphObservedBox], tolerance: Double,
                      maxInflation: Double, searchSlack: Double = 2) -> GlyphMatchReport {
        var failures: [GlyphMatchFailure] = []
        var candidates: [String: [Int]] = [:]
        var claims: [Int: [String]] = [:]
        let norm = observed.map { normalize($0.text) }
        for t in expected {
            let truth = (t.ink ?? t.glyph).cg
            let want = normalize(t.text)
            let center = CGPoint(x: truth.midX, y: truth.midY)
            let hits = observed.indices.filter { i in
                norm[i] == want && observed[i].rect.insetBy(dx: -searchSlack, dy: -searchSlack).contains(center)
            }
            candidates[t.id] = hits
            for i in hits { claims[i, default: []].append(t.id) }
        }
        var pairs: [GlyphMatchedPair] = []
        for t in expected {
            let hits = candidates[t.id] ?? []
            if hits.isEmpty { failures.append(.unmatchedExpected(t.id)); continue }
            if hits.count > 1 { failures.append(.ambiguousExpected(t.id, hits.count)); continue }
            let i = hits[0]
            if let c = claims[i], c.count > 1 { failures.append(.ambiguousObserved(i, c.sorted())); continue }
            let truth = (t.ink ?? t.glyph).cg
            let e = GlyphGeometry.edgeErrors(observed: observed[i].rect, truth: truth)
            if e.maxCut > tolerance { failures.append(.notContained(t.id, e.maxCut)) }
            let inflate = max(e.left, e.right, e.top, e.bottom)
            if inflate > maxInflation { failures.append(.excessInflation(t.id, inflate)) }
            pairs.append(GlyphMatchedPair(tokenID: t.id, observedIndex: i, errors: e))
        }
        let claimed = Set(pairs.map { $0.observedIndex })
        for i in observed.indices where !claimed.contains(i) && claims[i] == nil {
            failures.append(.unmatchedObserved(i))
        }
        // Reading order: observed boxes sorted by (line band, x) must follow expected `order`.
        let byOrder = expected.filter { t in pairs.contains { $0.tokenID == t.id } }.sorted { $0.order < $1.order }
        var lastKey: (Double, Double)? = nil
        for t in byOrder {
            guard let p = pairs.first(where: { $0.tokenID == t.id }) else { continue }
            let r = observed[p.observedIndex].rect
            let key: (Double, Double) = (Double(r.midY), Double(r.minX))
            let band = Double(max(2, r.height * 0.5))
            if let l = lastKey {
                let sameLine = abs(key.0 - l.0) < band
                if sameLine ? key.1 < l.1 : key.0 < l.0 { failures.append(.outOfOrder(t.id)) }
            }
            lastKey = key
        }
        return GlyphMatchReport(pairs: pairs, failures: failures)
    }

    /// Fixture self-check: the typographic glyph rect must contain the alpha-oracle ink within `tolerance`
    /// and not exceed it by more than `maxSlack` (a token without measured ink never agrees).
    static func oracleAgrees(_ t: GlyphToken, tolerance: Double, maxSlack: Double) -> Bool {
        guard let ink = t.ink?.cg else { return false }
        let e = GlyphGeometry.edgeErrors(observed: t.glyph.cg, truth: ink)
        return e.maxCut <= tolerance && max(e.left, e.right, e.top, e.bottom) <= maxSlack
    }
}

// MARK: - Production metric report (public IDs and numbers only)

/// Output of one capture -> snapshot -> match run against an OWNED public glyph scene. Contains token IDs,
/// signed edge errors and failure kinds only: no observed text, no pixels, no hashes, no private capture data.
struct GlyphMetricReport: Codable, Equatable, Sendable {
    struct Pair: Codable, Equatable, Sendable { var tokenID: String; var left: Double, right: Double, top: Double, bottom: Double }
    var sceneID: String
    var runRevision: Int
    var fixtureSequence: Int
    var backingScale: Double
    var stage: String              // "ocr" | "mask" | "translation": which product rectangle set was measured
    var expectedCount: Int
    var observedCount: Int
    var pairs: [Pair]
    var failures: [String]         // e.g. "unmatchedExpected:boundary.top.1"
    var passed: Bool
    var maxAbsErrorPoints: Double? // nil when nothing matched
}

enum GlyphMetric {
    /// Owned-scene gate: refuses any manifest that is not the fixture's own (bundle id prefix, live pid match).
    static func isOwned(_ s: GlyphScene, expectedPID: Int32, bundlePrefix: String = "local.desktop-translate.glyph-fixture.") -> Bool {
        s.schema == GlyphScene.schema && s.pid == expectedPID && s.bundleID.hasPrefix(bundlePrefix) && !s.tokens.isEmpty
    }

    /// Strict metric. `observed` are product rectangles in the scene's window-local space for one stage.
    /// The manifest must be the one read for the SAME capture (same runRevision before and after); callers
    /// pass both revisions and a mismatch fails closed instead of matching mutated text.
    static func measure(scene: GlyphScene, revisionBefore: Int, revisionAfter: Int, stage: String,
                        observed: [GlyphObservedBox], tolerance: Double, maxInflation: Double,
                        expectedPID: Int32) -> GlyphMetricReport {
        func fail(_ f: String) -> GlyphMetricReport {
            GlyphMetricReport(sceneID: scene.sceneID, runRevision: scene.runRevision, fixtureSequence: scene.sequence,
                              backingScale: scene.backingScale, stage: stage, expectedCount: scene.tokens.count,
                              observedCount: observed.count, pairs: [], failures: [f], passed: false, maxAbsErrorPoints: nil)
        }
        guard isOwned(scene, expectedPID: expectedPID) else { return fail("notOwnedScene") }
        guard revisionBefore == scene.runRevision, revisionAfter == scene.runRevision else { return fail("runRevisionChanged") }
        let r = GlyphMatcher.match(expected: scene.tokens, observed: observed, tolerance: tolerance, maxInflation: maxInflation)
        func name(_ f: GlyphMatchFailure) -> String {
            switch f {
            case .unmatchedExpected(let i): return "unmatchedExpected:\(i)"
            case .ambiguousExpected(let i, let n): return "ambiguousExpected:\(i):\(n)"
            case .ambiguousObserved(let i, let ids): return "ambiguousObserved:\(i):\(ids.joined(separator: ","))"
            case .unmatchedObserved(let i): return "unmatchedObserved:\(i)"
            case .outOfOrder(let i): return "outOfOrder:\(i)"
            case .notContained(let i, let a): return "notContained:\(i):\(a)"
            case .excessInflation(let i, let a): return "excessInflation:\(i):\(a)"
            }
        }
        return GlyphMetricReport(sceneID: scene.sceneID, runRevision: scene.runRevision, fixtureSequence: scene.sequence,
                                 backingScale: scene.backingScale, stage: stage, expectedCount: scene.tokens.count,
                                 observedCount: observed.count,
                                 pairs: r.pairs.map { .init(tokenID: $0.tokenID, left: $0.errors.left, right: $0.errors.right, top: $0.errors.top, bottom: $0.errors.bottom) },
                                 failures: r.failures.map(name), passed: r.passed, maxAbsErrorPoints: r.maxAbsError)
    }
}
