import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/// Language-pack state of the pair currently selected in the translation settings window. An `auto` source is its own
/// case: pack state is only knowable per concrete pair, i.e. after recognition, so it can never be reported as
/// installed/needs-install up front.
enum LanguagePackState: Equatable {
    case installed
    case needsInstall
    case unsupported
    /// Source equals target: nothing to translate, so no pack is needed.
    case samePair
    /// Auto source: the pack is checked against the language actually recognised at translation time.
    case autoDetectPending
    /// Auto source whose target language Apple Translation cannot produce at all.
    case autoTargetUnsupported
}

/// Local Apple Translation language availability. Preflight runs BEFORE any target lock or capture.
enum LanguagePreflight {
    enum Result: Equatable {
        case ready
        case needsInstall
        case unsupported
        /// Source equals target: nothing to translate (fixed message, no capture).
        case samePair
    }

    static func language(_ code: String) -> Locale.Language { Locale.Language(identifier: code) }

    /// Concrete pair check. `source` must be a real code (auto is resolved by `detect` first).
    static func check(source: String, target: String) async -> Result {
        if source == target { return .samePair }
        switch await LanguageAvailability().status(from: language(source), to: language(target)) {
        case .installed: return .ready
        case .supported: return .needsInstall
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Settings-window projection of `check` for the pair currently selected in the popups. An auto source can only be
    /// answered for its target here; which pack is needed follows from the recognised language at translation time.
    static func packState(for settings: TranslationSettings) async -> LanguagePackState {
        if settings.isAutoSource {
            return await checkTargetSupported(settings.targetLanguage) ? .autoDetectPending : .autoTargetUnsupported
        }
        switch await check(source: settings.sourceLanguage, target: settings.targetLanguage) {
        case .ready: return .installed
        case .needsInstall: return .needsInstall
        case .unsupported: return .unsupported
        case .samePair: return .samePair
        }
    }

    /// Target-only check used before capture when the source is auto: the target must be a language Apple Translation
    /// can produce at all. Pack state is only knowable per concrete pair, after detection.
    static func checkTargetSupported(_ target: String) async -> Bool {
        let supported = await LanguageAvailability().supportedLanguages
        return supported.contains { $0.isEquivalent(to: language(target)) }
    }

    /// Real detection with NLLanguageRecognizer over the text that will be translated. Returns a supported code from
    /// `TranslationLanguages` only when the recognizer's top hypothesis is a listed language with probability >= 0.6;
    /// otherwise nil (never guessed).
    static func detect(_ texts: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = TranslationLanguages.all.flatMap { entry -> [NLLanguage] in
            entry.code == "zh-Hans" ? [.simplifiedChinese] : entry.code == "zh-Hant" ? [.traditionalChinese] : [NLLanguage(rawValue: entry.code)]
        }
        recognizer.processString(texts.joined(separator: "\n"))
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 else { return nil }
        return TranslationLanguages.all.first { $0.code == best.key.rawValue }?.code
    }
}

@MainActor
final class LanguagePreparationModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published var status = "请先在目标应用中触发翻译以确定语言对。"
    @Published var busy = false
    @Published var installed = false
    /// Concrete (source, target) pair to prepare. nil = unknown (auto source before any detection).
    @Published var pair: (source: String, target: String)?

    private var pairName: String {
        guard let pair else { return "" }
        return "\(TranslationLanguages.name(pair.source)) → \(TranslationLanguages.name(pair.target))"
    }

    func setPair(_ pair: (source: String, target: String)?) {
        self.pair = pair
        installed = false
        if pair == nil { status = "源语言为“自动检测”：请先在目标应用中触发翻译，识别出语言后再准备对应语言包。" }
        else { status = "\(pairName) 语言包尚未确认。点击“下载语言包”由系统窗口完成安装；仅本机处理，不上传文字。" }
    }

    func refresh() async {
        guard let pair else { return }
        switch await LanguagePreflight.check(source: pair.source, target: pair.target) {
        case .ready: installed = true; status = "\(pairName) 语言包已安装。请回到目标应用重新触发翻译。"
        case .needsInstall: installed = false
        case .unsupported: installed = false; status = "此系统的 Apple 本机翻译不支持 \(pairName)。"
        case .samePair: installed = true; status = "源语言与目标语言相同，无需语言包。"
        }
    }

    func start() {
        guard !busy, let pair else { return }
        busy = true
        status = "正在请求系统准备语言包…如出现系统窗口，请点击“下载”。"
        configuration = TranslationSession.Configuration(source: LanguagePreflight.language(pair.source), target: LanguagePreflight.language(pair.target))
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
                Button("下载语言包") { model.start() }.disabled(model.busy || model.installed || model.pair == nil)
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
