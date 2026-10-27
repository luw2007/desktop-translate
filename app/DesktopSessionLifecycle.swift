import AppKit
import Foundation
import Translation
import UniformTypeIdentifiers

@MainActor
extension DesktopTranslationSession {
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
    func handleInvalidation(_ invalidation: TargetInvalidation) {
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
