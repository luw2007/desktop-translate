#!/usr/bin/env python3
"""Owned-terminal fixture launcher (fail-closed).

Launches a NEW, separate terminal-emulator process that runs only
terminal_public_producer.py, and only for apps whose installed bundle documents
an isolated, independent-process launch path. For every other app the launcher
refuses; it never falls back to `open`, AppleScript, activation of an existing
instance, or sending text/keys to any terminal.

Subcommands
  capabilities            JSON table of all five apps (no side effects)
  plan    --app A --token T   print the exact argv/env that `launch` would use (no side effects)
  launch  --app A --token T   spawn (requires DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=<token>)
  status  --token T       verify owned identity and print the producer report
  cleanup --token T       terminate ONLY the recorded, identity-verified owned pids

Evidence sources for the capability table (static only; nothing was executed to
decide them): man pages inside Ghostty.app (ghostty.1/ghostty.5), `kaku-gui
start --help`, `cmux --help`/docs, Info.plist of each bundle. Runtime behaviour
is UNVERIFIED until an authorized launch is observed.
"""

import argparse
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PRODUCER = os.path.join(HERE, "terminal_public_producer.py")
AUTH_ENV = "DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED"
TOKEN_RE = re.compile(r"^[A-Za-z0-9-]{1,48}$")
STATE_ROOT = os.path.join(REPO, ".dev", "terminal-fixtures")

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


class Refusal(Exception):
    pass


def validate_token(token):
    if not TOKEN_RE.match(token or ""):
        raise Refusal("token must match [A-Za-z0-9-]{1,48}")
    return token


def state_dir(token):
    return os.path.join(STATE_ROOT, validate_token(token))


def check_bundle(app):
    spec = APPS[app]
    plist_path = os.path.join(spec["bundlePath"], "Contents", "Info.plist")
    try:
        with open(plist_path, "rb") as fh:
            info = plistlib.load(fh)
    except OSError as exc:
        raise Refusal("%s not installed at %s (%s)" % (app, spec["bundlePath"], exc))
    if info.get("CFBundleIdentifier") != spec["bundleId"]:
        raise Refusal("bundle id mismatch for %s: %r" % (app, info.get("CFBundleIdentifier")))
    exe = os.path.join(spec["bundlePath"], spec["executable"])
    if not os.access(exe, os.X_OK):
        raise Refusal("executable missing: " + exe)
    return exe, info.get("CFBundleShortVersionString")


def parse_position(text):
    if text is None:
        return None
    m = re.match(r"^(-?\d{1,5}),(-?\d{1,5})$", text)
    if not m:
        raise Refusal("--position must be X,Y integers")
    return int(m.group(1)), int(m.group(2))


def build_plan(app, token, position=None, cols=None, rows=None):
    if app not in APPS:
        raise Refusal("unknown app %r; one of %s" % (app, ", ".join(sorted(APPS))))
    spec = APPS[app]
    if spec["launch"] is None:
        raise Refusal("unsupported-safe-launch: " + spec["unsupportedReason"])
    exe, version = check_bundle(app)
    sdir = state_dir(token)
    report = os.path.join(sdir, "report.json")
    producer_cmd = [sys.executable, PRODUCER, "--report", report, "--token", token]
    xdg = os.path.join(sdir, "xdg")
    if spec["launch"] == "ghostty":
        argv = [exe, "--config-default-files=false", "--window-save-state=never",
                "--confirm-close-surface=false", "--auto-update=off",
                "--title=DT-Fixture-" + token]
        if cols and rows:
            argv += ["--window-width=%d" % cols, "--window-height=%d" % rows]
        if position:
            argv += ["--window-position-x=%d" % position[0], "--window-position-y=%d" % position[1]]
        argv += ["-e"] + producer_cmd
    else:  # kaku
        argv = [exe, "--skip-config", "start", "--always-new-process", "--no-auto-connect",
                "--cwd", sdir]
        if position:
            argv += ["--position", "screen:%d,%d" % position]
        argv += ["--"] + producer_cmd
    env = {k: os.environ[k] for k in ("PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR") if k in os.environ}
    env.update({"XDG_CONFIG_HOME": xdg, "DESKTOP_TRANSLATE_FIXTURE_TOKEN": token})
    return {"app": app, "bundleId": spec["bundleId"], "bundleVersion": version, "executable": exe,
            "argv": argv, "env": env, "stateDir": sdir, "reportPath": report,
            "evidence": spec.get("evidence"), "caveat": spec.get("caveat")}


def ps_info(pid):
    """(lstart, command) for pid or None."""
    try:
        out = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "command="],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if not out:
        return None
    parts = out.split(None, 5)
    lstart = " ".join(parts[:5])
    command = parts[5] if len(parts) > 5 else ""
    return lstart, command


def ppid_of(pid):
    try:
        out = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid="], capture_output=True, text=True,
                             timeout=5).stdout.strip()
        return int(out) if out else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def is_descendant(pid, ancestor, limit=16):
    cur = pid
    for _ in range(limit):
        cur = ppid_of(cur)
        if cur is None or cur <= 1:
            return False
        if cur == ancestor:
            return True
    return False


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def prepare_state_dir(sdir):
    for p in (os.path.join(REPO, ".dev"), STATE_ROOT, sdir):
        if os.path.islink(p):
            raise Refusal("refusing symlinked path " + p)
    if os.path.exists(sdir):
        raise Refusal("state dir exists (token reuse); run cleanup first: " + sdir)
    os.makedirs(os.path.join(sdir, "xdg"), mode=0o700)


