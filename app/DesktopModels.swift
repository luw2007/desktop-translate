import CoreGraphics
import Foundation

// Pure value types for desktop capture. No AppKit. Coordinates:
//  - "window-local": points, origin top-left of the target window, y down.
//  - "global":       CoreGraphics display space (top-left of primary display, y down; may be negative).
//  - "AppKit":       bottom-left of primary display, y up (only produced by CoordinateMapper).

struct CaptureTarget: Equatable, Sendable {
    var pid: Int32
    var windowID: UInt32
    /// Launch time of the owning app (seconds since 1970). Distinguishes PID reuse.
    var appLaunchTime: TimeInterval?
    var bundleID: String?
    var appName: String
    var title: String
    /// Window frame in global (CG, top-left) points.
    var frame: CGRect
    var displayIDs: [UInt32]
    /// Window-local selection rect (points); nil = whole window (0,0,w,h).
    var selection: CGRect?
    /// Optional tab / pane identities when the app exposes them.
    var tabID: String?
    var paneID: String?
    /// Bumped whenever tab/pane content, layout or font changes.
    var revision: UInt64

    init(pid: Int32, windowID: UInt32, appLaunchTime: TimeInterval? = nil, bundleID: String? = nil,
         appName: String = "", title: String = "", frame: CGRect, displayIDs: [UInt32] = [],
         selection: CGRect? = nil, tabID: String? = nil, paneID: String? = nil, revision: UInt64 = 0) {
        self.pid = pid; self.windowID = windowID; self.appLaunchTime = appLaunchTime
        self.bundleID = bundleID; self.appName = appName; self.title = title; self.frame = frame
        self.displayIDs = displayIDs; self.selection = selection; self.tabID = tabID
        self.paneID = paneID; self.revision = revision
    }

    /// Tab/pane identity; selection memory is invalidated when this changes.
    var selectionKey: String? {
        (tabID == nil && paneID == nil) ? nil : "\(tabID ?? "")|\(paneID ?? "")"
    }

    /// Capture rect in window-local points: explicit `selection` verbatim if set, else (0,0,w,h).
    /// Adapters never mutate it.
    var effectiveSelection: CGRect {
        selection ?? CGRect(origin: .zero, size: frame.size)
    }

    /// Same window of the same app process instance (frame/title/revision may differ).
    func sameWindow(as other: CaptureTarget) -> Bool {
        pid == other.pid && windowID == other.windowID && appLaunchTime == other.appLaunchTime
    }

    /// Same window and same tab/pane content generation.
    func sameContent(as other: CaptureTarget) -> Bool {
        sameWindow(as: other) && selectionKey == other.selectionKey && revision == other.revision
    }
}

enum SupportLevel: String, Sendable { case verified, partial, unsupported }

/// One capability with the interface and app version that justify it. Unknown app versions can be
/// probed but never be `verified` (`versionVerified == false` caps the effective level at partial).
struct CapabilityEvidence: Equatable, Sendable {
    var level: SupportLevel
    var interface: String
    var appVersion: String?
    var versionVerified: Bool
    var note: String

    init(level: SupportLevel = .unsupported, interface: String = "", appVersion: String? = nil,
         versionVerified: Bool = false, note: String = "") {
        self.level = level; self.interface = interface; self.appVersion = appVersion
        self.versionVerified = versionVerified; self.note = note
    }

    static let unsupported = CapabilityEvidence()

    /// Level after the unverified-version rule.
    var effectiveLevel: SupportLevel {
        (level == .verified && !versionVerified) ? .partial : level
    }
}

struct SnapshotCapabilities: Equatable, Sendable {
    var visibleText: CapabilityEvidence
    var textGeometry: CapabilityEvidence
    var paneLayout: CapabilityEvidence
    var contentRevision: CapabilityEvidence
    var fontRevision: CapabilityEvidence

    init(visibleText: CapabilityEvidence = .unsupported, textGeometry: CapabilityEvidence = .unsupported,
         paneLayout: CapabilityEvidence = .unsupported, contentRevision: CapabilityEvidence = .unsupported,
         fontRevision: CapabilityEvidence = .unsupported) {
        self.visibleText = visibleText; self.textGeometry = textGeometry; self.paneLayout = paneLayout
        self.contentRevision = contentRevision; self.fontRevision = fontRevision
    }

