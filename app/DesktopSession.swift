import AppKit
import Foundation
import Translation
import UniformTypeIdentifiers

/// What a session is asked to do.
enum DesktopRun: Equatable {
    case fullWindow
    case region
}

/// Optional plugin routing hook. Returning nil means "no plugin for this target" (OCR is used).
/// `.none`/`.unsupported` fall through to OCR; `.error`/`.needsPermission` stop and offer an explicit one-time OCR.
typealias DesktopPluginProvider = @MainActor (CaptureTarget, CGRect) async -> TerminalPluginRoute?

/// One translation presentation over one locked target. Everything async revalidates `token`, target and layout.
@MainActor
final class DesktopTranslationSession {
    struct Environment {
        var settings: TranslationSettings
        /// Debug display switch, fixed for the lifetime of the session (a menu toggle applies to the next session).
        var debug: DebugSettings
        var shortcutDisplay: String
        var plugin: DesktopPluginProvider?
        var selectionMemory: SelectionMemoryBox
        var onFinished: (DesktopTranslationSession) -> Void
        /// Pair to prepare when known (nil = auto source not yet detected).
        var onPrepareLanguages: ((source: String, target: String)?) -> Void
        var onLogEvent: (String) -> Void
    }

    /// Reference box so window-local selection memory survives sessions.
    final class SelectionMemoryBox { var value = SelectionMemory() }

    var phaseDescription = "idle"
    let environment: Environment
    var tracker = OperationTracker()
    var token: OperationToken?
    let run: DesktopRun
    let hudModel = DesktopHUDModel()
    var hud: HUDPanel?
    var barrier: BarrierPanel?
    var selector: SelectionPanel?
    var expansion: ExpansionPanel?
    var monitor: TargetMonitor?
    var piRunner: PiTranslationRunner?
    var piTask: Task<Void, Never>?
    var captureTask: Task<Void, Never>?
    var geometry: TargetGeometry?
    var target: CaptureTarget?
    var snapshot: CaptureSnapshot?
    var plan: DesktopPlan?
    var items: [OverlayItem] = []
    /// Geometry-only marks of recognized lines that never became regions (debug overlay input).
    var debugMarks: [DebugMark] = []
    var debugLegend: DebugLegendPanel?
    var captureCounts: [String: Int] = [:]
    var finished = false
    var forceOCRNext = false
    var frontPID: Int32?
    /// Signature of the exact crop that was recognised; the only thing `verifyFreshness` may be given.
    var baselineSignature: RegionSignature?
    var baselineAt = Date()
    var appleStartedToken: OperationToken?
    /// Source language recognised by NLLanguageRecognizer for an auto source; nil until known.
    var detectedSource: String?
    var preparePair: (source: String, target: String)?

    var isFinished: Bool { finished }
    var presentedItems: [OverlayItem] { items }
    var presentedSnapshot: CaptureSnapshot? { snapshot }
    var overlayWindowVisible: Bool { barrier?.panel.isVisible ?? false }
    var hudVisible: Bool { hud?.panel.isVisible ?? false }
    var hudSourceText: String { hudModel.source }
    var hudProviderText: String { hudModel.provider }
    var hudShortcutText: String { hudModel.shortcut }
    var hudStatusText: String { hudModel.status }
    var barrierPanel: PassivePanel? { barrier?.panel }
    var hudPanel: PassivePanel? { hud?.panel }
    var expansionPanel: PassivePanel? { expansion?.panel }
    var isTranslating: Bool { tracker.state == .translating }

    init(run: DesktopRun, environment: Environment) {
        self.run = run
        self.environment = environment
        hudModel.shortcut = environment.shortcutDisplay
        hudModel.provider = Self.providerLabel(environment.settings, detected: nil)
        hudModel.source = "屏幕 OCR（本机 Vision）"
        hudModel.onClose = { [weak self] in self?.dismiss(reason: nil) }
        hudModel.onExpand = { [weak self] in self?.showExpansion() }
        hudModel.onRegion = { [weak self] in self?.restartAsRegion() }
        hudModel.onOCR = { [weak self] in self?.captureOCROnce() }
        hudModel.onPrepare = { [weak self] in self?.environment.onPrepareLanguages(self?.preparePair) }
        hudModel.sessionHandler = { [weak self] session in await self?.runAppleSession(session) }
    }

    /// The pair actually used: a fixed source is shown as is; an auto source shows the detected language when known.
    static func pairLabel(_ settings: TranslationSettings, detected: String?) -> String {
        let source = settings.isAutoSource
            ? (detected.map { "自动检测（\(TranslationLanguages.name($0))）" } ?? "自动检测")
            : TranslationLanguages.name(settings.sourceLanguage)
        return "\(source)→\(TranslationLanguages.name(settings.targetLanguage))"
    }

    static func providerLabel(_ settings: TranslationSettings, detected: String?) -> String {
        let pair = pairLabel(settings, detected: detected)
        if settings.mode == .local { return "Apple 本机翻译（\(pair)）" }
        return settings.inputMode == .image ? "pi · \(settings.model)（\(pair)；所选区域截图将发送到所选模型服务）" : "pi · \(settings.model)（\(pair)；文字将发送到所选模型服务）"
    }

    var selectorPanel: SelectionPanel? { selector }
    var currentSelectionPanelWindow: PassivePanel? { selector?.panel }

    func updateShortcut(_ display: String) { hudModel.shortcut = display }

}
