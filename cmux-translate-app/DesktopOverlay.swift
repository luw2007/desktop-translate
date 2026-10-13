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
/// use this same object construction (same font, paragraph style, padding, containers), so they cannot disagree.
final class OverlayTextLayout {
    let manager = NSLayoutManager()
    let storage: NSTextStorage
    private(set) var containers: [NSTextContainer] = []

    init(text: String, rects: [CGRect], size: CGFloat, color: NSColor) {
        storage = NSTextStorage(string: text, attributes: OverlayItem.attributes(size: size, color: color))
        manager.usesFontLeading = true
        storage.addLayoutManager(manager)
        for rect in rects {
            let container = NSTextContainer(size: rect.size)
            container.lineFragmentPadding = 2
            container.lineBreakMode = .byWordWrapping
            container.maximumNumberOfLines = 0
            manager.addTextContainer(container)
            containers.append(container)
        }
    }

    /// True only if every glyph is laid out inside the containers (width and height), and no whitespace-free
    /// non-CJK token (URL, path, identifier, protected fragment) had to be split across lines/containers.
    var fits: Bool {
        guard let last = containers.last else { return storage.length == 0 }
        let total = manager.numberOfGlyphs
        if total == 0 { return true }
        manager.ensureLayout(for: last)
        guard manager.textContainer(forGlyphAt: total - 1, effectiveRange: nil) != nil else { return false }
        var inside = true
        for container in containers {
            let range = manager.glyphRange(for: container)
            manager.enumerateLineFragments(forGlyphRange: range) { _, used, _, _, _ in
                if used.maxY > container.size.height + 0.5 || used.maxX > container.size.width + 0.5 { inside = false }
            }
        }
        guard inside else { return false }
        let ns = storage.string as NSString
        guard let regex = try? NSRegularExpression(pattern: "\\S+") else { return false }
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
        return unbroken
    }

    func draw(containerIndex: Int, at origin: CGPoint) {
        guard containers.indices.contains(containerIndex) else { return }
        let range = manager.glyphRange(for: containers[containerIndex])
        guard range.length > 0 else { return }
        manager.drawGlyphs(forGlyphRange: range, at: origin)
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
/// neighbouring content. If the translation cannot fit those rectangles at >= `minimumFontSize`, `overflow` is true:
/// nothing is painted over the source, a marker is shown, and the full text is available in the expansion panel.
/// Collision-unavailable items omit even the marker; their full text remains available through HUD expansion.
struct OverlayItem: Equatable {
    var regionID: String
    var readingOrder: Int
    var text: String
    var protectedFragments: [String]
    var occupied: [CGRect]          // window-local points, drawing order
    var clip: CGRect                // bounding box of `occupied`; informational, NEVER painted
    var background: NSColor
    var fontSize: CGFloat
    var overflow: Bool
    var occupancyUnavailable: Bool = false

    static let minimumFontSize: CGFloat = 12

    /// Rectangles that receive paint (empty on overflow).
    var paintRects: [CGRect] { overflow ? [] : occupied }

    static func make(from translations: [RegionTranslation], snapshot: CaptureSnapshot, selection: CGRect) -> [OverlayItem] {
        let bounds = CGRect(origin: .zero, size: snapshot.target.frame.size)
        let parents = Dictionary(snapshot.layout.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        let originals = Dictionary(snapshot.regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return translations.compactMap { t in
            let source = t.rects.isEmpty ? [t.unionRect] : t.rects
            let occupied = OverlayOccupancy.rects(source: source, parent: t.parentID.flatMap { parents[$0] }, bounds: bounds, selection: selection)
            guard let first = occupied.first else { return nil }
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
            let color: NSColor
            if let b = originals[t.regionID]?.background {
                color = NSColor(srgbRed: b.red, green: b.green, blue: b.blue, alpha: b.verified ? 1 : max(0.92, b.alpha))
            } else {
                color = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
            }
            return OverlayItem(regionID: t.regionID, readingOrder: t.readingOrder, text: t.text,
                               protectedFragments: t.protectedFragments, occupied: occupied, clip: clip,
                               background: color, fontSize: size, overflow: !fits, occupancyUnavailable: collision)
        }
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
    var sessionHandler: ((TranslationSession) async -> Void)?
    var onOCR: (() -> Void)?
    var onExpand: (() -> Void)?
    var onRegion: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onClose: (() -> Void)?
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

    init(geometry: TargetGeometry, model: DesktopHUDModel) {
        self.geometry = geometry
        self.model = model
        host = NSHostingView(rootView: DesktopHUDView(model: model))
        panel = PassivePanel(appKitFrame: .zero, level: .floating)
        panel.contentView = host
        panel.wantsKey = false
        panel.hasShadow = true
        panel.keyHandler = nil
        place()
    }

    /// Outside the target when there is room (above, else below); otherwise pinned inside the target's top edge.
    /// Always inside the visible frame of the screen holding the target so it stays visible.
    func place() {
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
        model.configuration = nil
        panel.keyHandler = nil
        panel.wantsKey = false
        panel.orderOut(nil)
        panel.contentView = nil
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
            let flag = item.overflow ? "（空间不足，未覆盖原文）" : ""
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
