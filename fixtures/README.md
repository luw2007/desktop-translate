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

Use the same DEV tag with `CMUX_TRANSLATE_GLYPH_SCENE=prose ./cmux-translate glyph-smoke`, or `glyph-pi-smoke` for the explicit pi backend. Smoke startup now reads selected backend settings from `TranslationSettingsStore` read-only, without writing daily settings; missing configuration defaults to local, invalid configuration fails without fallback, and explicit pi modes override the selected mode. Pi may send public captured text to the configured service. `DESKTOP_TRANSLATE_GLYPH_FIXTURE_APP` selects the independent bundle. Scenes are `boundary`, `collision`, `icon`, `code`, `cjk`, `prose`. Direct fixture options: required `--manifest`; optional `--scene` (default `boundary`), `--phase stable|mutate|caret` (default `stable`), `--period` (minimum 0.05 s), `--frame x,y,w,h`, `--title`, `--exit-file`, `--owner-pid`. It never activates or injects events. `mutate` changes public text and `runRevision`; `caret` changes only the decoration and never `runRevision` (see the finite caret-stop behavior below).

Current fixture source (built in the final consolidated gate): the oracle and real view reuse one cached `CTLine` per token and shared `drawToken` state (antialiasing on, smoothing off). `cjk.combining.1` supplies explicit combining scalars. The caret runs four ticks then publishes `caret-stop`, hidden, with its timer invalidated and `runRevision` unchanged; mutation advances revision only on actual text change. Caret geometry stays inside the last ink-bearing token. `GlyphView` is first responder; event-type-only zones use glyph-ink covered/uncovered rectangles and `keyDown.keyboard`, never typed characters/keycodes. Resize regenerates scene specs; publication requires a real window screen and non-zero display ID without guessed display bounds/scale. Schema stays 1.

The public manifest provides exact-string CoreText glyph-path bounds and in-memory alpha ink bounds at real backing scale. No oracle image/pixel/text hash is written to disk. GlyphSmoke matches public normalized-text identity and token-centre containment one-to-one, then reports public IDs and numeric OCR/mask edge errors. Readiness keeps exact owned PID/window, stable frame, layer 0, positive alpha and a single ordinary window for two ticks, without a sharing-value predicate. Foreground ownership is still required; only the explicitly authorized fresh owned fixture activation below is permitted, never event injection, existing-user-app activation or fallback. Product and harness use the same capture policy, with no fixture exception or OS-version guess.

Current `GlyphSmoke.swift` / `GlyphMetric.measure` contract (compiled in the final gate; no GUI smoke result): score actual `paintRects` only, associating each source line after product `OccupiedGeometry` clipping with exactly one painted rectangle, never sorted-index zip or nearest matching. `maskCounts` counts overflow/collision-unavailable items, which fail `maskEdgesWithin4pt`; deliberately unpainted overflow/protected content may be valid product behavior but is not a precision pass. `ocrMisalignedRegions` fails misaligned OCR regions rather than dropping them. Duplicate token IDs, missing non-whitespace ink and oracle disagreement fail closed. `targetMatchesFixtureWindow` checks PID/window/frame/display ID/bounds/backing scale and unchanged before/after geometry; `display` and `observerCounts` expose public metadata/counts. Neighbour checks cover token ink and published fixture decorations, not product-side icon/non-text safety. OCR/mask 4pt thresholds are unchanged.

Historical GUI attempts: local smoke lacked the Apple en→zh package; pi lacked an ordinary CG window; early glyph attempts failed sharing/foreground readiness before capture (the sharing predicate was subsequently superseded). No model request, presentation, real OCR/mask ≤4pt result or physical input proof resulted. These historical failures are distinct from the final build/offscreen evidence below.

