import AppKit
import Foundation
import Translation

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

    private(set) var phaseDescription = "idle"
    private let environment: Environment
    private var tracker = OperationTracker()
    private var token: OperationToken?
    private let run: DesktopRun
    private let hudModel = DesktopHUDModel()
    private var hud: HUDPanel?
    private var barrier: BarrierPanel?
    private var selector: SelectionPanel?
    private var expansion: ExpansionPanel?
    private var monitor: TargetMonitor?
    private var piRunner: PiTranslationRunner?
    private var piTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var geometry: TargetGeometry?
    private(set) var target: CaptureTarget?
    private var snapshot: CaptureSnapshot?
    private var plan: DesktopPlan?
    private var items: [OverlayItem] = []
    /// Geometry-only marks of recognized lines that never became regions (debug overlay input).
    private var debugMarks: [DebugMark] = []
    private var debugLegend: DebugLegendPanel?
    private var finished = false
    private var forceOCRNext = false
    private var frontPID: Int32?
    /// Signature of the exact crop that was recognised; the only thing `verifyFreshness` may be given.
    private var baselineSignature: RegionSignature?
    private var baselineAt = Date()
    private var appleStartedToken: OperationToken?
    /// Source language recognised by NLLanguageRecognizer for an auto source; nil until known.
    private var detectedSource: String?
    private var preparePair: (source: String, target: String)?

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

    // MARK: lifecycle

    /// The app that was frontmost at hotkey time. Locked synchronously before any UI exists.
    func start(frontmost: NSRunningApplication?) {
        guard let currentToken = Optional(tracker.begin()) else { return }
        token = currentToken
        phaseDescription = "preflight"
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.begin(frontmost: frontmost, token: currentToken)
        }
    }

    private func begin(frontmost: NSRunningApplication?, token: OperationToken) async {
        // 1. Local language availability BEFORE target lock, UI geometry and capture.
        if environment.settings.mode == .local {
            let settings = environment.settings
            if settings.isAutoSource {
                // Pack state is only knowable per concrete pair, i.e. after detection; here only the target must exist.
                let supported = await LanguagePreflight.checkTargetSupported(settings.targetLanguage)
                guard tracker.isCurrent(token) else { environment.onLogEvent("begin 提前返回：操作已过期（目标语言预检后）"); return }
                if !supported {
                    presentMessageOnly(status: "此系统的 Apple 本机翻译不支持目标语言 \(TranslationLanguages.name(settings.targetLanguage))。未捕获屏幕。", failed: true, prepare: false)
                    return
                }
            } else {
                let pairName = "\(TranslationLanguages.name(settings.sourceLanguage)) → \(TranslationLanguages.name(settings.targetLanguage))"
                let availability = await LanguagePreflight.check(source: settings.sourceLanguage, target: settings.targetLanguage)
                guard tracker.isCurrent(token) else { environment.onLogEvent("begin 提前返回：操作已过期（语言对预检后）"); return }
                switch availability {
                case .ready: break
                case .samePair:
                    presentMessageOnly(status: "源语言与目标语言相同，无需翻译。未捕获屏幕。", failed: true, prepare: false)
                    return
                case .unsupported:
                    presentMessageOnly(status: "此系统的 Apple 本机翻译不支持 \(pairName)。未捕获屏幕。", failed: true, prepare: false)
                    return
                case .needsInstall:
                    preparePair = (settings.sourceLanguage, settings.targetLanguage)
                    presentMessageOnly(status: "本机 \(pairName) 语言包尚未安装。未捕获屏幕；请点“准备本机语言包”，安装后再重新触发。", failed: true, prepare: true)
                    return
                }
            }
        }
        // 2. The target must still be the frontmost app we saw at hotkey time (no activation/target.activate).
        guard let frontmost, !frontmost.isTerminated else {
            presentMessageOnly(status: "没有可翻译的前台应用。", failed: true, prepare: false); return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost.processIdentifier else {
            presentMessageOnly(status: "前台应用在准备期间发生变化，已取消。请在目标应用中重新触发。", failed: true, prepare: false); return
        }
        // 3. Lock target (before any panel exists).
        switch TargetLocker.lock(app: frontmost) {
        case .failure(let error):
            presentMessageOnly(status: error.localizedDescription, failed: true, prepare: false)
            return
        case .success(var locked):
            frontPID = locked.pid
            let explicit: CGRect?
            if run == .region {
                explicit = environment.selectionMemory.value.restore(for: locked)
            } else { explicit = nil }
            locked.selection = nil
            target = locked
            let geometry = TargetGeometry(frame: locked.frame)
            self.geometry = geometry
            startMonitor(selection: locked.effectiveSelection, baseline: nil)
            let hudPanel = HUDPanel(geometry: geometry, model: hudModel)
            hud = hudPanel
            hudModel.offersRegion = run != .region
            hudModel.status = run == .region ? "拖选需要翻译的区域，Return 确认，Esc 取消。" : "正在捕获完整窗口…"
            hudModel.phase = .working
            hudPanel.show()
            if run == .region {
                phaseDescription = "selecting"
                presentSelector(initial: explicit, token: token)
            } else {
                presentBarrier()
                await captureAndTranslate(selection: nil, token: token)
            }
        }
    }

    /// Target-unbound persistent status: HUD only, on the pointer's screen, key-safe for Esc without activation.
    private func presentMessageOnly(status: String, failed: Bool, prepare: Bool) {
        environment.onLogEvent("begin 提前返回：仅显示提示 HUD（\(status)）")
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let strip = CGRect(x: visible.minX, y: visible.maxY - 120, width: visible.width, height: 120)
        let geometry = TargetGeometry(frame: CoordinateMapper.appKitToGlobal(strip, primaryHeight: TargetGeometry.primaryHeight))
        self.geometry = geometry
        hud?.close(); hud = nil
        hudModel.configuration = nil
        hudModel.status = status
        hudModel.phase = failed ? .failed : .done
        hudModel.offersPrepare = prepare
        hudModel.offersRegion = false
        hudModel.offersOCR = false
        hudModel.offersExpand = false
        let panel = HUDPanel(geometry: geometry, model: hudModel)
        hud = panel
        panel.showMessageOnly { [weak self] in self?.dismiss(reason: nil) }
        if let token { tracker.advance(token, to: .failed) }
        phaseDescription = "failed"
    }

    /// Observed target invalidation: remove every target-bound artefact first, then show the reason persistently.
    private func handleInvalidation(_ invalidation: TargetInvalidation) {
        guard !finished else { return }
        environment.onLogEvent("目标变化，已撤除覆盖：\(invalidation.reason)")
        if invalidation.clearsSelectionMemory { environment.selectionMemory.value.clear() }
        failUnbound(invalidation.reason)
    }

    private func failUnbound(_ reason: String) {
        guard !finished else { return }
        tracker.cancelActive()
        token = nil
        captureTask?.cancel(); captureTask = nil
        piTask?.cancel(); piTask = nil
        piRunner?.cancel(); piRunner = nil
        monitor?.stop(); monitor = nil
        hudModel.configuration = nil
        expansion?.close(); expansion = nil
        selector?.close(); selector = nil
        barrier?.close(); barrier = nil
        clearDebug()
        items = []; snapshot = nil; plan = nil; baselineSignature = nil
        target = nil
        phaseDescription = "invalidated"
        presentMessageOnly(status: reason, failed: true, prepare: false)
    }

    private func presentBarrier() {
        guard barrier == nil, let geometry else { return }
        let panel = BarrierPanel(geometry: geometry, onClose: { [weak self] in self?.dismiss(reason: nil) })
        panel.view.onMarker = { [weak self] in self?.showExpansion() }
        barrier = panel
        panel.show()
        hud?.show()
    }

    /// Debug overlay: outline + code for every recognized region/line of this capture, plus a legend. Pure display
    /// derived from the finished plan/items/marks; it never alters them. No-op when the setting is off or no barrier exists.
    private func refreshDebug() {
        guard environment.debug.showRegions, let barrier, let geometry else { return }
        let boxes = DebugRegions.boxes(snapshot: snapshot, plan: plan, items: items, marks: debugMarks)
        barrier.view.debugBoxes = boxes
        debugLegend?.close(); debugLegend = nil
        guard !boxes.isEmpty else { return }
        let counts = DebugRegions.counts(boxes)
        environment.onLogEvent(DebugRegions.logLine(counts))
        let legend = DebugLegendPanel(geometry: geometry, rows: counts)
        debugLegend = legend
        legend.show()
    }

    private func clearDebug() {
        debugMarks = []
        barrier?.view.debugBoxes = []
        debugLegend?.close(); debugLegend = nil
    }

    private func presentSelector(initial: CGRect?, token: OperationToken) {
        guard let geometry else { return }
        selector?.close(); selector = nil
        let panel = SelectionPanel(geometry: geometry, initial: initial, onConfirm: { [weak self] rect in
            guard let self, self.tracker.isCurrent(token), var target = self.target else { return }
            let old = self.selector
            target.selection = rect
            self.environment.selectionMemory.value.remember(rect, for: target)
            self.target = target
            self.selector = nil
            self.presentBarrier()
            old?.close()
            self.captureTask = Task { @MainActor in await self.captureAndTranslate(selection: rect, token: token) }
        }, onCancel: { [weak self] in self?.dismiss(reason: nil) })
        selector = panel
        panel.show()
    }

    private func startMonitor(selection: CGRect, baseline: RegionSignature?) {
        guard let target else { return }
        monitor?.stop()
        let monitor = TargetMonitor(target: target, selection: selection, baseline: baseline) { [weak self] invalidation in
            self?.handleInvalidation(invalidation)
        }
        self.monitor = monitor
        monitor.start()
    }

    private enum Validity { case ok, superseded, invalid(TargetInvalidation) }

    private func validity(_ token: OperationToken) -> Validity {
        guard !finished, !Task.isCancelled, tracker.isCurrent(token), let target else { return .superseded }
        if let error = TargetLocker.revalidate(target) { return .invalid(TargetInvalidation(error)) }
        return .ok
    }

    /// Call after EVERY await. A superseded/cancelled operation returns silently (never dismisses its replacement);
    /// only a current operation whose target is observed invalid tears the overlay down with a persistent reason.
    private func proceed(_ token: OperationToken) -> Bool {
        switch validity(token) {
        case .ok: return true
        case .superseded: return false
        case .invalid(let invalidation): handleInvalidation(invalidation); return false
        }
    }

    /// Single supersede: cancels all async work and clears every product of the previous operation, then
    /// starts a new operation token. Force-OCR is cleared here; `captureOCROnce` sets it again afterwards.
    private func supersede() -> OperationToken {
        captureTask?.cancel(); captureTask = nil
        piTask?.cancel(); piTask = nil
        piRunner?.cancel(); piRunner = nil
        hudModel.configuration = nil
        hudModel.offersCollapse = false
        hud?.expandImmediately()
        monitor?.stop(); monitor = nil
        expansion?.close(); expansion = nil
        selector?.close(); selector = nil
        barrier?.view.items = []
        clearDebug()
        items = []; snapshot = nil; plan = nil; baselineSignature = nil
        appleStartedToken = nil
        detectedSource = nil
        preparePair = nil
        hudModel.offersPrepare = false
        hudModel.provider = Self.providerLabel(environment.settings, detected: nil)
        forceOCRNext = false
        hudModel.offersExpand = false
        hudModel.offersOCR = false
        let fresh = tracker.begin()
        token = fresh
        return fresh
    }

    // MARK: capture

    private func captureOCROnce() {
        guard target != nil, !finished else { return }
        let token = supersede()
        forceOCRNext = true
        guard let target else { return }
        startMonitor(selection: target.effectiveSelection, baseline: nil)
        hudModel.offersRegion = false
        hudModel.phase = .working
        hudModel.status = "正在以屏幕 OCR 捕获（仅本次）…"
        captureTask = Task { @MainActor [weak self] in
            await self?.captureAndTranslate(selection: target.selection, token: token)
        }
    }

    private func restartAsRegion() {
        guard geometry != nil, let target, !finished else { return }
        let token = supersede()
        hudModel.offersRegion = false
        hudModel.phase = .working
        hudModel.status = "拖选需要翻译的区域，Return 确认，Esc 取消。"
        let restore = environment.selectionMemory.value.restore(for: target)
        barrier?.close(); barrier = nil
        startMonitor(selection: target.effectiveSelection, baseline: nil)
        phaseDescription = "selecting"
        presentSelector(initial: restore, token: token)
    }

    /// Bounded wait for the barrier to be key, then a fixed pause for the target's focus repaint. Never activates.
    private func settleOverlayFocus() async {
        if let panel = barrier?.panel {
            for _ in 0..<20 where !panel.isKeyWindow { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func captureAndTranslate(selection: CGRect?, token: OperationToken) async {
        guard proceed(token), var target else { return }
        target.selection = selection
        self.target = target
        let rect = target.effectiveSelection
        phaseDescription = "capturing"
        hudModel.phase = .working
        hudModel.detail = ""
        hudModel.source = forceOCRNext ? "屏幕 OCR（本机 Vision，仅本次）" : "屏幕 OCR（本机 Vision）"
        if let name = TerminalPluginRegistry.supportedTerminalNames[target.bundleID ?? ""], !forceOCRNext {
            hudModel.status = "已匹配终端：\(name)（内置插件）。正在读取插件证据；无可验证的原生内容修订时将用屏幕 OCR 并持续校验。"
        } else if forceOCRNext {
            hudModel.status = "正在以屏幕 OCR 捕获并识别（仅本次，跳过插件）…"
        } else {
            hudModel.status = "未匹配内置终端插件（\(target.appName)）：使用屏幕 OCR。正在捕获并识别…"
        }
        // The barrier (and a closing selector) change which of OUR panels is key, which the target observes as a
        // focus change and answers by repainting (hollow/dimmed cursor, selection colours) a little later. The one
        // baseline must be taken AFTER that repaint has settled, otherwise it records the pre-repaint pixels and
        // every later fresh sample differs from it persistently (a false "content changed"). The baseline is still
        // taken exactly once and never replaced; this only orders it after the overlay's own focus effect.
        await settleOverlayFocus()
        guard proceed(token) else { return }
        if environment.settings.mode == .pi, environment.settings.inputMode == .image {
            await captureImageAndTranslate(target: target, rect: rect, token: token)
            return
        }
        var outcome: RouterOutcome?
        var signature: RegionSignature?
        var sourceLabel = "屏幕 OCR（本机 Vision）"
        var pluginWarnings: [String] = []
        var pluginLayoutSnapshot: CaptureSnapshot?
        let skipPlugin = forceOCRNext
        if !skipPlugin, let plugin = environment.plugin {
            let route = await plugin(target, rect)
            guard proceed(token) else { return }
            if let route {
                // Metadata is shown as support evidence only; the source label below is always the actual path.
                if let metadata = route.metadata { hudModel.detail = DesktopHUDModel.sanitizedDetail(metadata.summary) }
                let routed = route.outcome
                switch routed {
                case .snapshot(let s):
                    sourceLabel = "应用插件 · \(s.provenance.rawValue)"
                    outcome = routed
                case .partial(let s, let w):
                    if s.regions.isEmpty {
                        do { try s.validate(currentRevision: target.revision) } catch {
                            showPluginStop(message: "插件布局无效，已拒绝：\(error)。可仅本次使用屏幕 OCR。", token: token); return
                        }
                        guard s.target.sameContent(as: target), s.target.selection == target.selection else {
                            showPluginStop(message: "插件结果与锁定的窗口或选区不一致，已拒绝。可仅本次使用屏幕 OCR。", token: token); return
                        }
                        pluginWarnings = w
                        pluginLayoutSnapshot = s
                        sourceLabel = "应用插件布局 + 屏幕 OCR（\(SnapshotProvenance.pluginOCR.rawValue)）"
                    } else {
                        sourceLabel = "应用插件 · \(s.provenance.rawValue)"
                        outcome = routed
                    }
                case .error(let message):
                    showPluginStop(message: "插件错误：\(message)", token: token); return
                case .needsPermission(let kind):
                    showPluginStop(message: "插件需要授权（\(kind.rawValue)）。可授权后重试，或仅本次使用屏幕 OCR。", token: token); return
                case .none, .unsupported:
                    break   // documented fallthrough to OCR
                }
            }
        }
        forceOCRNext = false
        hudModel.source = sourceLabel
        if outcome == nil {
            let verifiedLayout = pluginLayoutSnapshot.flatMap { $0.capabilities.paneLayout.effectiveLevel == .verified ? $0.layout : nil } ?? []
            let collectMarks: (@MainActor ([DebugMark]) -> Void)? = environment.debug.showRegions
                ? { @MainActor [weak self] (marks: [DebugMark]) in self?.debugMarks = marks }
                : nil
            let (result, sig) = await DesktopCapture.captureWithSignature(
                target: target, selection: rect, sourceLanguage: environment.settings.sourceLanguage, layout: verifiedLayout,
                onDebugMarks: collectMarks)
            guard proceed(token) else { return }
            outcome = result; signature = sig
        }
        guard let outcome else { return }
        var warnings: [String] = []
        let captured: CaptureSnapshot
        switch outcome {
        case .snapshot(let s): captured = s
        case .partial(var s, let w):
            if let plugin = pluginLayoutSnapshot {
                s = Self.merge(ocr: s, plugin: plugin)
            }
            captured = s; warnings = pluginWarnings + w
        case .none:
            finishFailed("未识别到可翻译的文字。可使用“区域翻译”缩小范围。", token: token, region: true); return
        case .unsupported(let message):
            finishFailed(message, token: token, region: false); return
        case .error(let message):
            finishFailed(message, token: token, region: run != .region); return
        case .needsPermission(let kind):
            finishFailed(Self.permissionMessage(kind), token: token, region: false); return
        }
        do { try captured.validate(currentRevision: target.revision) } catch {
            finishFailed("捕获结果无效，已拒绝显示：\(error)", token: token, region: false); return
        }
        guard captured.target.sameContent(as: target), captured.target.selection == target.selection else {
            finishFailed("捕获结果与锁定的目标或选区不一致，已拒绝显示。", token: token, region: false); return
        }
        // Text is accepted only with a concrete current-content signature produced by our own capture of this crop.
        // A plugin `.verified` claim alone is not an implementation of freshness checking.
        guard let signature else {
            if pluginLayoutSnapshot == nil, case .partial(let s, _) = outcome, s.provenance == .ocr {
                finishFailed("没有可核对内容变化的有效翻译区域，已拒绝显示。可使用“区域翻译”缩小范围。", token: token, region: true); return
            }
            showPluginStop(message: "插件文字没有可由本应用核对的当前内容签名（仅声明 verified 不被接受），已拒绝显示。可仅本次使用屏幕 OCR。", token: token); return
        }
        snapshot = captured
        baselineSignature = signature; baselineAt = Date()
        // Selection used an identity-only monitor; now watch the exact recognised crop's content too.
        startMonitor(selection: rect, baseline: signature)
        if !warnings.isEmpty { environment.onLogEvent("捕获提示 \(warnings.count) 项（不含文字内容）") }
        hudModel.detail = DesktopHUDModel.sanitizedDetail(([hudModel.detail] + warnings).filter { !$0.isEmpty }.joined(separator: "\n"))
        hudModel.source = sourceLabel + (warnings.isEmpty ? "" : "　⚠︎ \(warnings.count) 项估算提示，请核对译文")
        beginTranslation(captured, token: token)
    }

    /// Keeps the OCR evidence (visibleText/textGeometry/contentRevision) truthful; takes only paneLayout/fontRevision
    /// and verified, parent-consistent layout regions from the plugin. Falls back to OCR layout if the merge is invalid.
    static func merge(ocr: CaptureSnapshot, plugin: CaptureSnapshot) -> CaptureSnapshot {
        var merged = ocr
        merged.provenance = .pluginOCR
        if plugin.capabilities.paneLayout.effectiveLevel == .verified { merged.capabilities.paneLayout = plugin.capabilities.paneLayout }
        if plugin.capabilities.fontRevision.effectiveLevel == .verified { merged.capabilities.fontRevision = plugin.capabilities.fontRevision }
        guard plugin.capabilities.paneLayout.effectiveLevel == .verified else { return merged }
        var known = Set(ocr.layout.map(\.id) + ocr.regions.map(\.id))
        var extra: [LayoutRegion] = []
        for region in plugin.layout where !known.contains(region.id) {
            if let parent = region.parentID,
               !ocr.layout.contains(where: { $0.id == parent }) && !extra.contains(where: { $0.id == parent }) { continue }
            known.insert(region.id); extra.append(region)
        }
        var candidate = merged
        candidate.layout += extra
        if (try? candidate.validate()) != nil { return candidate }
        return merged
    }

    static func permissionMessage(_ kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "需要屏幕录制权限才能捕获目标窗口。请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许本应用后重试；未捕获任何内容，也没有改用其他窗口。"
        case .accessibility: return "需要辅助功能权限，未捕获。"
        case .automation: return "需要自动化权限，未捕获。"
        }
    }

    private func showPluginStop(message: String, token: OperationToken) {
        guard tracker.advance(token, to: .failed) else { return }
        phaseDescription = "pluginStopped"
        hudModel.phase = .failed
        hudModel.status = message.count > 200 ? String(message.prefix(200)) + "…" : message
        hudModel.offersOCR = true
        hudModel.offersRegion = false
        hud?.place()
    }

    private func finishFailed(_ message: String, token: OperationToken, region: Bool) {
        guard tracker.advance(token, to: .failed) else { return }
        phaseDescription = "failed"
        hudModel.phase = .failed
        hudModel.status = message.count > 200 ? String(message.prefix(200)) + "…" : message
        hudModel.offersRegion = region
        barrier?.view.items = []
        refreshDebug()
        hud?.place()
        // Keep the barrier so the failure remains attached to the locked target until dismissed.
    }

    // MARK: translation
    /// OCR-free image mode: capture the exact crop, send that one in-memory PNG to the selected image-capable pi model,
    /// validate its regions/geometry, derive the immutable baseline from the HELD original pixels, then use the same
    /// freshness gate and renderer as every other path. No OCR, no fallback model or mode on any error.
    private func captureImageAndTranslate(target: CaptureTarget, rect: CGRect, token: OperationToken) async {
        let settings = environment.settings
        hudModel.source = "模型图像理解（pi · \(settings.model)；无 OCR）"
        hudModel.status = "正在捕获所选区域…（该区域截图将发送到所选模型服务）"
        let (held, failure) = await DesktopCapture.captureHeld(target: target, selection: rect)
        guard proceed(token) else { return }
        if let failure {
            switch failure {
            case .needsPermission(let kind): finishFailed(Self.permissionMessage(kind), token: token, region: false)
            case .error(let message): finishFailed(message, token: token, region: run != .region)
            default: finishFailed("捕获失败。", token: token, region: false)
            }
            return
        }
        guard let held, let png = DesktopCapture.pngData(held) else {
            finishFailed("无法编码所选区域截图，未发送。", token: token, region: true); return
        }
        guard tracker.advance(token, to: .translating) else { return }
        phaseDescription = "translating"
        hudModel.phase = .working
        hudModel.status = "正在通过 pi 识别并翻译（\(settings.model)，图像输入）…所选区域截图已发送到所选模型服务"
        let runner = PiTranslationRunner()
        piRunner = runner
        piTask = Task { @MainActor [weak self] in
            do {
                let parsed = try await runner.translateImage(png: png, crop: held.crop, settings: settings)
                guard let self, self.proceed(token) else { return }
                let (snapshot, baseline) = try DesktopCapture.snapshotFromModel(target: target, held: held, regions: parsed.regions, unicode: self.unicodePlanning)
                guard let baseline else {
                    self.finishFailed("没有可核对内容变化的有效翻译区域，已拒绝显示。", token: token, region: true); return
                }
                guard snapshot.target.sameContent(as: target), snapshot.target.selection == target.selection else {
                    self.finishFailed("模型结果与锁定的目标或选区不一致，已拒绝显示。", token: token, region: false); return
                }
                let plan = DesktopPlan(snapshot: snapshot, unicode: self.unicodePlanning)
                guard !plan.requests.isEmpty else {
                    self.snapshot = snapshot; self.baselineSignature = baseline; self.baselineAt = Date(); self.plan = plan
                    self.startMonitor(selection: rect, baseline: baseline)
                    self.tracker.advance(token, to: .presenting)
                    self.hudModel.phase = .done
                    self.hudModel.status = "没有需要翻译的正文（\(plan.skipped.count) 个区域被保护或无需翻译）。"
                    self.hudModel.offersRegion = true
                    self.hud?.place()
                    self.refreshDebug()
                    return
                }
                self.snapshot = snapshot; self.baselineSignature = baseline; self.baselineAt = Date(); self.plan = plan
                self.hudModel.source += "　⚠︎ 位置由模型给出（未经 OCR/原生验证），请核对译文"
                self.startMonitor(selection: rect, baseline: baseline)
                await self.present(token: token) { try plan.renderedWhole(translations: parsed.translations) }
            } catch {
                guard let self, !Task.isCancelled, self.tracker.isCurrent(token), !self.finished else { return }
                // Only the fixed protocol/lifecycle messages; never model text or provider payloads.
                let message = (error as? PiTranslationError)?.message ?? "模型结果无效，已拒绝显示。"
                self.finishFailed("pi 图像翻译失败：\(message)", token: token, region: true)
            }
        }
    }

    private func beginTranslation(_ captured: CaptureSnapshot, token: OperationToken) {
        guard tracker.advance(token, to: .translating) else { return }
        phaseDescription = "translating"
        let plan = DesktopPlan(snapshot: captured, unicode: unicodePlanning)
        self.plan = plan
        if plan.requests.isEmpty {
            tracker.advance(token, to: .presenting)
            hudModel.phase = .done
            hudModel.status = "没有需要翻译的正文（\(plan.skipped.count) 个区域被保护或无需翻译）。"
            hudModel.offersRegion = true
            hud?.place()
            refreshDebug()
            return
        }
        hudModel.phase = .working
        if environment.settings.mode == .pi {
            hudModel.status = "正在通过 pi 翻译（\(environment.settings.model)）…文字已发送到所选模型服务"
            let runner = PiTranslationRunner()
            piRunner = runner
            let requests = plan.requests
            let settings = environment.settings
            piTask = Task { @MainActor [weak self] in
                do {
                    let translations = try await runner.translate(requests: requests, settings: settings)
                    guard let self, self.proceed(token) else { return }
                    await self.present(token: token) { try plan.rendered(translations: translations) }
                } catch {
                    guard let self, !Task.isCancelled, self.tracker.isCurrent(token), !self.finished else { return }
                    self.finishFailed("pi 翻译失败：\(error.localizedDescription)", token: token, region: false)
                }
            }
        } else {
            startLocalTranslation(plan: plan, token: token)
        }
    }

    /// English keeps the original ASCII-word heuristics; every other source (including auto) uses the Unicode ones.
    private var unicodePlanning: Bool { environment.settings.sourceLanguage != "en" }

    /// Resolves the concrete source (fixed, or detected with NLLanguageRecognizer over the texts about to be
    /// translated), checks the actual pair's pack, then starts the Apple session. Nothing is installed automatically.
    private func startLocalTranslation(plan: DesktopPlan, token: OperationToken) {
        let settings = environment.settings
        let texts = plan.requests.map { $0.text }
        hudModel.status = "正在确定源语言…"
        piTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let source: String
            if settings.isAutoSource {
                guard let detected = LanguagePreflight.detect(texts) else {
                    self.finishFailed("无法可靠识别源语言（文字过短或语言混杂）。请在翻译设置中指定源语言。", token: token, region: true)
                    return
                }
                source = detected
                self.detectedSource = detected
                self.hudModel.provider = Self.providerLabel(settings, detected: detected)
            } else {
                source = settings.sourceLanguage
            }
            let pairName = "\(TranslationLanguages.name(source)) → \(TranslationLanguages.name(settings.targetLanguage))"
            let availability = await LanguagePreflight.check(source: source, target: settings.targetLanguage)
            guard self.proceed(token) else { return }
            switch availability {
            case .ready: break
            case .samePair:
                self.tracker.advance(token, to: .presenting)
                self.hudModel.phase = .done
                self.hudModel.status = "识别到的源语言（\(TranslationLanguages.name(source))）与目标语言相同，无需翻译。"
                self.hudModel.offersRegion = true
                self.hud?.place()
                return
            case .unsupported:
                self.finishFailed("此系统的 Apple 本机翻译不支持 \(pairName)。", token: token, region: false)
                return
            case .needsInstall:
                self.preparePair = (source, settings.targetLanguage)
                self.hudModel.offersPrepare = true
                self.finishFailed("本机 \(pairName) 语言包尚未安装。请点“准备本机语言包”，安装后再重新触发。", token: token, region: false)
                return
            }
            self.hudModel.status = "正在翻译…（Apple 本机，\(pairName.replacingOccurrences(of: " → ", with: "→"))）"
            self.hudModel.configuration = TranslationSession.Configuration(source: LanguagePreflight.language(source), target: LanguagePreflight.language(settings.targetLanguage))
        }
    }

    private func runAppleSession(_ session: TranslationSession) async {
        guard !finished, let token = tracker.current, tracker.state == .translating, appleStartedToken != token, let plan else { return }
        appleStartedToken = token
        do {
            let requests = plan.requests.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
            let responses = try await session.translations(from: requests)
            guard proceed(token) else { return }
            let pairs = responses.map { (id: $0.clientIdentifier ?? "", text: $0.targetText) }
            await present(token: token) { try plan.rendered(pairs: pairs) }
        } catch {
            guard !Task.isCancelled, !finished, tracker.isCurrent(token) else { return }
            finishFailed("翻译失败：\(error.localizedDescription)", token: token, region: false)
        }
    }

    /// Common presentation path for BOTH backends. No mask, barrier item or expansion exists until the current
    /// selected crop has been re-verified against the signature recorded at capture time.
    private func present(token: OperationToken, render: () throws -> [RegionTranslation]) async {
        let translations: [RegionTranslation]
        do { translations = try render() }
        catch { finishFailed("翻译结果与请求不匹配，已拒绝显示：\(error)", token: token, region: false); return }
        guard proceed(token), let target, let baseline = baselineSignature else { return }
        hudModel.status = "正在核对所选区域是否仍与捕获时一致…"
        do {
            try await DesktopCapture.verifyFreshness(target: target, selection: target.effectiveSelection, baseline: baseline, baselineAt: baselineAt)
        } catch is CancellationError {
            return
        } catch {
            guard proceed(token) else { return }
            finishFailed("译文未显示：\(error.localizedDescription)", token: token, region: true); return
        }
        guard proceed(token) else { return }
        show(translations, token: token)
    }

    private func show(_ translations: [RegionTranslation], token: OperationToken) {
        guard let snapshot, let target, tracker.advance(token, to: .presenting) else { return }
        items = OverlayItem.make(from: translations, snapshot: snapshot, selection: target.effectiveSelection)
        presentBarrier()
        barrier?.view.items = items
        refreshDebug()
        let counts = OverlayItem.counts(items)
        phaseDescription = "presenting"
        hudModel.offersExpand = counts.total > 0 && counts.painted < counts.total
        hudModel.offersRegion = true
        let skipped = plan?.skipped.count ?? 0
        let protectedSkipped = plan?.skipped.filter { $0.reason.hasPrefix("protected kind") }.count ?? 0
        FileHandle.standardError.write(Data("呈现计数：规划区域 \(counts.total)；受保护跳过 \(protectedSkipped)；无需翻译跳过 \(skipped - protectedSkipped)；已绘制 \(counts.painted)；窄体/缩小 \(counts.condensed)；半透明覆盖 \(counts.cover)；向右扩展 \(counts.extendedRight)；向下扩展 \(counts.extendedDown)；空间不足 \(counts.fitOverflow)；冲突 \(counts.collisionUnavailable)；无位置 \(counts.noOccupancy)\n".utf8))
        if counts.painted == 0 {
            // Nothing was actually drawn in place: never a success, the full text is only in the read-only expansion.
            hudModel.phase = .failed
            hudModel.status = "未能在原位置显示译文（\(counts.total) 个区域：空间不足 \(counts.fitOverflow)、与其他文字冲突 \(counts.collisionUnavailable)、无可用位置 \(counts.noOccupancy)）；可展开查看全文。"
        } else {
            hudModel.phase = .done
            var parts = ["已在原位置显示 \(counts.painted) / \(counts.total) 个区域"]
            if counts.extendedRight > 0 { parts.append("其中 \(counts.extendedRight) 个向右扩展到已确认空白处") }
            if counts.condensed > 0 { parts.append("其中 \(counts.condensed) 个使用窄体/缩小字号（最小 9pt）") }
            if counts.cover > 0 { parts.append("其中 \(counts.cover) 个使用半透明覆盖，会盖住邻近内容") }
            if counts.extendedDown > 0 { parts.append("其中 \(counts.extendedDown) 个向下扩展到已确认空白处") }
            if counts.fitOverflow > 0 { parts.append("\(counts.fitOverflow) 处空间不足（橙色标记）") }
            if counts.collisionUnavailable > 0 { parts.append("\(counts.collisionUnavailable) 处与其他文字冲突而未覆盖") }
            if counts.noOccupancy > 0 { parts.append("\(counts.noOccupancy) 处无可用位置") }
            if counts.painted < counts.total { parts.append("可展开查看全文") }
            if skipped > 0 { parts.append("\(skipped) 个区域受保护或无需翻译") }
            hudModel.status = parts.joined(separator: "；")
        }
        hud?.place()
        // Presented: content changes no longer withdraw the overlay. The baseline-bearing monitor is replaced by a
        // geometry-only one (identity/frame/Space/screen/occlusion/frontmost still invalidate); Esc/shortcut exits.
        startMonitor(selection: target.effectiveSelection, baseline: nil)
        if counts.painted > 0 {
            hudModel.offersCollapse = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !self.finished, self.tracker.isCurrent(token), self.phaseDescription == "presenting" else { return }
                self.hud?.collapse()
            }
        }
    }

    private func showExpansion() {
        guard expansion == nil, let geometry, !items.isEmpty else { return }
        let panel = ExpansionPanel(geometry: geometry, items: items) { [weak self] in
            self?.expansion?.close(); self?.expansion = nil
            self?.barrier?.panel.makeKey()
        }
        expansion = panel
        panel.show()
        panel.panel.makeKey()
    }

    // MARK: teardown

    /// Removes every panel and cancels all async work. Never activates any application.
    func dismiss(reason: String?) {
        guard !finished else { return }
        finished = true
        baselineSignature = nil; appleStartedToken = nil
        tracker.cancelActive()
        token = nil
        captureTask?.cancel(); piTask?.cancel(); piRunner?.cancel()
        monitor?.stop(); monitor = nil
        if let reason { hudModel.status = reason; hudModel.phase = .failed }
        hudModel.configuration = nil
        expansion?.close(); expansion = nil
        selector?.close(); selector = nil
        barrier?.close(); barrier = nil
        hud?.close(); hud = nil
        clearDebug()
        items = []
        snapshot = nil
        plan = nil
        phaseDescription = "dismissed"
        environment.onFinished(self)
    }
}
