# Fixtures: public samples, glyph oracle, terminal producer

This directory holds the independent fixture apps and harness tools used to exercise the translator without touching a private window, a daily terminal, or a real document. None of these is translator UI, and none is product acceptance evidence on its own: see [Evidence boundaries](#evidence-boundaries).

Related documents: [design](../docs/design.md) (capture, overlay, overflow, permission and privacy contract), [change 001](../docs/changes/001-desktop-plugin-ocr.md) (desktop plugin/OCR specification), [change 002](../docs/changes/002-terminal-layout-plugins.md) (terminal specification). The root [README](../README.md) covers installation and user operation; [development history](../docs/development-history.md) is archived material, not current instructions.

This entry keeps the shared prerequisites, build commands, run matrix, and evidence boundaries. Each fixture and each contract has its own page:

| Document | Covers |
| --- | --- |
| [Public fixture app](public-fixture.md) | `PublicFixtureApp.swift`, command-line options, schema-1 manifest, coordinates, public samples, counters |
| [Harness runs: activation and permission probe](harness-runs.md) | the per-run activation opt-in, `HarnessReadiness` order, `permission-probe` (S0) versus a full `smoke` run |
| [Capture and OCR boundaries](capture-ocr-boundaries.md) | `TargetLocker` refusals, capture gates, Screen Recording, Vision settings, pi input modes, partial-capability warnings |
| [Glyph oracle workflow](glyph-oracle.md) | the CoreText scene app, fixture options, `GlyphMetric` matching, mask scoring rules and 4 pt thresholds |
| [Terminal fixture: producer and launcher](terminal-fixture.md) | `terminal_public_producer.py`, report schema, launcher commands, attach flow, capture consumer contract, app support table |
| [Historical evidence](history.md) | dated observations kept for traceability, not current instructions |

## Requirements

- Apple Silicon Mac, macOS 15 or later.
- Xcode Command Line Tools: `xcrun swiftc` and a macOS SDK that compiles the current sources.
- A Git checkout: the app launcher reads Git metadata, and every fixture path is derived from the checkout root.
- Python 3 via `/usr/bin/env python3`, with no third-party packages, for `terminal_fixture_launcher.py` and `terminal_public_producer.py`.
- Screen Recording permission for the app that performs capture; a capture attempt may present the system Screen Recording consent prompt. A terminal session may also trigger the system Automation consent prompt when its read-only terminal plugin uses Apple Events. No fixture flow requests Accessibility, and none modifies TCC, keychain, or daily configuration.
- pi is optional and only needed for the `pi-*` commands: it must be installed and authenticated separately, with a model the user has configured. The repository ships no pi installation, credentials, or model list.
- Build the fixture and the DEV app from the same checkout with the same `DESKTOP_TRANSLATE_DEV_TAG`; the harness resolves the fixture bundle relative to its own DEV bundle.

## Build

Both builders require a non-empty `DESKTOP_TRANSLATE_DEV_TAG` matching `[A-Za-z0-9-]+`. They write only under `.dev/`, refuse symlinked output paths and unrecognized existing bundles, and never launch, activate, capture, or inject events.

```sh
export DESKTOP_TRANSLATE_DEV_TAG=local      # any tag; use the same tag for the DEV app
./fixtures/build-fixture.sh                 # -> .dev/fixture/Public Fixture.app
./fixtures/build-glyph-fixture.sh           # -> .dev/glyph-fixture/<tag>/Glyph Fixture <tag>.app
```

`build-fixture.sh` targets `arm64-apple-macosx15.0`, links AppKit, generates an Info.plist, ad hoc signs a staged bundle, and replaces only an identified fixture bundle. Bundle ID `local.desktop-translate.public-fixture`, executable `public-fixture`.

`build-glyph-fixture.sh` compiles `GlyphSceneManifest.swift`, `GlyphSceneFixtureApp.swift`, `GlyphSceneFixtureDrawing.swift`, and `GlyphSceneFixtureDelegate.swift` with AppKit and CoreText. Bundle ID `local.desktop-translate.glyph-fixture.<tag>`, executable `glyph-fixture`. It does not touch `Public Fixture.app` or its builder.

Build the DEV app once with the same tag before any harness command, so the fixture can be resolved relative to it:

```sh
./desktop-translate build
```

The harness derives `.dev/fixture/Public Fixture.app` or `.dev/glyph-fixture/<tag>/Glyph Fixture <tag>.app` from its own DEV bundle location; `DESKTOP_TRANSLATE_FIXTURE_APP` or `DESKTOP_TRANSLATE_GLYPH_FIXTURE_APP` can point at an explicit bundle instead, and an override disables the one-time activation opt-in. `./desktop-translate` refuses a linked worktree without a tag, so keep the tag exported.

These commands are instructions, not evidence that a build or run has occurred.

## Workflow: permission probe, public smoke, glyph oracle, terminal fixture

The harness commands below run through `./desktop-translate` with the same `DESKTOP_TRANSLATE_DEV_TAG`, so they use the isolated DEV bundle and config under `.dev/`; the Python launcher and producer are invoked directly. Diagnostic commands are launched as their own LaunchServices process, not as a child of the terminal.

| Command | Fixture | Proves | Does not prove |
| --- | --- | --- | --- |
| `permission-probe` | public | one window-only ScreenCaptureKit call on an owned fixture window; image stays in memory, nothing saved | OCR, translation, general permission acceptance |
| `smoke` / `pi-smoke` | public | one real capture → OCR → selected backend → overlay → hotkey dismissal; public counters only | sensitive-content detection, mask-to-text accuracy, precision on real apps, input isolation |
| `glyph-smoke` / `glyph-pi-smoke` | glyph | OCR and source-mask edge errors against an exact glyph oracle | real application layout, physical input, cover/extension geometry |
| `terminal-fixture-smoke` / `terminal-fixture-pi-smoke` | terminal producer | one real session over a re-verified owned terminal window; `geometry.measured=false` | glyph precision, emulator UI acceptance, FocusLost acceptance |

`smoke`, `glyph-smoke`, and the terminal commands read the currently selected backend from the DEV config read-only. A missing config means defaults; an invalid config fails closed without fallback; `pi-*` variants override the backend explicitly. `glyph-smoke` requires the glyph fixture built with the same tag; `DESKTOP_TRANSLATE_GLYPH_SCENE` selects `boundary|collision|icon|code|cjk|prose` (default `boundary`), and `DESKTOP_TRANSLATE_GLYPH_FIXTURE_APP` may point at another glyph bundle.

Setup detail for each row lives on the linked page: the public app's options and manifest in [Public fixture app](public-fixture.md), the activation flag and `permission-probe`/`smoke` split in [Harness runs](harness-runs.md), the glyph scenes in [Glyph oracle workflow](glyph-oracle.md), and the producer, launcher, and consumer environment variables in [Terminal fixture](terminal-fixture.md).

## Evidence boundaries

- Offscreen and standalone checks (`DesktopChecks`, `GlyphMatcherChecks`, `GlyphFixtureOracleChecks`, `SegmentsChecks`, the Python fixture checks) are not GUI, capture, OCR, model, or input evidence.
- The hotkey dismissal in every smoke mode posts a queued synthetic Carbon event. It exercises the registered handler; it is not physical input or focus isolation.
- A successful public-fixture or glyph-fixture run proves exact-window/crop/OCR operation on a public sample only, never sensitive-content detection, real-application precision, or privacy acceptance.
- Terminal runs are not emulator UI runs, not physical FocusLost measurements, and not five-application evidence; attached private tabs and panes remain operator assertions.
- Nothing here supports a claim that “all current tests pass”. Report builds, checks, captures, model requests, and real UI runs separately.

Dated observations and superseded assumptions are in [Historical evidence](history.md).
