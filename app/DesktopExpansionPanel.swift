import AppKit
import Carbon.HIToolbox

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
            case .painted, .paintedCondensed: flag = ""
            case .paintedCover: flag = "（半透明覆盖，会盖住邻近内容）"
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
