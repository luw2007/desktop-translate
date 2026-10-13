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
    /// Window id / frame / display set differed: resize, pane or layout change. Distinct so the session can clear the selection at once.
    case layoutChangedBecause(String)
    /// True when the locked window's geometry or layout (not identity/occlusion) is what broke.
    var isLayoutChange: Bool {
        switch self {
        case .layoutChangedBecause, .overlappingWindows, .ambiguous, .offscreen: return true
        default: return false
        }
    }
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
        case .changedBecause(let detail), .layoutChangedBecause(let detail): return "目标窗口、显示器或前台应用已改变（\(detail)），请重新按快捷键。"
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
    /// Read-only publication evidence for ONE exact window (id + owner pid) in the on-screen list, for harness
    /// readiness only. nil = not listed (yet). Never used by the product capture path.
    static func publication(windowID: UInt32, pid: Int32) -> (layer: Int, frame: CGRect, alpha: Double, sharing: Int)? {
        guard let row = windows()?.first(where: { $0.id == windowID && $0.pid == pid }) else { return nil }
        return (row.layer, row.frame, row.alpha, row.sharing)
    }
    /// Ids of this pid's ordinary on-screen windows (identity-swap detection for harness readiness).
    static func ordinaryWindowIDs(pid: Int32) -> [UInt32] {
        (windows() ?? []).filter { $0.pid == pid && $0.ordinary }.map(\.id)
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
            guard now.windowID == target.windowID else { return .layoutChangedBecause("windowID \(target.windowID)→\(now.windowID)") }
            guard now.frame.size == target.frame.size else { return .layoutChangedBecause("size \(target.frame.size)→\(now.frame.size)") }
            guard now.frame == target.frame else { return .changedBecause("moved \(target.frame.origin)→\(now.frame.origin)") }
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


/// Why a TargetMonitor stopped. `clearsSelectionMemory` is true for size/layout/pane/tab/screen-parameter/Space
/// changes (the remembered selection no longer maps to the same content); false for move-only, occlusion,
/// frontmost change and content change. `reason` is user-safe text (never window text).
struct TargetInvalidation: Sendable {
    var reason: String
    var clearsSelectionMemory: Bool
    init(_ error: TargetLockError) {
        reason = error.localizedDescription
        clearsSelectionMemory = error.isLayoutChange
    }
    fileprivate init(reason: String, clearsSelectionMemory: Bool) {
        self.reason = reason; self.clearsSelectionMemory = clearsSelectionMemory
    }
    fileprivate static let occluded = TargetInvalidation(TargetLockError.obscured)
    fileprivate static let contentChanged = TargetInvalidation(reason: FreshnessError.contentChanged.localizedDescription, clearsSelectionMemory: false)
    fileprivate static let unverifiable = TargetInvalidation(reason: "无法继续确认目标区域，已撤除覆盖。", clearsSelectionMemory: false)
    fileprivate static func layout(_ detail: String) -> TargetInvalidation {
        TargetInvalidation(TargetLockError.layoutChangedBecause(detail))
    }
}

/// Thrown by `DesktopCapture.verifyFreshness` when the selected crop differs from the baseline on two consecutive samples.
enum FreshnessError: LocalizedError {
    case contentChanged
    var errorDescription: String? { "所选区域内容已变化（连续两次采样与基线不一致），未显示译文覆盖。" }
}

private struct CapturedRegion {
    let image: CGImage
    let crop: CGRect
    let transform: TransformProvenance
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

extension DesktopCapture {
    /// Occupied source rectangles (window-local points) the snapshot's plan can replace, as a validated area set.
    /// nil when the plan has no translatable region or no valid rectangle remains.
    static func relevantAreas(snapshot: CaptureSnapshot, selection: CGRect) -> RelevantAreas? {
        let plan = DesktopPlan(snapshot: snapshot)
        guard !plan.requests.isEmpty else { return nil }
        return RelevantAreas(rects: plan.replacedSourceRects(snapshot: snapshot, selection: selection), crop: selection)
    }

    /// Keep only plugin containers that are well-formed and whose whole ancestry resolves inside window/selection.
    /// Roots are re-parented to "selection", every rect is clipped to the selection, IDs are preserved.
    static func trustedLayout(_ layout: [LayoutRegion], window: LayoutRegion, selection: LayoutRegion) -> [LayoutRegion] {
        var accepted: [LayoutRegion] = []
        var rects: [String: CGRect] = [window.id: window.rect, selection.id: selection.rect]
        var pending = layout.filter { !$0.id.isEmpty && $0.id != window.id && $0.id != selection.id }
        var progressed = true
        while progressed, !pending.isEmpty {
            progressed = false
            var next: [LayoutRegion] = []
            for var region in pending {
                let parentID = region.parentID ?? window.id
                guard let parentRect = rects[parentID] else { next.append(region); continue }
                progressed = true
                let r = region.rect
                guard [r.origin.x, r.origin.y, r.width, r.height].allSatisfy({ $0.isFinite }),
                      rects[region.id] == nil, parentRect.insetBy(dx: -1, dy: -1).contains(r) else { continue }
                let clipped = r.intersection(selection.rect)
                guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
                region.rect = clipped
                region.parentID = parentID == window.id ? selection.id : parentID
                rects[region.id] = clipped; accepted.append(region)
            }
            pending = next
        }
        return accepted
    }
}

enum DesktopCapture {
    static func capture(target: CaptureTarget, selection: CGRect, languageCorrection: Bool = true) async -> RouterOutcome {
        await captureWithSignature(target: target, selection: selection, languageCorrection: languageCorrection).0
    }
    /// `layout` is optional plugin container geometry. Only an independently verified layout may be passed; it is
    /// re-validated here (ancestry resolves inside window/selection, containment, clipped to the crop) before grouping.
    /// The returned signature is taken from the ORIGINAL image, over exactly the occupied rectangles of the translatable
    /// regions of this snapshot's plan; the image is dropped on return.
    static func captureWithSignature(target: CaptureTarget, selection: CGRect, languageCorrection: Bool = true,
                                     layout: [LayoutRegion] = []) async -> (RouterOutcome, RegionSignature?) {
        guard await ScreenCapturePermission.preflight() else { return (.needsPermission(.screenRecording), nil) }
        do {
            let shot = try await screenshot(target: target, selection: selection)
            try Task.checkCancellation()
            let correct = languageCorrection && !OCRGrouper.terminalBundleIDs.contains(target.bundleID ?? "")
            let observations = try await recognize(shot.image, languageCorrection: correct)
            guard await TargetLocker.revalidate(target) == nil else { return (.error(DesktopCaptureError.changed.localizedDescription), nil) }
            let window = LayoutRegion(id: "window", role: .window, rect: CGRect(origin: .zero, size: target.frame.size))
            let selectionLayout = LayoutRegion(id: "selection", parentID: "window", role: .content, rect: shot.crop)
            let trusted = trustedLayout(layout, window: window, selection: selectionLayout)
            let grouped = OCRGrouper.grouped(observations, crop: shot.crop, target: target, layout: trusted)
            var regions = grouped.regions
            var dropped = 0
            let known = Dictionary(uniqueKeysWithValues: ([window, selectionLayout] + trusted).map { ($0.id, $0.rect) })
            for index in regions.indices {
                let parent = regions[index].parentID.flatMap { known[$0] != nil ? $0 : nil } ?? "selection"
                regions[index].parentID = parent
                regions[index].rect = regions[index].rect.intersection(shot.crop)
                regions[index].lineRects = regions[index].lineRects.map { $0.intersection(shot.crop) }.filter { !$0.isNull && !$0.isEmpty }
                // Full containment, not centre membership: text straddling its container's edge is never overlaid.
                let container = (known[parent] ?? shot.crop).insetBy(dx: -1, dy: -1)
                let rects = regions[index].lineRects.isEmpty ? [regions[index].rect] : regions[index].lineRects
                if regions[index].rect.isNull || regions[index].rect.isEmpty || !rects.allSatisfy({ container.contains($0) }) {
                    regions[index].rect = .null; dropped += 1; continue
                }
                regions[index].background = try background(image: shot.image, local: regions[index].rect, crop: shot.crop)
            }
            regions.removeAll { $0.rect.isNull || $0.rect.isEmpty }
            guard !regions.isEmpty else { return (.none, nil) }
            let evidence = CapabilityEvidence(level: .partial, interface: "ScreenCaptureKit cropped window + Vision accurate en-US/zh-Hans", note: "截图 OCR，不代表原生控件或字体布局")
            let snapshot = CaptureSnapshot(target: target,
                capabilities: SnapshotCapabilities(visibleText: evidence, textGeometry: evidence, contentRevision: CapabilityEvidence(level: .partial, interface: "full-resolution pixel hashes of the translatable source rectangles; two consecutive changes")),
                provenance: .ocr, transform: shot.transform,
                layout: [window, selectionLayout] + trusted, regions: regions)
            try snapshot.validate(currentRevision: target.revision)
            // Original-image baseline over exactly the rectangles the plan can replace. No valid relevant area =>
            // no signature (the session then refuses to present); never silently the whole crop.
            var baseline: RegionSignature?
            if let areas = relevantAreas(snapshot: snapshot, selection: shot.crop) {
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
            return (.partial(snapshot, warnings: warnings), baseline)
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

    /// One monitor/presentation sample: a fresh shot hashed with the BASELINE's own relevant areas.
    fileprivate static func signature(target: CaptureTarget, selection: CGRect, areas: RelevantAreas) async throws -> RegionSignature {
        let shot = try await screenshot(target: target, selection: selection)
        return try signature(of: shot.image, crop: shot.crop, areas: areas)
    }

    /// Shared pre-display gate. Takes a fresh sample (each one re-checks identity, full visibility and occlusion
    /// before and after the SCK capture and keeps the protected-black rejection). An unchanged sample passes.
    /// A first changed sample is not trusted: after the monitor's own interval (two 0.25 s ticks) a second sample is
    /// taken; unchanged passes (a one-off transient), changed again throws `FreshnessError.contentChanged`.
    /// `baseline` is compared as-is and is never replaced. `selection == nil` means the target's effective selection.
    /// Full-pixel signature, no tolerance and no caret exclusion: a rendered caret inside the selection that
    /// blinks on both samples is reported as content change (no independent geometry exists to exclude it).
    static func verifyFreshness(target: CaptureTarget, selection: CGRect?, baseline: RegionSignature) async throws {
        let rect = selection ?? target.effectiveSelection
        var tracker = FreshnessTracker(baseline: baseline)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
            let sample = try await signature(target: target, selection: rect, areas: baseline.areas)
            try Task.checkCancellation()
            if tracker.observe(sample) { throw FreshnessError.contentChanged }
            if tracker.changedSamples == 0 { return }
        }
    }

    /// Image-to-signature entry for screen-free consumers (same raw-BGRA / bounded-band hashing and protected-black
    /// rejection as live capture): hashes ONLY the pixel rectangles `areas` covers inside `image` (an image of `crop`).
    /// Feed results to `FreshnessTracker` to exercise the two-change policy.
    static func signature(of image: CGImage, crop: CGRect, areas: RelevantAreas) throws -> RegionSignature {
        try mapSignature { try ContentSignature.sample(image: image, crop: crop, areas: areas).signature }
    }

    private static func mapSignature<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as SignatureError {
            switch error {
            case .black: throw DesktopCaptureError.black
            case .wrongSize: throw DesktopCaptureError.wrongSize
            case .invalidAreas: throw DesktopCaptureError.invalidSelection
            }
        }
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
        try Task.checkCancellation()
        // Never use the configured scale as geometry without checking the actual result within 1 pixel.
        let pixels = CGSize(width: image.width, height: image.height)
        let transform = TransformProvenance(crop: crop, imagePixelSize: pixels, windowOrigin: target.frame.origin)
        guard transform.imageSizeMatches(expectedPixels: CGSize(width: crop.width * scale, height: crop.height * scale)),
              abs(filter.contentRect.width - target.frame.width) <= 1,
              abs(filter.contentRect.height - target.frame.height) <= 1 else { throw DesktopCaptureError.wrongSize }
        if let error = await TargetLocker.revalidate(target) { throw error }
        let flags = try mapSignature { try ContentSignature.inspect(image) }
        guard !flags.black else { throw DesktopCaptureError.black }
        return CapturedRegion(image: image, crop: crop, transform: transform, translucent: flags.translucent)
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

    /// Holds the in-flight Vision request so structured cancellation can cancel it from the cancellation handler.
    private final class RequestCanceller: @unchecked Sendable {
        private let lock = NSLock()
        private var request: VNRequest?
        private var cancelled = false
        func register(_ request: VNRequest) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            self.request = request; return true
        }
        func cancel() {
            lock.lock(); cancelled = true; let current = request; request = nil; lock.unlock()
            current?.cancel()
        }
        func clear() { lock.lock(); request = nil; lock.unlock() }
    }

    private static func recognize(_ image: CGImage, languageCorrection: Bool) async throws -> [OCRObservation] {
        let canceller = RequestCanceller()
        let task = Task.detached(priority: .userInitiated) { () throws -> [OCRObservation] in
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "zh-Hans"]
            request.usesLanguageCorrection = languageCorrection
            guard canceller.register(request) else { throw CancellationError() }
            defer { canceller.clear() }
            // The handler (and thus the image reference) lives only for this scope.
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
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel(); canceller.cancel()
        }
    }

}

@MainActor
final class TargetMonitor {
    private let target: CaptureTarget
    private let selection: CGRect
    private let baseline: RegionSignature?
    private let onInvalid: @MainActor (TargetInvalidation) -> Void
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sampleTask: Task<Void, Never>?
    private var tracker: FreshnessTracker?
    private var tickCount = 0
    private var active = false
    init(target: CaptureTarget, selection: CGRect, baseline: RegionSignature? = nil, onInvalid: @escaping @MainActor (TargetInvalidation) -> Void) {
        self.target = target; self.selection = selection; self.baseline = baseline; self.onInvalid = onInvalid
        self.tracker = baseline.map(FreshnessTracker.init)
    }
    func start() {
        stop(); active = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self.invalidate(.layout("activeSpaceDidChange")) }
                    else { self.check() }
                }
            }
            observers.append((workspace, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate(.layout("screenParametersChanged")) }
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
        observers.removeAll(); tracker = baseline.map(FreshnessTracker.init); tickCount = 0
    }
    private func invalidate(_ reason: TargetInvalidation) {
        guard active else { return }
        stop(); onInvalid(reason)
    }
    private func check() {
        guard active else { return }
        if let error = TargetLocker.revalidate(target) { invalidate(TargetInvalidation(error)); return }
        if TargetLocker.isOccluded(target, selection: selection) { invalidate(.occluded); return }
        tickCount += 1
        guard tickCount % 2 == 0, baseline != nil, sampleTask == nil else { return }
        // We do not mask/exclude cursor pixels heuristically. Only the SCK showsCursor=false contract
        // excludes cursor; a source that cannot prove exclusion must conservatively invalidate.
        // The baseline is never refreshed; two consecutive differing samples invalidate.
        sampleTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let areas = baseline?.areas else { invalidate(.unverifiable); return }
                let sample = try await DesktopCapture.signature(target: target, selection: selection, areas: areas)
                guard active, !Task.isCancelled else { return }
                sampleTask = nil
                if tracker?.observe(sample) == true { invalidate(.contentChanged) }
            } catch {
                guard active, !Task.isCancelled else { return }
                sampleTask = nil
                if let lock = error as? TargetLockError { invalidate(TargetInvalidation(lock)) } else { invalidate(.unverifiable) }
            }
        }
    }
}

