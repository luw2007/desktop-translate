import AppKit
import Foundation

// Debug overlay: where recognized text went. Display only. Everything here is derived AFTER the session decided what to
// translate/paint; nothing in this file feeds back into planning, painting, collision or freshness, and nothing carries
// text, pixels or hashes (boxes are geometry + a code + an index).

/// One outcome category per recognized line/region. Every case is produced by a real code path:
/// - `painted`/`extended`/`overflow`/`collision`/`noOccupancy`: `OverlayItem.Outcome` (extended = painted into proven-free space).
/// - `protected`/`skipped`: `DesktopPlan.skipped` ("protected kind ..." / "nothing to translate" or duplicate id).
/// - `missing`: a planned region with no presented item (translation failed, was refused, or freshness failed).
/// - `straddle`/`dropped`/`lowConfidence`: observations that never became regions (`OCRGrouper`, `DesktopCapture`).
enum DebugCode: String, CaseIterable {
    case painted = "T", extended = "E", overflow = "O", collision = "C", noOccupancy = "N"
    case condensed = "S", cover = "V"
    case protected = "P", skipped = "K", missing = "R"
    case straddle = "X", dropped = "D", lowConfidence = "L"

    var title: String {
        switch self {
        case .painted: return "已绘制译文"
        case .extended: return "已绘制（扩展到已确认空白处）"
        case .condensed: return "已绘制（窄体/缩小字号，最小 9pt）"
        case .cover: return "半透明覆盖（会盖住邻近内容）"
        case .overflow: return "空间不足（橙色标记）"
        case .collision: return "与其他文字冲突，未能显示（橙色标记）"
        case .noOccupancy: return "无可用原文位置"
        case .protected: return "受保护（代码/路径等）"
        case .skipped: return "无需翻译 / 非正文"
        case .missing: return "已规划但无译文"
        case .straddle: return "跨界文字，已省略"
        case .dropped: return "越界区域，已丢弃"
        case .lowConfidence: return "识别置信度过低，已忽略"
        }
    }

    var color: NSColor {
        switch self {
        case .painted: return .systemGreen
        case .extended: return .systemTeal
        case .condensed: return .systemMint
        case .cover: return .systemCyan
        case .overflow: return .systemOrange
        case .collision: return .systemRed
        case .noOccupancy: return .systemPink
        case .protected: return .systemBlue
        case .skipped: return .systemGray
        case .missing: return .systemYellow
        case .straddle: return .systemPurple
        case .dropped: return .systemBrown
        case .lowConfidence: return .systemIndigo
        }
    }

    var labelTextColor: NSColor { self == .missing ? .black : .white }
}

struct DebugBox: Equatable {
    var code: DebugCode
    var index: Int
    /// Window-local points (top-left origin), the same coordinate system as `OverlayItem.occupied`.
    var rects: [CGRect]
    /// Rule that fired for a `K` box (`SkipReason.rawValue`); nil otherwise. Code and counts stay `K`.
    var detail: SkipReason? = nil
    var label: String { "\(code.rawValue)\(index)" }
    /// Label drawn on screen: `K7:short` for skipped regions, otherwise `label`.
    var displayLabel: String { detail.map { "\(label):\($0.rawValue)" } ?? label }
}

enum DebugRegions {
    /// Boxes for every region of `snapshot` (classified from the plan and the presented items) plus every mark of an
    /// observation that never became a region. `snapshot`/`plan` may be nil (capture produced no region at all).
    static func boxes(snapshot: CaptureSnapshot?, plan: DesktopPlan?, items: [OverlayItem], marks: [DebugMark]) -> [DebugBox] {
        var out: [DebugBox] = []
        if let snapshot {
            // Snapshot validation guarantees unique region ids, so id lookup is exact.
            var skippedReason: [String: String] = [:]
            var skippedDetail: [String: SkipReason] = [:]
            for skip in plan?.skipped ?? [] { skippedReason[skip.regionID] = skip.reason; skippedDetail[skip.regionID] = skip.detail }
            var itemByID: [String: OverlayItem] = [:]
            for item in items { itemByID[item.regionID] = item }
            for region in snapshot.regions.sorted(by: { $0.readingOrder < $1.readingOrder }) {
                let source = region.lineRects.isEmpty ? [region.rect] : region.lineRects
                let rects = source.filter { !$0.isNull && !$0.isEmpty && $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite }
                guard !rects.isEmpty else { continue }
                let code: DebugCode
                var detail: SkipReason?
                if let reason = skippedReason[region.id] {
                    code = reason.hasPrefix(DesktopPlan.protectedReasonPrefix) ? .protected : .skipped
                    if code == .skipped { detail = skippedDetail[region.id] }
                } else if let item = itemByID[region.id] {
                    switch item.outcome {
                    case .painted: code = item.isExtended ? .extended : .painted
                    case .paintedCondensed: code = .condensed
                    case .paintedCover: code = .cover
                    case .fitOverflow: code = .overflow
                    case .collisionUnavailable: code = .collision
                    case .noOccupancy: code = .noOccupancy
                    }
                } else {
                    code = .missing
                }
                out.append(DebugBox(code: code, index: region.readingOrder + 1, rects: rects, detail: detail))
            }
        }
        var next: [DebugCode: Int] = [:]
        for mark in marks {
            let code: DebugCode
            switch mark.kind {
            case .lowConfidence: code = .lowConfidence
            case .straddleOmitted: code = .straddle
            case .dropped: code = .dropped
            }
            let rects = mark.rects.filter { !$0.isNull && !$0.isEmpty }
            guard !rects.isEmpty else { continue }
            next[code, default: 0] += 1
            out.append(DebugBox(code: code, index: next[code]!, rects: rects))
        }
        return out
    }

