import Foundation

/// A text-bearing snapshot made only by the explicit export action. It does not capture, translate, or log.
/// Geometry is window-local top-left points, except `target.frame` (global CG points) and pixel dimensions.
struct DebugSessionExport: Codable, Equatable {
    struct Rect: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = Double(rect.origin.x); y = Double(rect.origin.y)
            width = Double(rect.width); height = Double(rect.height)
        }
    }

    /// Deliberately whitelisted: executable paths, credentials, environment, and config are not exported.
    struct Settings: Codable, Equatable {
        var mode: String
        var inputMode: String
        var model: String
        var sourceLanguage: String
        var targetLanguage: String
    }

    struct Target: Codable, Equatable {
        var pid: Int32
        var windowID: UInt32
        var bundleID: String?
        var frame: Rect
        var selection: Rect?
        var effectiveSelection: Rect
        var scaleX: Double?
        var scaleY: Double?
    }

    struct Capture: Codable, Equatable {
        var snapshotID: UUID
        var capturedAt: String
        var provenance: String
        var crop: Rect?
        var imagePixelWidth: Double?
        var imagePixelHeight: Double?
        var windowOriginX: Double?
        var windowOriginY: Double?
    }

    struct Block: Codable, Equatable {
        var id: String
        var parentID: String?
        var role: String
        var rect: Rect
    }

    struct Region: Codable, Equatable {
        var id: String
        var index: Int
        var code: String
        /// `K` skip rule (`SkipReason.rawValue`) or the `R` residue note (`SourceResidue.subreason`); nil otherwise.
        var subreason: String?
        var skipReason: String?
        var parentID: String?
        var kind: String
        var source: String
        var rect: Rect
        var rects: [Rect]
        var confidence: Double
        var sourceText: String
        var translation: String?
        var outcome: String?
        var occupiedRects: [Rect]
        var paintRects: [Rect]
        var fontSize: Double?
        var isExtended: Bool?
        var extendedRects: [Rect]
        var coverRects: [Rect]
        /// No partner identity is retained by OverlayItem; geometry overlap is not recorded collision evidence.
        var collisionPartnerIndex: Int?
        var isParagraphBlock: Bool
        var protectedFragments: [String]?
    }

    /// Discarded capture observations retain geometry only. Text, provenance and confidence were not retained.
    struct Observation: Codable, Equatable {
        var index: Int
        var code: String
        var subreason: String?
        var rects: [Rect]
        var source: String?
        var sourceText: String?
        var confidence: Double?
    }

    var schemaVersion: Int
    var timestamp: String
    var appVersion: String?
    var appBuild: String?
    var appCommit: String?
    var settings: Settings
    var target: Target?
    var capture: Capture?
    var phase: String
    var captureCounts: [String: Int]
    var legendCounts: [String: Int]
    var blocks: [Block]
    var regions: [Region]
    var observations: [Observation]

    static func make(settings: TranslationSettings, target: CaptureTarget?, snapshot: CaptureSnapshot?,
                     plan: DesktopPlan?, items: [OverlayItem], marks: [DebugMark], phase: String,
                     captureCounts: [String: Int]) -> DebugSessionExport {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Use the same classifier and numbering as the displayed legend, not a second outcome policy.
        let boxes = DebugRegions.boxes(snapshot: snapshot, plan: plan, items: items, marks: marks,
                                       targetLanguage: settings.targetLanguage)
        var itemByID: [String: OverlayItem] = [:]
        for item in items { itemByID[item.regionID] = item }
        let plannedFragments = plan?.plannedProtectedFragments ?? [:]
        var skipByID: [String: SkippedRegion] = [:]
        for skip in plan?.skipped ?? [] { skipByID[skip.regionID] = skip }
        var regions: [Region] = []
        for region in (snapshot?.regions ?? []).sorted(by: { $0.readingOrder < $1.readingOrder }) {
            let sourceRects = region.lineRects.isEmpty ? [region.rect] : region.lineRects
            let rects = sourceRects.filter { !$0.isNull && !$0.isEmpty && $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite }
            guard !rects.isEmpty else { continue }
            let box = boxes[regions.count]
            let item = itemByID[region.id]
            regions.append(Region(id: region.id, index: box.index, code: box.code.rawValue,
                                  subreason: box.subreason ?? skipByID[region.id]?.detail?.rawValue,
                                  skipReason: skipByID[region.id]?.reason, parentID: region.parentID,
                                  kind: region.kind.rawValue, source: region.source.rawValue,
                                  rect: Rect(region.rect), rects: rects.map(Rect.init), confidence: region.confidence,
                                  sourceText: region.text, translation: item?.text, outcome: item.map { outcomeName($0.outcome) },
                                  occupiedRects: (item?.occupied ?? []).map(Rect.init), paintRects: (item?.paintRects ?? []).map(Rect.init),
                                  fontSize: item.map { Double($0.fontSize) }, isExtended: item?.isExtended,
                                  extendedRects: (item?.extended ?? []).map(Rect.init), coverRects: (item?.cover ?? []).map(Rect.init),
                                  collisionPartnerIndex: nil, isParagraphBlock: region.isParagraphBlock,
                                  protectedFragments: item?.protectedFragments ?? skipByID[region.id]?.protectedFragments ?? plannedFragments[region.id]))
        }
        let observations = boxes.dropFirst(regions.count).map {
            Observation(index: $0.index, code: $0.code.rawValue, subreason: nil, rects: $0.rects.map(Rect.init),
                        source: nil, sourceText: nil, confidence: nil)
        }
        let transform = snapshot?.transform
        let exportedTarget = (target ?? snapshot?.target).map {
            Target(pid: $0.pid, windowID: $0.windowID, bundleID: $0.bundleID, frame: Rect($0.frame),
                   selection: $0.selection.map(Rect.init), effectiveSelection: Rect($0.effectiveSelection),
                   scaleX: transform.map { Double($0.scaleX) }, scaleY: transform.map { Double($0.scaleY) })
        }
        let capture = snapshot.map {
            Capture(snapshotID: $0.id, capturedAt: formatter.string(from: $0.capturedAt), provenance: $0.provenance.rawValue,
                    crop: transform.map { Rect($0.crop) }, imagePixelWidth: transform.map { Double($0.imagePixelSize.width) },
                    imagePixelHeight: transform.map { Double($0.imagePixelSize.height) },
                    windowOriginX: transform.map { Double($0.windowOrigin.x) }, windowOriginY: transform.map { Double($0.windowOrigin.y) })
        }
        let bundle = Bundle.main
        return DebugSessionExport(schemaVersion: 1, timestamp: formatter.string(from: Date()),
                                  appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                  appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                  appCommit: bundle.object(forInfoDictionaryKey: "GitCommit") as? String,
                                  settings: Settings(mode: settings.mode.rawValue, inputMode: settings.inputMode.rawValue,
                                                     model: settings.model, sourceLanguage: settings.sourceLanguage,
                                                     targetLanguage: settings.targetLanguage),
                                  target: exportedTarget, capture: capture, phase: phase, captureCounts: captureCounts,
                                  legendCounts: Dictionary(uniqueKeysWithValues: DebugRegions.counts(boxes).map { ($0.code.rawValue, $0.count) }),
                                  blocks: (snapshot?.layout ?? []).map { Block(id: $0.id, parentID: $0.parentID, role: $0.role.rawValue, rect: Rect($0.rect)) },
                                  regions: regions, observations: observations)
    }

    private static func outcomeName(_ outcome: OverlayItem.Outcome) -> String {
        switch outcome {
        case .painted: return "painted"
        case .paintedCondensed: return "paintedCondensed"
        case .paintedCover: return "paintedCover"
        case .fitOverflow: return "fitOverflow"
        case .collisionUnavailable: return "collisionUnavailable"
        case .noOccupancy: return "noOccupancy"
        }
    }
}
