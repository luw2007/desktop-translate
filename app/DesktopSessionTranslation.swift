import AppKit
import Foundation
import Translation
import UniformTypeIdentifiers

@MainActor
extension DesktopTranslationSession {
    func beginTranslation(_ captured: CaptureSnapshot, token: OperationToken) {
        guard tracker.advance(token, to: .translating) else { return }
        phaseDescription = "translating"
        let plan = DesktopPlan(snapshot: captured, unicode: unicodePlanning, target: environment.settings.targetLanguage)
        self.plan = plan
        if plan.requests.isEmpty {
            tracker.advance(token, to: .presenting)
            hudModel.phase = .done
            hudModel.status = "没有需要翻译的文字（\(plan.skipped.count) 个区域被保护或无需翻译）。"
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
    var unicodePlanning: Bool { environment.settings.sourceLanguage != "en" }

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

    func runAppleSession(_ session: TranslationSession) async {
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

}