    /// Per-code totals in `DebugCode.allCases` order, only codes that occur.
    static func counts(_ boxes: [DebugBox]) -> [(code: DebugCode, count: Int)] {
        DebugCode.allCases.compactMap { code in
            let n = boxes.reduce(0) { $0 + ($1.code == code ? 1 : 0) }
            return n > 0 ? (code, n) : nil
        }
    }

    /// Counts only, never text or coordinates.
    static func logLine(_ counts: [(code: DebugCode, count: Int)]) -> String {
        "调试区域计数：" + (counts.isEmpty ? "无" : counts.map { "\($0.code.rawValue)=\($0.count)" }.joined(separator: " "))
    }

    /// Per-reason totals of the plan's "nothing to translate" skips (the `K` boxes), `SkipReason.allCases` order.
    static func skipCounts(_ skipped: [SkippedRegion]) -> [(reason: SkipReason, count: Int)] {
        SkipReason.allCases.compactMap { reason in
            let n = skipped.reduce(0) { $0 + ($1.detail == reason ? 1 : 0) }
            return n > 0 ? (reason, n) : nil
        }
    }

    /// Counts only, never text or coordinates.
    static func skipLogLine(_ counts: [(reason: SkipReason, count: Int)]) -> String {
        "无需翻译原因计数：" + (counts.isEmpty ? "无" : counts.map { "\($0.reason.rawValue)=\($0.count)" }.joined(separator: " "))
    }
}

// MARK: - Drawing

enum DebugBoxPainter {
    static let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
    static let labelHeight: CGFloat = 13

    /// Label rectangle for a box in a flipped (top-left origin) view of `bounds`: above the first outline when there is
    /// room (so it does not cover the text), else inside its top-left corner.
    static func labelRect(for outline: CGRect, textWidth: CGFloat, bounds: CGRect) -> CGRect {
        let width = textWidth + 6
        var x = outline.minX
        x = max(bounds.minX, min(bounds.maxX - width, x))
        let above = outline.minY - labelHeight
        let y = above >= bounds.minY ? above : outline.minY
        return CGRect(x: x, y: y, width: width, height: labelHeight)
    }

    /// Call from a flipped view's `draw`.
    static func draw(_ boxes: [DebugBox], in bounds: CGRect) {
        for box in boxes {
            let color = box.code.color
            color.setStroke()
            for rect in box.rects {
                let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1.5
                path.stroke()
            }
        }
        for box in boxes {
            guard let first = box.rects.first else { continue }
            let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: box.code.labelTextColor]
            let text = box.displayLabel as NSString
            let size = text.size(withAttributes: attributes)
            let rect = labelRect(for: first, textWidth: ceil(size.width), bounds: bounds)
            box.code.color.setFill()
            rect.fill()
            text.draw(at: CGPoint(x: rect.minX + 3, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attributes)
        }
    }
}

/// Small nonactivating, click-through legend next to the target window. Never key: Esc is still handled by the barrier.
@MainActor
final class DebugLegendPanel {
    let panel: PassivePanel

    private final class LegendView: NSView {
        let rows: [(code: DebugCode, count: Int)]
        static let rowHeight: CGFloat = 16
        static let width: CGFloat = 236
        override var isFlipped: Bool { true }
        init(rows: [(code: DebugCode, count: Int)]) {
            self.rows = rows
            super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: CGFloat(rows.count + 1) * Self.rowHeight + 12))
        }
        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.1, alpha: 0.88).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
            ("调试：识别区域" as NSString).draw(at: CGPoint(x: 8, y: 5), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
            for (index, row) in rows.enumerated() {
                let y = 6 + CGFloat(index + 1) * Self.rowHeight
                let swatch = CGRect(x: 8, y: y + 1, width: 22, height: 13)
                row.code.color.setFill(); swatch.fill()
                let code = row.code.rawValue as NSString
                let codeAttributes: [NSAttributedString.Key: Any] = [.font: DebugBoxPainter.labelFont, .foregroundColor: row.code.labelTextColor]
                let codeSize = code.size(withAttributes: codeAttributes)
                code.draw(at: CGPoint(x: swatch.midX - codeSize.width / 2, y: swatch.midY - codeSize.height / 2), withAttributes: codeAttributes)
                ("\(row.count)　\(row.code.title)" as NSString).draw(at: CGPoint(x: 36, y: y), withAttributes: body)
            }
        }
    }

    init(geometry: TargetGeometry, rows: [(code: DebugCode, count: Int)]) {
        let view = LegendView(rows: rows)
        let size = view.frame.size
        let target = geometry.appKitFrame
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? target
        // Beside the target when there is room (right, else left); otherwise inside its bottom-left corner.
        var origin = CGPoint(x: target.maxX + 8, y: target.maxY - size.height)
        if origin.x + size.width > visible.maxX {
            origin.x = target.minX - size.width - 8
            if origin.x < visible.minX { origin = CGPoint(x: target.minX + 8, y: target.minY + 8) }
        }
        origin.y = max(visible.minY, min(visible.maxY - size.height, origin.y))
        panel = PassivePanel(appKitFrame: CGRect(origin: origin, size: size))
        panel.wantsKey = false
        panel.ignoresMouseEvents = true
        panel.contentView = view
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil); panel.contentView = nil }
}