    static let none = SnapshotCapabilities()

    /// Full native placement needs text + geometry + revision, all effectively verified.
    var isFullyNative: Bool {
        [visibleText, textGeometry, contentRevision].allSatisfy { $0.effectiveLevel == .verified }
    }

    /// A stable overlay may only be shown when content can be re-read reliably.
    var canVerifyRevision: Bool { contentRevision.effectiveLevel != .unsupported }
}

enum SnapshotProvenance: String, Sendable {
    case native, pluginOCR, ocr
    /// Text and geometry reported by a vision model about the exact submitted crop (not native, not OCR).
    case modelImage
}

/// How region rects were derived (for evidence and round-trip checks). Window-local points otherwise.
struct TransformProvenance: Equatable, Sendable {
    /// Captured sub-rect in window-local points (the SCK sourceRect).
    var crop: CGRect
    /// Actual captured image size in pixels.
    var imagePixelSize: CGSize
    /// Pixels per point on each axis (imagePixelSize / crop.size).
    var scaleX: CGFloat
    var scaleY: CGFloat
    /// Window origin in global CG points at capture time.
    var windowOrigin: CGPoint

    init(crop: CGRect, imagePixelSize: CGSize, windowOrigin: CGPoint) {
        self.crop = crop; self.imagePixelSize = imagePixelSize; self.windowOrigin = windowOrigin
        scaleX = crop.width > 0 ? imagePixelSize.width / crop.width : 0
        scaleY = crop.height > 0 ? imagePixelSize.height / crop.height : 0
    }

    /// Capture is acceptable only if the image matches sourceRect*scale within 1px; `expected` is the
    /// size derived from point size times the backing scale.
    func imageSizeMatches(expectedPixels: CGSize) -> Bool {
        abs(imagePixelSize.width - expectedPixels.width) <= 1 && abs(imagePixelSize.height - expectedPixels.height) <= 1
    }
}

enum RegionKind: String, Sendable {
    case prose, code, command, prompt, path, diff, log, table, tui
    case button, label, menu, heading, cell
    case unknown

    enum Category: Sendable {
        /// Short UI strings: translated per region, never joined across regions.
        case ui
        /// Paragraph-like text: soft-wrapped lines are merged into one request.
        case prose
        /// Terminal/code content: existing conservative `TranslationPlan`.
        case terminal
        /// Not translated (paths, unknown kinds); surfaced as a warning.
        case protected
    }

    var category: Category {
        switch self {
        case .button, .label, .menu, .heading, .cell: return .ui
        case .prose: return .prose
        case .log, .table, .tui: return .terminal
        case .code, .command, .prompt, .diff, .path, .unknown: return .protected
        }
    }
}

struct LayoutRegion: Equatable, Sendable {
    enum Role: String, Sendable { case window, pane, toolbar, sidebar, list, content, other }
    var id: String
    var parentID: String?
    var role: Role
    var rect: CGRect   // window-local points
    init(id: String, parentID: String? = nil, role: Role = .content, rect: CGRect) {
        self.id = id; self.parentID = parentID; self.role = role; self.rect = rect
    }
}

