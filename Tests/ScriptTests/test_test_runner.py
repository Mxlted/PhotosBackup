"""Regression coverage for CI simulator startup and bounded process cleanup."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


selector = load_script("select-simulator")
bounded = load_script("run-bounded")


def phone(identifier, **overrides):
    return dict(name="iPhone 17 Pro", udid=identifier, isAvailable=True,
                state="Shutdown", **overrides)


def inventory(**runtimes):
    return {"devices": {f"com.apple.CoreSimulator.SimRuntime.iOS-{version}": devices
                        for version, devices in runtimes.items()}}


class SimulatorSelectionTests(unittest.TestCase):
    def select(self, devices, sdk="26.2"):
        with contextlib.redirect_stderr(io.StringIO()):
            return selector.select_simulator(devices, sdk)

    def test_old_runtime_first_does_not_win_over_matching_sdk(self):
        devices = inventory(**{"18-5": [phone("old")], "26-2": [phone("matching")]})
        self.assertEqual(self.select(devices), "matching")

    def test_chooses_latest_compatible_minor_numerically(self):
        devices = inventory(**{"26-2": [phone("older")], "26-10": [phone("latest")],
                               "26-11": [phone("too-new")]})
        self.assertEqual(self.select(devices, "26.10"), "latest")

    def test_ignores_unavailable_non_iphone_and_non_ios_devices(self):
        unavailable = {**phone("unavailable"), "isAvailable": False}
        ipad = {**phone("tablet"), "name": "iPad Pro"}
        devices = inventory(**{"26-2": [unavailable, ipad, phone("iphone")]})
        devices["devices"]["com.apple.CoreSimulator.SimRuntime.tvOS-26-2"] = [phone("tv")]
        self.assertEqual(self.select(devices), "iphone")

    def test_prefers_already_booted_iphone_on_same_runtime(self):
        booted = {**phone("booted"), "state": "Booted"}
        devices = inventory(**{"26-2": [phone("cold"), booted]})
        self.assertEqual(self.select(devices), "booted")

    def test_uses_older_minor_when_matching_major_is_available(self):
        devices = inventory(**{"18-5": [phone("old-major")], "26-1": [phone("compatible")]})
        self.assertEqual(self.select(devices), "compatible")

    def test_missing_compatible_runtime_fails_without_silent_fallback(self):
        devices = inventory(**{"18-5": [phone("old")], "26-3": [phone("newer-sdk")]})
        with self.assertRaisesRegex(ValueError, "Install a matching runtime"):
            self.select(devices)

    def test_cli_stdout_contains_only_destination_uuid(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "select-simulator.py"),
                                 "--sdk", "26.2"], text=True, capture_output=True,
                                input=json.dumps(inventory(**{"26-2": [phone("chosen")]})))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "chosen\n")
        self.assertIn("iOS 26.2", result.stderr)

    def test_cli_missing_runtime_exits_with_actionable_message(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "select-simulator.py"),
                                 "--sdk", "26.2"], text=True, capture_output=True, input='{"devices": {}}')
        self.assertEqual(result.returncode, 1)
        self.assertIn("pass a simulator UUID explicitly", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


class BoundedProcessTests(unittest.TestCase):
    def run_phase(self, code, timeout=2):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = bounded.run([sys.executable, "-c", code], timeout=timeout,
                                 label="Fixture", heartbeat=0.1, grace=0.1)
        return status, output.getvalue()

    def test_propagates_success_and_failure(self):
        for status in (0, 7):
            with self.subTest(status=status):
                self.assertEqual(self.run_phase(f"raise SystemExit({status})")[0], status)

    def test_reports_progress_for_silent_process(self):
        status, output = self.run_phase("import time; time.sleep(0.3)")
        self.assertEqual(status, 0)
        self.assertIn("still running", output)

    def test_timeout_kills_process_that_ignores_termination(self):
        started = time.monotonic()
        status, output = self.run_phase(
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
            timeout=0.5)
        self.assertEqual(status, 124)
        self.assertIn("exceeded", output)
        self.assertLess(time.monotonic() - started, 5)

    def test_cancellation_kills_descendants_after_parent_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_path = Path(directory) / "child.pid"
            code = f"""import os,signal,time
from pathlib import Path
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    Path({str(pid_path)!r}).write_text(str(os.getpid()))
while True:
    time.sleep(1)
"""
            runner = subprocess.Popen(
                [sys.executable, str(SCRIPTS / "run-bounded.py"), "--timeout", "10",
                 "--label", "Cancellation fixture", sys.executable, "-c", code],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while not pid_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(pid_path.exists(), "Child process did not start")
                child_pid = int(pid_path.read_text())
                runner.send_signal(signal.SIGTERM)
                stdout, stderr = runner.communicate(timeout=5)
                self.assertEqual(runner.returncode, 143, stdout + stderr)
                # A reaped process or a non-running zombie both prove the child
                # cannot continue holding simulator/test resources.
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    state = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="],
                                           text=True, capture_output=True).stdout.strip()
                    if not state or state.startswith("Z"):
                        break
                    time.sleep(0.02)
                self.assertTrue(not state or state.startswith("Z"), f"Child still running: {state}")
            finally:
                if runner.poll() is None:
                    runner.kill()
                runner.communicate()
                if child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
