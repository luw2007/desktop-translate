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
typealias DesktopPluginProvider = @MainActor (CaptureTarget, CGRect) async -> RouterOutcome?

/// One translation presentation over one locked target. Everything async revalidates `token`, target and layout.
@MainActor
final class DesktopTranslationSession {
    struct Environment {
        var settings: TranslationSettings
        var shortcutDisplay: String
        var plugin: DesktopPluginProvider?
        var selectionMemory: SelectionMemoryBox
        var onFinished: (DesktopTranslationSession) -> Void
        var onPrepareLanguages: () -> Void
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
    private var finished = false
    private var forceOCRNext = false
    private var frontPID: Int32?

    var isFinished: Bool { finished }
    var presentedItems: [OverlayItem] { items }
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
        hudModel.provider = Self.providerLabel(environment.settings)
        hudModel.source = "屏幕 OCR（本机 Vision）"
        hudModel.onClose = { [weak self] in self?.dismiss(reason: nil) }
        hudModel.onExpand = { [weak self] in self?.showExpansion() }
        hudModel.onRegion = { [weak self] in self?.restartAsRegion() }
        hudModel.onOCR = { [weak self] in self?.captureOCROnce() }
        hudModel.onPrepare = { [weak self] in self?.environment.onPrepareLanguages() }
        hudModel.sessionHandler = { [weak self] session in await self?.runAppleSession(session) }
    }