def cmd_launch(args):
    token = validate_token(args.token)
    if os.environ.get(AUTH_ENV) != token:
        raise Refusal("not authorized: set %s=<token> after Main approves a launch" % AUTH_ENV)
    plan = build_plan(args.app, token, parse_position(args.position), args.cols, args.rows)
    sdir = plan["stateDir"]
    prepare_state_dir(sdir)
    log = open(os.path.join(sdir, "emulator.log"), "wb")
    proc = subprocess.Popen(plan["argv"], env=plan["env"], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                            start_new_session=True, cwd=sdir)
    time.sleep(0.2)
    info = ps_info(proc.pid)
    state = {"schema": 1, "token": token, "app": args.app, "bundleId": plan["bundleId"],
             "emulatorPid": proc.pid, "emulatorLstart": info[0] if info else None,
             "executable": plan["executable"], "reportPath": plan["reportPath"], "launchedAtEpoch": time.time()}
    with open(os.path.join(sdir, "state.json"), "w", encoding="utf-8") as fh:
        json.dump(state, fh, sort_keys=True)
    deadline = time.monotonic() + args.timeout
    rep = None
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        rep = read_json(plan["reportPath"])
        if rep and rep.get("token") == token and rep.get("state") == "running":
            break
        rep = None
        time.sleep(0.25)
    if not rep or not is_descendant(rep["pid"], proc.pid):
        do_cleanup(token, quiet=True)
        raise Refusal("owned identity not proven (producer report missing or not a descendant of the spawned "
                      "emulator pid); cleaned up owned pid only. See %s/emulator.log" % sdir)
    state["producerPid"] = rep["pid"]
    state["producerLstart"] = (ps_info(rep["pid"]) or (None,))[0]
    with open(os.path.join(sdir, "state.json"), "w", encoding="utf-8") as fh:
        json.dump(state, fh, sort_keys=True)
    print(json.dumps({"launched": True, **state}, sort_keys=True))


def verified(pid, lstart, needle):
    """True only if pid is alive, same start time, and command mentions needle."""
    if not pid or not lstart:
        return False
    info = ps_info(pid)
    return bool(info and info[0] == lstart and needle in info[1])


def load_state(token):
    state = read_json(os.path.join(state_dir(token), "state.json"))
    if not state or state.get("token") != token:
        raise Refusal("no valid state for token")
    return state


def cmd_status(args):
    state = load_state(args.token)
    emu = verified(state["emulatorPid"], state.get("emulatorLstart"), state["executable"])
    prod = verified(state.get("producerPid"), state.get("producerLstart"), args.token)
    print(json.dumps({"state": state, "emulatorAlive": emu, "producerAlive": prod,
                      "report": read_json(state["reportPath"])}, sort_keys=True))


def terminate(pid, lstart, needle):
    if not verified(pid, lstart, needle):
        return "not-owned-or-gone"
    os.kill(pid, signal.SIGTERM)
    for _ in range(40):
        time.sleep(0.1)
        if not verified(pid, lstart, needle):
            return "terminated"
    if verified(pid, lstart, needle):
        os.kill(pid, signal.SIGKILL)
        return "killed"
    return "terminated"


def do_cleanup(token, quiet=False):
    sdir = state_dir(token)
    state = read_json(os.path.join(sdir, "state.json"))
    result = {"token": token}
    if state and state.get("token") == token:
        result["producer"] = terminate(state.get("producerPid"), state.get("producerLstart"), token)
        result["emulator"] = terminate(state["emulatorPid"], state.get("emulatorLstart"), state["executable"])
    else:
        result["note"] = "no recorded identity; nothing killed"
    if not os.path.islink(sdir) and os.path.isdir(sdir) and os.path.realpath(sdir).startswith(os.path.realpath(STATE_ROOT) + os.sep):
        shutil.rmtree(sdir)
        result["stateDirRemoved"] = True
    if not quiet:
        print(json.dumps(result, sort_keys=True))
    return result


def cmd_capabilities(_args):
    table = {}
    for key, spec in APPS.items():
        entry = {"bundleId": spec["bundleId"], "version": spec["version"],
                 "isolatedLaunch": spec["launch"] is not None}
        for f in ("evidence", "caveat", "unsupportedReason"):
            if spec.get(f):
                entry[f] = spec[f]
        table[key] = entry
    print(json.dumps(table, indent=2, sort_keys=True))


def cmd_plan(args):
    print(json.dumps(build_plan(args.app, validate_token(args.token), parse_position(args.position),
                                args.cols, args.rows), indent=2, sort_keys=True))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("capabilities").set_defaults(fn=cmd_capabilities)
    for name, fn in (("plan", cmd_plan), ("launch", cmd_launch)):
        s = sub.add_parser(name)
        s.add_argument("--app", required=True, choices=sorted(APPS))
        s.add_argument("--token", required=True)
        s.add_argument("--position")
        s.add_argument("--cols", type=int)
        s.add_argument("--rows", type=int)
        if name == "launch":
            s.add_argument("--timeout", type=float, default=15.0)
        s.set_defaults(fn=fn)
    for name, fn in (("status", cmd_status), ("cleanup", lambda a: do_cleanup(validate_token(a.token)))):
        s = sub.add_parser(name)
        s.add_argument("--token", required=True)
        s.set_defaults(fn=fn)
    args = p.parse_args(argv)
    try:
        args.fn(args)
    except Refusal as exc:
        print(json.dumps({"refused": True, "reason": str(exc)}), file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
