import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision
import Foundation

/// Fail-closed public window baseline. No Accessibility calls, window titles are never used as identity.
enum TargetLockError: LocalizedError {
    case ownApp, terminated, noWindow, ambiguous, sharingNone, offscreen, changed, obscured
    case unavailable
    var errorDescription: String? {
        switch self {
        case .ownApp: return "请在要翻译的应用中按快捷键，不能捕获翻译器自身。"
        case .terminated: return "目标应用已退出或进程身份改变，请重新选择。"
        case .noWindow: return "没有可确认的前台普通窗口；请切回目标窗口再试。"
        case .ambiguous: return "无法确定主窗口或模态窗口的边界，请关闭弹窗后重新选择。"
        case .sharingNone: return "目标窗口禁止屏幕共享，无法捕获。"
        case .offscreen: return "目标窗口不在当前可见桌面或显示器上。"
        case .changed: return "目标窗口、显示器或前台应用已改变，请重新按快捷键。"
        case .obscured: return "其他应用遮挡了翻译区域，已撤除覆盖。"
        case .unavailable: return "无法获取系统窗口列表，未捕获任何屏幕。"
        }
    }
}

fileprivate struct PublicWindow {
    let id: UInt32
    let pid: Int32
    let layer: Int
    let frame: CGRect
    let sharing: Int
    let alpha: Double
    let name: String
    init?(_ row: [String: Any]) {
        guard let id = row[kCGWindowNumber as String] as? NSNumber,
              let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
              let layer = row[kCGWindowLayer as String] as? NSNumber,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let sharing = row[kCGWindowSharingState as String] as? NSNumber else { return nil }
        self.id = id.uint32Value; self.pid = pid.int32Value; self.layer = layer.intValue
        self.frame = frame; self.sharing = sharing.intValue
        self.alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        self.name = row[kCGWindowName as String] as? String ?? ""
    }
    var ordinary: Bool { layer == 0 && alpha > 0 && frame.width > 1 && frame.height > 1 }
}

@MainActor
enum TargetLocker {
    fileprivate static func windows() -> [PublicWindow]? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return rows.compactMap(PublicWindow.init)
    }
    static func lock(app: NSRunningApplication) -> Result<CaptureTarget, TargetLockError> {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .failure(.ownApp) }
        guard !app.isTerminated, let launched = app.launchDate,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return .failure(.terminated) }
        guard let rows = windows() else { return .failure(.unavailable) }
        // The front-to-back first layer-zero window is the only no-AX candidate. Never fall back to a display.
        guard Set(rows.map(\.id)).count == rows.count else { return .failure(.ambiguous) }
        let owned = rows.filter { $0.pid == app.processIdentifier && $0.ordinary }
        guard let first = owned.first else { return .failure(.noWindow) }
        guard first.sharing != 0 else { return .failure(.sharingNone) }
        // Without AX we cannot prove which part of overlapping same-app windows is a sheet/dialog.
        // Refuse these instead of silently capturing an underlying/main window.
        guard !owned.dropFirst().contains(where: { $0.frame.intersects(first.frame) }) else { return .failure(.ambiguous) }
        let displays = displayIDs(intersecting: first.frame)
        guard !displays.isEmpty else { return .failure(.offscreen) }
        return .success(CaptureTarget(pid: app.processIdentifier, windowID: first.id,
            appLaunchTime: launched.timeIntervalSince1970, bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "应用", title: first.name, frame: first.frame, displayIDs: displays))
    }
    static func revalidate(_ target: CaptureTarget) -> TargetLockError? {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.launchDate?.timeIntervalSince1970 == target.appLaunchTime else { return .terminated }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return .changed }
        switch lock(app: app) {
        case .failure(let error): return error
        case .success(let now):
            guard now.windowID == target.windowID, now.frame == target.frame,
                  now.displayIDs == target.displayIDs else { return .changed }
            return nil
        }
    }
    fileprivate static func displayIDs(intersecting rect: CGRect) -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayBounds($0).intersects(rect) }.sorted()
    }
    static func isOccluded(_ target: CaptureTarget, selection: CGRect) -> Bool {
        guard let rows = windows(), let index = rows.firstIndex(where: { $0.id == target.windowID }) else { return true }
        let global = selection.offsetBy(dx: target.frame.minX, dy: target.frame.minY)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return rows[..<index].contains { $0.ordinary && $0.pid != target.pid && $0.pid != ownPID && $0.frame.intersects(global) }
    }
    static func isFullyVisible(_ target: CaptureTarget, selection: CGRect) -> Bool {
        var remaining = [selection.offsetBy(dx: target.frame.minX, dy: target.frame.minY)]
        // Subtract active displays: do not accept gaps or missing selected pixels.
        for id in target.displayIDs {
            var next: [CGRect] = []
            for rect in remaining {
                let cut = rect.intersection(CGDisplayBounds(id))
                if cut.isNull || cut.isEmpty { next.append(rect); continue }
                let pieces = [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
                              CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
                              CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
                              CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)]
                next += pieces.filter { $0.width > 0 && $0.height > 0 }
            }
            remaining = next
        }
        return remaining.isEmpty
    }
}

