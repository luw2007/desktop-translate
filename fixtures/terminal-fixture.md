# Terminal fixture: producer and launcher

`terminal_public_producer.py` is a real program (no mock) meant to run as the child of a fixture-owned terminal. It draws canned public scenes (static, unicode, wrap, full-screen TUI, dynamic line), enables DECSET 1004 focus reporting, sets the OSC 2 title `DT-Fixture-<token>`, and writes its report atomically. Every other byte received on stdin is discarded and only its count is kept: no keys, no characters, and no terminal content are recorded. It refuses to start without a terminal on stdin and stdout.

Producer arguments: `--report <path>` and `--token <token>` (both required), `--scene cycle|static|unicode|wrap|tui|dynamic` (default `cycle`), `--scene-interval <seconds>` (default 3.0), `--duration <seconds>` (0 = until signalled). The producer accepts any non-empty ASCII alphanumeric-or-hyphen token; the launcher additionally requires 1–48 characters, so use that shorter form everywhere.

Report schema is **version 2**: `schema`, `token`, `pid`, `ppid`, `pgid`, `tty`, `state` (`running`/`exited`), `scene`, `scenarioMode` (`cycle`/`fixed`), `sceneIndex`, `sceneChanges`, `renderCount`, `revision`, `focusIn`, `focusOut`, `focusReportingEnabled`, `discardedInputBytes`, `cols`, `rows`, `xpixel`, `ypixel` (0 when the emulator does not report pixels), `startedAtEpoch`, `updatedAtEpoch`.

`revision` is a tick counter, **not** a content-change proof: it increments on every scene render and on every 0.5 s tick, including ticks where nothing is redrawn. `sceneChanges` (scene transitions) and `renderCount` (full scene renders) are the counters that separate real redraws; `SIGWINCH` only marks the frame dirty so the next tick re-reads the new size. Version 1 reports are no longer produced.

Scenes: `static` (fixed lines including a command/prompt pair), `unicode` (CJK, Japanese, Korean, combining-mark Latin, symbols), `wrap` (soft-wrapping long ASCII and CJK lines sized to the current `cols`), `tui` (alternate screen box with a progress bar), `dynamic` (a single rewritten line), and `cycle` (all five in order, one per `--scene-interval`). `terminal_fixture_launcher.py` generates a producer command with no `--scene`, so a launcher-created fixture always runs `cycle`; only a hand-run producer can pin a single scene.

`terminal_fixture_launcher.py` (`capabilities`, `plan`, `launch`, `status`, `handoff`, `cleanup`, `attach-plan`, `attach`) is fail-closed. It spawns a NEW emulator process only where the installed bundle documents an isolated, independent-process launch; every other app is refused rather than driven through `open`, AppleScript, activation of an existing instance, or injected text or keys. State lives in `.dev/terminal-fixtures/<token>`; the token must match `[A-Za-z0-9-]{1,48}`. `capabilities` and `plan` have no side effects; `launch` additionally requires `DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=<token>`.

Typical launch flow:

```sh
python3 fixtures/terminal_fixture_launcher.py capabilities            # static table, nothing run
python3 fixtures/terminal_fixture_launcher.py plan --app ghostty --token fixture-a
DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=fixture-a \
  python3 fixtures/terminal_fixture_launcher.py launch --app ghostty --token fixture-a
python3 fixtures/terminal_fixture_launcher.py handoff --token fixture-a > /tmp/fixture-a-handoff.json
```

`launch` verifies the bundle identifier and executable, starts a new session, and records ownership only once a running producer report exists whose PID descends from the emulator PID it spawned; otherwise it refuses and cleans up only the PID it started. Its `ownershipProof` is `spawned-by-launcher;producer-descendant-of-spawned-pid`.

`handoff` prints schema `terminal-fixture-handoff/1`: `token`, `app`, `bundleId`, `origin` (`launched`/`attached`), `candidateStatus` (always `unverified` — this tool never declares a candidate verified), `ready` plus `notReadyReasons` (`owner-process-not-verified-alive`, `producer-not-verified-alive`, `report-identity-mismatch`, `report-not-running`, `report-stale` when the report is older than 5 seconds), `scenario`, `dimensions`, `focus`, `process` (owner and producer pid/`lstart`/executable/alive), `windowBinding` (`ownerPid`, `expectedTitle` = `DT-Fixture-<token>`, `claimedWindowId` as a hint that must match the consumer's own resolution, `ownershipProof`, attestation fields, and the caveat that the title comes from OSC 2 and an emulator may decorate or override it), `reportPath`, `stateDir`, `fixtureOnly: true`, `dailyAppsTouched: false`.

## Attaching a user-created fixture window

The three apps without a documented isolated launch path (cmux, iTerm2, Terminal.app) can still be used through `attach-plan` plus `attach`, which never launch, activate, or type anything and never attach to the daily instance:

1. `attach-plan --app A --token T` creates the token-owned state directory and an immutable, create-only `attach-plan.json` (mode 0600, `O_EXCL`) recording `planCreatedAtEpoch`, and prints the producer command for the user to run by hand.
2. The user starts a brand-new dedicated process of that app **after** the plan (never the daily terminal) and runs that producer command inside it.
3. `attach --app A --token T --owner-pid P --window-id W --attest-new-disposable-process` requires `DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=<token>` and fails closed unless the plan exists and is unmodified; the owner PID is a live process of that app whose `ps lstart` is strictly later than the plan time; the producer report is running and fresh (≤ 5 s); the report PID is a live `terminal_public_producer.py` process carrying this token; and that PID descends from the owner PID.

Attached state records `fixtureAttestation: new-disposable-process-fixture-only`, `dailyInstanceReused: false`, and `attestationKind: operator-asserted; machine-checked only: owner start > plan time, producer descendant`. **“A new disposable process, not the daily instance” is an operator assertion.** The launcher machine-checks only the start-time ordering, report identity/freshness, and ancestry; the consumer checks the tty and window later. Nothing in this workflow proves the attached process holds no other tabs or panes, and the `--window-id` claim is operator-supplied.

`cleanup --token T` signals only what `launch` itself started, and only while PID, start time, and command still match (SIGTERM, then SIGKILL after ~4 s). For an attached fixture it signals nothing: it reports `attached-left-running`, drops only the ownership record while the producer still runs, and leaves the user's process and report in place.

## Core capture consumer contract

`desktop-translate terminal-fixture-smoke` (and `terminal-fixture-pi-smoke`) consumes one handoff and re-proves everything against live OS facts; `terminal_fixture_launcher.py`'s own record is treated as derived data. These are app modes reached through the `desktop-translate` wrapper (`--terminal-fixture-smoke` / `--terminal-fixture-pi-smoke`), not subcommands of the Python launcher. Required environment: `DESKTOP_TRANSLATE_TERMINAL_TOKEN`, `DESKTOP_TRANSLATE_TERMINAL_HANDOFF`, `DESKTOP_TRANSLATE_TERMINAL_STATE_ROOT` (set it to the launcher's state root, `<repo>/.dev/terminal-fixtures`), and `DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED` (must equal the token).

