#!/usr/bin/env python3
"""Public terminal fixture producer.

A real program meant to run as the child process of a fixture-owned terminal
emulator. It draws canned public text (ASCII, Unicode, wrapping, a full-screen
TUI, and a dynamically updating line), enables DECSET 1004 focus reporting and
counts focus-in / focus-out reports.

Privacy contract: every other byte received on stdin is discarded and only its
COUNT is recorded. Neither key values nor terminal content are ever stored.
The report file contains scene names, counters, sizes and owned process ids.

Report schema (version 1), written atomically as JSON to --report:
  schema, token, pid, ppid, pgid, tty, state(running|exited), scene,
  sceneIndex, sceneChanges, renderCount, focusIn, focusOut, focusReportingEnabled,
  discardedInputBytes, cols, rows, startedAtEpoch, updatedAtEpoch
"""

import argparse
import json
import os
import select
import signal
import sys
import termios
import time
import tty

SCHEMA = 1
SCENES = ("static", "unicode", "wrap", "tui", "dynamic")
FOCUS_IN = b"\x1b[I"
FOCUS_OUT = b"\x1b[O"


class FocusCounter:
    """Counts DECSET 1004 reports; discards all other input, keeping only a byte count."""

    def __init__(self):
        self.focus_in = 0
        self.focus_out = 0
        self.discarded = 0
        self._pending = b""

    def feed(self, data):
        buf = self._pending + data
        self._pending = b""
        i = 0
        n = len(buf)
        while i < n:
            if buf[i] != 0x1B:
                self.discarded += 1
                i += 1
                continue
            rest = buf[i:i + 3]
            if rest == FOCUS_IN:
                self.focus_in += 1
                i += 3
            elif rest == FOCUS_OUT:
                self.focus_out += 1
                i += 3
            elif len(rest) < 3 and (FOCUS_IN.startswith(rest) or FOCUS_OUT.startswith(rest)):
                self._pending = rest  # possible split report; keep at most 2 bytes
                i = n
            else:
                self.discarded += 1
                i += 1


