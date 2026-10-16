import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import Translation

// MARK: - Geometry

/// Window-local (top-left, y down) <-> AppKit screen conversion for a locked target. Uses the primary screen height.
struct TargetGeometry {
    let frame: CGRect   // global CG points
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    var appKitFrame: CGRect { CoordinateMapper.globalToAppKit(frame, primaryHeight: Self.primaryHeight) }

    /// Window-local rect -> panel-content rect (panel content is flipped=false, origin bottom-left of panel).
    func contentRect(_ local: CGRect) -> CGRect {
        CGRect(x: local.minX, y: frame.height - local.maxY, width: local.width, height: local.height)
    }
}

// MARK: - Non-activating panel base

/// Never activates the app. It may become key (to swallow keys) without activation because of `.nonactivatingPanel`.
class PassivePanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var wantsKey = false
    /// Set only on the expansion panel: its read-only text view is the sole Command-C/A recipient.
    weak var copyTarget: NSTextView?

    init(appKitFrame: CGRect, level: NSWindow.Level = .floating) {
        super.init(contentRect: appKitFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary]
        animationBehavior = .none
        setFrame(appKitFrame, display: false)
    }

    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
            if event.type == .keyDown {
                // Only the read-only translation text may receive Command-C / Command-A; all other keys stay contained.
                if let target = copyTarget, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   let key = event.charactersIgnoringModifiers?.lowercased() {
                    if key == "c" { target.copy(nil); return }
                    if key == "a" { target.selectAll(nil); return }
                }
                _ = keyHandler?(event)
            }
            return   // every other key is consumed; close keys are handled by keyHandler
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
    override func keyDown(with event: NSEvent) {}
}

// MARK: - Barrier

class BarrierView: NSView {
    /// Marker click points are window-local (flipped view) coordinates.
    var onClick: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func pressureChange(with event: NSEvent) {}
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    // A (nearly) transparent but hit-testable surface: alpha 0 content would be click-through.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.01).setFill()
        dirtyRect.fill()
    }
}

/// Whole-window transparent barrier above the target window. Swallows click/scroll/gesture/non-close keys.
@MainActor
final class BarrierPanel {
    let panel: PassivePanel
    let view: OverlayContentView

    init(geometry: TargetGeometry, onClose: @escaping () -> Void) {
        panel = PassivePanel(appKitFrame: geometry.appKitFrame)
        panel.wantsKey = true
        panel.ignoresMouseEvents = false
        view = OverlayContentView(frame: CGRect(origin: .zero, size: geometry.frame.size))
        panel.contentView = view
        panel.keyHandler = { event in
            if event.keyCode == UInt16(kVK_Escape) { onClose() }
            return true
        }
    }

    func show() { panel.orderFrontRegardless(); panel.makeKey() }
    func close() { panel.orderOut(nil); panel.contentView = nil }
}

// MARK: - Region selection

private final class SelectionView: NSView {
    var rect: CGRect?                 // view coords (bottom-left origin)
    var dragStart: CGPoint?
    var onChange: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        rect = nil
        needsDisplay = true
        onChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(s.x - p.x), height: abs(s.y - p.y))
            .intersection(bounds)
        needsDisplay = true
        onChange?()
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.18).setFill()
        bounds.fill()
        if let rect {
            NSColor.clear.setFill()
            NSGraphicsContext.current?.cgContext.clear(rect)
            NSColor(white: 0, alpha: 0.01).setFill()
            rect.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
        }
    }
}

/// Drag to select, Return confirms, Esc cancels. Window-local points out. Never activates the app.
@MainActor
final class SelectionPanel {
    let panel: PassivePanel
    private let view: SelectionView
    private let geometry: TargetGeometry
    private var onConfirm: ((CGRect) -> Void)?
    private var onCancel: (() -> Void)?

    var currentLocalSelection: CGRect? {
        guard let r = view.rect, r.width >= 1, r.height >= 1 else { return nil }
        return CGRect(x: r.minX, y: geometry.frame.height - r.maxY, width: r.width, height: r.height)
    }