enum ScreenCapturePermission {
    static func preflight() async -> Bool { CGPreflightScreenCaptureAccess() }
    /// Only call following an explicit user's permission action; baseline checks never prompt.
    @MainActor static func request() async -> Bool { CGRequestScreenCaptureAccess() }
}

struct RegionSignature: Equatable, Sendable {
    /// 32x32 grayscale pixels; no screenshot is retained by the monitor.
    fileprivate let pixels: [UInt8]
    func differs(from baseline: RegionSignature) -> Bool {
        guard pixels.count == baseline.pixels.count, !pixels.isEmpty else { return true }
        var changed = 0
        for (a, b) in zip(pixels, baseline.pixels) where abs(Int(a) - Int(b)) > 18 { changed += 1 }
        return changed >= max(3, pixels.count / 100)
    }
}

private struct CapturedRegion {
    let image: CGImage
    let crop: CGRect
    let transform: TransformProvenance
    let signature: RegionSignature
    let translucent: Bool
}

private enum DesktopCaptureError: LocalizedError {
    case invalidSelection, wrongSize, black, protectedWindow, changed
    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "所选区域不在目标窗口内。"
        case .wrongSize: return "截图像素尺寸与窗口区域不匹配，无法保证原位置覆盖。"
        case .black: return "截图全部为黑色，可能受系统或应用保护；未进行识别。"
        case .protectedWindow: return "目标窗口禁止共享或不再可见。"
        case .changed: return "捕获期间目标改变，已丢弃截图。"
        }
    }
}

