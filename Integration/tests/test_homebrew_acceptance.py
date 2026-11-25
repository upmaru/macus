import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import hashlib
import json
import os
import plistlib
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[1] / "scripts/homebrew-acceptance.py"
SPEC = importlib.util.spec_from_file_location("homebrew_acceptance", FILE)
acceptance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acceptance)


class HomebrewAcceptanceTests(unittest.TestCase):
    def test_isolated_state_gets_its_own_gateway_port(self):
        with tempfile.TemporaryDirectory() as root:
            state = Path(root) / 'state'
            port = acceptance.isolated_gateway_port(state)
            self.assertNotEqual(port, 8443)
            config = json.loads((state / 'server/gateway.json').read_text())
            self.assertEqual(config, {'schema_version': 1, 'port': port})
            self.assertEqual(acceptance.isolated_gateway_port(state), port)
            (state / 'server/gateway.json').write_text(json.dumps({'schema_version': 1, 'port': 8443}))
            with self.assertRaises(SystemExit):
                acceptance.isolated_gateway_port(state)

    def test_retry_completes_owned_marker_without_duplicate_launch(self):
        state = Path('/tmp/owned-test/state')
        value = {'name': 'macus-brew-marker', 'status': 'Running',
                 'config': {'user.macus.homebrew-acceptance': hashlib.sha256(str(state).encode()).hexdigest()}}
        with patch.object(acceptance, 'execute', side_effect=[json.dumps([value]), '']) as command:
            acceptance.ensure_marker('/incus', 'macus-brew:macus-brew-marker', {}, {}, state)
            calls = [args.args[0] for args in command.call_args_list]
            self.assertFalse(any('launch' in call for call in calls))
            self.assertEqual(calls[-1][1], 'exec')
        value['config'] = {}
        with patch.object(acceptance, 'execute', return_value=json.dumps([value])) as command:
            with self.assertRaisesRegex(ValueError, 'unrelated'):
                acceptance.ensure_marker('/incus', 'macus-brew:macus-brew-marker', {}, {}, state)
            self.assertEqual(command.call_count, 1)

    def test_resume_requires_stop_unload_and_new_candidate(self):
        with self.assertRaisesRegex(ValueError, 'stop and unload'):
            acceptance.require_upgrade({'checks': {}}, {'version': 'new'})
        report = {'checks': {'stopped_and_unloaded': True}, 'stopped_version': 'old'}
        with self.assertRaisesRegex(ValueError, 'different installed'):
            acceptance.require_upgrade(report, {'version': 'old'})
        acceptance.require_upgrade(report, {'version': 'new'})

    def test_launchd_label_matches_platform_aliases(self):
        self.assertEqual(acceptance.service_label(Path('/private/tmp/macus-brew/state')),
                         acceptance.service_label(Path('/tmp/macus-brew/state')))
        self.assertEqual(acceptance.service_label(Path('/private/var/macus-brew/state')),
                         acceptance.service_label(Path('/var/macus-brew/state')))
        self.assertNotEqual(acceptance.service_label(Path('/tmp/macus-brew/state')),
                            acceptance.service_label(Path('/tmp/other/state')))

    def test_refuses_without_opt_in_before_creating_state(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory) / "fresh"
            result = subprocess.run([sys.executable, str(FILE), "--root", str(root),
                "--candidate", "/missing", "--phase", "start"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("explicit --opt-in --hardware", result.stderr)
            self.assertFalse(root.exists())

    def test_refuses_ordinary_existing_and_relative_roots(self):
        with self.assertRaises(ValueError):
            acceptance.fixture_paths(Path.home(), first=True)
        with self.assertRaises(ValueError):
            acceptance.fixture_paths(Path("relative"), first=True)
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory)
            (root / "sentinel").write_text("preserve")
            with self.assertRaises(ValueError):
                acceptance.fixture_paths(root, first=True)
            self.assertEqual((root / "sentinel").read_text(), "preserve")

    def test_refuses_symlink_state_client_and_report(self):
        for name in ("state", "client", "hardware.json"):
            with self.subTest(name=name), tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
                root = Path(directory)
                (root / name).symlink_to(root / "outside")
                with self.assertRaisesRegex(ValueError, "symlink"):
                    acceptance.fixture_paths(root)


    def fixture(self, root):
        """An isolated state after start: disks, settings, credentials, both owned plists and a client."""
        state, client = root / "state", root / "client"
        for name in acceptance.DISKS + acceptance.SETTINGS + acceptance.CREDENTIALS:
            (state / name).parent.mkdir(parents=True, exist_ok=True)
            (state / name).write_bytes(f"secret-{hashlib.sha256(name.encode()).hexdigest()}".encode())
        (state / "server/endpoint.json").write_text('{"pid": 1}')
        (client / "servercerts").mkdir(parents=True)
        for name in ("config.yml", "client.crt", "client.key", "servercerts/macus-brew.crt"):
            (client / name).write_text(f"secret-{hashlib.sha256(name.encode()).hexdigest()}")
        runtime, server = acceptance.service_labels(state)
        (state / "launchd").mkdir()
        self.plist(state, runtime, {"ProgramArguments": ["/brew/opt/macus/bin/macus", "serve", "--state-dir", str(state)]})
        self.plist(state, server, {"ProgramArguments": ["/brew/opt/macus/libexec/macus/bin/macus", "start"],
                                   "EnvironmentVariables": {"MACUS_STATE_DIR": str(state), "MACUS_EXPECTED_REVISION": "a" * 40}})
        (state / "launchd/com.example.other.plist").write_bytes(plistlib.dumps({"Label": "com.example.other"}))
        return state, client, (runtime, server)

    def plist(self, state, label, data):
        (state / "launchd" / f"{label}.plist").write_bytes(plistlib.dumps({"Label": label, **data}))

    def stop(self, state, client, labels, transition, status="stopped"):
        report = {"checks": {}}
        replies = {"status": json.dumps({"state": status})}
        commands = []

        def execute(arguments, env, report_):
            commands.append(arguments)
            return replies["status"] if arguments[-1] == "status" else ""

        with patch.object(acceptance, "execute", side_effect=execute), \
                patch.object(acceptance, "loaded", return_value=True), \
                patch.object(acceptance, "wait_unloaded"):
            acceptance.stop_and_unload("/brew/opt/macus/bin/macus", state, client, labels, transition, {}, report)
        return report, commands

    def test_both_labels_share_the_state_hash(self):
        runtime, server = acceptance.service_labels(Path("/tmp/macus-brew/state"))
        self.assertEqual(runtime, acceptance.service_label(Path("/tmp/macus-brew/state")))
        self.assertEqual(server, runtime.replace("com.upmaru.macus.", "com.upmaru.macus.server."))

    def test_stop_unloads_the_server_then_the_runtime_and_removes_only_owned_plists(self):
        for transition, removed in (("upgrade", {1}), ("removal", {0, 1})):
            with self.subTest(transition=transition), tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
                state, client, labels = self.fixture(Path(directory))
                report, commands = self.stop(state, client, labels, transition)
                bootouts = [arguments[-1].rsplit("/", 1)[1] for arguments in commands if "bootout" in arguments]
                self.assertEqual(bootouts, [labels[1], labels[0]])
                self.assertEqual([arguments[-1] for arguments in commands[:2]], ["stop", "status"])
                for index, label in enumerate(labels):
                    self.assertEqual((state / "launchd" / f"{label}.plist").exists(), index not in removed)
                self.assertTrue((state / "launchd/com.example.other.plist").exists())
                self.assertEqual((report["transition"], report["checks"]["stopped_and_unloaded"]), (transition, True))
                # Retention evidence never carries a secret or a plain digest of one.
                text = json.dumps(report)
                for name in ("server/gateway.key", "server/local-cli.token", "client/client.key"):
                    path = state / name if name.startswith("server") else client / name.removeprefix("client/")
                    self.assertNotIn(path.read_text(), text)
                    self.assertNotIn(hashlib.sha256(path.read_bytes()).hexdigest(), text)
                self.assertNotIn("server/endpoint.json", report["retained"]["content"])
                self.assertIn("client/servercerts/macus-brew.crt", report["retained"]["content"])

    def test_stop_refuses_a_running_runtime_or_a_foreign_plist_before_unloading(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            state, client, labels = self.fixture(Path(directory))
            with self.assertRaisesRegex(ValueError, "did not stop"):
                self.stop(state, client, labels, "upgrade", status="running")
            self.plist(state, labels[1], {"EnvironmentVariables": {"MACUS_STATE_DIR": "/other/state"}})
            with self.assertRaisesRegex(ValueError, "not this state"):
                self.stop(state, client, labels, "upgrade")
            self.assertTrue(all((state / "launchd" / f"{label}.plist").exists() for label in labels))

    def test_transitions_must_retain_disks_settings_credentials_and_client(self):
        def replaced_disk(state, client):
            disk = state / "runtime/data.raw"
            copy = disk.with_suffix(".new")
            copy.write_bytes(disk.read_bytes())
            os.replace(copy, disk)

        changes = {
            "replaced disk": replaced_disk,
            "resized disk": lambda state, client: (state / "runtime/root.raw").write_bytes(b"grown root disk"),
            "settings": lambda state, client: (state / "config.json").write_text("{}"),
            "gateway key": lambda state, client: (state / "server/gateway.key").write_text("new key"),
            "gateway certificate": lambda state, client: (state / "server/gateway.crt").write_text("new certificate"),
            "token removed": lambda state, client: (state / "server/local-cli.token").unlink(),
            "trust": lambda state, client: (state / "server/trusted-certificates.json").write_text("[]"),
            "client certificate": lambda state, client: (client / "client.crt").write_text("other"),
            "remote": lambda state, client: (client / "servercerts/macus-brew.crt").unlink(),
        }
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            state, client, labels = self.fixture(Path(directory))
            report, _ = self.stop(state, client, labels, "upgrade")
            # A booted guest rewrites its disks in place, and every start rewrites endpoint.json.
            with (state / "runtime/data.raw").open("r+b") as disk:
                disk.write(b"D")
            (state / "server/endpoint.json").write_text('{"pid": 2}')
            (client / "cache").mkdir()
            acceptance.require_retained(report, state, client)
        for label, change in changes.items():
            with self.subTest(change=label), tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
                state, client, labels = self.fixture(Path(directory))
                report, _ = self.stop(state, client, labels, "upgrade")
                change(state, client)
                with self.assertRaisesRegex(ValueError, "did not retain|no server|no gateway"):
                    acceptance.require_retained(report, state, client)
        with self.assertRaisesRegex(ValueError, "No retained data"):
            acceptance.require_retained({}, Path("/tmp/state"), Path("/tmp/client"))

    def test_resume_requires_the_server_job_registered_for_the_new_revision(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            state, client, labels = self.fixture(Path(directory))
            manifest = {"source_commit": "b" * 40}
            with self.assertRaisesRegex(ValueError, "registered again"):
                acceptance.require_reregistered(state, labels[1], manifest)
            (state / "launchd" / f"{labels[1]}.plist").unlink()
            with self.assertRaisesRegex(ValueError, "registered again"):
                acceptance.require_reregistered(state, labels[1], manifest)
            self.plist(state, labels[1], {"EnvironmentVariables": {"MACUS_STATE_DIR": str(state),
                                                                   "MACUS_EXPECTED_REVISION": "b" * 40}})
            acceptance.require_reregistered(state, labels[1], manifest)
        report = {"checks": {"stopped_and_unloaded": True}, "stopped_version": "old", "transition": "removal"}
        with self.assertRaisesRegex(ValueError, "upgrade or rollback"):
            acceptance.require_upgrade(report, {"version": "new"})

    def test_removal_leaves_no_job_or_owned_plist_and_keeps_the_data(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            state, client, labels = self.fixture(Path(directory))
            upgrade, _ = self.stop(state, client, labels, "upgrade")
            with patch.object(acceptance, "loaded", return_value=False):
                with self.assertRaisesRegex(ValueError, "stop for removal"):
                    acceptance.require_removed(upgrade, state, client, labels)
            self.plist(state, labels[1], {"EnvironmentVariables": {"MACUS_STATE_DIR": str(state)}})
            report, _ = self.stop(state, client, labels, "removal")
            with patch.object(acceptance, "loaded", return_value=True):
                with self.assertRaisesRegex(ValueError, "still loaded"):
                    acceptance.require_removed(report, state, client, labels)
            with patch.object(acceptance, "loaded", return_value=False):
                acceptance.require_removed(report, state, client, labels)
                self.plist(state, labels[0], {"ProgramArguments": ["macus", "serve", "--state-dir", str(state)]})
                with self.assertRaisesRegex(ValueError, "owned plist remains"):
                    acceptance.require_removed(report, state, client, labels)
                (state / "launchd" / f"{labels[0]}.plist").unlink()
                (state / "server/bearer-tokens.json").write_text("{}")
                with self.assertRaisesRegex(ValueError, "did not retain"):
                    acceptance.require_removed(report, state, client, labels)

if __name__ == "__main__":
    unittest.main()
