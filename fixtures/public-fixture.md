# Public fixture app

`PublicFixtureApp.swift` is an independent AppKit app with its own bundle, PID, and window. It draws fixed public samples and is never substituted with a translator-owned window in capture evidence.

A manual run (keep the launching terminal attached, or manage the process separately):

```sh
".dev/fixture/Public Fixture.app/Contents/MacOS/public-fixture" \
  --manifest "$PWD/.dev/fixture/manual-manifest.json" \
  --frame 120,120,760,520
```

Closing the window terminates it. Launching without `--activate` does not explicitly activate the app; the window still appears. Never add synthetic input or keys, and never use `--activate` to manufacture foreground state for a permission probe or capture evidence; the only sanctioned activation for harness evidence is the per-run opt-in in [Harness runs](harness-runs.md). Harness runs launch a new instance through LaunchServices instead of this command line.

| Option | Meaning |
| --- | --- |
| `--manifest <path>` | Required JSON output path; use an existing writable parent directory. |
| `--frame x,y,w,h` | Full window frame in Quartz desktop points, top-left origin; negative positions allowed. Width and height must each be at least 200. Default `120,120,760,520`. |
| `--title <text>` | Window title; default `Public Fixture`. |
| `--black` | Borderless solid black whole window with no sample text, including no title bar; all-black refusal evidence. Takes precedence over `--no-text`. It has no close button, so terminate the process or use the harness completion protocol. |
| `--no-text` | Blank white content with no sample text; no-text evidence. |
| `--sharing-none` | Sets the legacy `NSWindow.sharingType = .none`. Apple documents this constant as legacy and warns against relying on it to prevent capture; the CGWindow sharing value is a non-authoritative diagnostic. Record only the actual ScreenCaptureKit outcome (error, all black, or a normal image). It is never protected-window, sensitive-content, or privacy evidence. |
| `--activate` | Calls `NSApp.activate(ignoringOtherApps:)` once after showing the window. Do not use it for a permission probe or capture evidence, because activation changes foreground state; harness runs never pass it and use the per-run opt-in in [Harness runs](harness-runs.md) instead. |
| `--exit-file <path>` | Harness completion protocol: the fixture quits itself once this file exists. The harness creates it only after overlays are dismissed and results are recorded, so the foreground never returns to the launching terminal mid-run. |
| `--owner-pid <pid>` | The fixture quits if this harness process is gone (no orphan). |

The public manifest additionally carries `items[].lines`, the measured per-line glyph rectangles of the exact drawn string (TextKit layout, window-local points, top-left origin). Only this public manifest carries them; product output stays metadata-only.

## Manifest and coordinates

The schema-1 manifest is atomically rewritten on changes, with frame/state polling every 0.25 seconds. It contains `pid`, `bundleID`, `windowID`, `displayID`, `frameQuartz`, `contentTopInset`, `backingScale`, `mode`, `items`, interaction counters, `isActive`, and a monotonically incremented `sequence`. Use the manifest's actual window ID and frame, not a title or the initial arguments.

`frameQuartz` uses desktop points with a top-left origin. Each item has `id`, `text`, `kind`, and a `{x,y,w,h}` rectangle in **full-window-local points**, top-left origin, including the title bar. Content-layout y coordinates are already shifted by `contentTopInset`; do not add that inset twice. A desktop rectangle is `frameQuartz.x/.y` plus the local x/y. `backingScale` describes point-to-pixel scaling; never treat point rectangles as pixel rectangles. Layout sizes and button positions change on resize, so consume current manifest rectangles. In black/empty modes `items` is empty.

## Public samples and counters

Text-mode items: `heading` (`Public Fixture Window`), `sentence` (`The quick brown fox jumps over the lazy dog.`), `chinese` (`你好，世界`), `code` (`npm test --coverage`), `paragraph` (wraps in a 360-point box), `cell-name` (`Name`), `cell-value` (`Value`), and `button-cancel`, `button-settings`, `button-ok`.

The code sample is drawn text, not a command to execute. The three real buttons only increment `buttonPressCount`; they do not cancel, open settings, or confirm anything. `mouseDownCount`, `scrollCount`, and `keyDownCount` count events received by the custom content view, not necessarily every event handled by button subviews. `resignActiveCount` counts window-key resignations (despite its name); `isActive` reports application activation. Record counters before and after a separate interaction test rather than assuming they must all increase together.

Back to the [fixture guide](README.md). Requirements, build commands, and the run matrix are shared; capture, OCR, and permission semantics are in [Capture and OCR boundaries](capture-ocr-boundaries.md).