    init(geometry: TargetGeometry, initial: CGRect?, onConfirm: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.geometry = geometry
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        panel = PassivePanel(appKitFrame: geometry.appKitFrame)
        panel.wantsKey = true
        view = SelectionView(frame: CGRect(origin: .zero, size: geometry.frame.size))
        if let initial { view.rect = geometry.contentRect(initial) }
        panel.contentView = view
        panel.keyHandler = { [weak self] event in
            guard let self else { return true }
            switch Int(event.keyCode) {
            case kVK_Escape: self.finish(confirm: false)
            case kVK_Return, kVK_ANSI_KeypadEnter: self.finish(confirm: true)
            default: break
            }
            return true
        }
    }

    func show() { panel.orderFrontRegardless(); panel.makeKey() }

    /// Verification hook: set the drag rectangle (window-local points) as if the user dragged it.
    func setSelectionForVerification(_ local: CGRect) {
        view.rect = geometry.contentRect(local)
        view.needsDisplay = true
    }

    /// Verification hook: confirm programmatically with the current selection.
    func confirmCurrent() { finish(confirm: true) }

    private func finish(confirm: Bool) {
        if confirm {
            // Empty selection: keep the selector open.
            guard let rect = currentLocalSelection else { return }
            let handler = onConfirm
            onConfirm = nil; onCancel = nil
            handler?(rect)
        } else {
            let handler = onCancel
            onConfirm = nil; onCancel = nil
            handler?()
        }
    }

    func close() { panel.orderOut(nil); panel.contentView = nil }
}

// MARK: - Translated masks

/// Multi-container TextKit layout: one container per measured occupied rectangle. Measurement (`fits`) and drawing
/// use this same object (same font, fixed line height, padding, containers, ink shifts), so they cannot disagree.
///
/// A source OCR rectangle bounds glyph INK, not a typographic line box: a 12pt CJK fallback line is taller than a
/// tight English OCR box. Lines are therefore laid out with a fixed line height no taller than the smallest
/// container, then the real drawable glyph ink (CoreText path bounds of the actual fallback-resolved runs, placed at
/// the layout manager's baseline) is measured per container. Fit requires that ink - after a vertical shift inside
/// the container, never beyond it - to lie within the exact source rectangle; the same shift is applied when drawing.
final class OverlayTextLayout {
    let manager = NSLayoutManager()
    let storage: NSTextStorage
    private(set) var containers: [NSTextContainer] = []
    private var measured: (fits: Bool, shifts: [CGFloat])?

    init(text: String, rects: [CGRect], size: CGFloat, color: NSColor) {
        let natural = NSFont.systemFont(ofSize: size).boundingRectForFont.height
        let line = min(natural, rects.map(\.height).min() ?? natural)
        storage = NSTextStorage(string: text, attributes: OverlayItem.attributes(size: size, color: color, lineHeight: line))
        manager.usesFontLeading = false
        storage.addLayoutManager(manager)
        for rect in rects {
            let container = NSTextContainer(size: rect.size)
            container.lineFragmentPadding = 1
            container.lineBreakMode = .byWordWrapping
            container.maximumNumberOfLines = 0
            manager.addTextContainer(container)
            containers.append(container)
        }
    }

    /// True only if every glyph is laid out inside the containers, its measured ink lies inside each exact
    /// container (width and height), and no whitespace-free non-CJK token (URL, path, identifier, protected
    /// fragment) had to be split across lines/containers.
    var fits: Bool { measure().fits }

    /// Vertical ink shift applied to a container when drawing (0 when the typographic baseline already fits).
    func verticalShift(containerIndex: Int) -> CGFloat {
        let shifts = measure().shifts
        return shifts.indices.contains(containerIndex) ? shifts[containerIndex] : 0
    }

