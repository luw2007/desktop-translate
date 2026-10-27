import AppKit
import Carbon.HIToolbox

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


/// Barrier + masks in one hit-testable surface: masks never receive different event rules than the barrier.
final class OverlayContentView: BarrierView {
    var items: [OverlayItem] = [] { didSet { needsDisplay = true } }
    /// Debug outlines drawn above everything else; display only, never hit-tested differently from the barrier.
    var debugBoxes: [DebugBox] = [] { didSet { needsDisplay = true } }
    var onMarker: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if items.contains(where: { $0.overflow && !$0.occupancyUnavailable && $0.markerRect.insetBy(dx: -4, dy: -4).contains(p) }) { onMarker?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for item in items {
            // Paint only the measured occupied rectangles, never the union (gaps between them belong to neighbours).
            if item.outcome == .paintedCover {
                // Last resort: translucent cover (opaque only over the baselined source lines), thin border, narrow 12pt text.
                let rects = item.cover
                let layout = OverlayTextLayout(text: item.text, rects: rects, size: item.fontSize, color: item.textColor, narrow: true)
                let translucent = item.background.withAlphaComponent(OverlayItem.coverAlpha)
                for (index, rect) in rects.enumerated() {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: rect).addClip()
                    translucent.setFill()
                    rect.fill()
                    item.background.setFill()
                    for base in item.baseRects {
                        let part = base.intersection(rect)
                        if !part.isNull { part.fill() }
                    }
                    layout.draw(containerIndex: index, at: rect.origin)
                    NSGraphicsContext.restoreGraphicsState()
                }
                if let first = rects.first {
                    let outline = rects.dropFirst().reduce(first) { $0.union($1) }
                    NSGraphicsContext.saveGraphicsState()
                    item.textColor.withAlphaComponent(0.6).setStroke()
                    let path = NSBezierPath(rect: outline.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1
                    path.stroke()
                    NSGraphicsContext.restoreGraphicsState()
                }
            } else if !item.overflow {
                let rects = item.paintRects
                let layout = OverlayTextLayout(text: item.text, rects: rects, size: item.fontSize, color: item.textColor, narrow: item.narrow)
                for (index, rect) in rects.enumerated() {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: rect).addClip()
                    item.background.setFill()
                    rect.fill()
                    layout.draw(containerIndex: index, at: rect.origin)
                    NSGraphicsContext.restoreGraphicsState()
                }
            } else if !item.occupancyUnavailable {
                // Fit overflow and unresolved collisions: nothing over the source, only the expandable marker.
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
        if !debugBoxes.isEmpty { DebugBoxPainter.draw(debugBoxes, in: bounds) }
    }
}
