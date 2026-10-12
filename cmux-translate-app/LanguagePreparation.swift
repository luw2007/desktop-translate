import AppKit
import SwiftUI
import Translation

/// Local Apple Translation language availability. Preflight runs BEFORE any target lock or capture.
enum LanguagePreflight {
    static let source = Locale.Language(identifier: "en")
    static let target = Locale.Language(identifier: "zh-Hans")

    enum Result: Equatable {
        case ready
        case needsInstall
        case unsupported
    }

    static func check() async -> Result {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .ready
        case .supported: return .needsInstall
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}

@MainActor
final class LanguagePreparationModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published var status = "英文 → 简体中文语言包尚未确认。点击“下载语言包”由系统窗口完成安装；仅本机处理，不上传文字。"
    @Published var busy = false
    @Published var installed = false

    func refresh() async {
        switch await LanguagePreflight.check() {
        case .ready: installed = true; status = "语言包已安装。请回到目标应用重新触发翻译。"
        case .needsInstall: installed = false
        case .unsupported: installed = false; status = "此系统的 Apple 本机翻译不支持 英文 → 简体中文。"
        }
    }

    func start() {
        guard !busy else { return }
        busy = true
        status = "正在请求系统准备语言包…如出现系统窗口，请点击“下载”。"
        configuration = TranslationSession.Configuration(source: LanguagePreflight.source, target: LanguagePreflight.target)
    }

    func run(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            busy = false
            await refresh()
        } catch {
            busy = false
            status = "语言包准备失败：\(error.localizedDescription)"
        }
        configuration = nil
    }
}

private struct LanguagePreparationView: View {
    @ObservedObject var model: LanguagePreparationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("准备本机语言包").font(.headline)
            Text(model.status).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("下载语言包") { model.start() }.disabled(model.busy || model.installed)
            }
        }
        .padding(20)
        .frame(width: 440)
        // Visible host so the system download approval sheet attaches to this independent window.
        .translationTask(model.configuration) { session in await model.run(session) }
        .task { await model.refresh() }
    }
}

/// Independent, activatable, target-unbound window. Activation here is the one explicitly allowed exception.
@MainActor
final class LanguagePreparationController: NSObject, NSWindowDelegate {
    let model = LanguagePreparationModel()
    private let window: NSWindow
    var onClose: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 160), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "准备本机语言包"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LanguagePreparationView(model: model))
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
