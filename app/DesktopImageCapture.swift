import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Image mode (OCR-free)

/// The one captured crop held IN MEMORY for image mode. It is encoded to PNG for the single model request and is
/// afterwards used only to derive the immutable freshness baseline from the model's validated regions. Never written
/// to disk, never logged; dropped with the session.
struct HeldCapture {
    fileprivate let region: CapturedRegion
    var crop: CGRect { region.crop }
    var transform: TransformProvenance { region.transform }
}

extension DesktopCapture {
    /// Same exact-window/crop SCK path, identity, visibility, occlusion and protected-black checks as OCR capture,
    /// but no recognition. Returns the held image or a fail-closed outcome (never a fallback to OCR).
    static func captureHeld(target: CaptureTarget, selection: CGRect) async -> (HeldCapture?, RouterOutcome?) {
        guard await ScreenCapturePermission.preflight() else { return (nil, .needsPermission(.screenRecording)) }
        do { return (HeldCapture(region: try await screenshot(target: target, selection: selection)), nil) }
        catch is CancellationError { return (nil, .error("捕获已取消。")) }
        catch let error as TargetLockError { return (nil, .error(error.localizedDescription)) }
        catch let error as DesktopCaptureError { return (nil, .error(error.localizedDescription)) }
        catch {
            let failure = error as NSError
            if !CGPreflightScreenCaptureAccess() || (failure.domain == SCStreamErrorDomain && [-3801, -3817, -3821].contains(failure.code)) {
                return (nil, .needsPermission(.screenRecording))
            }
            return (nil, .error("ScreenCaptureKit 捕获失败（\(failure.domain) \(failure.code)）；窗口可能受系统或应用保护，无法捕获（这不代表没有文字）。"))
        }
    }

    /// In-memory PNG of exactly the captured crop pixels.
    static func pngData(_ held: HeldCapture) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, held.region.image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Model geometry → snapshot + baseline. Regions come from `PiImageResponse` (crop fractions already mapped to
    /// window-local points, clamped to the crop). Background evidence is sampled from the HELD original pixels, the
    /// same full containment rule drops anything straddling the crop, and the baseline signature is taken from the
    /// held ORIGINAL image over exactly the rectangles the plan can replace. No recapture, no widening.
    /// Provenance is `.modelImage`: model-derived, never verified-native and never labelled OCR.
    static func snapshotFromModel(target: CaptureTarget, held: HeldCapture, regions input: [TextRegion], unicode: Bool = false, targetLanguage: String? = nil) throws -> (CaptureSnapshot, RegionSignature?) {
        let shot = held.region
        let window = LayoutRegion(id: "window", role: .window, rect: CGRect(origin: .zero, size: target.frame.size))
        let selectionLayout = LayoutRegion(id: "selection", parentID: "window", role: .content, rect: shot.crop)
        var regions: [TextRegion] = []
        for var region in input {
            region.source = .modelImage
            region.rect = region.rect.intersection(shot.crop)
            region.lineRects = region.lineRects.map { $0.intersection(shot.crop) }.filter { !$0.isNull && !$0.isEmpty }
            let rects = region.lineRects.isEmpty ? [region.rect] : region.lineRects
            guard !region.rect.isNull, !region.rect.isEmpty, rects.allSatisfy({ shot.crop.insetBy(dx: -1, dy: -1).contains($0) }) else { continue }
            region.background = try background(image: shot.image, local: region.rect, crop: shot.crop)
            regions.append(region)
        }
        let bounds = CGRect(origin: .zero, size: target.frame.size)
        FreeSpace.attach(to: &regions, image: shot.image, crop: shot.crop, bounds: bounds, containers: [window.id: window.rect, selectionLayout.id: selectionLayout.rect])
        guard !regions.isEmpty else { throw DesktopCaptureError.invalidSelection }
        let evidence = CapabilityEvidence(level: .partial, interface: "ScreenCaptureKit cropped window + 模型图像理解（pi RPC）", note: "模型给出的文字与位置，未经原生或 OCR 验证")
        let snapshot = CaptureSnapshot(target: target,
            capabilities: SnapshotCapabilities(visibleText: evidence, textGeometry: evidence, contentRevision: CapabilityEvidence(level: .partial, interface: "full-resolution pixel hashes of the model-reported source rectangles; two consecutive changes")),
            provenance: .modelImage, transform: shot.transform, layout: [window, selectionLayout], regions: regions)
        try snapshot.validate(currentRevision: target.revision)
        var baseline: RegionSignature?
        if let areas = relevantAreas(snapshot: snapshot, selection: shot.crop, unicode: unicode, target: targetLanguage) {
            baseline = try signature(of: shot.image, crop: shot.crop, areas: areas)
        }
        return (snapshot, baseline)
    }
}
