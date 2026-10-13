import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision
import Foundation

/// Fail-closed public window baseline. No Accessibility calls, window titles are never used as identity.
enum TargetLockError: LocalizedError {
    case ownApp, terminated, noWindow, ambiguous, sharingNone, offscreen, changed, obscured
    case unavailable, overlappingWindows
    /// Same as `changed`, but names which public identity component differed (pid/ids/geometry only, never text).
    case changedBecause(String)
    var errorDescription: String? {
        switch self {
        case .ownApp: return "请在要翻译的应用中按快捷键，不能捕获翻译器自身。"
        case .terminated: return "目标应用已退出或进程身份改变，请重新选择。"
        case .noWindow: return "没有可确认的前台普通窗口；请切回目标窗口再试。"
        case .ambiguous: return "无法确定主窗口或模态窗口的边界，请关闭弹窗后重新选择。"
        case .overlappingWindows: return "目标应用有多个相互重叠的普通窗口（包括位置和大小相同但窗口 ID 不同的窗口），无法确定要翻译哪一个；请关闭多余窗口后重试。"
        case .sharingNone: return "目标窗口禁止屏幕共享，无法捕获。"
        case .offscreen: return "目标窗口不在当前可见桌面或显示器上。"
        case .changed: return "目标窗口、显示器或前台应用已改变，请重新按快捷键。"
        case .changedBecause(let detail): return "目标窗口、显示器或前台应用已改变（\(detail)），请重新按快捷键。"
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
        // Without AX we cannot prove which same-app window is the main window versus a sheet/dialog/duplicate surface.
        // Any other overlapping ordinary same-app window (including a different ID with an EQUAL frame) is refused:
        // equal bounds are NOT proof of identical contents or of which ID is the main window.
        guard !owned.dropFirst().contains(where: { $0.frame.intersects(first.frame) }) else { return .failure(.overlappingWindows) }
        let displays = displayIDs(intersecting: first.frame)
        guard !displays.isEmpty else { return .failure(.offscreen) }
        return .success(CaptureTarget(pid: app.processIdentifier, windowID: first.id,
            appLaunchTime: launched.timeIntervalSince1970, bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "应用", title: first.name, frame: first.frame, displayIDs: displays))
    }
    static func revalidate(_ target: CaptureTarget) -> TargetLockError? {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.launchDate?.timeIntervalSince1970 == target.appLaunchTime else { return .terminated }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == target.pid else {
            return .changedBecause("frontmost pid \(target.pid)→\(front.map { String($0.processIdentifier) } ?? "nil") \(front?.bundleIdentifier ?? "-")")
        }
        switch lock(app: app) {
        case .failure(let error): return error
        case .success(let now):
            guard now.windowID == target.windowID else { return .changedBecause("windowID \(target.windowID)→\(now.windowID)") }
            guard now.frame == target.frame else { return .changedBecause("frame \(target.frame)→\(now.frame)") }
            guard now.displayIDs == target.displayIDs else { return .changedBecause("displays \(target.displayIDs)→\(now.displayIDs)") }
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

/// Content signature of the exact captured region: pixel dimensions, selected crop, pixel format and one
/// 64-bit hash per block of full-resolution pixels (at most 64x64 blocks = 32 KiB). No pixels are kept.
/// Any differing block is a change; there is no tolerance, so a blinking caret is a (documented) false positive.
struct RegionSignature: Equatable, Sendable {
    fileprivate let width: Int
    fileprivate let height: Int
    fileprivate let crop: CGRect
    fileprivate let blockWidth: Int
    fileprivate let blockHeight: Int
    fileprivate let format: UInt32
    fileprivate let hashes: [UInt64]
    func differs(from baseline: RegionSignature) -> Bool { self != baseline || hashes.isEmpty }
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
            let correct = languageCorrection && !OCRGrouper.terminalBundleIDs.contains(target.bundleID ?? "")
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
                capabilities: SnapshotCapabilities(visibleText: evidence, textGeometry: evidence, contentRevision: CapabilityEvidence(level: .partial, interface: "full-resolution per-block pixel hashes (dimensions+crop); two consecutive changes")),
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
        let analysis = try analyze(image, crop: crop)
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
                // Per-word boxes (normalized to the same crop) let the grouper split one Vision line that
                // spans unrelated columns or buttons. They are all-or-nothing: if any token lacks a valid box,
                // the observation carries no words at all (line-level fallback), never a partial list.
                let string = text.string
                var words: [OCRWord] = []
                var complete = true
                var index = string.startIndex
                scan: while index < string.endIndex {
                    while index < string.endIndex, string[index].isWhitespace { index = string.index(after: index) }
                    let start = index
                    while index < string.endIndex, !string[index].isWhitespace { index = string.index(after: index) }
                    guard start < index else { break }
                    guard let observed = try? text.boundingBox(for: start..<index) else { complete = false; break scan }
                    let box = observed.boundingBox
                    guard [box.minX, box.minY, box.width, box.height].allSatisfy({ $0.isFinite }), box.width > 0, box.height > 0 else {
                        complete = false; break scan
                    }
                    words.append(OCRWord(text: String(string[start..<index]), normalizedBox: box))
                }
                if !complete { words = [] }
                return OCRObservation(text: string, confidence: Double(text.confidence), normalizedBox: observation.boundingBox, words: words)
            }
        }.value
    }

    /// One pass over the captured pixels yields the black/translucent flags and the content signature.
    /// Nothing is serialized or logged; only the derived block hashes survive this call.
    private static func analyze(_ image: CGImage, crop: CGRect) throws -> (black: Bool, translucent: Bool, signature: RegionSignature) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { throw DesktopCaptureError.wrongSize }
        let bw = max(16, (w + 63) / 64), bh = max(16, (h + 63) / 64)
        let cols = (w + bw - 1) / bw, rows = (h + bh - 1) / bh
        let prime: UInt64 = 0x100000001b3
        var hashes = [UInt64](repeating: 0xcbf29ce484222325, count: cols * rows)
        var black = true, translucent = false

        /// Canonical word layout (both paths): A<<24 | R<<16 | G<<8 | B. Alpha is skipped when the format has none.
        func hashRow(_ row: UnsafeRawPointer, blockRow by: Int, mask: UInt32, hasAlpha: Bool) {
            for bx in 0..<cols {
                let x0 = bx * bw, x1 = min(w, x0 + bw)
                var hv = hashes[by * cols + bx]
                for x in x0..<x1 {
                    let px = row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
                    if px & 0x00FCFCFC != 0 { black = false }
                    if hasAlpha, px >> 24 < 250 { translucent = true }
                    hv = (hv ^ UInt64(px & mask)) &* prime
                }
                hashes[by * cols + bx] = hv
            }
        }

        let info = image.bitmapInfo
        let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let nativeLayout = image.bitsPerPixel == 32 && image.bitsPerComponent == 8
            && info.intersection(.byteOrderMask) == .byteOrder32Little
            && (alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst)
        var mode: UInt32 = 1
        if nativeLayout, let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * (h - 1) + w * 4 {
            // Hash the provider's own bytes in place: no second full-resolution image is allocated
            // (the CFData itself may be a transient system copy; that is not observable from here).
            mode = 0
            let hasAlpha = alpha != .noneSkipFirst
            let mask: UInt32 = hasAlpha ? 0xFFFFFFFF : 0x00FFFFFF
            for y in 0..<h { hashRow(UnsafeRawPointer(base) + y * image.bytesPerRow, blockRow: y / bh, mask: mask, hasAlpha: hasAlpha) }
            mode |= info.rawValue << 1
        } else {
            // Unknown native layout: convert one block-row band at a time into the canonical layout
            // (memory bounded by width * blockHeight * 4), never the whole image.
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw DesktopCaptureError.wrongSize }
            let bandInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            for by in 0..<rows {
                let y0 = by * bh, bandH = min(bh, h - y0)
                var band = [UInt8](repeating: 0, count: w * 4 * bandH)
                let ok = band.withUnsafeMutableBytes { bytes -> Bool in
                    guard let base = bytes.baseAddress,
                          let ctx = CGContext(data: base, width: w, height: bandH, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: space, bitmapInfo: bandInfo) else { return false }
                    ctx.interpolationQuality = .none
                    ctx.draw(image, in: CGRect(x: 0, y: bandH + y0 - h, width: w, height: h))
                    for r in 0..<bandH { hashRow(UnsafeRawPointer(base) + r * w * 4, blockRow: by, mask: 0xFFFFFFFF, hasAlpha: true) }
                    return true
                }
                guard ok else { throw DesktopCaptureError.wrongSize }
            }
        }
        return (black, translucent, RegionSignature(width: w, height: h, crop: crop, blockWidth: bw, blockHeight: bh, format: mode, hashes: hashes))
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
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self.invalidate(TargetLockError.changedBecause("activeSpaceDidChange").localizedDescription) }
                    else { self.check() }
                }
            }
            observers.append((workspace, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate(TargetLockError.changedBecause("screenParametersChanged").localizedDescription) }
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
