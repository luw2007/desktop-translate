"""Documented terminal app capabilities for the owned fixture launcher."""

# app key -> static facts. "launch" is None when no documented isolated path exists.
APPS = {
    "cmux": {
        "bundleId": "com.cmuxterm.app", "bundlePath": "/Applications/cmux.app",
        "version": "0.65.0", "executable": "Contents/MacOS/cmux", "launch": None,
        "unsupportedReason": (
            "No documented flag for a separate, isolated release instance. CMUX_TAG is only for tagged DEV builds "
            "(binary refuses untagged DEV); CMUX_SOCKET_PATH override on stable builds needs CMUX_ALLOW_SOCKET_OVERRIDE "
            "and the app/session state is still shared; CMUX_ALLOW_REPLACING_RUNNING_CMUX indicates a second release "
            "instance can replace the user's. Driving the user's instance via `cmux new-workspace`/socket is forbidden "
            "(touches daily sessions). Needs an approved, user-created cmux fixture workspace or a tagged DEV build."),
    },
    "iterm2": {
        "bundleId": "com.googlecode.iterm2", "bundlePath": "/Applications/iTerm.app",
        "version": "3.7.0", "executable": "Contents/MacOS/iTerm2", "launch": None,
        "unsupportedReason": (
            "No documented command-line option for an isolated instance (separate prefs/state or command execution); "
            "automation is AppleScript/Python API against the running app, which is forbidden. Needs an approved "
            "user-created fixture window."),
    },
    "ghostty": {
        "bundleId": "com.mitchellh.ghostty", "bundlePath": "/Applications/Ghostty.app",
        "version": "1.3.1", "executable": "Contents/MacOS/ghostty", "launch": "ghostty",
        "evidence": "ghostty.5 `initial-command`/-e (forces new instance + quit-after-last-window-closed), "
                    "`--config-default-files=false` (CLI-only, 'minimizes external effects'), `window-save-state=never`, "
                    "`confirm-close-surface`, `auto-update`, `window-width/height/position-x/y`.",
        "caveat": "Docs say default config path is XDG and, per edit-config text, also ~/Library/Application Support/"
                  "com.mitchellh.ghostty; whether config-default-files=false suppresses the latter is not stated. "
                  "XDG_CONFIG_HOME is redirected as extra belt. Direct exec of the MacOS binary starting a GUI is "
                  "unverified until observed.",
    },
    "terminal": {
        "bundleId": "com.apple.Terminal", "bundlePath": "/System/Applications/Utilities/Terminal.app",
        "version": "2.15", "executable": "Contents/MacOS/Terminal", "launch": None,
        "unsupportedReason": (
            "No documented isolated-instance or run-command flag. Only `open -n file.command` exists, which shares "
            "com.apple.Terminal prefs/saved-state with the user's profile and yields no owned pid. Needs an approved "
            "user-created fixture window."),
    },
    "kaku": {
        "bundleId": "fun.tw93.kaku", "bundlePath": "/Applications/Kaku.app",
        "version": "0.19.0", "executable": "Contents/MacOS/kaku-gui", "launch": "kaku",
        "evidence": "`kaku-gui start --help`: `--always-new-process` (do not ask an existing GUI instance), "
                    "`[PROG]...`/-e, `--cwd`, `--position`, `--no-auto-connect`; top-level `-n/--skip-config`. "
                    "Binary string: 'Use kaku start --always-new-process if you do not want [the existing-instance] behavior'.",
        "caveat": "Runtime behaviour unobserved; the launched process pid is the emulator pid only if kaku-gui does not "
                  "re-exec/daemonize, which launch verifies via producer ancestry and fails closed otherwise.",
    },
}
