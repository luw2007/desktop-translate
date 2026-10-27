import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    // MARK: explicit debug JSON export (synthetic data only; no disk, capture, permission or model calls)

    static func debugExportChecks() {
        var t = target(selection: rect(20, 30, 500, 200))
        t.bundleID = "test.synthetic"
        let block = LayoutRegion(id: "pane", role: .pane, rect: rect(0, 0, 800, 600))
        let r = TextRegion(id: "paragraph", parentID: "pane", kind: .prose, rect: rect(30, 40, 150, 34),
                           text: "Read `value` carefully", confidence: 0.875, lineRects: [rect(30, 40, 150, 14), rect(30, 60, 90, 14)],
                           isParagraphBlock: true)
        let transform = TransformProvenance(crop: t.effectiveSelection, imagePixelSize: CGSize(width: 1000, height: 400), windowOrigin: t.frame.origin)
        let snap = CaptureSnapshot(target: t, provenance: .ocr, transform: transform, layout: [block], regions: [r])
        let plan = DesktopPlan(snapshot: snap)
        let protected = TextRegion(id: "protected", kind: .label, rect: rect(300, 100), text: "`value`", readingOrder: 1)
        let protectedSnapshot = snapshot([protected])
        let protectedPlan = DesktopPlan(snapshot: protectedSnapshot)
        let protectedExport = DebugSessionExport.make(settings: .defaults, target: nil, snapshot: protectedSnapshot,
                                                       plan: protectedPlan, items: [], marks: [], phase: "planned", captureCounts: [:])
        expect(protectedExport.regions.first?.protectedFragments == protectedPlan.skipped.first?.protectedFragments,
               "Skipped exports retain plan fragment evidence")
        let item = OverlayItem(regionID: r.id, readingOrder: 0, text: "仔细阅读 `value`", protectedFragments: ["`value`"],
                               occupied: [r.rect], clip: r.rect, cover: [rect(30, 40, 220, 60)], background: .white,
                               fontSize: 12, outcome: .paintedCover)
        var settings = TranslationSettings.defaults
        settings.piExecutable = "/private/secret/not-exported"
        settings.inputMode = .image
        let export = DebugSessionExport.make(settings: settings, target: nil, snapshot: snap, plan: plan,
                                             items: [item], marks: [], phase: "presented", captureCounts: ["ocrLines": 2])
        expect(export.schemaVersion == 1 && ISO8601DateFormatter().date(from: String(export.timestamp.prefix(19)) + "Z") != nil, "Versioned export has ISO8601 timestamp")
        expect(export.target?.bundleID == t.bundleID && export.target?.frame.x == -1200 && export.target?.selection == DebugSessionExport.Rect(t.effectiveSelection), "Target identity and coordinate systems preserved")
        expect(export.target?.scaleX == 2 && export.target?.scaleY == 2 && export.capture?.imagePixelWidth == 1000, "Exact captured scales and pixels exported")
        expect(export.blocks.first?.id == "pane" && export.regions.first?.parentID == "pane" && export.regions.first?.isParagraphBlock == true, "Block and paragraph association preserved")
        expect(export.regions.first?.confidence == 0.875 && export.regions.first?.sourceText == r.text && export.regions.first?.translation == item.text, "Source evidence and translated text preserved")
        expect(export.regions.first?.paintRects == item.cover.map(DebugSessionExport.Rect.init) && export.regions.first?.fontSize == 12, "Cover geometry and font evidence retained")
        expect(export.regions.first?.protectedFragments == item.protectedFragments, "Rendered protected fragments exported")
        let pending = DebugSessionExport.make(settings: settings, target: t, snapshot: snap, plan: plan,
                                              items: [], marks: [], phase: "translating", captureCounts: [:])
        expect(pending.regions.first?.protectedFragments == plan.plannedProtectedFragments[r.id], "Pending export retains plan fragments without reclassification")
        let mark = DebugMark(kind: .dropped, rects: [rect(10, 10), rect(10, 30)])
        let failed = DebugSessionExport.make(settings: settings, target: t, snapshot: nil, plan: nil,
                                             items: [], marks: [mark], phase: "failed", captureCounts: ["dropped": 1])
        let empty = DebugSessionExport.make(settings: settings, target: nil, snapshot: nil, plan: nil,
                                            items: [], marks: [], phase: "idle", captureCounts: [:])
        expect(failed.regions.isEmpty && failed.observations.count == 1 && failed.legendCounts == ["D": 1] && failed.capture == nil, "Failure exports held geometry without inventing a snapshot")
        expect(empty.target == nil && empty.regions.isEmpty && empty.observations.isEmpty && empty.legendCounts.isEmpty, "No-session export remains valid")
        do {
            for value in [export, pending, failed, empty] {
                let data = try JSONEncoder().encode(value)
                expect(try JSONDecoder().decode(DebugSessionExport.self, from: data) == value, "Debug export JSON roundtrip")
                let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let settingsJSON = json["settings"] as! [String: Any]
                expect(Set(settingsJSON.keys) == Set(["mode", "inputMode", "model", "sourceLanguage", "targetLanguage"]), "Settings JSON is explicitly whitelisted")
                expect(!String(decoding: data, as: UTF8.self).contains(settings.piExecutable), "Executable/config paths do not leak into JSON")
                if let observations = json["observations"] as? [[String: Any]] {
                    expect(observations.allSatisfy { $0["sourceText"] == nil && $0["source"] == nil && $0["confidence"] == nil }, "Discarded JSON never invents source/confidence")
                }
            }
        } catch { expect(false, "Debug export JSON failed: \(error)") }
    }


}
