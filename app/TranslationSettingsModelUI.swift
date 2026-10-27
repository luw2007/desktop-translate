import AppKit
import Foundation

/// Model list and popup actions: pi's real model snapshot, image-capability gating, the refresh lifecycle, and the
/// mode/input/model change handlers. Split out of `TranslationSettingsController`'s core window file unchanged.
extension TranslationSettingsController {

    // MARK: Model list

    /// Items: the selected model first when pi does not (or cannot yet) vouch for it, then pi's real models.
    /// In image mode only models whose pi metadata declares image input are choosable; a saved text-only choice stays
    /// visible but disabled and labelled. Nothing here infers capability from a model name.
    func rebuildModelPopup() {
        let imageMode = selectedInputMode == .image
        modelPopup.removeAllItems()
        let models = discovered ?? []
        let known = Set(models.map(\.identifier))
        func add(_ title: String, identifier: String, enabled: Bool) {
            modelPopup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let item = modelPopup.lastItem
            item?.representedObject = identifier
            item?.isEnabled = enabled
        }
        if !selectedModel.isEmpty, !known.contains(selectedModel) {
            let note = discovered == nil ? "（未验证，点“刷新模型”）" : "（pi 当前不可用）"
            add(selectedModel + note, identifier: selectedModel, enabled: true)
        }
        for model in models {
            if imageMode && !model.acceptsImages {
                // Visible only when it is the saved/selected choice, so it is never silently dropped or replaced.
                if model.identifier == selectedModel { add(model.identifier + "（不支持图像输入）", identifier: model.identifier, enabled: false) }
                continue
            }
            add(model.identifier, identifier: model.identifier, enabled: true)
        }
        if let index = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedModel }) {
            modelPopup.selectItem(at: index)
        }
        modelPopup.isEnabled = selectedMode == .pi
    }

    /// Image-mode problem with the selected model, if pi has told us enough to know. nil = no known problem.
    func imageModeProblem(for identifier: String) -> String? {
        guard selectedMode == .pi, selectedInputMode == .image, let discovered else { return nil }
        guard let model = discovered.first(where: { $0.identifier == identifier }) else { return "所选模型不在 pi 当前可用模型中，请重新选择。" }
        return model.acceptsImages ? nil : "所选模型不支持图像输入，请选择支持图像的模型或改用“OCR 文字”。"
    }

    func cancelDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryGeneration += 1
        discoveryInFlight = false
    }

    /// Bounded (the transport has a 20 s timeout and output cap), cancellable, stale results ignored.
    func refreshModelList() {
        guard selectedMode == .pi else { return }
        discoveryTask?.cancel()
        discoveryGeneration += 1
        let generation = discoveryGeneration
        // Discovery does not depend on the language pair; keep it valid even while the pair is mid-edit.
        let settings = TranslationSettings(mode: .pi, piExecutable: executableField.stringValue, model: selectedModel,
                                           inputMode: selectedInputMode)
        discoveryInFlight = true
        refreshButton.isEnabled = false
        setMessage("正在读取 pi 当前可用的模型…", error: false)
        let discover = self.discover
        discoveryTask = Task { @MainActor [weak self] in
            let result: Result<[PiModel], Error>
            do { result = .success(try await discover(settings)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, generation == self.discoveryGeneration, !self.closed else { return }
            self.discoveryInFlight = false
            self.refreshButton.isEnabled = self.selectedMode == .pi
            switch result {
            case .success(let models):
                self.discovered = models
                self.rebuildModelPopup()
                let problem = self.imageModeProblem(for: self.selectedModel)
                self.setMessage(problem ?? "已读取 \(models.count) 个 pi 可用模型。", error: problem != nil)
            case .failure(let error):
                self.discovered = nil
                self.rebuildModelPopup()
                self.setMessage("无法读取 pi 模型列表：\((error as? PiTranslationError)?.message ?? "未知错误")（已保存的选择未改变）", error: true)
            }
        }
    }

    // MARK: Actions

    /// Shows the latest saved settings, discarding unsaved edits, then refreshes the model list in the background.
    func show() {
        closed = false
        load(current)                 // also re-reads the pack state for the loaded pair
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if current.mode == .pi { refreshModelList() }
    }

    @objc func modeChanged() {
        applyModeState()
        if selectedMode == .pi {
            setMessage("配置 pi 可执行文件、输入方式与模型；保存后下一次翻译生效。", error: false)
            if discovered == nil { refreshModelList() }
        } else {
            cancelDiscovery()
            setMessage("本地模式使用 Apple 设备端翻译，文字不会离开本机。", error: false)
        }
        refreshPackState()
    }

    @objc func inputModeChanged() {
        applyModeState()
        let problem = imageModeProblem(for: selectedModel)
        setMessage(problem ?? (selectedInputMode == .image ? "图像模式：翻译时所选区域截图会发送给模型。" : "OCR 文字模式：只发送本机识别出的文字。"), error: problem != nil)
    }

    @objc func modelChanged() {
        guard let identifier = modelPopup.selectedItem?.representedObject as? String else { return }
        selectedModel = identifier
    }

    @objc func refreshModels() { refreshModelList() }
}
