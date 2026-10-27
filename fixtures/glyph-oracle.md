# Glyph oracle workflow

`GlyphSceneManifest.swift`, `GlyphSceneFixtureApp.swift`, `GlyphSceneFixtureDrawing.swift`, and `GlyphSceneFixtureDelegate.swift` form a separate CoreText public scene app, not translator UI. It draws known tokens and publishes an exact oracle in memory: `glyph` is the CoreText/TextKit glyph-bounds rectangle, `ink` is the tight bound of pixels an in-memory alpha oracle painted for the same `CTLine` at the real backing scale. No oracle image, pixel hash, or text hash is written to disk; the manifest carries fixed public text, stable token IDs, rectangles, scales, and event-type counts.

Direct fixture options: required `--manifest`; optional `--scene` (default `boundary`), `--phase stable|mutate|caret` (default `stable`), `--period` (minimum 0.05 s), `--frame x,y,w,h`, `--title`, `--exit-file`, `--owner-pid`. The binary itself never activates or injects events; the harness [activation opt-in](harness-runs.md) is the only activation path. `mutate` changes public text and `runRevision`; `caret` changes only the decoration and never `runRevision`. `glyph-smoke` itself always launches with `--phase stable`. The caret is visible on two of its first four ticks, then the fixture publishes `caret-stop` and hides it with the timer invalidated. `GlyphView` is first responder; observer zones are glyph-ink covered/uncovered rectangles and a `keyDown.keyboard` bucket, never typed characters or key codes.

`GlyphSmoke.swift` / `GlyphMetric.measure` match public normalized-text identity and token-centre containment one-to-one (never nearest-edge or sorted-index zip), then report public IDs and numeric edge errors with a 4-point tolerance. Duplicate token IDs, missing non-whitespace ink, and oracle disagreement fail closed. `targetMatchesFixtureWindow` checks PID/window/frame/display ID/bounds/backing scale and unchanged before/after geometry.

The mask stage scores **only rectangles that receive paint**, and associates each source line after the product's `OccupiedGeometry` clipping with exactly one painted rectangle:

- `.painted` and `.paintedCondensed` items are scored on their source lines. Proven-free **extension strips** are not part of the glyph oracle; they are exercised by `DesktopChecks` instead.
- `.paintedCover` items are scored on their **source lines only**: the translucent cover area outside the source lines is not compared against the glyph oracle, so a cover result does not evidence ≤4 pt geometry for the covered content.
- `maskCounts` reports `overflowItems` and `unavailableItems`; either being non-zero fails `maskEdgesWithin4pt`, because an unpainted item is valid product behaviour but not a precision pass.
- `minimumFontSize` uses the product's `fontSizeAllowed`: regular text ≥ 12 pt, condensed text ≥ 9 pt, cover text exactly 12 pt. A glyph-smoke pass is therefore not a “≥ 12 pt everywhere” guarantee.

OCR and mask 4 pt thresholds are unchanged. Neighbour checks cover token ink and published fixture decorations, not product-side icon or non-text safety.

Back to the [fixture guide](README.md). Build the glyph fixture with `build-glyph-fixture.sh` under the same `DESKTOP_TRANSLATE_DEV_TAG` as the DEV app; the run matrix and evidence boundaries are shared.