Final consolidated gate, reported by Main on 2026-10-16: DEV app and glyph fixture builds exited 0 (fixture not launched); GlyphMatcherChecks and DesktopChecks passed, including actual paint/source clipping, gaps, overflow, collision and invoked signature checks. The actual `drawToken` offscreen oracle passed 68 draws across six scenes at 1x/2x, comparing alpha with final `oracleConsistent` using outward pixel snapping plus one device pixel for antialiasing. This bounded offscreen model is not general physical geometry proof; OCR/mask 4pt thresholds were not relaxed. Two actual PTY/CLI Python tests passed; fresh attach exercised real process/TTY with a synthetic bundle boundary, not an emulator UI. Initial enum/whitespace/oracle-1x/real-ps-date failures were fixed and only failed steps resumed. No additional GUI, capture, permission preflight/request or network occurred. Product in-line caret and product non-text safety remain unfinished; user permission/language-package and real terminal/display hardware acceptance remain pending. S2/S3/S4/S6/S7 and 001/002 remain unaccepted.

Optional per-run authorization: `./cmux-translate glyph-pi-smoke --authorize-fixture-activation` (also valid for `smoke`, `pi-smoke`, `glyph-smoke`, `permission-probe`) lets the harness call `NSRunningApplication.activate()` at most once on the fixture instance created by that run, only when the fixture is not already frontmost, the bundle path is the default (no `DESKTOP_TRANSLATE_*_FIXTURE_APP` override), and running PID/bundle ID/bundle URL and the manifest PID/bundle ID/window ID all match exactly. The launcher turns the flag into `DESKTOP_TRANSLATE_AUTHORIZE_FIXTURE_ACTIVATION=1` for that run (an ambient value is discarded). Activation happens before target readiness only; the product overlay never activates and nothing re-activates afterwards. Result JSON records `fixtureActivation: {authorized, activated, expectedPID}`.

Readiness order (shared `HarnessReadiness`): manifest → owned window publication (exact id/pid, frame, layer 0, alpha > 0 on two ticks, single ordinary window; no foreground needed) → the single authorized fresh owned fixture activation (if flagged) → owned foreground on two consecutive ticks → exact revalidation + `TargetLocker.lock`. Sharing may be logged only as labelled non-authoritative diagnostic. On failure `fixtureActivation.failingStage` is one of `manifest|window|activation|foreground|revalidation` (public stage names only). No activation after readiness.

2026-10-15: the user explicitly approved the revised SCK-outcome contract (“批准修正契约并继续”). Earlier sharing=None failures are historical observations, not protection evidence; the former sharing1/2 readiness condition is superseded. Public fixture success can prove exact-window/crop/OCR operation only, not sensitive-content detection or privacy acceptance. No new runtime evidence accompanies this amendment; S2/S3/S4/S6 and original 001/002 gates remain unaccepted. No extra permissions, TCC/keychain/daily configuration changes or existing-user-app activation are authorized.


## Terminal public producer and owned-terminal launcher

`terminal_public_producer.py` is a real program (no mock) that runs as the child of a fixture-owned terminal. It draws canned public scenes (static, unicode, wrap, full-screen TUI, dynamic line), enables DECSET 1004 focus reporting, sets the OSC 2 title `DT-Fixture-<token>`, and writes its report atomically. Every other byte received on stdin is discarded and only its COUNT is kept: no keys, no characters and no terminal content are recorded.

Producer arguments: `--report <path>` and `--token <A-Za-z0-9->` (both required), `--scene cycle|static|unicode|wrap|tui|dynamic` (default `cycle`), `--scene-interval <seconds>` (default 3.0), `--duration <seconds>` (0 = until signalled). It refuses to start without a terminal on stdin and stdout.

Report schema is **version 2**: `schema`, `token`, `pid`, `ppid`, `pgid`, `tty`, `state` (`running`/`exited`), `scene`, `scenarioMode` (`cycle`/`fixed`), `sceneIndex`, `sceneChanges`, `renderCount`, `revision`, `focusIn`, `focusOut`, `focusReportingEnabled`, `discardedInputBytes`, `cols`, `rows`, `xpixel`, `ypixel` (0 when the emulator does not report pixels), `startedAtEpoch`, `updatedAtEpoch`. `revision` is a tick counter, not a content-change proof: it increments on every scene render AND on every 0.5 s tick, including ticks where nothing is redrawn. `sceneChanges` (scene transitions only) and `renderCount` (full scene renders) are the counters that separate real redraws; `SIGWINCH` only marks the frame dirty so the next tick re-reads the new size. Version 1 reports (without `scenarioMode`, `revision`, `xpixel`/`ypixel`) are no longer produced.