struct TextRegion: Equatable, Sendable {
    var id: String
    /// Layout region (pane/container) this text belongs to.
    var parentID: String?
    var kind: RegionKind
    var source: SnapshotProvenance
    var rect: CGRect   // window-local points; union of lineRects when present
    var text: String   // soft-wrapped lines joined with "\n", one per lineRects entry
    var confidence: Double
    /// Per visual line rects (window-local points) for soft-wrapped paragraphs; empty = just `rect`.
    var lineRects: [CGRect]
    var readingOrder: Int
    var font: RegionFontEvidence?
    var background: RegionBackgroundEvidence?
    /// Per `lineRects` entry (or `[rect]`): width in points of pixel-verified flat background directly to the right of
    /// that line, measured on the held ORIGINAL capture. Empty or 0 = nothing proven. Never larger than the
    /// geometric room `FreeSpace.room` allows; `OverlayItem.make` re-derives that room and takes the minimum.
    var freeRight: [CGFloat]
    /// Only safely grouped OCR prose may paint the bounding union, including gaps.
    var isParagraphBlock: Bool
    var freeDown: [CGFloat]
    var extensionObstacles: [CGRect]
    var paintSourceRects: [CGRect] { isParagraphBlock ? [rect] : (lineRects.isEmpty ? [rect] : lineRects) }
    init(id: String, parentID: String? = nil, kind: RegionKind = .prose, source: SnapshotProvenance = .ocr,
         rect: CGRect, text: String, confidence: Double = 1, lineRects: [CGRect] = [],
         readingOrder: Int = 0, font: RegionFontEvidence? = nil, background: RegionBackgroundEvidence? = nil,
         freeRight: [CGFloat] = [], isParagraphBlock: Bool = false, freeDown: [CGFloat] = [],
         extensionObstacles: [CGRect] = []) {
        self.id = id; self.parentID = parentID; self.kind = kind; self.source = source
        self.rect = rect; self.text = text; self.confidence = confidence; self.lineRects = lineRects
        self.readingOrder = readingOrder; self.font = font; self.background = background; self.freeRight = freeRight
        self.isParagraphBlock = isParagraphBlock; self.freeDown = freeDown; self.extensionObstacles = extensionObstacles
    }
}

enum SnapshotLimits {
    static let maxRegions = 2_000
    static let maxLayoutRegions = 500
    static let maxCharactersPerRegion = 20_000
    static let maxTotalCharacters = 200_000
}

enum SnapshotValidationError: Error, Equatable, CustomStringConvertible {
    case emptyID, duplicateID(String), missingParent(id: String, parent: String), parentCycle(String)
    case tooManyRegions(Int), regionTooLong(id: String), totalTooLong
    case invalidRect(id: String), outOfBounds(id: String), invalidConfidence(id: String)
    case invalidBounds, stale

    var description: String {
        switch self {
        case .emptyID: return "empty id"
        case .duplicateID(let i): return "duplicate id \(i)"
        case .missingParent(let i, let p): return "region \(i) has unknown parent \(p)"
        case .parentCycle(let i): return "parent cycle at \(i)"
        case .tooManyRegions(let n): return "too many regions (\(n))"
        case .regionTooLong(let i): return "region \(i) too long"
        case .totalTooLong: return "snapshot text too long"
        case .invalidRect(let i): return "region \(i) has invalid rect"
        case .outOfBounds(let i): return "region \(i) outside window bounds"
        case .invalidConfidence(let i): return "region \(i) has invalid confidence"
        case .invalidBounds: return "invalid window bounds"
        case .stale: return "snapshot revision is stale"
        }
    }
}

/// Geometry-only record of recognized text that never became a translatable region (debug overlay only).
/// Window-local points; carries no text, pixels or hashes.
struct DebugMark: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Vision confidence below `OCRGrouper.minimumConfidence`: the line was ignored.
        case lowConfidence
        /// The line straddles a reliable container boundary without complete word evidence: withheld from translation.
        case straddleOmitted
        /// A grouped region whose lines are not fully contained by its container (or crop): dropped at capture.
        case dropped
    }
    var kind: Kind
    var rects: [CGRect]
}

struct CaptureSnapshot: Equatable, Sendable {
    var id: UUID
    var target: CaptureTarget
    var capabilities: SnapshotCapabilities
    var provenance: SnapshotProvenance
    var transform: TransformProvenance?
    var layout: [LayoutRegion]
    var regions: [TextRegion]
    var capturedAt: Date

    init(id: UUID = UUID(), target: CaptureTarget, capabilities: SnapshotCapabilities = .none,
         provenance: SnapshotProvenance, transform: TransformProvenance? = nil,
         layout: [LayoutRegion] = [], regions: [TextRegion], capturedAt: Date = Date()) {
        self.id = id; self.target = target; self.capabilities = capabilities; self.provenance = provenance
        self.transform = transform; self.layout = layout; self.regions = regions; self.capturedAt = capturedAt
    }

