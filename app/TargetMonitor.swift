import AppKit
import Foundation

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
    private var trace: FreshnessTrace?
    private var startedAt = Date()
    init(target: CaptureTarget, selection: CGRect, baseline: RegionSignature? = nil, onInvalid: @escaping @MainActor (TargetInvalidation) -> Void) {
        self.target = target; self.selection = selection; self.baseline = baseline; self.onInvalid = onInvalid
        self.tracker = baseline.map(FreshnessTracker.init)
        self.trace = baseline.map(FreshnessTrace.init)
    }
    func start() {
        stop(); active = true; startedAt = Date()
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
        observers.removeAll(); tracker = baseline.map(FreshnessTracker.init); trace = baseline.map(FreshnessTrace.init); tickCount = 0
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
                trace?.record(sample)
                if tracker?.observe(sample) == true {
                    if let trace { DesktopCapture.logFreshnessRefusal(trace, since: startedAt) }
                    invalidate(.contentChanged)
                }
            } catch {
                guard active, !Task.isCancelled else { return }
                sampleTask = nil
                if let lock = error as? TargetLockError { invalidate(TargetInvalidation(lock)) } else { invalidate(.unverifiable) }
            }
        }
    }
}