Scenes: `static` (fixed lines including a command/prompt pair), `unicode` (CJK, Japanese, Korean, combining-mark Latin, symbols), `wrap` (soft-wrapping long ASCII and CJK lines sized to the current `cols`), `tui` (alternate screen box with a progress bar), `dynamic` (a single rewritten line), and `cycle` (all five in order, one per `--scene-interval`). The launcher's generated producer command passes no `--scene`, so a launcher-created fixture always runs `cycle`; only a hand-run producer can pin a single scene.

`terminal_fixture_launcher.py` (`capabilities`, `plan`, `launch`, `status`, `handoff`, `cleanup`, `attach-plan`, `attach`) is fail-closed. It spawns a NEW emulator process only where the installed bundle documents an isolated, independent-process launch; every other app is refused rather than driven through `open`, AppleScript, activation of an existing instance, or injected text/keys. State lives in `.dev/terminal-fixtures/<token>` and the token must match `[A-Za-z0-9-]{1,48}`. `capabilities` and `plan` have no side effects; `launch` additionally requires `DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=<token>`.

`launch` verifies the bundle identifier/executable, starts a new session, and only records ownership once a running producer report exists whose pid is a descendant of the emulator pid it spawned; otherwise it refuses and cleans up only the pid it started. Its recorded `ownershipProof` is `spawned-by-launcher;producer-descendant-of-spawned-pid`.