    private func measure() -> (fits: Bool, shifts: [CGFloat]) {
        if let measured { return measured }
        let none = (fits: false, shifts: [CGFloat](repeating: 0, count: containers.count))
        guard let last = containers.last else { return (storage.length == 0, []) }
        let total = manager.numberOfGlyphs
        if total == 0 { return (true, none.shifts) }
        manager.ensureLayout(for: last)
        guard manager.textContainer(forGlyphAt: total - 1, effectiveRange: nil) != nil else { measured = none; return none }

        var shifts = none.shifts
        var inside = true
        for (index, container) in containers.enumerated() {
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            let range = manager.glyphRange(for: container)
            manager.enumerateLineFragments(forGlyphRange: range) { fragment, used, _, glyphs, _ in
                if used.maxX > container.size.width + 0.5 { inside = false }
                let chars = self.manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let line = CTLineCreateWithAttributedString(self.storage.attributedSubstring(from: chars))
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                guard !ink.isNull, ink.width > 0 || ink.height > 0 else { return }
                let location = self.manager.location(forGlyphAt: glyphs.location)
                let baseline = fragment.minY + location.y
                let originX = fragment.minX + location.x
                if originX + ink.minX < -0.5 || originX + ink.maxX > container.size.width + 0.5 { inside = false }
                top = min(top, baseline - ink.maxY)
                bottom = max(bottom, baseline - ink.minY)
            }
            guard top <= bottom else { continue }
            let low = -top, high = container.size.height - bottom
            if low > high + 0.5 { inside = false; continue }
            shifts[index] = min(max(0, low), max(high, low))
        }
        guard inside else { measured = (false, shifts); return measured! }

        let ns = storage.string as NSString
        guard let regex = try? NSRegularExpression(pattern: "\\S+") else { measured = (false, shifts); return measured! }
        var unbroken = true
        regex.enumerateMatches(in: storage.string, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let range = match?.range else { return }
            let token = ns.substring(with: range)
            if token.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 1 else { return }
            let tail = glyphs.location + glyphs.length - 1
            let a = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let b = manager.lineFragmentRect(forGlyphAt: tail, effectiveRange: nil)
            let ca = manager.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
            let cb = manager.textContainer(forGlyphAt: tail, effectiveRange: nil)
            if a != b || ca !== cb { unbroken = false; stop.pointee = true }
        }
        measured = (unbroken, shifts)
        return measured!
    }

    func draw(containerIndex: Int, at origin: CGPoint) {
        guard containers.indices.contains(containerIndex) else { return }
        let range = manager.glyphRange(for: containers[containerIndex])
        guard range.length > 0 else { return }
        manager.drawGlyphs(forGlyphRange: range, at: CGPoint(x: origin.x, y: origin.y + verticalShift(containerIndex: containerIndex)))
    }
}

/// Painting uses exact selection boundaries, independently of coordinate-validation tolerance.
/// Only measured text occupancy is known here; this does not establish icon/nontext avoidance.
enum OverlayOccupancy {
    static func rects(source: [CGRect], parent: CGRect?, bounds: CGRect, selection: CGRect) -> [CGRect] {
        OccupiedGeometry.rects(source: source, parent: parent, bounds: bounds, selection: selection)
    }

    /// Edge contact is not overlap. Duplicate/missing identities cannot safely identify self.
    static func collides(occupied: [CGRect], regionID: String, regions: [TextRegion]) -> Bool {
        guard regions.reduce(0, { $0 + ($1.id == regionID ? 1 : 0) }) == 1 else { return true }
        return regions.contains { region in
            guard region.id != regionID else { return false }
            let measured = region.lineRects.isEmpty ? [region.rect] : region.lineRects
            return occupied.contains { paint in
                measured.contains { source in
                    let overlap = paint.intersection(source)
                    return !overlap.isNull && overlap.width > 0 && overlap.height > 0
                }
            }
        }
    }
}

