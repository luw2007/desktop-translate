import CoreGraphics
import Foundation
import ScreenCaptureKit

extension DesktopCapture {
    static func capture(target: CaptureTarget, selection: CGRect, languageCorrection: Bool = true,
                        sourceLanguage: String = TranslationLanguages.legacySource,
                        targetLanguage: String? = nil) async -> RouterOutcome {
        await captureWithSignature(target: target, selection: selection, languageCorrection: languageCorrection,
                                   sourceLanguage: sourceLanguage, targetLanguage: targetLanguage).0
    }
    /// `layout` is optional plugin container geometry. Only an independently verified layout may be passed; it is
    /// re-validated here (ancestry resolves inside window/selection, containment, clipped to the crop) before grouping.
    /// The returned signature is taken from the ORIGINAL image, over exactly the occupied rectangles of the translatable
    /// regions of this snapshot's plan; the image is dropped on return.
    static func captureWithSignature(target: CaptureTarget, selection: CGRect, languageCorrection: Bool = true,
                                     sourceLanguage: String = TranslationLanguages.legacySource,
                                     targetLanguage: String? = nil,
                                     layout: [LayoutRegion] = [],
                                     onDebugMarks: (@MainActor ([DebugMark]) -> Void)? = nil,
                                     onDebugCounts: (@MainActor ([String: Int]) -> Void)? = nil) async -> (RouterOutcome, RegionSignature?) {
        guard await ScreenCapturePermission.preflight() else { return (.needsPermission(.screenRecording), nil) }
        do {
            let shot = try await screenshot(target: target, selection: selection)
            try Task.checkCancellation()
            let correct = languageCorrection && !OCRGrouper.terminalBundleIDs.contains(target.bundleID ?? "")
            let observations = try await recognize(shot.image, languageCorrection: correct, sourceLanguage: sourceLanguage)
            guard await TargetLocker.revalidate(target) == nil else { return (.error(DesktopCaptureError.changed.localizedDescription), nil) }
            let window = LayoutRegion(id: "window", role: .window, rect: CGRect(origin: .zero, size: target.frame.size))
            let selectionLayout = LayoutRegion(id: "selection", parentID: "window", role: .content, rect: shot.crop)
            let trusted = trustedLayout(layout, window: window, selection: selectionLayout)
            let grouped = OCRGrouper.grouped(observations, crop: shot.crop, target: target, layout: trusted, unicode: sourceLanguage != "en")
            var regions = grouped.regions
            var dropped = 0
            var debugMarks = grouped.marks
            let known = Dictionary(uniqueKeysWithValues: ([window, selectionLayout] + trusted).map { ($0.id, $0.rect) })
            for index in regions.indices {
                let parent = regions[index].parentID.flatMap { known[$0] != nil ? $0 : nil } ?? "selection"
                regions[index].parentID = parent
                let sourceRects = regions[index].lineRects.isEmpty ? [regions[index].rect] : regions[index].lineRects
                regions[index].rect = regions[index].rect.intersection(shot.crop)
                regions[index].lineRects = regions[index].lineRects.map { $0.intersection(shot.crop) }.filter { !$0.isNull && !$0.isEmpty }
                // Full containment, not centre membership: text straddling its container's edge is never overlaid.
                let container = (known[parent] ?? shot.crop).insetBy(dx: -1, dy: -1)
                let rects = regions[index].lineRects.isEmpty ? [regions[index].rect] : regions[index].lineRects
                if regions[index].rect.isNull || regions[index].rect.isEmpty || !rects.allSatisfy({ container.contains($0) }) {
                    regions[index].rect = .null; dropped += 1
                    debugMarks.append(DebugMark(kind: .dropped, rects: sourceRects.filter { !$0.isNull && !$0.isEmpty }))
                    continue
                }
                regions[index].background = try background(image: shot.image, local: regions[index].rect, crop: shot.crop)
            }
            regions.removeAll { $0.rect.isNull || $0.rect.isEmpty }
            if let onDebugMarks { await onDebugMarks(debugMarks) }
            // Counts only: never text, coordinates or identifiers.
            if let onDebugCounts {
                await onDebugCounts(["observations": observations.count,
                                     "regions": regions.count,
                                     "straddleOmitted": grouped.omittedObservations,
                                     "dropped": dropped,
                                     "lowConfidence": debugMarks.lazy.filter { $0.kind == .lowConfidence }.count])
            }
            FreeSpace.attach(to: &regions, image: shot.image, crop: shot.crop, bounds: window.rect, containers: known,
                             omitted: debugMarks.flatMap(\.rects))
            guard !regions.isEmpty else { return (.none, nil) }
            let recognizers = TranslationLanguages.visionLanguages(source: sourceLanguage)
            let evidence = CapabilityEvidence(level: .partial, interface: "ScreenCaptureKit cropped window + Vision accurate (\(recognizers.isEmpty ? "auto-detect" : recognizers.joined(separator: "/")))", note: "截图 OCR，不代表原生控件或字体布局")
            let snapshot = CaptureSnapshot(target: target,
                capabilities: SnapshotCapabilities(visibleText: evidence, textGeometry: evidence, contentRevision: CapabilityEvidence(level: .partial, interface: "full-resolution pixel hashes of the translatable source rectangles; two consecutive changes")),
                provenance: .ocr, transform: shot.transform,
                layout: [window, selectionLayout] + trusted, regions: regions)
            try snapshot.validate(currentRevision: target.revision)
            // Original-image baseline over exactly the rectangles the plan can replace. No valid relevant area =>
            // no signature (the session then refuses to present); never silently the whole crop.
            var baseline: RegionSignature?
            if let areas = relevantAreas(snapshot: snapshot, selection: shot.crop, unicode: sourceLanguage != "en", target: targetLanguage) {
                baseline = try signature(of: shot.image, crop: shot.crop, areas: areas)
            }
            var warnings = ["OCR 定位和背景颜色为估算；请核对译文，覆盖可随时撤除。"]
            if regions.contains(where: { $0.confidence < 0.7 }) { warnings.append("部分文字识别置信度较低，可能存在识别错误。") }
            if shot.translucent { warnings.append("目标区域包含透明背景，覆盖可能无法准确还原背景。") }
            warnings.append("复杂或非均匀背景可能影响遮盖效果；背景采样未经原生验证。")
            if dropped > 0 { warnings.append("有 \(dropped) 处文字跨越区块边界，已不覆盖。") }
            if grouped.omittedObservations > 0 { warnings.append(OCRGrouper.straddleWarning) }
            if observations.contains(where: { $0.normalizedBox.minX <= 0.005 || $0.normalizedBox.minY <= 0.005 || $0.normalizedBox.maxX >= 0.995 || $0.normalizedBox.maxY >= 0.995 }) {
                warnings.append("所选区域边缘可能截断文字；只显示裁剪区域内的位置。")
            }
            // Counts only: never text, coordinates or identifiers.
            FileHandle.standardError.write(Data("捕获计数：识别区域 \(regions.count)；跨界未覆盖观察 \(grouped.omittedObservations)；越界丢弃区域 \(dropped)\n".utf8))
            return (.partial(snapshot, warnings: warnings), baseline)
        } catch is CancellationError { return (.error("捕获已取消。"), nil) }
        catch let error as TargetLockError { return (.error(error.localizedDescription), nil) }
        catch let error as DesktopCaptureError { return (.error(error.localizedDescription), nil) }
        catch {
            let failure = error as NSError
            if !CGPreflightScreenCaptureAccess() || (failure.domain == SCStreamErrorDomain && [-3801, -3817, -3821].contains(failure.code)) {
                return (.needsPermission(.screenRecording), nil)
            }
            return (.error("ScreenCaptureKit 捕获失败（\(failure.domain) \(failure.code)）；窗口可能受系统或应用保护，无法捕获，未进行识别（这不代表没有文字）。"), nil)
        }
    }
}
