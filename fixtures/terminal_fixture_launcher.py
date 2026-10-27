#!/usr/bin/env python3
"""Owned-terminal fixture launcher (fail-closed).

Launches a NEW, separate terminal-emulator process that runs only
terminal_public_producer.py, and only for apps whose installed bundle documents
an isolated, independent-process launch path. For every other app the launcher
refuses; it never falls back to `open`, AppleScript, activation of an existing
instance, or sending text/keys to any terminal.

Subcommands
  capabilities            JSON table of all five apps (no side effects)
  cleanup --token T       terminate ONLY the recorded, identity-verified owned pids (attached: never signals)
  handoff --token T       JSON handoff for core capture: scenario/revision/dims/focus, owner+producer pid/lstart,
                          windowBinding contract; candidateStatus is always "unverified"
  attach-plan --app A --token T   print the producer command for the USER to run by hand in their own fixture window
                          (works for unsupported apps too; nothing is typed into any terminal)
  attach  --app A --token T --owner-pid P --window-id W --attest-new-disposable-process   (requires AUTH env)
                          binds a producer run by hand inside a NEW dedicated app process started after attach-plan;
                          fails closed unless owner start > plan time, producer live/token-matched/descendant of P
  launch  --app A --token T   spawn (requires DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED=<token>)
  status  --token T       verify owned identity and print the producer report
  plan    --app A --token T   print the exact argv/env that `launch` would use (no side effects)

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

from terminal_fixture_apps import APPS
import terminal_fixture_attach as attachment

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PRODUCER = os.path.join(HERE, "terminal_public_producer.py")
AUTH_ENV = "DESKTOP_TRANSLATE_TERMINAL_FIXTURE_AUTHORIZED"
TOKEN_RE = re.compile(r"^[A-Za-z0-9-]{1,48}$")
STATE_ROOT = os.path.join(REPO, ".dev", "terminal-fixtures")
REPORT_FRESH_SECONDS = 5.0

# Static capability facts live in terminal_fixture_apps; runtime roots remain here.


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
                             capture_output=True, text=True, timeout=5,
                             env={**os.environ, "LC_ALL": "C", "LANG": "C"}).stdout.strip()
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
    state["schema"] = 2
    state["ownershipProof"] = "spawned-by-launcher;producer-descendant-of-spawned-pid"
    with open(os.path.join(sdir, "state.json"), "w", encoding="utf-8") as fh:
        json.dump(state, fh, sort_keys=True)
    print(json.dumps({"launched": True, **state, "handoff": build_handoff(state)}, sort_keys=True))


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


def build_handoff(state):
    """Bounded core-capture handoff. Never declares a candidate verified; core capture must re-prove the window."""
    report = read_json(state["reportPath"]) or {}
    owner_alive = verified(state["emulatorPid"], state.get("emulatorLstart"), state["executable"])
    prod_alive = verified(state.get("producerPid"), state.get("producerLstart"), state["token"])
    reasons = []
    if not owner_alive:
        reasons.append("owner-process-not-verified-alive")
    if not prod_alive:
        reasons.append("producer-not-verified-alive")
    if report.get("token") != state["token"] or report.get("pid") != state.get("producerPid"):
        reasons.append("report-identity-mismatch")
    if report.get("state") != "running":
        reasons.append("report-not-running")
    if time.time() - report.get("updatedAtEpoch", 0) > REPORT_FRESH_SECONDS:
        reasons.append("report-stale")
    spec = APPS[state["app"]]
    return {
        "schema": "terminal-fixture-handoff/1", "token": state["token"], "app": state["app"],
        "bundleId": state["bundleId"], "origin": "attached" if state.get("attached") else "launched",
        "candidateStatus": "unverified",  # runtime/window ownership is never declared verified by this tool
        "ready": not reasons, "notReadyReasons": reasons,
        "scenario": {"name": report.get("scene"), "mode": report.get("scenarioMode"),
                     "sceneIndex": report.get("sceneIndex"), "sceneChanges": report.get("sceneChanges"),
                     "renderCount": report.get("renderCount"), "revision": report.get("revision")},
        "dimensions": {"cols": report.get("cols"), "rows": report.get("rows"),
                       "xpixel": report.get("xpixel"), "ypixel": report.get("ypixel")},
        "focus": {"in": report.get("focusIn"), "out": report.get("focusOut"),
                  "reportingEnabled": report.get("focusReportingEnabled"),
                  "discardedInputBytes": report.get("discardedInputBytes")},
        "process": {
            "owner": {"pid": state["emulatorPid"], "lstart": state.get("emulatorLstart"),
                      "executable": state["executable"], "alive": owner_alive},
            "producer": {"pid": state.get("producerPid"), "lstart": state.get("producerLstart"),
                         "pgid": report.get("pgid"), "tty": report.get("tty"), "alive": prod_alive}},
        # Window binding contract: core capture must resolve the window itself (on-screen, owner pid == owner.pid,
        # title == expectedTitle) and treat claimedWindowId only as a hint that must match that resolution.
        "windowBinding": {"ownerPid": state["emulatorPid"], "expectedTitle": "DT-Fixture-" + state["token"],
                          "claimedWindowId": state.get("claimedWindowId"),
                          "ownershipProof": state.get("ownershipProof"),
                          "fixtureAttestation": state.get("fixtureAttestation"),
                          "dailyInstanceReused": state.get("dailyInstanceReused"),
                          "planCreatedAtEpoch": state.get("planCreatedAtEpoch"),
                          "ownerStartEpoch": state.get("ownerStartEpoch"),
                          "titleCaveat": "title is set via OSC 2 by the producer; emulators may decorate or override it"},
        "reportPath": state["reportPath"], "stateDir": state_dir(state["token"]),
        "fixtureOnly": True, "dailyAppsTouched": False, "bundleVersionDocumented": spec["version"],
    }


def cmd_status(args):
    state = load_state(args.token)
    emu = verified(state["emulatorPid"], state.get("emulatorLstart"), state["executable"])
    prod = verified(state.get("producerPid"), state.get("producerLstart"), args.token)
    print(json.dumps({"state": state, "emulatorAlive": emu, "producerAlive": prod,
                      "report": read_json(state["reportPath"]), "handoff": build_handoff(state)}, sort_keys=True))


def cmd_handoff(args):
    print(json.dumps(build_handoff(load_state(args.token)), indent=2, sort_keys=True))




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
    attached = bool(state and state.get("token") == token and state.get("attached"))
    if state and state.get("token") == token and not attached:
        result["producer"] = terminate(state.get("producerPid"), state.get("producerLstart"), token)
        result["emulator"] = terminate(state["emulatorPid"], state.get("emulatorLstart"), state["executable"])
    elif attached:
        # User-created fixture: never signal anything we did not spawn.
        result["producer"] = result["emulator"] = "attached-left-running"
        live = verified(state.get("producerPid"), state.get("producerLstart"), token)
        result["detached"] = True
        if live:
            # Producer still writes its report here; drop only the ownership record.
            os.unlink(os.path.join(sdir, "state.json"))
            if not quiet:
                print(json.dumps(result, sort_keys=True))
            return result
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
    for name, fn in (("status", cmd_status), ("handoff", cmd_handoff),
                     ("cleanup", lambda a: do_cleanup(validate_token(a.token)))):
        s = sub.add_parser(name)
        s.add_argument("--token", required=True)
        s.set_defaults(fn=fn)
    runtime = sys.modules[__name__]
    for name, fn in (("attach-plan", lambda a: attachment.cmd_attach_plan(a, runtime)),
                     ("attach", lambda a: attachment.cmd_attach(a, runtime))):
        s = sub.add_parser(name)
        s.add_argument("--app", required=True, choices=sorted(APPS))
        s.add_argument("--token", required=True)
        if name == "attach":
            s.add_argument("--owner-pid", type=int, required=True)
            s.add_argument("--window-id", type=int, required=True)
            s.add_argument("--attest-new-disposable-process", action="store_true")
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
