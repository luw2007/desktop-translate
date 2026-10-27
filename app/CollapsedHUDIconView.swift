import AppKit

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