    /// Window-local bounds (origin zero, size of target frame).
    var bounds: CGRect { CGRect(origin: .zero, size: target.frame.size) }

    /// Validates ids (non-empty, unique across layout+regions), parent links (exist, acyclic),
    /// limits, finite in-bounds rects (1pt tolerance), confidence in 0...1, and optional revision freshness.
    func validate(currentRevision: UInt64? = nil) throws {
        if let currentRevision, currentRevision != target.revision { throw SnapshotValidationError.stale }
        let size = target.frame.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw SnapshotValidationError.invalidBounds
        }
        guard regions.count <= SnapshotLimits.maxRegions else { throw SnapshotValidationError.tooManyRegions(regions.count) }
        guard layout.count <= SnapshotLimits.maxLayoutRegions else { throw SnapshotValidationError.tooManyRegions(layout.count) }
        var seen = Set<String>()
        var parents: [String: String?] = [:]
        func note(_ id: String, _ parent: String?) throws {
            guard !id.isEmpty else { throw SnapshotValidationError.emptyID }
            guard seen.insert(id).inserted else { throw SnapshotValidationError.duplicateID(id) }
            parents[id] = .some(parent)
        }
        let bounds = self.bounds.insetBy(dx: -1, dy: -1)
        func check(_ id: String, _ r: CGRect) throws {
            let vals = [r.origin.x, r.origin.y, r.size.width, r.size.height]
            guard vals.allSatisfy({ $0.isFinite }), r.width >= 0, r.height >= 0 else {
                throw SnapshotValidationError.invalidRect(id: id)
            }
            guard bounds.contains(r) else { throw SnapshotValidationError.outOfBounds(id: id) }
        }
        for l in layout { try note(l.id, l.parentID); try check(l.id, l.rect) }
        var total = 0
        for r in regions {
            try note(r.id, r.parentID); try check(r.id, r.rect)
            for lr in r.lineRects { try check(r.id, lr) }
            guard r.text.count <= SnapshotLimits.maxCharactersPerRegion else { throw SnapshotValidationError.regionTooLong(id: r.id) }
            guard r.confidence.isFinite, (0...1).contains(r.confidence) else { throw SnapshotValidationError.invalidConfidence(id: r.id) }
            total += r.text.count
        }
        guard total <= SnapshotLimits.maxTotalCharacters else { throw SnapshotValidationError.totalTooLong }
        for (id, parent) in parents {
            var cur = parent ?? nil
            var hops = 0
            while let p = cur {
                guard let next = parents[p] else { throw SnapshotValidationError.missingParent(id: id, parent: p) }
                hops += 1
                if p == id || hops > parents.count { throw SnapshotValidationError.parentCycle(id) }
                cur = next ?? nil
            }
        }
        let layoutByID = Dictionary(uniqueKeysWithValues: layout.map { ($0.id, $0) })
        for l in layout {
            if let parent = l.parentID, let p = layoutByID[parent], !p.rect.insetBy(dx: -1, dy: -1).contains(l.rect) {
                throw SnapshotValidationError.outOfBounds(id: l.id)
            }
        }
        for r in regions {
            if let parent = r.parentID {
                // Text must be clipped by a layout parent, not another text region.
                guard let p = layoutByID[parent] else { throw SnapshotValidationError.missingParent(id: r.id, parent: parent) }
                guard p.rect.insetBy(dx: -1, dy: -1).contains(r.rect) else { throw SnapshotValidationError.outOfBounds(id: r.id) }
            }
            for lr in r.lineRects where !r.rect.insetBy(dx: -1, dy: -1).contains(lr) {
                throw SnapshotValidationError.outOfBounds(id: r.id)
            }
        }
    }
}


struct RegionFontEvidence: Equatable, Sendable {
    var family: String?
    var pointSize: CGFloat?
    /// Verified terminal grid cell size in points (nil = no reliable Unicode/grid mapping).
    var gridCellSize: CGSize?
}

struct RegionBackgroundEvidence: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    var verified: Bool
}
