import Foundation

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
    static let occluded = TargetInvalidation(TargetLockError.obscured)
    static let contentChanged = TargetInvalidation(reason: FreshnessError.contentChanged.localizedDescription, clearsSelectionMemory: false)
    static let unverifiable = TargetInvalidation(reason: "无法继续确认目标区域，已撤除覆盖。", clearsSelectionMemory: false)
    static func layout(_ detail: String) -> TargetInvalidation {
        TargetInvalidation(TargetLockError.layoutChangedBecause(detail))
    }
}

/// Fixed, content-free message for the two-consecutive-change policy. It is thrown by `DesktopCapture.verifyFreshness`
/// and reported by `TargetMonitor` ONLY BEFORE anything is drawn (the baseline-bearing monitor is replaced by a
/// geometry-only monitor once the overlay is presented: later content changes never withdraw it).
enum FreshnessError: LocalizedError {
    case contentChanged
    var errorDescription: String? {
        switch self {
        case .contentChanged: return "所选区域内文字的像素与捕获时不一致（连续两次采样），为避免覆盖到已变化的内容，未显示译文覆盖。"
        }
    }
}
