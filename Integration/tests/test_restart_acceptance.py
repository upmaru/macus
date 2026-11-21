"""The restart acceptance runner must restart nothing without opt-in, hardware and its own gateway."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
RUNNER = HERE.parent / "scripts" / "restart-acceptance.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


start_tests = load("test_start_acceptance", HERE / "test_start_acceptance.py")
workload_tests = load("test_workload_acceptance", HERE / "test_workload_acceptance.py")
restart = load("restart_acceptance", RUNNER)


def started_state(root, url="https://127.0.0.1:61000"):
    state, client = workload_tests.started_state(root, url)
    (state / "server" / "gateway.json").write_text(json.dumps({"schema_version": 1, "port": 61000}))
    return state, client


IDENTITY = {"runtime_pid": 10, "server_pid": 20, "runtime_state": "ready", "uptime_seconds": 100,
            "guest_boot_id": "boot", "instance_uuid": "uuid", "instance_status": "Running",
            "instance_pid": 30, "marker": "macus-11.3\n"}


class RestartAcceptanceTests(unittest.TestCase):
    def arguments(self, root, state, client, incus, *extra):
        return [sys.executable, str(RUNNER), *extra, "--state-dir", str(state), "--prefix",
                str(root / "prefix"), "--incus-conf", str(client), "--incus", str(incus),
                "--remote", "accept", "--report", str(root / "report.json")]

    def run_runner(self, root, state, client, incus, *extra):
        sentinel = root / "macus-ran"
        result = subprocess.run(self.arguments(root, state, client, incus, *extra), text=True,
                                capture_output=True, timeout=60,
                                env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
        return result, sentinel

    def test_without_opt_in_nothing_is_read_written_or_run(self):
        with tempfile.TemporaryDirectory(prefix="mra", dir="/tmp") as folder:
            root = Path(folder)
            start_tests.installed_pair(root / "prefix")
            state, client = started_state(root)
            incus, log = workload_tests.fake_incus(root, "https://127.0.0.1:61000")
            result, sentinel = self.run_runner(root, state, client, incus, "--hardware")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("without --opt-in", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists() or (root / "report.json").exists())

    def test_without_hardware_nothing_is_restarted(self):
        with tempfile.TemporaryDirectory(prefix="mra", dir="/tmp") as folder:
            root = Path(folder)
            start_tests.installed_pair(root / "prefix")
            state, client = started_state(root)
            incus, log = workload_tests.fake_incus(root, "https://127.0.0.1:61000")
            result, sentinel = self.run_runner(root, state, client, incus, "--opt-in")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Hardware acceptance was not run", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists())
            data = json.loads((root / "report.json").read_text())
            self.assertFalse(data["hardware_ran"])
            self.assertEqual(data["pair"]["revision"], start_tests.REVISION)

    def test_a_remote_that_is_not_this_states_gateway_is_refused_before_any_restart(self):
        with tempfile.TemporaryDirectory(prefix="mra", dir="/tmp") as folder:
            root = Path(folder)
            start_tests.installed_pair(root / "prefix")
            state, client = started_state(root)
            incus, log = workload_tests.fake_incus(root, "https://127.0.0.1:8443")
            result, sentinel = self.run_runner(root, state, client, incus, "--opt-in", "--hardware")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not this state's gateway", result.stderr)
            self.assertEqual(log.read_text().splitlines(), ["remote list --format json"])
            self.assertFalse(sentinel.exists())
            data = json.loads((root / "report.json").read_text())
            self.assertFalse(data["success"] or data["hardware_ran"])

    def test_the_ordinary_client_configuration_and_state_are_refused(self):
        with tempfile.TemporaryDirectory(prefix="mra", dir="/tmp") as folder:
            root = Path(folder)
            state, client = started_state(root)
            incus, log = workload_tests.fake_incus(root, "https://127.0.0.1:61000")
            for label, chosen_state, chosen_client in (
                    ("client", state, Path.home() / ".config" / "incus"),
                    ("state", Path.home() / ".tama" / "incus-mac", client)):
                with self.subTest(label=label):
                    result, _ = self.run_runner(root, chosen_state, chosen_client, incus,
                                                "--opt-in", "--hardware")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Refusing", result.stderr)
                    self.assertFalse(log.exists() or (root / "report.json").exists())

    def test_only_the_server_pid_may_change_and_uptime_only_grows(self):
        retained = restart.Restart.retained
        relaunched = dict(IDENTITY, server_pid=21, uptime_seconds=130)
        retained(None, IDENTITY, relaunched, "restart")
        for change, message in (({"server_pid": 20}, "did not relaunch"),
                                ({"server_pid": None}, "did not relaunch"),
                                ({"uptime_seconds": 5}, "reset the runtime uptime"),
                                ({"runtime_pid": 11}, "runtime_pid"),
                                ({"guest_boot_id": "rebooted"}, "guest_boot_id"),
                                ({"instance_pid": 31}, "instance_pid"),
                                ({"instance_uuid": "recreated"}, "instance_uuid"),
                                ({"marker": None}, "marker")):
            with self.subTest(change=change):
                with self.assertRaisesRegex(restart.CheckFailure, message):
                    retained(None, IDENTITY, dict(relaunched, **change), "restart")

    def test_effects_are_counted_by_whole_lines(self):
        self.assertEqual(restart.count_lines("started\nfinished\nstarted\n", "started"), 2)
        self.assertEqual(restart.count_lines("restarted\n", "started"), 0)
        self.assertEqual(restart.count_lines("", "finished"), 0)

    def test_the_guest_checks_cover_the_task(self):
        for check in ("retained_workload", "running_operation_identity", "interrupted_call",
                      "crash_restart", "explicit_restart", "missing_job_recovery",
                      "no_mutation_replay", "guest_unaffected"):
            self.assertIn(check, restart.GUEST_CHECKS)


if __name__ == "__main__":
    unittest.main()
