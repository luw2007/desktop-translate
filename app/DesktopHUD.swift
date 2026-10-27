import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import Translation

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
