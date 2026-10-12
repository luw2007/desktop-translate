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
            if event.type == .keyDown { _ = keyHandler?(event) }
            return   // every key is consumed; close keys are handled by keyHandler
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

    func show() { panel.orderFrontRegardless() }
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

    func show() { panel.orderFrontRegardless() }

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

/// One drawable mask: text confined to `clip` (the region's occupied bounds clipped to its parent and the selection).
struct OverlayItem: Equatable {
    var regionID: String
    var text: String
    var protectedFragments: [String]
    var clip: CGRect                // window-local points
    var background: NSColor
    var fontSize: CGFloat
    var overflow: Bool

    static let minimumFontSize: CGFloat = 12

    /// Builds items from planned translations. Masks cover only recognised regions, never the whole window.
    static func make(from translations: [RegionTranslation], snapshot: CaptureSnapshot, selection: CGRect) -> [OverlayItem] {
        let bounds = CGRect(origin: .zero, size: snapshot.target.frame.size)
        let parents = Dictionary(uniqueKeysWithValues: snapshot.layout.map { ($0.id, $0.rect) })
        let originals = Dictionary(uniqueKeysWithValues: snapshot.regions.map { ($0.id, $0) })
        return translations.compactMap { t in
            var clip = t.unionRect.intersection(bounds).intersection(selection.insetBy(dx: -1, dy: -1))
            if let parentID = t.parentID, let parent = parents[parentID] { clip = clip.intersection(parent) }
            guard !clip.isNull, clip.width >= 2, clip.height >= 2 else { return nil }
            let region = originals[t.regionID]
            let lines = max(1, t.rects.count)
            let natural = max(OverlayItem.minimumFontSize, min(28, (clip.height / CGFloat(lines)) * 0.78))
            var size = natural
            var fits = OverlayItem.fits(t.text, width: clip.width, height: clip.height, size: size)
            while !fits && size > OverlayItem.minimumFontSize {
                size = max(OverlayItem.minimumFontSize, size - 1)
                fits = OverlayItem.fits(t.text, width: clip.width, height: clip.height, size: size)
            }
            let color: NSColor
            if let b = region?.background {
                color = NSColor(srgbRed: b.red, green: b.green, blue: b.blue, alpha: b.verified ? 1 : max(0.92, b.alpha))
            } else {
                color = NSColor.windowBackgroundColor.withAlphaComponent(0.96)
            }
            return OverlayItem(regionID: t.regionID, text: t.text, protectedFragments: t.protectedFragments,
                               clip: clip, background: color, fontSize: size, overflow: !fits)
        }
    }

    static func attributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    static func fits(_ text: String, width: CGFloat, height: CGFloat, size: CGFloat) -> Bool {
        let rect = (text as NSString).boundingRect(with: CGSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: attributes(size: size, color: .black))
        return ceil(rect.height) <= height
    }

    var textColor: NSColor {
        let rgb = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance < 0.5 ? .white : .black
    }

    var markerRect: CGRect {
        CGRect(x: clip.maxX - 14, y: clip.maxY - 14, width: 14, height: 14)
    }
}

/// Barrier + masks in one hit-testable surface: masks never receive different event rules than the barrier.
final class OverlayContentView: BarrierView {
    var items: [OverlayItem] = [] { didSet { needsDisplay = true } }
    var onMarker: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if items.contains(where: { $0.overflow && $0.markerRect.insetBy(dx: -4, dy: -4).contains(p) }) { onMarker?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for item in items {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: item.clip).addClip()
            item.background.setFill()
            item.clip.fill()
            (item.text as NSString).draw(with: item.clip.insetBy(dx: 2, dy: 0),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: OverlayItem.attributes(size: item.fontSize, color: item.textColor))
            if item.overflow {
                NSColor.systemOrange.setFill()
                item.markerRect.fill()
                ("⤢" as NSString).draw(at: CGPoint(x: item.markerRect.minX + 2, y: item.markerRect.minY - 1),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
            }
            NSGraphicsContext.restoreGraphicsState()
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
    func close() { model.configuration = nil; panel.orderOut(nil); panel.contentView = nil }
}

// MARK: - Expansion (full translation, non-activating, scrollable)

@MainActor
final class ExpansionPanel {
    let panel: PassivePanel
    private let onClose: () -> Void

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
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.textContainerInset = NSSize(width: 16, height: 12)
            text.drawsBackground = true
            text.backgroundColor = .textBackgroundColor
            let body = items.map(\.text).joined(separator: "\n\n")
            text.textStorage?.setAttributedString(NSAttributedString(
                string: body, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]))
        }
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(scroll)
        panel.contentView = container
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil); panel.contentView = nil }
}
