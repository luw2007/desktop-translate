import AppKit
import Foundation
import Translation
import UniformTypeIdentifiers

@MainActor
extension DesktopTranslationSession {
    // MARK: translation
    /// OCR-free image mode: capture the exact crop, send that one in-memory PNG to the selected image-capable pi model,
    /// validate its regions/geometry, derive the immutable baseline from the HELD original pixels, then use the same
    /// freshness gate and renderer as every other path. No OCR, no fallback model or mode on any error.
    func captureImageAndTranslate(target: CaptureTarget, rect: CGRect, token: OperationToken) async {
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
                let (snapshot, baseline) = try DesktopCapture.snapshotFromModel(target: target, held: held, regions: parsed.regions,
                    unicode: self.unicodePlanning, targetLanguage: settings.targetLanguage)
                guard let baseline else {
                    self.finishFailed("没有可核对内容变化的有效翻译区域，已拒绝显示。", token: token, region: true); return
                }
                guard snapshot.target.sameContent(as: target), snapshot.target.selection == target.selection else {
                    self.finishFailed("模型结果与锁定的目标或选区不一致，已拒绝显示。", token: token, region: false); return
                }
                let plan = DesktopPlan(snapshot: snapshot, unicode: self.unicodePlanning, target: settings.targetLanguage)
                self.captureCounts = ["regions": snapshot.regions.count]
                guard !plan.requests.isEmpty else {
                    self.snapshot = snapshot; self.baselineSignature = baseline; self.baselineAt = Date(); self.plan = plan
                    self.startMonitor(selection: rect, baseline: baseline)
                    self.tracker.advance(token, to: .presenting)
                    self.hudModel.phase = .done
                    self.hudModel.status = "没有需要翻译的文字（\(plan.skipped.count) 个区域被保护或无需翻译）。"
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

}
