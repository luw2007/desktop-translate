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
| `--sharing-none` | Sets legacy `NSWindow.sharingType = .none`. Record only the actual outcome (system refusal / all black / still captured); this is not protected-window refusal acceptance evidence. |
| `--activate` | Explicitly activates the fixture once after showing it; opt-in for separate manual/full-smoke work only. |
| `--exit-file <path>` | Harness completion protocol: the fixture quits itself once this file exists. `PublicFixture.Instance.finish()` creates it only after overlays are dismissed and results recorded, so the foreground never returns to the launching terminal mid-run. |
| `--owner-pid <pid>` | The fixture quits if this harness process is gone (no orphan). |

Manifest `items[].lines` holds measured per-line glyph rectangles (TextKit layout of the exact drawn string; window-local points, top-left origin). Only the public manifest carries them; product output stays metadata-only.

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

`TargetLocker.lock(app:)` locks the supplied pre-UI frontmost application by PID, launch identity and unique CG window. It refuses modal/overlapping same-app ambiguity and missing visible frames; there is no display or other-window fallback. `DesktopCapture.captureWithSignature(target:selection:languageCorrection:)` requires `selection == target.effectiveSelection`, preserves the target, and returns a router outcome plus a small region signature. It uses a desktop-independent target-window filter, sourceRect equal to selected window-local points, shadow exclusion, no scales-to-fit, and validates actual image dimensions within one pixel. Before capture SR is checked: denied/revoked SR is `.needsPermission`, distinct from capture errors. A target absent from SCShareableContent with exact windowID/PID, onScreen/layer 0/equal frame, an SCK error, or an all-black result is explicitly cannot-capture (possibly system/app protected), never no-text; errors are not proof of protection. Empty OCR alone is `.none`. Vision uses accurate English/Simplified Chinese recognition; terminal identities disable correction. Legacy sharing values are non-authoritative diagnostics only, not refusal/allowance or user-warning predicates. AX secure-subtree exclusion applies only to AX reads: OCR cannot detect/exclude secure controls, sensitive pixels or legacy anti-capture intent. Partially black regions may leave other pixels available to OCR. The locked window/selection is the exclusion boundary; provider is visible before capture and pi sends translated source text, not images.

OCR returns `.partial` with visible confidence/background/clipping warnings and transform provenance. Background is an unverified edge-median bitmap sample, not a native color/font claim. `TargetMonitor` needs the returned baseline signature for OCR content invalidation; it polls window identity/frame/other-PID layer-zero occlusion excluding translator windows, handles frontmost/Space/display changes, and requires two successive signature changes. No heuristic caret mask is claimed: SCK excludes the pointer via `showsCursor=false`, while an unproved blinking caret remains part of comparison and may cause conservative removal. App/UI owns generation cancellation and presentation-time revalidation.

## Independent glyph oracle workflow

`GlyphSceneFixtureApp.swift` + `GlyphSceneManifest.swift` are a separate CoreText public scene app, not translator UI. Build with `DESKTOP_TRANSLATE_DEV_TAG=desktop-plugins-ocr ./fixtures/build-glyph-fixture.sh`; output is `.dev/glyph-fixture/desktop-plugins-ocr/Glyph Fixture desktop-plugins-ocr.app`, bundle ID `local.desktop-translate.glyph-fixture.desktop-plugins-ocr`. The builder does not launch or activate it and does not change the original public fixture builder. These commands are instructions, not new runtime evidence.

Use the same DEV tag with `CMUX_TRANSLATE_GLYPH_SCENE=prose ./cmux-translate glyph-smoke`, or `glyph-pi-smoke` for the explicit pi backend. Smoke startup now reads selected backend settings from `TranslationSettingsStore` read-only, without writing daily settings; missing configuration defaults to local, invalid configuration fails without fallback, and explicit pi modes override the selected mode. Pi may send public captured text to the configured service. `DESKTOP_TRANSLATE_GLYPH_FIXTURE_APP` selects the independent bundle. Scenes are `boundary`, `collision`, `icon`, `code`, `cjk`, `prose`. Direct fixture options include required `--manifest`, `--scene`, `--phase stable|mutate|caret`, `--period`, `--frame`, `--title`, `--exit-file`, `--owner-pid`; it never activates or injects events. `mutate` changes public text/revision; `caret` toggles decoration without changing runRevision.

The public manifest provides exact-string CoreText glyph-path bounds and in-memory alpha ink bounds at real backing scale. No oracle image/pixel/text hash is written to disk. GlyphSmoke matches public normalized-text identity and token-centre containment one-to-one, then reports public IDs and numeric OCR/mask edge errors. Readiness keeps exact owned PID/window, stable frame, layer 0, positive alpha and a single ordinary window for two ticks, without a sharing-value predicate. Foreground ownership is still required; only the explicitly authorized fresh owned fixture activation below is permitted, never event injection, existing-user-app activation or fallback. Product and harness use the same capture policy, with no fixture exception or OS-version guess.

