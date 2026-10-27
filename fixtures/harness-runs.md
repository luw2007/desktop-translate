# Harness runs: activation and permission probe

## Permission probe versus full smoke

`permission-probe` (historical gate name S0) opens a fresh fixture through LaunchServices, verifies the manifest PID/window/CG frame, performs exactly one cropped-window ScreenCaptureKit capture, prints public metadata, terminates that fixture instance, and exits. Image data stays in memory; there is no OCR and no image output. The JSON manifest is public metadata, not image output. A refusal or an all-black result is a blocker, never an automatic retry, and never a fallback to another window.

A full smoke run is separately selected and must not be reported as permission evidence. It exercises text/paragraph/Chinese/code/button-region recognition and before/after counters under its own acceptance criteria. `maskAccuracy` is deliberately reported as `unmeasured`: overlay text is the translation, so a mask cannot be associated to a public fixture item by text identity without a tautology.

## Activation opt-in

Only an explicit per-run flag can activate the fixture:

```sh
./desktop-translate smoke --authorize-fixture-activation      # also pi-smoke, glyph-smoke, glyph-pi-smoke, permission-probe
```

The `desktop-translate` launcher turns the flag into `DESKTOP_TRANSLATE_AUTHORIZE_FIXTURE_ACTIVATION=1` for that run and discards an ambient value. The harness then calls `NSRunningApplication.activate()` at most once, only on the fixture instance this run created, only when the default bundle path is used (no `DESKTOP_TRANSLATE_*_FIXTURE_APP` override), and only when the running PID, bundle ID, bundle URL, and manifest PID/bundle/window ID all match. It happens before target readiness; nothing re-activates afterwards, and the product overlay never activates. This flag is separate from how the fixture is opened: the harness launches it through LaunchServices as a new application instance with activation requested, which is normal app launch, never activation of an existing instance or of a user application. The result JSON records `fixtureActivation: {authorized, activated, expectedPID}`. `--authorize-fixture-activation` is accepted only for `smoke`, `pi-smoke`, `glyph-smoke`, `glyph-pi-smoke`, and `permission-probe`; the terminal fixture commands reject it and never activate, type, spawn, or signal the target.

Readiness order (shared `HarnessReadiness`): manifest → owned window publication (exact id/pid, frame, layer 0, alpha > 0 on two ticks, single ordinary window; no foreground requirement) → the single authorized activation, if flagged → owned foreground on two consecutive ticks → exact revalidation and `TargetLocker.lock`. On failure, `fixtureActivation.failingStage` is one of `manifest|window|activation|foreground|revalidation`. The sharing value may be logged only as a labelled non-authoritative diagnostic.

Back to the [fixture guide](README.md). The run matrix, build steps, and evidence boundaries are shared; capture and OCR semantics are in [Capture and OCR boundaries](capture-ocr-boundaries.md).
