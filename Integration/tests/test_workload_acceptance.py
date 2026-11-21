"""The workload acceptance runner must reach no guest without opt-in, hardware and its own gateway."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
RUNNER = HERE.parent / "scripts" / "workload-acceptance.py"
SPEC = importlib.util.spec_from_file_location("test_start_acceptance", HERE / "test_start_acceptance.py")
start_tests = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(start_tests)
SPEC = importlib.util.spec_from_file_location("workload_acceptance", RUNNER)
workload = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workload)


def started_state(root, url="https://127.0.0.1:61000"):
    state = root / "state"
    (state / "server").mkdir(parents=True, mode=0o700)
    (state / "server" / "endpoint.json").write_text(json.dumps({"url": url, "certificate": "x"}))
    client = root / "client"
    client.mkdir(mode=0o700)
    return state, client


def fake_incus(root, addr):
    """Records every invocation; `remote list` names the remote at `addr`."""
    incus = root / "incus"
    log = root / "incus-calls"
    remotes = json.dumps({"accept": {"Addrs": [addr], "Protocol": "incus"}})
    incus.write_text(f"#!/bin/sh\necho \"$*\" >> '{log}'\n"
                     f"if [ \"$1\" = remote ]; then echo '{remotes}'; exit 0; fi\nexit 1\n")
    incus.chmod(0o755)
    return incus, log


class WorkloadAcceptanceTests(unittest.TestCase):
    def arguments(self, root, state, client, incus, *extra):
        return [sys.executable, str(RUNNER), *extra, "--state-dir", str(state), "--prefix",
                str(root / "prefix"), "--incus-conf", str(client), "--incus", str(incus),
                "--remote", "accept", "--report", str(root / "report.json")]

    def test_without_opt_in_nothing_is_read_written_or_run(self):
        with tempfile.TemporaryDirectory(prefix="mwa", dir="/tmp") as folder:
            root = Path(folder)
            start_tests.installed_pair(root / "prefix")
            state, client = started_state(root)
            incus, log = fake_incus(root, "https://127.0.0.1:61000")
            sentinel = root / "macus-ran"
            result = subprocess.run(
                self.arguments(root, state, client, incus, "--hardware"), text=True,
                capture_output=True, timeout=60,
                env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("without --opt-in", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists() or (root / "report.json").exists())

    def test_without_hardware_the_guest_is_not_reached(self):
        with tempfile.TemporaryDirectory(prefix="mwa", dir="/tmp") as folder:
            root = Path(folder)
            start_tests.installed_pair(root / "prefix")
            state, client = started_state(root)
            incus, log = fake_incus(root, "https://127.0.0.1:61000")
            sentinel = root / "macus-ran"
            result = subprocess.run(
                self.arguments(root, state, client, incus, "--opt-in"), text=True,
                capture_output=True, timeout=60,
                env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Hardware acceptance was not run", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists())
            data = json.loads((root / "report.json").read_text())
            self.assertFalse(data["hardware_ran"])
            self.assertEqual(data["pair"]["revision"], start_tests.REVISION)

    def test_a_remote_that_is_not_this_states_gateway_is_refused_before_any_change(self):
        with tempfile.TemporaryDirectory(prefix="mwa", dir="/tmp") as folder:
            root = Path(folder)
            start_tests.installed_pair(root / "prefix")
            state, client = started_state(root)
            incus, log = fake_incus(root, "https://127.0.0.1:8443")
            sentinel = root / "macus-ran"
            result = subprocess.run(
                self.arguments(root, state, client, incus, "--opt-in", "--hardware"), text=True,
                capture_output=True, timeout=60,
                env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not this state's gateway", result.stderr)
            self.assertEqual(log.read_text().splitlines(), ["remote list --format json"])
            self.assertFalse(sentinel.exists())
            data = json.loads((root / "report.json").read_text())
            self.assertFalse(data["success"])
            self.assertFalse(data["hardware_ran"])

    def test_the_ordinary_client_configuration_and_state_are_refused(self):
        with tempfile.TemporaryDirectory(prefix="mwa", dir="/tmp") as folder:
            root = Path(folder)
            state, client = started_state(root)
            incus, log = fake_incus(root, "https://127.0.0.1:61000")
            for label, chosen_state, chosen_client in (
                    ("client", state, Path.home() / ".config" / "incus"),
                    ("state", Path.home() / ".tama" / "incus-mac", client)):
                with self.subTest(label=label):
                    result = subprocess.run(
                        self.arguments(root, chosen_state, chosen_client, incus, "--opt-in",
                                       "--hardware"), text=True, capture_output=True, timeout=60)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Refusing", result.stderr)
                    self.assertFalse(log.exists() or (root / "report.json").exists())

    def test_the_guest_checks_cover_the_task(self):
        for check in ("native_exec", "native_console", "native_events", "binary_transfers",
                      "mcp_shared_operations", "mcp_runtime_operations", "denied_scopes",
                      "denied_confirmations", "denied_native_credentials", "guest_unaffected"):
            self.assertIn(check, workload.GUEST_CHECKS)


if __name__ == "__main__":
    unittest.main()