Observed limits: glyph fixture build and GlyphMatcher checks passed, but actual oracle render geometry has not been runtime verified. First scene sharing=None failed before OCR; after shared readiness was added and build exit0, the deliberate prose glyph-pi attempt failed notFrontmost before capture. Ordinary public local smoke lacked Apple en→zh package; pi lacked an ordinary CG window. No model request, successful presentation, ≤4pt metric or real input proof resulted. S2/S3/S4 remain blocked; no permission changes or new private screenshot files were made. Related-line caret changes remain conservative fail-closed: exclusion development is unfinished, not just awaiting hardware acceptance. Pixel recurrence/debounce relaxation is not approved or implemented.

Optional per-run authorization: `./cmux-translate glyph-pi-smoke --authorize-fixture-activation` (also valid for `smoke`, `pi-smoke`, `glyph-smoke`, `permission-probe`) lets the harness call `NSRunningApplication.activate()` at most once on the fixture instance created by that run, only when the fixture is not already frontmost, the bundle path is the default (no `DESKTOP_TRANSLATE_*_FIXTURE_APP` override), and running PID/bundle ID/bundle URL and the manifest PID/bundle ID/window ID all match exactly. The launcher turns the flag into `DESKTOP_TRANSLATE_AUTHORIZE_FIXTURE_ACTIVATION=1` for that run (an ambient value is discarded). Activation happens before target readiness only; the product overlay never activates and nothing re-activates afterwards. Result JSON records `fixtureActivation: {authorized, activated, expectedPID}`.

Readiness order (shared `HarnessReadiness`): manifest → owned window publication (exact id/pid, frame, layer 0, alpha > 0 on two ticks, single ordinary window; no foreground needed) → the single authorized fresh owned fixture activation (if flagged) → owned foreground on two consecutive ticks → exact revalidation + `TargetLocker.lock`. Sharing may be logged only as labelled non-authoritative diagnostic. On failure `fixtureActivation.failingStage` is one of `manifest|window|activation|foreground|revalidation` (public stage names only). No activation after readiness.

2026-10-15: the user explicitly approved the revised SCK-outcome contract (“批准修正契约并继续”). Earlier sharing=None failures are historical observations, not protection evidence; the former sharing1/2 readiness condition is superseded. Public fixture success can prove exact-window/crop/OCR operation only, not sensitive-content detection or privacy acceptance. No new runtime evidence accompanies this amendment; S2/S3/S4/S6 and original 001/002 gates remain unaccepted. No extra permissions, TCC/keychain/daily configuration changes or existing-user-app activation are authorized.


## Terminal public producer and owned-terminal launcher

`terminal_public_producer.py` is a real program (no mock) that runs as the child of a fixture-owned terminal. It renders canned public scenes (static, unicode, wrap, full-screen TUI, dynamic line), enables DECSET 1004 and writes an atomic JSON report with scene, render count, `focusIn`/`focusOut` counts, `discardedInputBytes`, size and owned `pid`/`ppid`/`pgid`/`tty`. All other input is discarded and only its byte count is kept; no keys or terminal content are recorded.

`terminal_fixture_launcher.py` (`capabilities`, `plan`, `launch`, `status`, `cleanup`) spawns a NEW emulator process only where the installed bundle documents an isolated independent launch, and fails closed otherwise. `launch` additionally requires `DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=<token>`; `capabilities` and `plan` have no side effects. Cleanup terminates only pids recorded at launch whose start time and command still match, then removes `.dev/terminal-fixtures/<token>`. It never uses `open`, AppleScript, activation, or text/key injection.

| App | Isolated launch | Basis (static only; no app was run) |
| --- | --- | --- |
| Ghostty 1.3.1 | candidate | man5: `-e`, `--config-default-files=false`, `window-save-state=never`; XDG redirected; Application Support config suppression unproven |
| Kaku 0.19.0 | candidate | `kaku-gui start --always-new-process -- PROG`, `--skip-config`; pid ancestry verified at launch |
| cmux 0.65.0 | unsupported | no documented isolated release instance; CMUX_TAG is DEV-only; needs approved user-created fixture or tagged DEV build |
| iTerm2 3.7.0 | unsupported | no documented isolated/command flag; needs approved user-created fixture |
| Terminal.app 2.15 | unsupported | only `open -n`, shared prefs, no owned pid; needs approved user-created fixture |

"Candidate" means documented, not observed. No five-terminal acceptance is claimed; real launch, window ownership and focus-report counts remain unverified.

Central producer checks: 14 owned-PTY checks passed for five canned scenes, synthetic CSI focus counts, 22 discarded input bytes and ownership cleanup. These are not real emulator runs or physical FocusLost evidence. Ghostty/Kaku remain safeguarded candidates requiring explicit authorization token; cmux/iTerm2/Terminal still need approved user-created fixtures. S6 is blocked, and the original delivery stages are not complete.
