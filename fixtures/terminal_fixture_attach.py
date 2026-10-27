"""Explicit-plan attachment commands using the launcher's injectable runtime.

The launcher owns filesystem roots and process observations; this module never
derives them from its own __file__ or loads a second launcher instance.
"""

import json
import os
import re
import sys
import time


def attach_report_path(token, runtime):
    return os.path.join(runtime.state_dir(token), "report.json")


ATTEST_VALUE = "new-disposable-process-fixture-only"
PLAN_NAME = "attach-plan.json"


_MONTHS = {m: i for i, m in enumerate(("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), 1)}
_LSTART_RE = re.compile(r"^[A-Z][a-z]{2} (?:(?P<d1>\d{1,2}) (?P<m1>[A-Z][a-z]{2})|(?P<m2>[A-Z][a-z]{2}) (?P<d2>\d{1,2})) "
                        r"(?P<H>\d{2}):(?P<M>\d{2}):(?P<S>\d{2}) (?P<Y>\d{4})$")


def lstart_epoch(lstart):
    """ps lstart -> epoch seconds (local time, 1 s resolution) or None.

    Accepts exactly the two observed layouts, locale-independently (fixed English month table, no strptime):
      'Mon 12 Oct 22:13:40 2026' (macOS actual, day before month) and 'Mon Oct 12 22:13:40 2026' (month before day).
    Anything else, including an unknown month or out-of-range field, is rejected (None)."""
    m = _LSTART_RE.match(lstart or "")
    if not m:
        return None
    mon = _MONTHS.get(m.group("m1") or m.group("m2"))
    if mon is None:
        return None
    day = int(m.group("d1") or m.group("d2"))
    try:
        hh, mm, ss, yy = int(m.group("H")), int(m.group("M")), int(m.group("S")), int(m.group("Y"))
        if not (1 <= day <= 31 and hh < 24 and mm < 60 and ss < 61):
            return None
        return time.mktime((yy, mon, day, hh, mm, ss, 0, 0, -1))
    except (ValueError, OverflowError):
        return None


def write_new_json(path, doc):
    """Create-only (O_EXCL, no symlink follow), 0600; never overwrites."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, sort_keys=True)


def cmd_attach_plan(args, runtime):
    """Record plan creation time and print (never type, never launch) the command a NEW dedicated app process must run.

    The user must start a brand-new, dedicated instance of the app AFTER this plan (never their daily terminal) and
    run producerCommand inside it by hand. Creates the token-owned state dir and an immutable plan file."""
    token = runtime.validate_token(args.token)
    if args.app not in runtime.APPS:
        raise runtime.Refusal("unknown app %r" % args.app)
    sdir = runtime.state_dir(token)
    runtime.prepare_state_dir(sdir)
    cmd = [sys.executable, runtime.PRODUCER, "--report", attach_report_path(token, runtime), "--token", token]
    plan = {"schema": 1, "token": token, "app": args.app, "bundleId": runtime.APPS[args.app]["bundleId"],
            "planCreatedAtEpoch": time.time(), "planCreatedMonotonic": time.monotonic(),
            "producerCommand": cmd, "reportPath": attach_report_path(token, runtime)}
    write_new_json(os.path.join(sdir, PLAN_NAME), plan)
    print(json.dumps({**plan, "stateDir": sdir, "launches": False,
                      "instructions": "Nothing was launched or typed. Start a NEW dedicated process of the app now "
                                      "(not your daily terminal; a pre-existing process is refused), run "
                                      "producerCommand in it by hand, then run attach.",
                      "attachRequires": [runtime.AUTH_ENV + "=<token>", "--owner-pid", "--window-id",
                                         "--attest-new-disposable-process"]}, indent=2))


def cmd_attach(args, runtime):
    token = runtime.validate_token(args.token)
    if os.environ.get(runtime.AUTH_ENV) != token:
        raise runtime.Refusal("not authorized: set %s=<token> after Main approves attaching" % runtime.AUTH_ENV)
    if not args.attest_new_disposable_process:
        raise runtime.Refusal("--attest-new-disposable-process is required (operator asserts a new disposable process)")
    if args.window_id is None:
        raise runtime.Refusal("--window-id is mandatory")
    if args.app not in runtime.APPS:
        raise runtime.Refusal("unknown app %r" % args.app)
    spec = runtime.APPS[args.app]
    exe, _version = runtime.check_bundle(args.app)
    sdir = runtime.state_dir(token)
    for p in (os.path.join(runtime.REPO, ".dev"), runtime.STATE_ROOT, sdir, os.path.join(sdir, PLAN_NAME)):
        if os.path.islink(p):
            raise runtime.Refusal("refusing symlinked path " + p)
    if os.path.realpath(sdir) != os.path.join(os.path.realpath(runtime.STATE_ROOT), token):
        raise runtime.Refusal("state dir is not token-owned under the fixture root")
    plan = runtime.read_json(os.path.join(sdir, PLAN_NAME))
    if not plan or plan.get("token") != token or plan.get("app") != args.app or plan.get("schema") != 1 \
            or not isinstance(plan.get("planCreatedAtEpoch"), (int, float)):
        raise runtime.Refusal("no valid attach-plan for this token/app; run attach-plan first (plan is never recreated here)")
    if os.path.exists(os.path.join(sdir, "state.json")):
        raise runtime.Refusal("already attached/launched; run cleanup")
    owner = runtime.ps_info(args.owner_pid)
    if not owner or exe not in owner[1]:
        raise runtime.Refusal("owner pid %d is not a running process of %s (%s)" % (args.owner_pid, args.app, exe))
    owner_start = lstart_epoch(owner[0])
    if owner_start is None or owner_start <= plan["planCreatedAtEpoch"]:
        raise runtime.Refusal("owner process did not start strictly after the plan (existing/daily instance or unparseable "
                      "start time); start a new dedicated process after attach-plan")
    rep = runtime.read_json(attach_report_path(token, runtime))
    if not rep or rep.get("token") != token or rep.get("state") != "running":
        raise runtime.Refusal("no running producer report for token; producer must be started by the user first")
    if time.time() - rep.get("updatedAtEpoch", 0) > runtime.REPORT_FRESH_SECONDS:
        raise runtime.Refusal("producer report is stale")
    pinfo = runtime.ps_info(rep["pid"])
    if not pinfo or token not in pinfo[1] or runtime.PRODUCER not in pinfo[1]:
        raise runtime.Refusal("report pid is not a live terminal_public_producer.py process for this token")
    if not runtime.is_descendant(rep["pid"], args.owner_pid):
        raise runtime.Refusal("producer is not a descendant of owner pid %d; ownership not proven (fail closed)" % args.owner_pid)
    state = {"schema": 2, "token": token, "app": args.app, "bundleId": spec["bundleId"], "attached": True,
             "emulatorPid": args.owner_pid, "emulatorLstart": owner[0], "executable": exe,
             "producerPid": rep["pid"], "producerLstart": pinfo[0], "reportPath": attach_report_path(token, runtime),
             "claimedWindowId": args.window_id, "launchedAtEpoch": time.time(),
             "fixtureAttestation": ATTEST_VALUE, "dailyInstanceReused": False,
             "attestationKind": "operator-asserted; machine-checked only: owner start > plan time, producer descendant",
             "planCreatedAtEpoch": plan["planCreatedAtEpoch"], "planCreatedMonotonic": plan.get("planCreatedMonotonic"),
             "ownerStartEpoch": owner_start,
             "ownershipProof": "plan-before-owner-start;owner-command-contains-bundle-executable;"
                               "producer-command-token;producer-descendant-of-owner"}
    write_new_json(os.path.join(sdir, "state.json"), state)
    print(json.dumps({"attached": True, "handoff": runtime.build_handoff(state)}, sort_keys=True))