`handoff` prints schema `terminal-fixture-handoff/1`: `token`, `app`, `bundleId`, `origin` (`launched`/`attached`), `candidateStatus` (always `unverified` — this tool never declares a candidate verified), `ready` plus `notReadyReasons` (`owner-process-not-verified-alive`, `producer-not-verified-alive`, `report-identity-mismatch`, `report-not-running`, `report-stale` when the report is older than 5 seconds), `scenario`, `dimensions`, `focus`, `process` (owner and producer pid/`lstart`/executable/alive), `windowBinding` (`ownerPid`, `expectedTitle` = `DT-Fixture-<token>`, `claimedWindowId` as a hint that must match the consumer's own resolution, `ownershipProof`, attestation fields, and the caveat that the title comes from OSC 2 and an emulator may decorate or override it), `reportPath`, `stateDir`, `fixtureOnly: true`, `dailyAppsTouched: false`.

### Attaching a user-created fixture window

The three apps without a documented isolated launch path (cmux, iTerm2, Terminal.app) can still be used through `attach-plan` + `attach`, which never launch or type anything:

1. `attach-plan --app A --token T` creates the token-owned state directory and an immutable, create-only `attach-plan.json` (mode 0600, `O_EXCL`) recording `planCreatedAtEpoch`, and prints the producer command for the user to run by hand.
2. The user starts a brand-new dedicated process of that app AFTER the plan (never the daily terminal) and runs that producer command inside it.
3. `attach --app A --token T --owner-pid P --window-id W --attest-new-disposable-process` requires `DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=<token>` and fails closed unless: the plan exists and is unmodified; the owner pid is a live process of that app whose `ps lstart` is strictly LATER than the plan time; the producer report is running and fresh (≤ 5 s); the report pid is a live `terminal_public_producer.py` process carrying this token; and that pid is a descendant of the owner pid.

Attached state records `fixtureAttestation: new-disposable-process-fixture-only`, `dailyInstanceReused: false`, and `attestationKind: operator-asserted; machine-checked only: owner start > plan time, producer descendant`. That distinction is the point: **"a new disposable process, not the daily instance" is an operator assertion**; the launcher machine-checks only the start-time ordering, the report identity/freshness and the ancestry. The tty and the window are machine-checked later, by the consumer. Nothing in this workflow proves that the attached process holds no other tabs or panes, and the `--window-id` claim is operator-supplied.

`cleanup --token T` signals only what `launch` itself started, and only while pid + start time + command still match (SIGTERM, then SIGKILL after ~4 s). For an attached fixture it never signals anything: it reports `attached-left-running`, drops only the ownership record, and leaves the user's process and the producer report in place.

### Core capture consumer contract

`cmux-translate terminal-fixture-smoke` (and `terminal-fixture-pi-smoke`) consumes one handoff and re-proves everything against live OS facts; the launcher's own record is treated as derived data. These are app modes reached through the `cmux-translate` wrapper (`--terminal-fixture-smoke` / `--terminal-fixture-pi-smoke`), NOT subcommands of `terminal_fixture_launcher.py`. Required environment: `DESKTOP_TRANSLATE_TERMINAL_TOKEN`, `DESKTOP_TRANSLATE_TERMINAL_HANDOFF`, `DESKTOP_TRANSLATE_TERMINAL_STATE_ROOT`, and `DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED` (must equal the token). It refuses (no fallback, no other window captured) unless: the handoff schema/token/`fixtureOnly`/`ready`/`candidateStatus == unverified`/origin are valid; the bundle is in the built-in terminal whitelist; `ownershipProof` is present; all paths stay inside the state root without symlinks; `state.json` agrees with the handoff on token, bundle, pids, `lstart`, attached flag, owner pid and expected title; `launched` state carries the launcher's own `spawned-by-launcher…` proof, or `attached` state carries the attestation, `dailyInstanceReused == false`, a claimed window id, and an `attach-plan.json` whose plan time precedes the owner's live start time.

It then re-verifies live, before and after the session: `sysctl` start times equal the recorded `lstart` strings, the producer descends from the owner pid, the producer's controlling tty matches the reported tty (`/dev/ttys*`, `st_rdev` equal), and the owner is a running application of the expected bundle. The locked target must be the owner's SINGLE ordinary window, the claimed window id must match exactly when present, and a non-empty title must contain `DT-Fixture-<token>`. Readiness requires the owner to be naturally frontmost with that single ordinary window stable on two consecutive ticks within 10 seconds — nothing is activated, typed, spawned or signalled, and a failure never falls back to another window. The run then performs ONE real session (plugin route → OCR → translation → overlay → hotkey dismissal through the queued Carbon handler) and reports public counters only; it deliberately reports `geometry.measured = false` because no glyph-geometry oracle exists for terminal text. Fixture cleanup stays with the launcher.

| App | Isolated launch | Basis (static only; no app was run) |
| --- | --- | --- |
| Ghostty 1.3.1 | candidate | man5: `-e`, `--config-default-files=false`, `window-save-state=never`; XDG redirected; Application Support config suppression unproven |
| Kaku 0.19.0 | candidate | `kaku-gui start --always-new-process -- PROG`, `--skip-config`; pid ancestry verified at launch |
| cmux 0.65.0 | unsupported | no documented isolated release instance; CMUX_TAG is DEV-only; needs approved user-created fixture or tagged DEV build |
| iTerm2 3.7.0 | unsupported | no documented isolated/command flag; needs approved user-created fixture |
| Terminal.app 2.15 | unsupported | only `open -n`, shared prefs, no owned pid; needs approved user-created fixture |

"Candidate" means documented, not observed. No five-terminal acceptance is claimed.

### Status of this terminal work

Final source is built and the consolidated PTY/CLI and fresh-attach boundary checks passed as reported above. These are not emulator UI runs, physical FocusLost measurements or five-application evidence; no candidate emulator launch was observed. Attached private tabs/panes remain operator assertions despite machine checks of process identity/ancestry/TTY and consumer window binding. `geometry.measured=false` remains intentional, and S6 is not accepted.
