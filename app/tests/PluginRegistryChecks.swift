import CoreGraphics
import Foundation

@main
struct PluginRegistryChecks {
    static func main() {
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }
        let target = CaptureTarget(pid: 42, windowID: 7, appLaunchTime: 123,
                                   bundleID: "com.example.terminal", appName: "Terminal",
                                   title: "Untrusted window title", frame: CGRect(x: 100, y: 200, width: 400, height: 300),
                                   selection: CGRect(x: 20, y: 30, width: 200, height: 100),
                                   tabID: "tab", paneID: "pane", revision: 9)
        func identity(pid: Int32 = 42, bundleID: String = "com.example.terminal",
                      launchTime: TimeInterval? = 123, windowID: UInt32 = 7,
                      windowOwnerPID: Int32 = 42, frame: CGRect? = nil) -> TerminalPluginValidation.RunningIdentity {
            TerminalPluginValidation.RunningIdentity(pid: pid, bundleID: bundleID, launchTime: launchTime,
                                                     windowID: windowID, windowOwnerPID: windowOwnerPID,
                                                     frame: frame ?? target.frame)
        }
        expect(TerminalPluginValidation.matches(target: target, identity: identity()), "Exact running identity is accepted")
        expect(!TerminalPluginValidation.matches(target: target, identity: identity(bundleID: "com.example.terminal.other")), "Bundle matching is exact, regardless of title")
        var misleading = target
        misleading.title = "com.example.terminal.other"
        expect(TerminalPluginValidation.matches(target: misleading, identity: identity()), "Window title cannot override exact bundle identity")
        expect(!TerminalPluginValidation.matches(target: target, identity: identity(pid: 43)), "PID mismatch is rejected")
        expect(!TerminalPluginValidation.matches(target: target, identity: identity(windowOwnerPID: 43)), "Window owner mismatch is rejected")
        expect(!TerminalPluginValidation.matches(target: target, identity: identity(windowID: 8)), "Window ID mismatch is rejected")
        expect(!TerminalPluginValidation.matches(target: target, identity: identity(launchTime: nil)), "Missing running launch time is rejected")
        expect(!TerminalPluginValidation.matches(target: target, identity: identity(launchTime: 124)), "Reused PID launch mismatch is rejected")
        var missingLaunch = target
        missingLaunch.appLaunchTime = nil
        expect(!TerminalPluginValidation.matches(target: missingLaunch, identity: identity()), "Missing target launch time is rejected")
        expect(!TerminalPluginValidation.matches(target: missingLaunch, identity: identity(launchTime: nil)), "Two missing launch times do not establish identity")
        var missingBundle = target
        missingBundle.bundleID = nil
        expect(!TerminalPluginValidation.matches(target: missingBundle, identity: identity()), "Missing target bundle is rejected")
        expect(!TerminalPluginValidation.matches(target: target, identity: identity(frame: target.frame.offsetBy(dx: 1, dy: 0))), "Changed global window frame is rejected")

        let rect = CGRect(x: 30, y: 40, width: 100, height: 20)
        let snapshot = CaptureSnapshot(target: target, provenance: .native,
                                       layout: [LayoutRegion(id: "layout", role: .pane, rect: target.effectiveSelection)],
                                       regions: [TextRegion(id: "text", parentID: "layout", source: .native,
                                                            rect: rect, text: "Visible prose", lineRects: [rect])])
        func rejected(_ candidate: CaptureSnapshot, _ message: String) {
            if case .error = TerminalPluginValidation.validated(outcome: .snapshot(candidate), target: target) {} else {
                preconditionFailure(message)
            }
            if case .error = TerminalPluginValidation.validated(outcome: .partial(candidate, warnings: ["missing geometry"]), target: target) {} else {
                preconditionFailure("Invalid partial snapshot: " + message)
            }
        }
        func changedTarget(_ message: String, _ change: (inout CaptureTarget) -> Void) {
            var candidate = snapshot
            change(&candidate.target)
            rejected(candidate, message)
        }
        changedTarget("Stale revision is rejected") { $0.revision += 1 }
        changedTarget("Changed pane is rejected") { $0.paneID = "other" }
        changedTarget("Changed tab is rejected") { $0.tabID = "other" }
        changedTarget("Changed bundle is rejected") { $0.bundleID = "other.bundle" }
        changedTarget("Changed PID is rejected") { $0.pid += 1 }
        changedTarget("Changed window is rejected") { $0.windowID += 1 }
        changedTarget("Changed launch time is rejected") { $0.appLaunchTime = 124 }
        changedTarget("Changed frame is rejected") { $0.frame.origin.x += 1 }
        changedTarget("Changed selection is rejected") { $0.selection = CGRect(x: 20, y: 30, width: 201, height: 100) }

        var invalid = snapshot
        invalid.regions.append(invalid.regions[0])
        rejected(invalid, "Duplicate text IDs are rejected")
        invalid = snapshot
        invalid.regions[0].id = "layout"
        rejected(invalid, "IDs must be unique across layout and text")
        invalid = snapshot
        invalid.regions[0].parentID = "missing"
        rejected(invalid, "Missing text parent is rejected")
        invalid = snapshot
        invalid.layout[0].parentID = "missing"
        rejected(invalid, "Missing layout parent is rejected")
        invalid = snapshot
        invalid.regions[0].rect = CGRect(x: 500, y: 40, width: 100, height: 20)
        rejected(invalid, "Text outside window bounds is rejected")
        invalid = snapshot
        invalid.layout[0].rect = CGRect(x: 500, y: 40, width: 100, height: 20)
        rejected(invalid, "Layout outside window bounds is rejected")
        invalid = snapshot
        invalid.regions[0].lineRects = [CGRect(x: 500, y: 40, width: 100, height: 20)]
        rejected(invalid, "Out-of-bounds line geometry is rejected")
        invalid = snapshot
        invalid.layout = []
        invalid.regions[0].parentID = nil
        invalid.regions[0].rect = CGRect(x: 250, y: 40, width: 100, height: 20)
        invalid.regions[0].lineRects = []
        rejected(invalid, "Text must be clipped to effective selection, not merely window bounds")
        invalid = snapshot
        invalid.layout[0].rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        expect(TerminalPluginValidation.validated(outcome: .snapshot(invalid), target: target) == .snapshot(invalid),
               "Window and pane layout ancestors may extend beyond selection")
        invalid = snapshot
        invalid.regions = (0...SnapshotLimits.maxRegions).map {
            TextRegion(id: "text-\($0)", rect: rect, text: "x")
        }
        rejected(invalid, "Text region count limit is enforced")
        invalid = snapshot
        invalid.layout = (0...SnapshotLimits.maxLayoutRegions).map {
            LayoutRegion(id: "layout-\($0)", rect: rect)
        }
        invalid.regions = []
        rejected(invalid, "Layout region count limit is enforced")
        invalid = snapshot
        invalid.regions[0].text = String(repeating: "x", count: SnapshotLimits.maxCharactersPerRegion + 1)
        rejected(invalid, "Per-region character limit is enforced")
        invalid = snapshot
        invalid.regions = (0...(SnapshotLimits.maxTotalCharacters / SnapshotLimits.maxCharactersPerRegion)).map {
            TextRegion(id: "text-\($0)", rect: rect,
                       text: String(repeating: "x", count: SnapshotLimits.maxCharactersPerRegion))
        }
        rejected(invalid, "Total character limit is enforced")

        print("Plugin registry checks passed")
    }
}
