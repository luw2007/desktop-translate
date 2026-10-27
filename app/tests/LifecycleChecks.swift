import AppKit
import CoreGraphics
import Foundation
#if DESKTOP_CHECKS_MODULE
@testable import DesktopChecksModule
#endif

extension DesktopChecks {
    static func routerChecks() {
        expect(CaptureRouter.resolve([.error("e"), .needsPermission(.screenRecording)]) == .needsPermission(.screenRecording), "Permission beats error")
        expect(CaptureRouter.resolve([.unsupported("u"), .error("e"), .none]) == .error("e"), "Error beats none")
    }

    static func selectionChecks() {
        var mem = SelectionMemory()
        let t = target()
        let selected = CGRect(x: 80, y: 60, width: 160, height: 120)
        expect(mem.remember(selected, for: t) == selected, "Remember")
        var moved = t; moved.frame.origin = CGPoint(x: 5, y: 5)
        expect(mem.restore(for: moved) == selected, "Moving window keeps exact window-local selection")
        expect(mem.restore(for: target(revision: 5)) == selected, "Content revision alone keeps selection")
        var wider = t; wider.frame.size.width += 1
        expect(mem.restore(for: wider) == nil && mem.isEmpty && mem.window == nil, "Width change invalidates and clears")
        expect(mem.restore(for: t) == nil, "Returning to original size does not revive selection")
        mem.remember(selected, for: t)
        var taller = t; taller.frame.size.height += 1
        expect(mem.restore(for: taller) == nil && mem.isEmpty && mem.window == nil, "Height change invalidates and clears")
        mem.remember(selected, for: t)
        expect(mem.restore(for: target(pane: "p2")) == nil && mem.isEmpty, "Pane change invalidates and clears")
        mem.remember(selected, for: t)
        expect(mem.restore(for: target(tab: "t2")) == nil && mem.isEmpty, "Tab change invalidates and clears")
        mem.remember(selected, for: t)
        var relaunched = t; relaunched.appLaunchTime = 5
        expect(mem.restore(for: relaunched) == nil && mem.isEmpty, "App relaunch invalidates and clears")
        mem.remember(selected, for: t)
        var newWindow = t; newWindow.windowID = 8
        expect(mem.restore(for: newWindow) == nil && mem.isEmpty, "Different window invalidates and clears")
        mem.remember(selected, for: t)
        var newProcess = t; newProcess.pid += 1
        expect(mem.restore(for: newProcess) == nil && mem.isEmpty, "Different process invalidates and clears")
        mem.remember(selected, for: t)
        var newApp = t; newApp.bundleID = "other.app"
        expect(mem.restore(for: newApp) == nil && mem.isEmpty, "Different bundle invalidates and clears")
        mem.remember(selected, for: t)
        expect(mem.remember(CGRect(x: 900, y: 900, width: 5, height: 5), for: t) == nil && mem.isEmpty, "Invalid remember clears previous")
    }

    static func operationChecks() {
        var op = OperationTracker()
        let a = op.begin()
        expect(op.state == .capturing && op.isActive && op.isCurrent(a), "Begin captures")
        expect(!op.advance(a, to: .idle), "Cannot jump capturing->idle")
        expect(op.advance(a, to: .translating) && op.advance(a, to: .presenting), "Forward path")
        expect(!op.advance(a, to: .translating), "No going backwards")
        let b = op.begin()
        expect(!op.isCurrent(a) && op.isCurrent(b), "New operation supersedes")
        expect(!op.advance(a, to: .presenting), "Stale token cannot advance")
        expect(op.state == .capturing, "Stale token left state untouched")
        op.cancelActive()
        expect(op.state == .cancelled && !op.isActive && !op.isCurrent(b), "Cancel invalidates token")
        expect(!op.advance(b, to: .translating), "Late result after cancel ignored")
        let c = op.begin()
        expect(op.advance(c, to: .failed) && op.advance(c, to: .idle) && op.current == nil, "Failed -> idle")
        var idle = OperationTracker()
        idle.cancelActive()
        expect(idle.state == .idle, "Cancel when idle is a no-op")
    }

}
