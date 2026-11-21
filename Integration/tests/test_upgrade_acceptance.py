"""The upgrade acceptance runner must stop, install and unload nothing without both opt-ins."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
RUNNER = HERE.parent / "scripts" / "upgrade-acceptance.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


start_tests = load("test_start_acceptance", HERE / "test_start_acceptance.py")
workload_tests = load("test_workload_acceptance", HERE / "test_workload_acceptance.py")
upgrade = load("upgrade_acceptance", RUNNER)
OLD, NEW = "b" * 40, "c" * 40


class UpgradeAcceptanceTests(unittest.TestCase):
    def prepared(self, root, old=OLD, new=NEW):
        start_tests.installed_pair(root / "old", revision=old, release_revision=old)
        start_tests.installed_pair(root / "new", revision=new, release_revision=new)
        state, client = workload_tests.started_state(root)
        incus, log = workload_tests.fake_incus(root, "https://127.0.0.1:61000")
        return state, client, incus, log

    def run_runner(self, root, state, client, incus, *extra):
        sentinel = root / "macus-ran"
        lock = upgrade.ROOT / "server" / "mix.lock"
        result = subprocess.run(
            [sys.executable, str(RUNNER), *extra, "--state-dir", str(state), "--package-root",
             str(root / "package"), "--old-candidate", str(root / "old"), "--new-candidate",
             str(root / "new"), "--old-lock", str(lock), "--incus-conf", str(client),
             "--incus", str(incus), "--remote", "accept", "--report", str(root / "report.json")],
            text=True, capture_output=True, timeout=60,
            env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
        return result, sentinel

    def test_without_opt_in_nothing_is_read_written_or_run(self):
        with tempfile.TemporaryDirectory(prefix="mup", dir="/tmp") as folder:
            root = Path(folder)
            state, client, incus, log = self.prepared(root)
            result, sentinel = self.run_runner(root, state, client, incus, "--hardware")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("without --opt-in", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists() or (root / "report.json").exists()
                             or (root / "package").exists())

    def test_without_hardware_only_the_candidates_are_checked(self):
        with tempfile.TemporaryDirectory(prefix="mup", dir="/tmp") as folder:
            root = Path(folder)
            state, client, incus, log = self.prepared(root)
            result, sentinel = self.run_runner(root, state, client, incus, "--opt-in")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Hardware acceptance was not run", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists() or (root / "package").exists())
            report = upgrade.json.loads((root / "report.json").read_text())
            self.assertFalse(report["hardware_ran"])
            self.assertEqual(report["evidence"]["package"]["old"]["revision"], OLD)
            self.assertEqual(report["evidence"]["package"]["new"]["revision"], NEW)

    def test_two_candidates_of_one_revision_are_refused(self):
        with tempfile.TemporaryDirectory(prefix="mup", dir="/tmp") as folder:
            root = Path(folder)
            state, client, incus, log = self.prepared(root, new=OLD)
            result, _ = self.run_runner(root, state, client, incus, "--opt-in", "--hardware")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("same revision", result.stderr)
            self.assertFalse(log.exists() or (root / "package").exists())

    def test_ordinary_package_roots_are_refused(self):
        home = Path.home()
        for path in (Path("relative/root"), Path("/opt/homebrew/macus-test"), Path("/usr/local/x"),
                     home, home / ".tama" / "pkg", home / "Library" / "pkg"):
            with self.assertRaises(SystemExit, msg=str(path)):
                upgrade.package_root(path)
        self.assertEqual(upgrade.package_root(Path("/tmp/macus-pkg-test")), Path("/tmp/macus-pkg-test"))

    def test_kegs_switch_through_the_stable_opt_link_and_removal_leaves_nothing(self):
        with tempfile.TemporaryDirectory(prefix="mup", dir="/tmp") as folder:
            root = Path(folder)
            start_tests.installed_pair(root / "old", revision=OLD, release_revision=OLD)
            start_tests.installed_pair(root / "new", revision=NEW, release_revision=NEW)
            pairs = {name: upgrade.start.installed_pair(root / name) for name in ("old", "new")}
            package = upgrade.Package(root / "package")
            old = package.install(root / "old", pairs["old"], None)
            self.assertEqual(old["binary"], str(root / "package/opt/macus/bin/macus"))
            self.assertEqual(Path(old["keg"]).name, f"0.1.0_{OLD[:12]}")
            new = package.install(root / "new", pairs["new"], None)
            self.assertEqual(new["binary"], old["binary"])
            self.assertEqual(package.binary.resolve(), (Path(new["keg"]) / "bin/macus").resolve())
            self.assertTrue(Path(old["keg"]).is_dir(), "the earlier keg is kept for rollback")
            self.assertEqual(package.install(root / "old", pairs["old"], None)["revision"], OLD)
            self.assertEqual(package.binary.resolve(), (Path(old["keg"]) / "bin/macus").resolve())
            package.remove()
            self.assertFalse(package.installed())
            self.assertEqual(list((root / "package").iterdir()), [])
            self.assertTrue((root / "old/bin/macus").is_file(), "candidates are never removed")

    def test_the_sequence_upgrades_rolls_back_removes_and_reinstalls(self):
        names = [name for name, _ in upgrade.TRANSITIONS]
        self.assertEqual(names, ["adopt", "upgrade", "rollback", "upgrade_again", "removal",
                                 "reinstall"])
        self.assertEqual(dict(upgrade.TRANSITIONS)["rollback"], "old")
        self.assertIsNone(dict(upgrade.TRANSITIONS)["removal"])


if __name__ == "__main__":
    unittest.main()
