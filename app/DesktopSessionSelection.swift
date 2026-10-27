import AppKit
import Foundation
import Translation
import UniformTypeIdentifiers

@MainActor
extension DesktopTranslationSession {
    func presentSelector(initial: CGRect?, token: OperationToken) {
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

    func startMonitor(selection: CGRect, baseline: RegionSignature?) {
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
    func proceed(_ token: OperationToken) -> Bool {
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

    func captureOCROnce() {
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

    func restartAsRegion() {
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

}