enum DesktopCapture {
    static func capture(target: CaptureTarget, selection: CGRect, languageCorrection: Bool = true) async -> RouterOutcome {
        await captureWithSignature(target: target, selection: selection, languageCorrection: languageCorrection).0
    }
    static func captureWithSignature(target: CaptureTarget, selection: CGRect, languageCorrection: Bool = true) async -> (RouterOutcome, RegionSignature?) {
        guard await ScreenCapturePermission.preflight() else { return (.needsPermission(.screenRecording), nil) }
        do {
            let shot = try await screenshot(target: target, selection: selection)
            try Task.checkCancellation()
            let terminalIDs: Set<String> = ["com.cmuxterm.app", "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "fun.tw93.kaku"]
            let correct = languageCorrection && !terminalIDs.contains(target.bundleID ?? "")
            let observations = try await recognize(shot.image, languageCorrection: correct)
            guard await TargetLocker.revalidate(target) == nil else { return (.error(DesktopCaptureError.changed.localizedDescription), nil) }
            var regions = OCRGrouper.group(observations, crop: shot.crop, target: target)
            for index in regions.indices {
                regions[index].parentID = "selection"
                regions[index].rect = regions[index].rect.intersection(shot.crop)
                regions[index].lineRects = regions[index].lineRects.map { $0.intersection(shot.crop) }.filter { !$0.isNull && !$0.isEmpty }
                regions[index].background = try background(image: shot.image, local: regions[index].rect, crop: shot.crop)
            }
            regions.removeAll { $0.rect.isNull || $0.rect.isEmpty }
            guard !regions.isEmpty else { return (.none, shot.signature) }
            let evidence = CapabilityEvidence(level: .partial, interface: "ScreenCaptureKit cropped window + Vision accurate en-US/zh-Hans", note: "截图 OCR，不代表原生控件或字体布局")
            let snapshot = CaptureSnapshot(target: target,
                capabilities: SnapshotCapabilities(visibleText: evidence, textGeometry: evidence, contentRevision: CapabilityEvidence(level: .partial, interface: "32x32 region signature; two consecutive changes")),
                provenance: .ocr, transform: shot.transform,
                layout: [LayoutRegion(id: "window", role: .window, rect: CGRect(origin: .zero, size: target.frame.size)),
                         LayoutRegion(id: "selection", parentID: "window", role: .content, rect: shot.crop)], regions: regions)
            try snapshot.validate(currentRevision: target.revision)
            var warnings = ["OCR 定位和背景颜色为估算；请核对译文，覆盖可随时撤除。"]
            if regions.contains(where: { $0.confidence < 0.7 }) { warnings.append("部分文字识别置信度较低，可能存在识别错误。") }
            if shot.translucent { warnings.append("目标区域包含透明背景，覆盖可能无法准确还原背景。") }
            warnings.append("复杂或非均匀背景可能影响遮盖效果；背景采样未经原生验证。")
            if observations.contains(where: { $0.normalizedBox.minX <= 0.005 || $0.normalizedBox.minY <= 0.005 || $0.normalizedBox.maxX >= 0.995 || $0.normalizedBox.maxY >= 0.995 }) {
                warnings.append("所选区域边缘可能截断文字；只显示裁剪区域内的位置。")
            }
            return (.partial(snapshot, warnings: warnings), shot.signature)
        } catch is CancellationError { return (.error("捕获已取消。"), nil) }
        catch let error as TargetLockError { return (.error(error.localizedDescription), nil) }
        catch let error as DesktopCaptureError { return (.error(error.localizedDescription), nil) }
        catch {
            let failure = error as NSError
            if !CGPreflightScreenCaptureAccess() || (failure.domain == SCStreamErrorDomain && [-3801, -3817, -3821].contains(failure.code)) {
                return (.needsPermission(.screenRecording), nil)
            }
            return (.error("无法捕获或识别所选窗口；请检查屏幕录制权限后重试。"), nil)
        }
    }

    /// S0 uses exactly this one shot and discards it; does not call Vision or write an image.
    static func permissionShot(target: CaptureTarget) async throws -> CGSize {
        let shot = try await screenshot(target: target, selection: CGRect(origin: .zero, size: target.frame.size))
        return shot.transform.imagePixelSize
    }

    fileprivate static func signature(target: CaptureTarget, selection: CGRect) async throws -> RegionSignature {
        try await screenshot(target: target, selection: selection).signature
    }

    private static func screenshot(target: CaptureTarget, selection: CGRect) async throws -> CapturedRegion {
        if let error = await TargetLocker.revalidate(target) { throw error }
        guard let crop = SelectionMemory.clamp(selection, to: target.frame.size) else { throw DesktopCaptureError.invalidSelection }
        guard selection == target.effectiveSelection else { throw DesktopCaptureError.invalidSelection }
        guard await TargetLocker.isFullyVisible(target, selection: crop) else { throw TargetLockError.offscreen }
        guard !(await TargetLocker.isOccluded(target, selection: crop)) else { throw TargetLockError.obscured }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID && $0.owningApplication?.processID == target.pid }),
              window.isOnScreen, window.windowLayer == 0, window.frame == target.frame else { throw DesktopCaptureError.protectedWindow }
        // A desktop-independent filter captures only the locked window, not displays or other apps.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0 else { throw DesktopCaptureError.wrongSize }
        let config = SCStreamConfiguration()
        config.sourceRect = crop
        config.width = Int((crop.width * scale).rounded())
        config.height = Int((crop.height * scale).rounded())
        guard config.width > 0, config.height > 0, config.width <= 32768, config.height <= 32768,
              Double(config.width) * Double(config.height) <= 100_000_000 else { throw DesktopCaptureError.invalidSelection }
        config.scalesToFit = false
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // Never use the configured scale as geometry without checking the actual result within 1 pixel.
        let pixels = CGSize(width: image.width, height: image.height)
        let transform = TransformProvenance(crop: crop, imagePixelSize: pixels, windowOrigin: target.frame.origin)
        guard transform.imageSizeMatches(expectedPixels: CGSize(width: crop.width * scale, height: crop.height * scale)),
              abs(filter.contentRect.width - target.frame.width) <= 1,
              abs(filter.contentRect.height - target.frame.height) <= 1 else { throw DesktopCaptureError.wrongSize }
        if let error = await TargetLocker.revalidate(target) { throw error }
        let analysis = try analyze(image)
        guard !analysis.black else { throw DesktopCaptureError.black }
        return CapturedRegion(image: image, crop: crop, transform: transform, signature: analysis.signature, translucent: analysis.translucent)
    }

    private static func background(image: CGImage, local: CGRect, crop: CGRect) throws -> RegionBackgroundEvidence? {
        let relative = local.offsetBy(dx: -crop.minX, dy: -crop.minY)
        guard let pixelRect = CoordinateMapper.cropPixelRect(local: relative, windowSize: crop.size,
              imageSize: CGSize(width: image.width, height: image.height)), let part = image.cropping(to: pixelRect) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: 8, height: 8)); return true
        }
        guard ok else { return nil }
        // Edge median reduces text-ink contamination, without pretending a bitmap is native background evidence.
        var channels = [[UInt8]](repeating: [], count: 4)
        for y in 0..<8 { for x in 0..<8 where x == 0 || x == 7 || y == 0 || y == 7 {
            let i = (y * 8 + x) * 4
            for c in 0..<4 { channels[c].append(rgba[i + c]) }
        } }
        let medians = channels.map { Double($0.sorted()[$0.count / 2]) / 255 }
        return RegionBackgroundEvidence(red: medians[0], green: medians[1], blue: medians[2], alpha: medians[3], verified: false)
    }

    private static func recognize(_ image: CGImage, languageCorrection: Bool) async throws -> [OCRObservation] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "zh-Hans"]
            request.usesLanguageCorrection = languageCorrection
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return OCRObservation(text: text.string, confidence: Double(text.confidence), normalizedBox: observation.boundingBox)
            }
        }.value
    }

    private static func analyze(_ image: CGImage) throws -> (black: Bool, translucent: Bool, signature: RegionSignature) {
        // The small derived buffer is discarded after measuring; no image disk serialization or logs.
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard ok else { throw DesktopCaptureError.wrongSize }
        var gray = [UInt8](); gray.reserveCapacity(1024)
        var black = true, translucent = false
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if r > 3 || g > 3 || b > 3 { black = false }
            if pixels[i + 3] < 250 { translucent = true }
            gray.append(UInt8((r * 77 + g * 150 + b * 29) >> 8))
        }
        return (black, translucent, RegionSignature(pixels: gray))
    }
}