/// One translated region. Masks are painted ONLY on `occupied` (independently measured source line rectangles clipped
/// to window, selection and verified parent container) - never on the union of a paragraph, whose gaps may hold
/// neighbouring content. Every translated region yields exactly one item with one truthful `outcome`; items are never
/// dropped, so full text stays available through the expansion panel (deliberate overflow access, not positioning):
/// - `.painted`: mask + text drawn on the exact source lines; measured ink fits at >= `minimumFontSize`.
/// - `.fitOverflow`: occupancy known and collision-free, but the translation cannot fit at the minimum size; nothing
///   is painted over the source, an orange marker is shown.
/// - `.collisionUnavailable`: the source rectangles overlap another captured region (or identities are ambiguous);
///   nothing and no marker is drawn, source pixels are untouched.
/// - `.noOccupancy`: exact clipping (window/selection/parent) left no source rectangle; nothing drawn.
struct OverlayItem: Equatable {
    enum Outcome: Equatable { case painted, fitOverflow, collisionUnavailable, noOccupancy }

    var regionID: String
    var readingOrder: Int
    var text: String
    var protectedFragments: [String]
    var occupied: [CGRect]          // window-local points, drawing order (empty only for `.noOccupancy`)
    var clip: CGRect                // bounding box of `occupied`; informational, NEVER painted (`.zero` if none)
    var background: NSColor
    var fontSize: CGFloat
    var outcome: Outcome

    static let minimumFontSize: CGFloat = 12

    /// True for every outcome that paints nothing over the source (fit overflow, collision, no occupancy).
    var overflow: Bool { outcome != .painted }
    /// True when no paint AND no marker exist for this item (collision or no occupancy).
    var occupancyUnavailable: Bool { outcome == .collisionUnavailable || outcome == .noOccupancy }

    /// Rectangles that receive paint (empty unless `.painted`).
    var paintRects: [CGRect] { outcome == .painted ? occupied : [] }

    /// Per-outcome totals over a presented set; they always sum to `items.count`.
    struct Counts: Equatable {
        var painted = 0, fitOverflow = 0, collisionUnavailable = 0, noOccupancy = 0
        var total: Int { painted + fitOverflow + collisionUnavailable + noOccupancy }
    }

    static func counts(_ items: [OverlayItem]) -> Counts {
        var c = Counts()
        for item in items {
            switch item.outcome {
            case .painted: c.painted += 1
            case .fitOverflow: c.fitOverflow += 1
            case .collisionUnavailable: c.collisionUnavailable += 1
            case .noOccupancy: c.noOccupancy += 1
            }
        }
        return c
    }

