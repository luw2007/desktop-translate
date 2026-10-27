import CoreGraphics
import Foundation

// Provider outcome resolution and coordinate transforms for desktop capture. No AppKit.

// MARK: - Router outcomes

enum PermissionKind: String, Sendable { case screenRecording, accessibility, automation }

enum RouterOutcome: Equatable, Sendable {
    case snapshot(CaptureSnapshot)
    /// Some regions were captured; `warnings` explains what is missing.
    case partial(CaptureSnapshot, warnings: [String])
    /// Provider ran but found no translatable content.
    case none
    /// No provider supports this target.
    case unsupported(String)
    case error(String)
    case needsPermission(PermissionKind)
}

enum CaptureRouter {
    /// Combine provider results in priority order. First fully valid snapshot wins; a partial one is kept
    /// as fallback; otherwise needsPermission > error > none > unsupported. Invalid snapshots become errors.
    static func resolve(_ results: [RouterOutcome], currentRevision: UInt64? = nil) -> RouterOutcome {
        var partial: RouterOutcome?
        var permission: PermissionKind?
        var error: String?
        var sawNone = false
        var unsupported: String?
        for r in results {
            switch r {
            case .snapshot(let s):
                do { try s.validate(currentRevision: currentRevision); return r }
                catch let e { if error == nil { error = "invalid snapshot: \(e)" } }
            case .partial(let s, _):
                if partial == nil {
                    if (try? s.validate(currentRevision: currentRevision)) != nil { partial = r }
                    else if error == nil { error = "invalid partial snapshot" }
                }
            case .none: sawNone = true
            case .unsupported(let m): if unsupported == nil { unsupported = m }
            case .error(let m): if error == nil { error = m }
            case .needsPermission(let p): if permission == nil { permission = p }
            }
        }
        if let partial { return partial }
        if let permission { return .needsPermission(permission) }
        if let error { return .error(error) }
        if sawNone { return .none }
        return .unsupported(unsupported ?? "no provider")
    }
}

// MARK: - Coordinate transforms

enum CoordinateMapper {
    /// Vision normalized rect (origin bottom-left, 0...1 of the cropped image) to window-local points
    /// (origin top-left). `crop` is the captured sub-rect in window-local points; it may have any
    /// positive aspect (non-uniform scale) and any origin (including negative).
    static func visionToLocal(_ n: CGRect, crop: CGRect) -> CGRect {
        CGRect(x: crop.minX + n.minX * crop.width,
               y: crop.minY + (1 - n.maxY) * crop.height,
               width: n.width * crop.width,
               height: n.height * crop.height)
    }

    /// Inverse of `visionToLocal`.
    static func localToVision(_ r: CGRect, crop: CGRect) -> CGRect {
        guard crop.width > 0, crop.height > 0 else { return .zero }
        return CGRect(x: (r.minX - crop.minX) / crop.width,
                      y: 1 - (r.maxY - crop.minY) / crop.height,
                      width: r.width / crop.width,
                      height: r.height / crop.height)
    }

    /// Window-local crop rect (points) to pixel rect in an image of `imageSize` pixels covering the whole
    /// window of `windowSize` points. Scale may differ per axis. Result is clamped to the image and
    /// rounded outward to whole pixels; nil when empty after clamping.
    static func cropPixelRect(local: CGRect, windowSize: CGSize, imageSize: CGSize) -> CGRect? {
        guard windowSize.width > 0, windowSize.height > 0, imageSize.width > 0, imageSize.height > 0,
              local.width > 0, local.height > 0 else { return nil }
        let sx = imageSize.width / windowSize.width, sy = imageSize.height / windowSize.height
        let minX = max(0, (local.minX * sx).rounded(.down)), minY = max(0, (local.minY * sy).rounded(.down))
        let maxX = min(imageSize.width, (local.maxX * sx).rounded(.up))
        let maxY = min(imageSize.height, (local.maxY * sy).rounded(.up))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func localToGlobal(_ r: CGRect, windowOrigin: CGPoint) -> CGRect {
        r.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
    }

    static func globalToLocal(_ r: CGRect, windowOrigin: CGPoint) -> CGRect {
        r.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y)
    }

    /// Global CG (top-left of primary, y down) to AppKit (bottom-left of primary, y up). Involution.
    static func globalToAppKit(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func appKitToGlobal(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        globalToAppKit(r, primaryHeight: primaryHeight)
    }
}
