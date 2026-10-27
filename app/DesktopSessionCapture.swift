import AppKit
import Foundation
import Translation
import UniformTypeIdentifiers

@MainActor
extension DesktopTranslationSession {
    /// Bounded wait for the barrier to be key, then a fixed pause for the target's focus repaint. Never activates.
    private func settleOverlayFocus() async {
        if let panel = barrier?.panel {
            for _ in 0..<20 where !panel.isKeyWindow { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    func captureAndTranslate(selection: CGRect?, token: OperationToken) async {
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
                target: target, selection: rect, sourceLanguage: environment.settings.sourceLanguage,
                targetLanguage: environment.settings.targetLanguage, layout: verifiedLayout,
                onDebugMarks: collectMarks, onDebugCounts: { @MainActor [weak self] counts in self?.captureCounts = counts })
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
        // Nothing will be painted, so no replaceable-pixel signature is needed. Keep captured K/P diagnostics.
        if DesktopPlan(snapshot: captured, unicode: unicodePlanning, target: environment.settings.targetLanguage).requests.isEmpty {
            snapshot = captured
            captureCounts["warnings"] = warnings.count
            beginTranslation(captured, token: token)
            return
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
        captureCounts["warnings"] = warnings.count
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

    func finishFailed(_ message: String, token: OperationToken, region: Bool) {
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

}