class Producer:
    def __init__(self, args):
        self.args = args
        self.focus = FocusCounter()
        self.scene_index = 0
        self.scene_changes = 0
        self.render_count = 0
        self.alt_screen = False
        self.started = time.time()
        self.stop = False
        self.tick = 0
        self.last_report = 0.0
        self.dirty = True

    # --- output -----------------------------------------------------------
    def out(self, text):
        os.write(1, text.encode("utf-8"))

    def size(self):
        try:
            s = os.get_terminal_size(1)
            return s.columns, s.lines
        except OSError:
            return 0, 0

    @property
    def scene(self):
        return SCENES[self.scene_index % len(SCENES)]

    def set_alt(self, on):
        if on and not self.alt_screen:
            self.out("\x1b[?1049h")
        elif not on and self.alt_screen:
            self.out("\x1b[?1049l")
        self.alt_screen = on

    def render(self):
        cols, rows = self.size()
        cols = cols or 80
        rows = rows or 24
        scene = self.scene
        self.set_alt(scene == "tui")
        self.out("\x1b[2J\x1b[H")
        tag = "DT-FIXTURE " + self.args.token
        if scene == "static":
            lines = [
                tag,
                "Scene: static",
                "The quick brown fox jumps over the lazy dog.",
                "Translate this sentence: Please open the settings panel.",
                "Error: connection refused (public canned text).",
                "$ echo hello world",
                "hello world",
            ]
            self.out("\r\n".join(lines) + "\r\n")
        elif scene == "unicode":
            lines = [
                tag,
                "Scene: unicode",
                "\u4f60\u597d\uff0c\u4e16\u754c \u2014 \u7ec8\u7aef\u7ffb\u8bd1\u6d4b\u8bd5",
                "\u3053\u3093\u306b\u3061\u306f\u3001\u7aef\u672b\u30c6\u30b9\u30c8",
                "\ud55c\uad6d\uc5b4 \ud130\ubbf8\ub110 \ud14c\uc2a4\ud2b8",
                "caf\u00e9 / cafe\u0301 (combining) / na\u00efve / \u00dcber",
                "Symbols: \u2713 \u2717 \u2192 \u2593 \u2551 \u2603 \U0001F642 \U0001F680",
            ]
            self.out("\r\n".join(lines) + "\r\n")
        elif scene == "wrap":
            words = ("wrapping fixture sentence number %d should soft wrap across columns " % k for k in range(1, 40))
            long_line = "".join(words)[: cols * 4 + 7]
            self.out(tag + "\r\nScene: wrap\r\n" + long_line + "\r\n")
            cjk = "\u4e2d\u6587\u5b57\u7b26\u6362\u884c\u6d4b\u8bd5" * ((cols // 4) + 3)
            self.out(cjk + "\r\n")
        elif scene == "tui":
            w = min(cols, 60)
            h = min(rows, 12)
            self.out("\x1b[1;1H")
            self.out("\u250c" + "\u2500" * (w - 2) + "\u2510")
            for r in range(2, h):
                text = {2: " DT-FIXTURE TUI", 3: " Scene: tui", 4: " [F1] Help  [F2] Settings  [q] Quit"}.get(r, "")
                text = (text + " " * (w - 2))[: w - 2]
                self.out("\x1b[%d;1H\u2502%s\u2502" % (r, text))
            self.out("\x1b[%d;1H\u2514" % h + "\u2500" * (w - 2) + "\u2518")
            self.draw_tui_status(w, h)
        elif scene == "dynamic":
            self.out(tag + "\r\nScene: dynamic\r\n\r\n")
            self.draw_dynamic()
        self.render_count += 1
        self.dirty = True

    def draw_tui_status(self, w, h):
        pct = (self.tick * 7) % 101
        bar_w = max(w - 14, 4)
        fill = bar_w * pct // 100
        self.out("\x1b[%d;3H" % (h - 1) + ("Progress %3d%% [" % pct) + "#" * fill + "." * (bar_w - fill) + "]")

    def draw_dynamic(self):
        self.out("\r\x1b[2KTick %d: build progress %d%%" % (self.tick, (self.tick * 3) % 101))

    def update_dynamic(self):
        self.tick += 1
        if self.scene == "dynamic":
            self.draw_dynamic()
        elif self.scene == "tui":
            w = min(self.size()[0] or 80, 60)
            h = min(self.size()[1] or 24, 12)
            self.draw_tui_status(w, h)
        self.dirty = True

    # --- report -----------------------------------------------------------
    def write_report(self, state):
        cols, rows = self.size()
        doc = {
            "schema": SCHEMA,
            "token": self.args.token,
            "pid": os.getpid(),
            "ppid": os.getppid(),
            "pgid": os.getpgrp(),
            "tty": os.ttyname(1) if os.isatty(1) else None,
            "state": state,
            "scene": self.scene,
            "sceneIndex": self.scene_index,
            "sceneChanges": self.scene_changes,
            "renderCount": self.render_count,
            "focusIn": self.focus.focus_in,
            "focusOut": self.focus.focus_out,
            "focusReportingEnabled": True,
            "discardedInputBytes": self.focus.discarded,
            "cols": cols,
            "rows": rows,
            "startedAtEpoch": self.started,
            "updatedAtEpoch": time.time(),
        }
        tmp = self.args.report + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, sort_keys=True)
        os.replace(tmp, self.args.report)
        self.last_report = time.monotonic()
        self.dirty = False

    # --- main loop --------------------------------------------------------
    def run(self):
        fd = 0
        saved = termios.tcgetattr(fd)
        signal.signal(signal.SIGTERM, self.on_signal)
        signal.signal(signal.SIGHUP, self.on_signal)
        signal.signal(signal.SIGINT, self.on_signal)
        try:
            tty.setcbreak(fd)  # ISIG stays on so the owner can interrupt
            self.out("\x1b]2;DT-Fixture-%s\x07" % self.args.token)
            self.out("\x1b[?1004h")
            if self.args.scene != "cycle":
                self.scene_index = SCENES.index(self.args.scene)
            self.render()
            self.write_report("running")
            next_scene = time.monotonic() + self.args.scene_interval
            next_tick = time.monotonic() + 0.5
            deadline = time.monotonic() + self.args.duration if self.args.duration > 0 else None
            while not self.stop:
                ready, _, _ = select.select([fd], [], [], 0.1)
                if ready:
                    data = os.read(fd, 4096)
                    if not data:
                        break
                    before = (self.focus.focus_in, self.focus.focus_out, self.focus.discarded)
                    self.focus.feed(data)
                    if before != (self.focus.focus_in, self.focus.focus_out, self.focus.discarded):
                        self.dirty = True
                now = time.monotonic()
                if self.args.scene == "cycle" and now >= next_scene:
                    self.scene_index += 1
                    self.scene_changes += 1
                    self.render()
                    next_scene = now + self.args.scene_interval
                if now >= next_tick:
                    self.update_dynamic()
                    next_tick = now + 0.5
                if self.dirty or now - self.last_report >= 1.0:
                    self.write_report("running")
                if deadline is not None and now >= deadline:
                    break
        finally:
            try:
                self.out("\x1b[?1004l")
                self.set_alt(False)
                termios.tcsetattr(fd, termios.TCSADRAIN, saved)
            finally:
                self.write_report("exited")

    def on_signal(self, _signum, _frame):
        self.stop = True


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--report", required=True, help="path of the JSON identity/count report")
    p.add_argument("--token", required=True, help="fixture token (A-Za-z0-9-)")
    p.add_argument("--scene", default="cycle", choices=("cycle",) + SCENES)
    p.add_argument("--scene-interval", type=float, default=3.0)
    p.add_argument("--duration", type=float, default=0.0, help="seconds; 0 = until signalled")
    args = p.parse_args(argv)
    if not args.token or any(not (c.isalnum() or c == "-") or ord(c) > 127 for c in args.token):
        print("token must be ASCII alphanumeric or hyphen", file=sys.stderr)
        return 2
    if not (os.isatty(0) and os.isatty(1)):
        print("producer requires a terminal on stdin/stdout", file=sys.stderr)
        return 2
    Producer(args).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
