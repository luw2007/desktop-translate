import AppKit
import Carbon.HIToolbox

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