    static func providerLabel(_ settings: TranslationSettings) -> String {
        settings.mode == .local ? "Apple 本机翻译（英文→简体中文）" : "pi · \(settings.model)（文字将发送到所选模型服务）"
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
            let availability = await LanguagePreflight.check()
            guard tracker.isCurrent(token) else { return }
            switch availability {
            case .ready: break
            case .unsupported:
                presentMessageOnly(status: "此系统的 Apple 本机翻译不支持 英文 → 简体中文。未捕获屏幕。", failed: true, prepare: false)
                return
            case .needsInstall:
                presentMessageOnly(status: "本机英文 → 简体中文语言包尚未安装。未捕获屏幕；请点“准备本机语言包”，安装后再重新触发。", failed: true, prepare: true)
                return
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

    private func presentMessageOnly(status: String, failed: Bool, prepare: Bool) {
        // No target exists yet: place the HUD on the screen that holds the pointer, never capture it.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let strip = CGRect(x: visible.minX, y: visible.maxY - 120, width: visible.width, height: 120)
        let geometry = TargetGeometry(frame: CoordinateMapper.appKitToGlobal(strip, primaryHeight: TargetGeometry.primaryHeight))
        self.geometry = geometry
        hudModel.status = status
        hudModel.phase = failed ? .failed : .done
        hudModel.offersPrepare = prepare
        hudModel.offersRegion = false
        let panel = HUDPanel(geometry: geometry, model: hudModel)
        hud = panel
        panel.show()
        tracker.advance(token!, to: .failed)
        phaseDescription = "failed"
    }

    private func presentBarrier() {
        guard barrier == nil, let geometry else { return }
        let panel = BarrierPanel(geometry: geometry, onClose: { [weak self] in self?.dismiss(reason: nil) })
        panel.view.onMarker = { [weak self] in self?.showExpansion() }
        barrier = panel
        panel.show()
        hud?.show()
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
        let monitor = TargetMonitor(target: target, selection: selection, baseline: baseline) { [weak self] reason in
            self?.environment.onLogEvent("目标变化，已撤除覆盖：\(reason)")
            self?.dismiss(reason: reason)
        }
        self.monitor = monitor
        monitor.start()
    }

    /// Target still the same window, same layout, same operation, target app still frontmost.
    private func stillValid(_ token: OperationToken) -> Bool {
        guard !finished, tracker.isCurrent(token), let target else { return false }
        if TargetLocker.revalidate(target) != nil { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }

    // MARK: capture

    private func captureOCROnce() {
        forceOCRNext = true
        guard target != nil else { return }
        let token = tracker.begin()
        self.token = token
        appleSessionStarted = false
        guard let target else { return }
        hudModel.offersOCR = false
        hudModel.phase = .working
        hudModel.status = "正在以屏幕 OCR 捕获（仅本次）…"
        captureTask = Task { @MainActor [weak self] in
            await self?.captureAndTranslate(selection: target.selection, token: token)
        }
    }

    private func restartAsRegion() {
        guard geometry != nil, target != nil else { return }
        captureTask?.cancel()
        piTask?.cancel(); piRunner?.cancel(); hudModel.configuration = nil
        barrier?.view.items = []
        items = []
        hudModel.offersExpand = false
        hudModel.offersRegion = false
        hudModel.phase = .working
        hudModel.status = "拖选需要翻译的区域，Return 确认，Esc 取消。"
        var restore: CGRect?
        if let target { restore = environment.selectionMemory.value.restore(for: target) }
        barrier?.close(); barrier = nil
        let token = tracker.begin()
        self.token = token
        appleSessionStarted = false
        phaseDescription = "selecting"
        presentSelector(initial: restore, token: token)
    }

    private func captureAndTranslate(selection: CGRect?, token: OperationToken) async {
        guard var target, stillValid(token) else { dismiss(reason: nil); return }
        target.selection = selection
        self.target = target
        let rect = target.effectiveSelection
        phaseDescription = "capturing"
        hudModel.phase = .working
        if let name = TerminalPluginRegistry.supportedTerminalNames[target.bundleID ?? ""], !forceOCRNext {
            hudModel.status = "已匹配终端：\(name)（内置插件）。正在读取插件证据；无可验证的原生内容修订时将用屏幕 OCR 并持续校验。"
        } else if forceOCRNext {
            hudModel.status = "正在以屏幕 OCR 捕获并识别（仅本次，跳过插件）…"
        } else {
            hudModel.status = "未匹配内置终端插件（\(target.appName)）：使用屏幕 OCR。正在捕获并识别…"
        }
        var outcome: RouterOutcome?
        var signature: RegionSignature?
        var sourceLabel = "屏幕 OCR（本机 Vision）"
        var pluginWarnings: [String] = []
        var pluginLayoutSnapshot: CaptureSnapshot?
        if !forceOCRNext, let plugin = environment.plugin, let routed = await plugin(target, rect) {
            guard stillValid(token) else { dismiss(reason: nil); return }
            switch routed {
            case .snapshot(let s):
                sourceLabel = "应用插件 · \(s.provenance.rawValue)"
                outcome = routed
            case .partial(let s, let w):
                if s.regions.isEmpty {
                    // Layout/capability-only plugin result: validate it BEFORE any OCR; never trust it blindly.
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
        forceOCRNext = false
        hudModel.source = sourceLabel
        if outcome == nil {
            let (result, sig) = await DesktopCapture.captureWithSignature(target: target, selection: rect)
            outcome = result; signature = sig
        }
        guard stillValid(token), let outcome else { dismiss(reason: nil); return }
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
        if captured.provenance == .native && !captured.capabilities.canVerifyRevision {
            showPluginStop(message: "原生快照没有可靠的内容修订，无法保证译文不会过期，已拒绝显示。可仅本次使用屏幕 OCR。", token: token); return
        }
        snapshot = captured
        startMonitor(selection: rect, baseline: signature)
        if !warnings.isEmpty { environment.onLogEvent("捕获提示 \(warnings.count) 项（不含文字内容）") }
        hudModel.source = sourceLabel + (warnings.isEmpty ? "" : "　⚠︎ \(warnings.count) 项估算提示，请核对译文")
        beginTranslation(captured, token: token)
    }

    /// Keeps the OCR evidence (visibleText/textGeometry/contentRevision) truthful; takes only paneLayout/fontRevision
    /// and verified, parent-consistent layout regions from the plugin. Falls back to OCR layout if the merge is invalid.
    static func merge(ocr: CaptureSnapshot, plugin: CaptureSnapshot) -> CaptureSnapshot {
        var merged = ocr
        merged.provenance = .pluginOCR
        merged.capabilities.paneLayout = plugin.capabilities.paneLayout
        merged.capabilities.fontRevision = plugin.capabilities.fontRevision
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
        hud?.place()
        // Keep the barrier so the failure remains attached to the locked target until dismissed.
    }

    // MARK: translation

    private func beginTranslation(_ captured: CaptureSnapshot, token: OperationToken) {
        guard tracker.advance(token, to: .translating) else { return }
        phaseDescription = "translating"
        let plan = DesktopPlan(snapshot: captured)
        self.plan = plan
        if plan.requests.isEmpty {
            tracker.advance(token, to: .presenting)
            hudModel.phase = .done
            hudModel.status = "没有需要翻译的英文正文（\(plan.skipped.count) 个区域被保护或无需翻译）。"
            hudModel.offersRegion = true
            hud?.place()
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
                    guard let self, self.stillValid(token) else { self?.dismiss(reason: nil); return }
                    self.present(plan: plan, translations: translations, token: token)
                } catch {
                    guard let self, self.tracker.isCurrent(token), !Task.isCancelled else { return }
                    self.finishFailed("pi 翻译失败：\(error.localizedDescription)", token: token, region: false)
                }
            }
        } else {
            hudModel.status = "正在翻译…（Apple 本机，英文→简体中文）"
            hudModel.configuration = TranslationSession.Configuration(source: LanguagePreflight.source, target: LanguagePreflight.target)
        }
    }

    private var appleSessionStarted = false

    private func runAppleSession(_ session: TranslationSession) async {
        guard let token = tracker.current, tracker.state == .translating, !appleSessionStarted, let plan else { return }
        appleSessionStarted = true
        do {
            let requests = plan.requests.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
            let responses = try await session.translations(from: requests)
            guard stillValid(token) else { dismiss(reason: nil); return }
            let pairs = responses.map { (id: $0.clientIdentifier ?? "", text: $0.targetText) }
            present(plan: plan, pairs: pairs, token: token)
        } catch {
            guard tracker.isCurrent(token) else { return }
            finishFailed("翻译失败：\(error.localizedDescription)", token: token, region: false)
        }
    }

    private func present(plan: DesktopPlan, translations: [String: String], token: OperationToken) {
        do { show(try plan.rendered(translations: translations), token: token) }
        catch { finishFailed("翻译结果与请求不匹配，已拒绝显示：\(error)", token: token, region: false) }
    }

    private func present(plan: DesktopPlan, pairs: [(id: String, text: String)], token: OperationToken) {
        do { show(try plan.rendered(pairs: pairs), token: token) }
        catch { finishFailed("翻译结果与请求不匹配，已拒绝显示：\(error)", token: token, region: false) }
    }

    private func show(_ translations: [RegionTranslation], token: OperationToken) {
        guard stillValid(token), let snapshot, let target, tracker.advance(token, to: .presenting) else { dismiss(reason: nil); return }
        items = OverlayItem.make(from: translations, snapshot: snapshot, selection: target.effectiveSelection)
        presentBarrier()
        barrier?.view.items = items
        let overflowCount = items.filter(\.overflow).count
        phaseDescription = "presenting"
        hudModel.phase = .done
        hudModel.offersExpand = overflowCount > 0
        hudModel.offersRegion = true
        hudModel.status = "已翻译 \(items.count) 个区域" + (overflowCount > 0 ? "；\(overflowCount) 处空间不足（橙色标记），可展开全文" : "")
        hud?.place()
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
        items = []
        snapshot = nil
        plan = nil
        phaseDescription = "dismissed"
        environment.onFinished(self)
    }
}