@MainActor
final class TargetMonitor {
    private let target: CaptureTarget
    private let selection: CGRect
    private let baseline: RegionSignature?
    private let onInvalid: @MainActor (String) -> Void
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sampleTask: Task<Void, Never>?
    private var changedSamples = 0
    private var tickCount = 0
    private var active = false
    init(target: CaptureTarget, selection: CGRect, baseline: RegionSignature? = nil, onInvalid: @escaping @MainActor (String) -> Void) {
        self.target = target; self.selection = selection; self.baseline = baseline; self.onInvalid = onInvalid
    }
    func start() {
        stop(); active = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self.invalidate(TargetLockError.changed.localizedDescription) }
                    else { self.check() }
                }
            }
            observers.append((workspace, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate(TargetLockError.changed.localizedDescription) }
        }
        observers.append((center, token))
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        check()
    }
    func stop() {
        active = false; timer?.invalidate(); timer = nil
        sampleTask?.cancel(); sampleTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll(); changedSamples = 0; tickCount = 0
    }
    private func invalidate(_ reason: String) {
        guard active else { return }
        stop(); onInvalid(reason)
    }
    private func check() {
        guard active else { return }
        if let error = TargetLocker.revalidate(target) { invalidate(error.localizedDescription); return }
        if TargetLocker.isOccluded(target, selection: selection) { invalidate(TargetLockError.obscured.localizedDescription); return }
        tickCount += 1
        guard tickCount % 2 == 0, let baseline, sampleTask == nil else { return }
        // We do not mask/exclude cursor pixels heuristically. Only the SCK showsCursor=false contract
        // excludes cursor; a source that cannot prove exclusion must conservatively invalidate.
        sampleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sample = try await DesktopCapture.signature(target: target, selection: selection)
                guard active, !Task.isCancelled else { return }
                changedSamples = sample.differs(from: baseline) ? changedSamples + 1 : 0
                sampleTask = nil
                if changedSamples >= 2 { invalidate("目标区域连续两次发生内容变化，已撤除覆盖。") }
            } catch {
                guard active, !Task.isCancelled else { return }
                sampleTask = nil; invalidate("无法继续确认目标区域，已撤除覆盖。")
            }
        }
    }
}
