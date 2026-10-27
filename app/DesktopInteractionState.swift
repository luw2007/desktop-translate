import CoreGraphics
import Foundation

// Per-window selection memory and the single-flight operation generation state machine. No AppKit.

// MARK: - Selection memory

/// Remembers a window-local user selection for the current window/session identity.
/// Size or tab/pane changes clear it; moving the window preserves its local coordinates.
struct SelectionMemory: Equatable, Sendable {
    private(set) var window: CaptureTarget?
    private var rect: CGRect?

    init() {}

    var isEmpty: Bool { rect == nil }

    /// Clamp a window-local rect into [0,size]; nil if degenerate or non-finite after clamping.
    static func clamp(_ r: CGRect, to size: CGSize) -> CGRect? {
        let v = [r.origin.x, r.origin.y, r.width, r.height]
        guard v.allSatisfy({ $0.isFinite }), size.width > 0, size.height > 0 else { return nil }
        let n = r.standardized
        let c = n.intersection(CGRect(origin: .zero, size: size))
        guard !c.isNull, c.width >= 1, c.height >= 1 else { return nil }
        return c
    }

    /// Store `rect` (window-local points) for `target`. Returns the clamped rect stored, or nil (and clears).
    @discardableResult
    mutating func remember(_ rect: CGRect, for target: CaptureTarget) -> CGRect? {
        guard let c = Self.clamp(rect, to: target.frame.size) else { clear(); return nil }
        window = target
        self.rect = c
        return c
    }

    /// Selection for `target`, or nil when none / invalidated.
    /// Invalidates on window/session identity, tab/pane identity, or either size dimension changing.
    mutating func restore(for target: CaptureTarget) -> CGRect? {
        guard let w = window, let rect else { return nil }
        guard w.sameWindow(as: target), w.bundleID == target.bundleID,
              w.tabID == target.tabID, w.paneID == target.paneID,
              w.frame.size == target.frame.size else { clear(); return nil }
        return rect
    }

    mutating func clear() { window = nil; rect = nil }
}

// MARK: - Operation generation state machine

enum OperationState: Equatable, Sendable {
    case idle, capturing, translating, presenting, failed, cancelled
}

struct OperationToken: Equatable, Hashable, Sendable {
    let id: UUID
    let generation: UInt64
}

/// Single-flight operation tracker. Every `begin()` supersedes the previous operation; stale tokens
/// can no longer advance the machine, so late async results are ignored.
struct OperationTracker: Sendable {
    private(set) var state: OperationState = .idle
    private(set) var current: OperationToken?
    private var generation: UInt64 = 0

    init() {}

    var isActive: Bool { state == .capturing || state == .translating || state == .presenting }

    func isCurrent(_ t: OperationToken) -> Bool { current == t }

    mutating func begin() -> OperationToken {
        generation += 1
        let t = OperationToken(id: UUID(), generation: generation)
        current = t
        state = .capturing
        return t
    }

    /// Advance along capturing -> translating -> presenting. Returns false (no change) for stale tokens
    /// or illegal transitions.
    @discardableResult
    mutating func advance(_ t: OperationToken, to next: OperationState) -> Bool {
        guard isCurrent(t) else { return false }
        switch (state, next) {
        case (.capturing, .translating), (.translating, .presenting), (.capturing, .presenting),
             (.capturing, .failed), (.translating, .failed), (.presenting, .failed),
             (.capturing, .cancelled), (.translating, .cancelled), (.presenting, .cancelled),
             (.presenting, .idle), (.failed, .idle), (.cancelled, .idle):
            state = next
            if next == .idle { current = nil }
            return true
        default:
            return false
        }
    }

    /// Cancel whatever is active (e.g. hotkey toggle / Esc), invalidating its token.
    mutating func cancelActive() {
        guard isActive, let t = current else { return }
        _ = advance(t, to: .cancelled)
        current = nil
    }
}