    static func make(from translations: [RegionTranslation], snapshot: CaptureSnapshot, selection: CGRect) -> [OverlayItem] {
        let bounds = CGRect(origin: .zero, size: snapshot.target.frame.size)
        let parents = Dictionary(snapshot.layout.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        let originals = Dictionary(snapshot.regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return translations.map { t in
            let source = t.rects.isEmpty ? [t.unionRect] : t.rects
            let occupied = OverlayOccupancy.rects(source: source, parent: t.parentID.flatMap { parents[$0] }, bounds: bounds, selection: selection)
            let color: NSColor
            if let b = originals[t.regionID]?.background {
                color = NSColor(srgbRed: b.red, green: b.green, blue: b.blue, alpha: b.verified ? 1 : max(0.92, b.alpha))
            } else {
                color = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
            }
            guard let first = occupied.first else {
                return OverlayItem(regionID: t.regionID, readingOrder: t.readingOrder, text: t.text,
                                   protectedFragments: t.protectedFragments, occupied: [], clip: .zero,
                                   background: color, fontSize: minimumFontSize, outcome: .noOccupancy)
            }
            let clip = occupied.dropFirst().reduce(first) { $0.union($1) }
            let minHeight = occupied.map(\.height).min() ?? first.height
            let collision = translations.reduce(0, { $0 + ($1.regionID == t.regionID ? 1 : 0) }) != 1
                || OverlayOccupancy.collides(occupied: occupied, regionID: t.regionID, regions: snapshot.regions)
            var size = max(minimumFontSize, min(28, minHeight * 0.78))
            var fits = !collision && OverlayTextLayout(text: t.text, rects: occupied, size: size, color: .black).fits
            while !collision && !fits && size > minimumFontSize {
                size = max(minimumFontSize, size - 1)
                fits = OverlayTextLayout(text: t.text, rects: occupied, size: size, color: .black).fits
            }
            return OverlayItem(regionID: t.regionID, readingOrder: t.readingOrder, text: t.text,
                               protectedFragments: t.protectedFragments, occupied: occupied, clip: clip,
                               background: color, fontSize: size,
                               outcome: collision ? .collisionUnavailable : (fits ? .painted : .fitOverflow))
        }
    }

    static func attributes(size: CGFloat, color: NSColor, lineHeight: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    static func attributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    var textColor: NSColor {
        let rgb = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance < 0.5 ? .white : .black
    }

    /// Marker sits inside the last occupied rectangle (bottom-right), shrunk to fit it.
    var markerRect: CGRect {
        let rect = occupied.last ?? clip
        let side = min(14, rect.width, rect.height)
        return CGRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side)
    }
}

/// Barrier + masks in one hit-testable surface: masks never receive different event rules than the barrier.
final class OverlayContentView: BarrierView {
    var items: [OverlayItem] = [] { didSet { needsDisplay = true } }
    var onMarker: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if items.contains(where: { $0.overflow && !$0.occupancyUnavailable && $0.markerRect.insetBy(dx: -4, dy: -4).contains(p) }) { onMarker?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for item in items {
            // Paint only the measured occupied rectangles, never the union (gaps between them belong to neighbours).
            if !item.overflow {
                let layout = OverlayTextLayout(text: item.text, rects: item.occupied, size: item.fontSize, color: item.textColor)
                for (index, rect) in item.occupied.enumerated() {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: rect).addClip()
                    item.background.setFill()
                    rect.fill()
                    layout.draw(containerIndex: index, at: rect.origin)
                    NSGraphicsContext.restoreGraphicsState()
                }
            } else if !item.occupancyUnavailable {
                // Fit overflow only: collision-unavailable items must leave every source pixel untouched.
                let marker = item.markerRect
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: marker).addClip()
                NSColor.systemOrange.setFill()
                marker.fill()
                ("⤢" as NSString).draw(at: CGPoint(x: marker.minX + 2, y: marker.minY - 1),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

// MARK: - HUD

@MainActor
final class DesktopHUDModel: ObservableObject {
    enum Phase { case working, done, failed }
    @Published var phase: Phase = .working
    @Published var status = ""
    /// Always visible BEFORE capture: capture source and translation provider.
    @Published var source = ""
    @Published var provider = ""
    /// Human-readable, sanitized plugin support / version / limitation / warning lines (never captured text).
    @Published var detail = ""

    /// Strips control characters, bounds line count and length. Use for any plugin-provided metadata shown in the HUD.
    static func sanitizedDetail(_ raw: String, maxLines: Int = 8, maxLineLength: Int = 160) -> String {
        let lines = raw.split(whereSeparator: \.isNewline).prefix(maxLines).map { line -> String in
            let clean = String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
                .trimmingCharacters(in: .whitespaces)
            return clean.count > maxLineLength ? String(clean.prefix(maxLineLength)) + "…" : clean
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    @Published var shortcut = ""
    @Published var configuration: TranslationSession.Configuration?
    @Published var offersOCR = false
    @Published var offersExpand = false
    @Published var offersRegion = true
    @Published var offersPrepare = false
    @Published var offersCollapse = false
    var sessionHandler: ((TranslationSession) async -> Void)?
    var onOCR: (() -> Void)?
    var onExpand: (() -> Void)?
    var onRegion: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onClose: (() -> Void)?
    var onCollapse: (() -> Void)?
}

private struct DesktopHUDView: View {
    @ObservedObject var model: DesktopHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch model.phase {
                case .working: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                }
                Text(model.status).font(.system(size: 13)).lineLimit(3)
                    .foregroundColor(model.phase == .failed ? .red : .primary)
                Spacer(minLength: 8)
            }
            Text("来源：\(model.source)　翻译：\(model.provider)").font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
            if !model.detail.isEmpty {
                Text(model.detail).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.offersOCR { Button("仅本次使用 OCR") { model.onOCR?() } }
                if model.offersPrepare { Button("准备本机语言包") { model.onPrepare?() } }
                if model.offersRegion { Button("区域翻译") { model.onRegion?() } }
                if model.offersExpand { Button("展开全文") { model.onExpand?() } }
                Spacer()
                if model.offersCollapse { Button("收起") { model.onCollapse?() } }
                Button("关闭") { model.onClose?() }
                Text("Esc / \(model.shortcut)").font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(width: 520, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        // Visible host of the Apple Translation session (download approval sheet needs a visible window).
        .translationTask(model.configuration) { session in await model.sessionHandler?(session) }
    }
}

@MainActor
final class HUDPanel {
    let panel: PassivePanel
    let model: DesktopHUDModel
    private let host: NSHostingView<DesktopHUDView>
    private let geometry: TargetGeometry

    private var collapsed = false
    private var generation = 0
    private lazy var icon = CollapsedHUDIconView { [weak self] in self?.expand() }
    private static let iconSide: CGFloat = 40

    init(geometry: TargetGeometry, model: DesktopHUDModel) {
        self.geometry = geometry
        self.model = model
        host = NSHostingView(rootView: DesktopHUDView(model: model))
        // The panel frame is ours (collapse/expand animate it) so SwiftUI must not drive window sizing, but the
        // intrinsic size must stay: with `[]` fittingSize is 0x0 and every HUD became a zero-size, invisible panel.
        host.sizingOptions = [.intrinsicContentSize]
        panel = PassivePanel(appKitFrame: .zero, level: .floating)
        panel.contentView = host
        panel.wantsKey = false
        panel.hasShadow = true
        panel.keyHandler = nil
        model.onCollapse = { [weak self] in self?.collapse() }
        place()
    }

    var isCollapsed: Bool { collapsed }

    /// Animates the info panel into a small draggable icon. Never key and never activating: the barrier stays the key
    /// window, so Esc keeps dismissing. Clicking the icon (see `CollapsedHUDIconView`) expands it again.
    func collapse() {
        guard !collapsed, panel.isVisible else { return }
        collapsed = true; generation += 1
        let token = generation
        let old = panel.frame, side = Self.iconSide
        let small = CGRect(x: old.maxX - side, y: old.maxY - side, width: side, height: side)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            panel.animator().setFrame(small, display: true)
            host.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.collapsed, self.generation == token, self.panel.isVisible else { return }
                self.panel.contentView = self.icon
                self.host.alphaValue = 1
                self.panel.setFrame(small, display: true)
            }
        })
    }

    func expand() {
        guard collapsed else { return }
        collapsed = false; generation += 1
        let old = panel.frame
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(old) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? old
        var origin = CGPoint(x: old.maxX - size.width, y: old.maxY - size.height)
        origin.x = max(visible.minX, min(visible.maxX - size.width, origin.x))
        origin.y = max(visible.minY, min(visible.maxY - size.height, origin.y))
        host.alphaValue = 0
        panel.contentView = host
        panel.setFrame(old, display: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().setFrame(CGRect(origin: origin, size: size), display: true)
            host.animator().alphaValue = 1
        }
    }

    /// Used when a new operation supersedes the presentation: no animation, back to the ordinary HUD.
    func expandImmediately() {
        guard collapsed else { return }
        collapsed = false; generation += 1
        host.alphaValue = 1
        panel.contentView = host
        place()
    }

    /// Outside the target when there is room (above, else below); otherwise pinned inside the target's top edge.
    /// Always inside the visible frame of the screen holding the target so it stays visible.
    func place() {
        guard !collapsed else { return }
        let size = host.fittingSize
        let target = geometry.appKitFrame
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? target
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.maxY + 6)
        if origin.y + size.height > visible.maxY {
            origin.y = target.minY - size.height - 6
            if origin.y < visible.minY { origin.y = max(visible.minY, min(visible.maxY - size.height, target.maxY - size.height - 6)) }
        }
        origin.x = max(visible.minX, min(visible.maxX - size.width, origin.x))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func show() { place(); panel.orderFrontRegardless() }

    /// Target-unbound error/status mode: the HUD becomes key WITHOUT activating the app (nonactivating panel,
    /// no event tap) so Esc reaches `onEscape`. While in this mode every key is consumed by this HUD only;
    /// call `endMessageOnly()` (or `close()`) to return to the ordinary non-key HUD.
    func showMessageOnly(onEscape: @escaping () -> Void) {
        panel.wantsKey = true
        panel.keyHandler = { event in
            if event.keyCode == UInt16(kVK_Escape) { onEscape() }
            return true
        }
        place()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func endMessageOnly() {
        panel.keyHandler = nil
        panel.wantsKey = false
        if panel.isKeyWindow { panel.resignKey() }
    }

    func close() {
        collapsed = false; generation += 1
        host.alphaValue = 1
        model.onCollapse = nil
        model.configuration = nil
        panel.keyHandler = nil
        panel.wantsKey = false
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

/// Small draggable icon shown while the HUD is collapsed. The hosting panel is non-key and non-activating, so a
/// click or drag here never changes which window is key (the barrier stays key and Esc still dismisses).
final class CollapsedHUDIconView: NSView {
    private let onExpand: () -> Void
    private var dragOrigin: NSPoint?
    private var mouseStart: NSPoint?
    private var dragged = false

    init(onExpand: @escaping () -> Void) {
        self.onExpand = onExpand
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        toolTip = "译文覆盖中：点击展开，拖动移动，Esc 退出"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill(); path.fill()
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
        if let image = NSImage(systemSymbolName: "character.bubble.fill", accessibilityDescription: "译文覆盖中")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold)) {
            let tinted = image.copy() as! NSImage
            tinted.lockFocus()
            NSColor.controlAccentColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(at: NSPoint(x: (bounds.width - tinted.size.width) / 2, y: (bounds.height - tinted.size.height) / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = window?.frame.origin
        mouseStart = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = mouseStart, let origin = dragOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseStart = nil; dragOrigin = nil; dragged = false }
        if !dragged { onExpand() }
    }
}

// MARK: - Expansion (full translation, non-activating, scrollable)

@MainActor
final class ExpansionPanel {
    let panel: PassivePanel
    /// The only responder that may receive Command-C / Command-A (read-only translation text).
    let textView: NSTextView
    private let onClose: () -> Void

    /// Full translations, each preceded by its source region identity (reading-order number and region id).
    static func body(items: [OverlayItem]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let header: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                      .foregroundColor: NSColor.secondaryLabelColor]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
        for (index, item) in items.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n\n", attributes: body)) }
            let flag: String
            switch item.outcome {
            case .painted: flag = ""
            case .fitOverflow: flag = "（空间不足，未覆盖原文）"
            case .collisionUnavailable: flag = "（与相邻文字重叠，未覆盖原文）"
            case .noOccupancy: flag = "（无可用原文位置，未覆盖原文）"
            }
            out.append(NSAttributedString(string: "区域 \(item.readingOrder + 1) · \(item.regionID)\(flag)\n", attributes: header))
            out.append(NSAttributedString(string: item.text, attributes: body))
        }
        return out
    }

    init(geometry: TargetGeometry, items: [OverlayItem], onClose: @escaping () -> Void) {
        self.onClose = onClose
        let target = geometry.appKitFrame
        let size = CGSize(width: min(640, max(320, target.width * 0.7)), height: min(520, max(240, target.height * 0.7)))
        let frame = CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2, width: size.width, height: size.height)
        panel = PassivePanel(appKitFrame: frame, level: .floating)
        panel.wantsKey = true
        panel.hasShadow = true
        panel.keyHandler = { [onClose] event in
            if event.keyCode == UInt16(kVK_Escape) { onClose() }
            return true
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.frame = CGRect(origin: .zero, size: size)
        scroll.autoresizingMask = [.width, .height]
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 16, height: 12)
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textStorage?.setAttributedString(ExpansionPanel.body(items: items))
        textView = text
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(scroll)
        panel.contentView = container
        panel.copyTarget = text
        panel.makeFirstResponder(text)
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.copyTarget = nil; panel.orderOut(nil); panel.contentView = nil }
}
