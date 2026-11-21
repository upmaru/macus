"""The Linux acceptance runner must stop, create and launch nothing without both opt-ins."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
RUNNER = HERE.parent / "scripts" / "linux-acceptance.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


start_tests = load("test_start_acceptance", HERE / "test_start_acceptance.py")
workload_tests = load("test_workload_acceptance", HERE / "test_workload_acceptance.py")
linux = load("linux_acceptance", RUNNER)


class LinuxAcceptanceTests(unittest.TestCase):
    def prepared(self, root):
        start_tests.installed_pair(root / "prefix")
        state, client = workload_tests.started_state(root)
        incus, log = workload_tests.fake_incus(root, "https://127.0.0.1:61000")
        return state, client, incus, log

    def run_runner(self, root, state, client, incus, *extra):
        sentinel = root / "macus-ran"
        result = subprocess.run(
            [sys.executable, str(RUNNER), *extra, "--state-dir", str(state), "--prefix",
             str(root / "prefix"), "--incus-conf", str(client), "--incus", str(incus),
             "--remote", "accept", "--report", str(root / "report.json")],
            text=True, capture_output=True, timeout=60,
            env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
        return result, sentinel

    def test_without_opt_in_nothing_is_read_written_or_run(self):
        with tempfile.TemporaryDirectory(prefix="mlx", dir="/tmp") as folder:
            root = Path(folder)
            state, client, incus, log = self.prepared(root)
            result, sentinel = self.run_runner(root, state, client, incus, "--hardware")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("without --opt-in", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists() or (root / "report.json").exists())

    def test_without_hardware_only_the_pair_and_fixture_are_checked(self):
        with tempfile.TemporaryDirectory(prefix="mlx", dir="/tmp") as folder:
            root = Path(folder)
            state, client, incus, log = self.prepared(root)
            result, sentinel = self.run_runner(root, state, client, incus, "--opt-in")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Hardware acceptance was not run", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists())
            report = json.loads((root / "report.json").read_text())
            self.assertFalse(report["hardware_ran"])
            self.assertEqual(report["pair"]["revision"], start_tests.REVISION)
            self.assertEqual(sorted(w["kind"] for w in report["fixture"]["workloads"]),
                             ["oci-container", "system-container", "virtual-machine"])
            # Boot, readiness, gateway and capability evidence are kept apart.
            self.assertEqual(sorted(report["evidence"]), ["boot", "capabilities", "gateway", "readiness"])

    def test_the_checked_in_fixture_defines_all_three_workloads_in_its_own_project(self):
        spec = linux.fixture(linux.FIXTURE)
        self.assertNotEqual(spec["project"], "default")
        vm = next(entry for entry in spec["workloads"] if entry["kind"] == "virtual-machine")
        self.assertEqual(vm["requires_capability"], "vm")

    def test_incomplete_or_unsafe_fixtures_are_refused(self):
        base = json.loads(linux.FIXTURE.read_text())

        def broken(change):
            data = copy.deepcopy(base)
            change(data)
            return data

        cases = {
            "no virtual machine": broken(lambda d: d["workloads"].pop()),
            "default project": broken(lambda d: d.update(project="default")),
            "foreign OCI image": broken(lambda d: d["workloads"][1].update(image="docker:nginx")),
            "duplicate name": broken(lambda d: d["workloads"][2].update(name=d["workloads"][0]["name"])),
            "no readiness": broken(lambda d: d["workloads"][0].pop("readiness")),
            "unknown kind": broken(lambda d: d["workloads"][0].update(kind="pod")),
        }
        with tempfile.TemporaryDirectory(prefix="mlx", dir="/tmp") as folder:
            for label, data in cases.items():
                path = Path(folder) / "fixture.json"
                path.write_text(json.dumps(data))
                with self.assertRaises(linux.CheckFailure, msg=label):
                    linux.fixture(path)


if __name__ == "__main__":
    unittest.main()
