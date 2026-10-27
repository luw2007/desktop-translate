import CoreGraphics
import Foundation

extension DesktopCapture {
    /// S0 uses exactly this one shot and discards it; does not call Vision or write an image.
    static func permissionShot(target: CaptureTarget) async throws -> CGSize {
        let shot = try await screenshot(target: target, selection: CGRect(origin: .zero, size: target.frame.size))
        return shot.transform.imagePixelSize
    }

    /// One monitor/presentation sample: a fresh shot hashed with the BASELINE's own relevant areas.
    static func signature(target: CaptureTarget, selection: CGRect, areas: RelevantAreas) async throws -> RegionSignature {
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
    static func verifyFreshness(target: CaptureTarget, selection: CGRect?, baseline: RegionSignature, baselineAt: Date) async throws {
        let rect = selection ?? target.effectiveSelection
        var tracker = FreshnessTracker(baseline: baseline)
        var trace = FreshnessTrace(baseline: baseline)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
            let sample = try await signature(target: target, selection: rect, areas: baseline.areas)
            try Task.checkCancellation()
            trace.record(sample)
            if tracker.observe(sample) {
                logFreshnessRefusal(trace, since: baselineAt)
                throw FreshnessError.contentChanged
            }
            if tracker.changedSamples == 0 { return }
        }
    }

    /// Counts only (see `FreshnessTrace`), to the same stderr sink as `onLogEvent` (app.log).
    static func logFreshnessRefusal(_ trace: FreshnessTrace, since baselineAt: Date) {
        let ms = max(0, Int(Date().timeIntervalSince(baselineAt) * 1000))
        FileHandle.standardError.write(Data((trace.summary(elapsedMilliseconds: ms) + "\n").utf8))
    }

    /// Image-to-signature entry for screen-free consumers (same raw-BGRA / bounded-band hashing and protected-black
    /// rejection as live capture): hashes ONLY the pixel rectangles `areas` covers inside `image` (an image of `crop`).
    /// Feed results to `FreshnessTracker` to exercise the two-change policy.
    static func signature(of image: CGImage, crop: CGRect, areas: RelevantAreas) throws -> RegionSignature {
        try mapSignature { try ContentSignature.sample(image: image, crop: crop, areas: areas).signature }
    }

    static func mapSignature<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as SignatureError {
            switch error {
            case .black: throw DesktopCaptureError.black
            case .wrongSize: throw DesktopCaptureError.wrongSize
            case .invalidAreas: throw DesktopCaptureError.invalidSelection
            }
        }
    }
}
