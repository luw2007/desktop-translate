"""Safe terminal-fixture contract checks; only owned PTYs and an isolated state root.

Run after the development source is declared ready:
    python3 -m unittest discover -s app/tests -p test_terminal_fixture.py
No terminal emulator, ScreenCaptureKit, permissions, activation, or daily app is involved.
"""
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "fixtures"
sys.path.insert(0, str(FIXTURES))
import terminal_fixture_launcher as launcher  # noqa: E402
import terminal_public_producer as producer  # noqa: E402


class LauncherCLIEntryChecks(unittest.TestCase):
    def test_entry_point_fails_closed_without_touching_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(launcher, "REPO", str(root)), \
                 mock.patch.object(launcher, "STATE_ROOT", str(root / ".dev" / "terminal-fixtures")), \
                 contextlib.redirect_stdout(io.StringIO()) as output, \
                 contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(launcher.main(["attach-plan", "--app", "terminal", "--token", "cli-public"]), 0)
                plan = json.loads(output.getvalue())
                self.assertIs(plan["launches"], False)
                self.assertEqual(plan["reportPath"], str(root / ".dev" / "terminal-fixtures" / "cli-public" / "report.json"))
                plan_path = root / ".dev" / "terminal-fixtures" / "cli-public" / "attach-plan.json"
                self.assertEqual(json.loads(plan_path.read_text())["planCreatedAtEpoch"], plan["planCreatedAtEpoch"])
                self.assertEqual(plan_path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(launcher.main(["attach-plan", "--app", "terminal", "--token", "cli-public"]), 3)
                self.assertEqual(json.loads(plan_path.read_text())["planCreatedAtEpoch"], plan["planCreatedAtEpoch"])
                with mock.patch.dict(os.environ, {launcher.AUTH_ENV: "not-authorized"}):
                    self.assertEqual(launcher.main(["launch", "--app", "terminal", "--token", "cli-public"]), 3)
                self.assertIn('"refused": true', errors.getvalue())
                for app in ("cmux", "iterm2", "terminal"):
                    with self.subTest(app=app):
                        self.assertEqual(launcher.main(["plan", "--app", app, "--token", "cli-public"]), 3)
                self.assertIn("unsupported-safe-launch", errors.getvalue())
                self.assertFalse((root / ".dev" / "terminal-fixtures" / "cli-public" / "state.json").exists())
                symlink = root / ".dev" / "terminal-fixtures" / "cli-symlink"
                symlink.symlink_to(root, target_is_directory=True)
                self.assertEqual(launcher.main(["attach-plan", "--app", "terminal", "--token", "cli-symlink"]), 3)
                self.assertIn("symlinked path", errors.getvalue())



class ProducerChecks(unittest.TestCase):
    def test_real_producer_on_owned_pty_all_public_scenes(self):
        token = "terminal-test-public"
        for scene in producer.SCENES:
            with self.subTest(scene=scene), tempfile.TemporaryDirectory() as directory:
                report_path = Path(directory) / "report.json"
                master, slave = os.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 800, 480))
                os.set_blocking(master, False)
                args = [sys.executable, str(FIXTURES / "terminal_public_producer.py"),
                        "--report", str(report_path), "--token", token,
                        "--scene", scene, "--duration", "1.3"]
                child = None
                try:
                    child = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                                             start_new_session=True)
                    os.close(slave)
                    slave = -1
                    output = bytearray()
                    sent = False
                    first_running = None
                    deadline = time.monotonic() + 6
                    while time.monotonic() < deadline:
                        try:
                            while True:
                                chunk = os.read(master, 65536)
                                if not chunk:
                                    break
                                output.extend(chunk)
                        except (BlockingIOError, OSError):
                            pass  # The child either has no output yet or has closed its owned PTY.
                        if report_path.exists():
                            report = json.loads(report_path.read_text())
                            if report["state"] == "running":
                                if first_running is None:
                                    first_running = report
                                    info = launcher.ps_info(child.pid)
                                    self.assertIsNotNone(info)
                                    self.assertTrue(launcher.verified(child.pid, info[0], token))
                                    self.assertTrue(launcher.is_descendant(child.pid, os.getpid()))
                                    self.assertEqual(report["ppid"], os.getpid())
                                    self.assertEqual(report["pgid"], child.pid)
                                if scene == "static" and not sent:
                                    os.write(master, b"\x1b[I\x1b[Opublic")
                                    sent = True
                        if child.poll() is not None:
                            break
                        time.sleep(0.025)
                    # Read the last bytes the owned child wrote before closing its PTY.
                    try:
                        while True:
                            chunk = os.read(master, 65536)
                            if not chunk:
                                break
                            output.extend(chunk)
                    except (BlockingIOError, OSError):
                        pass
                    self.assertIsNotNone(child.poll(), "Only our own producer must finish on its timeout")
                    self.assertEqual(child.returncode, 0, bytes(output[-1200:]))
                    self.assertIsNotNone(first_running, "Must observe a real running report, not a fabricated report")
                    final = json.loads(report_path.read_text())
                    self.assertEqual(final["schema"], 2)
                    self.assertEqual(final["state"], "exited")
                    self.assertEqual(final["scenarioMode"], "fixed")
                    self.assertEqual(final["scene"], scene)
                    self.assertEqual(final["pid"], child.pid)
                    self.assertEqual(final["token"], token)
                    self.assertEqual((final["cols"], final["rows"]), (80, 24))
                    self.assertEqual((final["xpixel"], final["ypixel"]), (800, 480))
                    self.assertGreaterEqual(final["renderCount"], 1)
                    self.assertEqual(final["sceneChanges"], 0)
                    self.assertTrue(final["focusReportingEnabled"])
                    self.assertGreaterEqual(final["updatedAtEpoch"], final["startedAtEpoch"])
                    self.assertIn(("Scene: " + scene).encode(), output)
                    if scene == "unicode":
                        self.assertIn("你好".encode(), output)
                    if scene == "tui":
                        self.assertIn(b"\x1b[?1049h", output)
                        self.assertIn(b"\x1b[?1049l", output)
                    if scene == "dynamic":
                        self.assertIn(b"Tick ", output)
                        self.assertGreater(final["revision"], first_running["revision"])
                    if scene == "static":
                        self.assertTrue(sent)
                        self.assertEqual((final["focusIn"], final["focusOut"]), (1, 1))
                        self.assertEqual(final["discardedInputBytes"], len(b"public"))
                finally:
                    if child is not None and child.poll() is None:
                        child.terminate()  # Only the fixture child created by this test.
                        try:
                            child.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