```sh
export DESKTOP_TRANSLATE_TERMINAL_TOKEN=fixture-a
export DESKTOP_TRANSLATE_TERMINAL_STATE_ROOT="$PWD/.dev/terminal-fixtures"
export DESKTOP_TRANSLATE_TERMINAL_HANDOFF="$DESKTOP_TRANSLATE_TERMINAL_STATE_ROOT/fixture-a/handoff.json"
python3 fixtures/terminal_fixture_launcher.py handoff --token "$DESKTOP_TRANSLATE_TERMINAL_TOKEN" > "$DESKTOP_TRANSLATE_TERMINAL_HANDOFF"
export DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED="$DESKTOP_TRANSLATE_TERMINAL_TOKEN"
./desktop-translate terminal-fixture-smoke
```

The wrapper forwards only named variables to the LaunchServices process — `DESKTOP_TRANSLATE_PI_MODEL`, `DESKTOP_TRANSLATE_PI_EXECUTABLE`, `DESKTOP_TRANSLATE_GLYPH_SCENE`, `DESKTOP_TRANSLATE_FIXTURE_APP`, `DESKTOP_TRANSLATE_GLYPH_FIXTURE_APP`, `DESKTOP_TRANSLATE_AUTHORIZE_FIXTURE_ACTIVATION`, the four `DESKTOP_TRANSLATE_TERMINAL_*` fixture variables, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `PATH`, `HOME`, and `PI_CODING_AGENT_DIR` — so export them in the invoking shell; a variable outside that list never reaches the harness. The terminal emulator must already be the natural frontmost app with its single fixture window; the command does not raise it.

It refuses, with no fallback and no other window captured, unless: the handoff schema/token/`fixtureOnly`/`ready`/`candidateStatus == unverified`/origin are valid; the bundle is in the built-in terminal whitelist; `ownershipProof` is present; all paths stay inside the state root without symlinks; `state.json` agrees with the handoff on token, bundle, PIDs, `lstart`, attached flag, owner PID, and expected title; `launched` state carries the launcher's `spawned-by-launcher…` proof, or `attached` state carries the attestation, `dailyInstanceReused == false`, a claimed window ID, and an `attach-plan.json` whose plan time precedes the owner's live start time.

It then re-verifies live, before and after the session: `sysctl` start times equal the recorded `lstart` strings, the producer descends from the owner PID, the producer's controlling tty matches the reported tty (`/dev/ttys*`, `st_rdev` equal), and the owner is a running application of the expected bundle. The locked target must be the owner's single ordinary window, the claimed window ID must match exactly when present, and a non-empty window title must contain `DT-Fixture-<token>`; an empty title is accepted only together with a claimed window ID. Readiness requires the owner to be naturally frontmost with that single ordinary window stable on two consecutive ticks within 10 seconds — nothing is activated, typed, spawned, or signalled, and a failure never falls back to another window. The run then performs one real session (plugin route → OCR fallback → translation → overlay → hotkey dismissal through the queued Carbon handler) and reports public counters only. It reports `geometry.measured = false` because no glyph-geometry oracle exists for terminal text; only source, support, and mask association are checked. Fixture cleanup stays with the launcher.

| App | Isolated launch | Basis (static only; no app was run) |
| --- | --- | --- |
| Ghostty 1.3.1 | candidate | man5: `-e`, `--config-default-files=false`, `window-save-state=never`; XDG redirected; Application Support config suppression unproven |
| Kaku 0.19.0 | candidate | `kaku-gui start --always-new-process -- PROG`, `--skip-config`; pid ancestry verified at launch |
| cmux 0.65.0 | unsupported | no documented isolated release instance; `CMUX_TAG` is DEV-only; needs an approved user-created fixture or a tagged DEV build |
| iTerm2 3.7.0 | unsupported | no documented isolated/command flag; needs an approved user-created fixture |
| Terminal.app 2.15 | unsupported | only `open -n`, shared prefs, no owned pid; needs an approved user-created fixture |

“Candidate” means documented, not observed. No five-terminal acceptance is claimed.

Back to the [fixture guide](README.md). Build steps and the run matrix are shared; capture and OCR semantics for the consumer session are in [Capture and OCR boundaries](capture-ocr-boundaries.md).
