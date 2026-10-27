import CoreGraphics
import Foundation

struct CapturedRegion {
    let image: CGImage
    let crop: CGRect
    let transform: TransformProvenance
    let translucent: Bool
}

enum DesktopCaptureError: LocalizedError {
    case invalidSelection, wrongSize, black, noCaptureTarget, changed
    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "所选区域不在目标窗口内。"
        case .wrongSize: return "截图像素尺寸与窗口区域不匹配，无法保证原位置覆盖。"
        case .black: return "截图全部为黑色，无法确认原因；窗口可能受系统或应用保护，也可能确实为纯黑。无法捕获可识别内容，未进行识别（这不代表没有文字）。"
        case .noCaptureTarget: return "ScreenCaptureKit 未提供该窗口的捕获目标，窗口可能受系统或应用保护或已不可见；无法捕获，未进行识别（这不代表没有文字）。"
        case .changed: return "捕获期间目标改变，已丢弃截图。"
        }
    }
}

extension DesktopCapture {
    /// Occupied source rectangles (window-local points) the snapshot's plan can replace, as a validated area set.
    /// nil when the plan has no translatable region or no valid rectangle remains.
    static func relevantAreas(snapshot: CaptureSnapshot, selection: CGRect, unicode: Bool = false, target: String? = nil) -> RelevantAreas? {
        let plan = DesktopPlan(snapshot: snapshot, unicode: unicode, target: target)
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

enum DesktopCapture {}
