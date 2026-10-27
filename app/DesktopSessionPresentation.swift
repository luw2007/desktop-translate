import AppKit
import Foundation
import Translation
import UniformTypeIdentifiers

@MainActor
extension DesktopTranslationSession {
    func presentBarrier() {
        guard barrier == nil, let geometry else { return }
        let panel = BarrierPanel(geometry: geometry, onClose: { [weak self] in self?.dismiss(reason: nil) })
        panel.view.onMarker = { [weak self] in self?.showExpansion() }
        barrier = panel
        panel.show()
        hud?.show()
    }

    /// Debug overlay: outline + code for every recognized region/line of this capture, plus a legend. Pure display
    /// derived from the finished plan/items/marks; it never alters them. No-op when the setting is off or no barrier exists.
    func refreshDebug() {
        guard environment.debug.showRegions, let barrier, let geometry else { return }
        let boxes = DebugRegions.boxes(snapshot: snapshot, plan: plan, items: items, marks: debugMarks,
                                       targetLanguage: environment.settings.targetLanguage)
        barrier.view.debugBoxes = boxes
        debugLegend?.close(); debugLegend = nil
        guard !boxes.isEmpty else { return }
        let counts = DebugRegions.counts(boxes)
        environment.onLogEvent(DebugRegions.logLine(counts))
        let skipCounts = DebugRegions.skipCounts(plan?.skipped ?? [])
        if !skipCounts.isEmpty { environment.onLogEvent(DebugRegions.skipLogLine(skipCounts)) }
        let legend = DebugLegendPanel(geometry: geometry, rows: counts) { [weak self] in self?.exportDebugJSON() }
        debugLegend = legend
        legend.show()
    }

    /// Freeze before teardown. Saving is explicit; no source/translation content is sent to logs.
    private func exportDebugJSON() {
        guard environment.debug.showRegions, !finished else { return }
        let report = DebugSessionExport.make(settings: environment.settings, target: target,
            snapshot: snapshot, plan: plan, items: items, marks: debugMarks,
            phase: phaseDescription, captureCounts: captureCounts)
        // A save dialog may activate the app. End the overlay first so its key barrier/monitor cannot fight the dialog.
        dismiss(reason: nil)
        let save = NSSavePanel()
        save.allowedContentTypes = [.json]
        save.canCreateDirectories = true
        save.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        save.nameFieldStringValue = "desktop-translate-debug-\(formatter.string(from: Date())).json"
        save.title = "导出调试信息（JSON）"
        save.message = "文件包含本次识别原文和译文，请仅分享给可信任的人。覆盖层已关闭。"
        NSApp.activate(ignoringOtherApps: true)
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法导出调试信息"
            alert.informativeText = "文件未能保存。请检查所选目录的写入权限与可用空间。"
            alert.runModal()
        }
    }

    func clearDebug() {
        debugMarks = []
        captureCounts = [:]
        barrier?.view.debugBoxes = []
        debugLegend?.close(); debugLegend = nil
    }

    /// Common presentation path for BOTH backends. No mask, barrier item or expansion exists until the current
    /// selected crop has been re-verified against the signature recorded at capture time.
    func present(token: OperationToken, render: () throws -> [RegionTranslation]) async {
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
        // Unconditional, count-only, like the line above: a painted translation that is still mostly in the source
        // script is never a silent success, whether or not the debug overlay is on. No text and no coordinates.
        let residue = SourceResidue.count(snapshot: snapshot, items: items, targetLanguage: environment.settings.targetLanguage)
        if residue > 0 { environment.onLogEvent(SourceResidue.logLine(residue)) }
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

    func showExpansion() {
        guard expansion == nil, let geometry, !items.isEmpty else { return }
        let panel = ExpansionPanel(geometry: geometry, items: items) { [weak self] in
            self?.expansion?.close(); self?.expansion = nil
            self?.barrier?.panel.makeKey()
        }
        expansion = panel
        panel.show()
        panel.panel.makeKey()
    }

}
