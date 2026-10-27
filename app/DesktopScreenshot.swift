import CoreGraphics
import Foundation
import ScreenCaptureKit

extension DesktopCapture {
    static func screenshot(target: CaptureTarget, selection: CGRect) async throws -> CapturedRegion {
        if let error = await TargetLocker.revalidate(target) { throw error }
        guard let crop = SelectionMemory.clamp(selection, to: target.frame.size) else { throw DesktopCaptureError.invalidSelection }
        guard selection == target.effectiveSelection else { throw DesktopCaptureError.invalidSelection }
        guard await TargetLocker.isFullyVisible(target, selection: crop) else { throw TargetLockError.offscreen }
        guard !(await TargetLocker.isOccluded(target, selection: crop)) else { throw TargetLockError.obscured }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.windowID && $0.owningApplication?.processID == target.pid }),
              window.isOnScreen, window.windowLayer == 0, window.frame == target.frame else { throw DesktopCaptureError.noCaptureTarget }
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

    static func background(image: CGImage, local: CGRect, crop: CGRect) throws -> RegionBackgroundEvidence? {
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
}
