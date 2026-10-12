# Standalone public fixture

`PublicFixtureApp.swift` is an independent AppKit app with its own bundle, PID, and window. It draws fixed public samples; it is not translator UI and must not be substituted with a translator-owned window in capture evidence.

## Build and launch commands

Run from the repository root on an Apple Silicon Mac with macOS 15 or later and an installed macOS SDK/Swift compiler:

```sh
export DESKTOP_TRANSLATE_DEV_TAG=fixture-local
./fixtures/build-fixture.sh
```

The tag is required and must match `[A-Za-z0-9-]+`. The builder targets `arm64-apple-macosx15.0`, links AppKit, generates an Info.plist, and ad hoc signs a temporary staged bundle before installing `.dev/fixture/Public Fixture.app`. Its bundle identifier is `local.desktop-translate.public-fixture`; its executable is `public-fixture`. It creates the existing-compatible `.dev/fixture` directory, refuses symlinked output paths and unrecognized existing bundles, and replaces only an identified fixture bundle. No release output is touched. The builder does not launch an app, activate a window, or inject focus/events.

For a manual public-fixture session, the parent can run the executable directly (keep this terminal attached, or manage the process separately):

```sh
".dev/fixture/Public Fixture.app/Contents/MacOS/public-fixture" \
  --manifest "$PWD/.dev/fixture/manifest.json" \
  --frame 120,120,760,520
```

Close its window to terminate it. Launching without `--activate` does not explicitly activate the app; the app still shows its window. Do not add activation or synthetic input to a permission probe. These commands are instructions, not evidence that a build or smoke run has occurred.

## App options

| Option | Meaning |
| --- | --- |
| `--manifest <path>` | Required JSON output path; use an existing writable parent directory. |
| `--frame x,y,w,h` | Full window frame in Quartz desktop points, top-left origin; negative positions allowed. Width and height must each be at least 200. Default: `120,120,760,520`. |
| `--title <text>` | Window title; default `Public Fixture`. |
| `--black` | Borderless solid black whole window with no sample text, including no title bar; all-black refusal evidence. Takes precedence over `--no-text`. Terminate the process explicitly or use `PublicFixture.Instance.terminate()` because it has no close button. |
| `--no-text` | Blank white content with no sample text; no-text evidence. |
| `--sharing-none` | Sets `NSWindow.sharingType = .none` for protected-window evidence; actual capture behavior must be observed, not assumed. |
| `--activate` | Explicitly activates the fixture once after showing it; opt-in for separate manual/full-smoke work only. |

## Manifest and coordinates

The schema-1 manifest is atomically rewritten on changes, with frame/state polling every 0.25 seconds. It contains `pid`, `bundleID`, `windowID`, `displayID`, `frameQuartz`, `contentTopInset`, `backingScale`, `mode`, `items`, counters, `isActive`, and a monotonically incremented `sequence`. Use the manifest's actual window ID and frame, rather than guessing from a title or initial arguments.

`frameQuartz` uses desktop points with a top-left origin. Each item has `id`, `text`, `kind`, and a `{x,y,w,h}` rectangle in **full-window-local points**, top-left origin, including the title bar. The content layout's y coordinates have already been shifted by `contentTopInset`; do not add that inset a second time. A desktop item rectangle is obtained by adding `frameQuartz.x` and `.y` to its local x and y. `backingScale` describes point-to-pixel scaling; do not treat point rectangles as pixel rectangles. Layout sizes and button positions can change on resize, so consume current manifest rectangles. In black/empty modes `items` is empty.

## Known public samples and interaction evidence

Text-mode items are:

| ID | Kind | Public text |
| --- | --- | --- |
| `heading` | heading | Public Fixture Window |
| `sentence` | label | The quick brown fox jumps over the lazy dog. |
| `chinese` | label | 你好，世界 |
| `code` | code | npm test --coverage |
| `paragraph` | paragraph | This paragraph wraps inside a fixed box so that several lines of ordinary English sit together for soft line merging. |
| `cell-name` | cell | Name |
| `cell-value` | cell | Value |
| `button-cancel` | button | Cancel |
| `button-settings` | button | Settings |
| `button-ok` | button | OK |

The code sample is drawn text, not a command to execute. The paragraph wraps in a 360-point box. The three real buttons only increment `buttonPressCount`; they do not cancel, open settings, or confirm anything. `mouseDownCount`, `scrollCount`, and `keyDownCount` count events received by the custom content view, not necessarily every event handled by button subviews. `resignActiveCount` counts window-key resignations (despite its name); `isActive` reports application activity. Record counters before and after a separate interaction test rather than assuming they must all increase together.

## S0 permission probe versus full smoke

S0 is a narrowly bounded permission/capture probe using this independent public fixture. After building the fixture and isolated dev app, the integrated `--permission-probe` entry calls `PermissionProbe.run()`: it opens a fresh fixture through LaunchServices (ordinary app activation, no event/focus injection), verifies the manifest's PID/window/CG frame, invokes exactly one window-only SCK capture attempt, prints public metadata, terminates that fixture instance, and exits. **Image data stays in memory; no OCR or image disk output.** The JSON manifest is public metadata, not image output. Permission refusal is a blocker, never an automatic retry.

A full smoke run is separate and explicitly selected: it may exercise text/paragraph/Chinese/code/button-region recognition, black/no-text/protected-window outcomes, alternate frames or displays, and before/after interaction counters under that run's own acceptance criteria. It must not be reported as S0 evidence. This fixture README does not invent a translator CLI entry point: use the parent-owned launch/probe command for the integrated application and preserve the distinction between permission probing and full smoke.

## Capture and monitoring contract

`TargetLocker.lock(app:)` locks the supplied pre-UI frontmost application by PID, launch identity and unique CG window. It refuses protected windows, modal/overlapping same-app ambiguity and missing visible frames; there is no display fallback. `DesktopCapture.captureWithSignature(target:selection:languageCorrection:)` requires `selection == target.effectiveSelection`, preserves the target, and returns a router outcome plus a small region signature. It uses a desktop-independent target-window filter, sourceRect equal to the selected window-local points, shadow exclusion, no scales-to-fit, and validates actual image dimensions within one pixel. Vision uses accurate English/Simplified Chinese recognition; terminal identities disable correction. All-black capture is an error, empty OCR is `.none`, denied/revoked SR is `.needsPermission`.

OCR returns `.partial` with visible confidence/background/clipping warnings and transform provenance. Background is an unverified edge-median bitmap sample, not a native color/font claim. `TargetMonitor` needs the returned baseline signature for OCR content invalidation; it polls window identity/frame/other-PID layer-zero occlusion excluding translator windows, handles frontmost/Space/display changes, and requires two successive signature changes. No heuristic caret mask is claimed: SCK excludes the pointer via `showsCursor=false`, while an unproved blinking caret remains part of comparison and may cause conservative removal. App/UI owns generation cancellation and presentation-time revalidation.
