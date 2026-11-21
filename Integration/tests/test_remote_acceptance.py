"""The remote acceptance runner must rebind, launch and enroll nothing without both opt-ins."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
RUNNER = HERE.parent / "scripts" / "remote-acceptance.py"
PROBE = HERE.parent / "scripts" / "remote-client-probe.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


start_tests = load("test_start_acceptance", HERE / "test_start_acceptance.py")
workload_tests = load("test_workload_acceptance", HERE / "test_workload_acceptance.py")
remote = load("remote_acceptance", RUNNER)


def started_state(root, url="https://127.0.0.1:61000"):
    state, client = workload_tests.started_state(root, url)
    (state / "server" / "gateway.json").write_text(json.dumps({"schema_version": 1, "port": 61000}))
    return state, client


class RemoteAcceptanceTests(unittest.TestCase):
    def arguments(self, root, state, client, incus, *extra, bind="100.105.58.2"):
        return [sys.executable, str(RUNNER), *extra, "--state-dir", str(state), "--prefix",
                str(root / "prefix"), "--incus-conf", str(client), "--incus", str(incus),
                "--remote", "accept", "--report", str(root / "report.json"),
                "--bind-address", bind, "--client-remote", "elsewhere"]

    def run_runner(self, root, state, client, incus, *extra, **options):
        sentinel = root / "macus-ran"
        result = subprocess.run(self.arguments(root, state, client, incus, *extra, **options),
                                text=True, capture_output=True, timeout=60,
                                env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
        return result, sentinel

    def prepared(self, root, addr="https://127.0.0.1:61000"):
        start_tests.installed_pair(root / "prefix")
        state, client = started_state(root)
        incus, log = workload_tests.fake_incus(root, addr)
        return state, client, incus, log

    def test_without_opt_in_nothing_is_read_written_or_run(self):
        with tempfile.TemporaryDirectory(prefix="mre", dir="/tmp") as folder:
            root = Path(folder)
            state, client, incus, log = self.prepared(root)
            result, sentinel = self.run_runner(root, state, client, incus, "--remote-opt-in")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("without --opt-in", result.stderr)
            self.assertFalse(log.exists() or sentinel.exists() or (root / "report.json").exists())

    def test_without_remote_opt_in_nothing_is_rebound_launched_or_enrolled(self):
        with tempfile.TemporaryDirectory(prefix="mre", dir="/tmp") as folder:
            root = Path(folder)
            state, client, incus, log = self.prepared(root)
            gateway = (state / "server" / "gateway.json").read_text()
            result, sentinel = self.run_runner(root, state, client, incus, "--opt-in")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Remote acceptance was not run", result.stderr)
            # Only this state's own remote is read; the client's server is never contacted.
            self.assertEqual(log.read_text().splitlines(), ["remote list --format json"])
            self.assertFalse(sentinel.exists())
            self.assertEqual((state / "server" / "gateway.json").read_text(), gateway)
            data = json.loads((root / "report.json").read_text())
            self.assertFalse(data["remote_ran"] or data["loopback_evidence"])
            self.assertEqual(data["pair"]["revision"], start_tests.REVISION)

    def test_a_remote_that_is_not_this_states_loopback_gateway_is_refused(self):
        with tempfile.TemporaryDirectory(prefix="mre", dir="/tmp") as folder:
            root = Path(folder)
            state, client, incus, log = self.prepared(root, "https://127.0.0.1:8443")
            result, sentinel = self.run_runner(root, state, client, incus, "--opt-in",
                                               "--remote-opt-in")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not this state's loopback gateway", result.stderr)
            self.assertEqual(log.read_text().splitlines(), ["remote list --format json"])
            self.assertFalse(sentinel.exists())

    def test_unsafe_bind_addresses_are_refused_before_anything(self):
        for bind in ("127.0.0.1", "0.0.0.0", "::", "8.8.8.8", "224.0.0.1", "macmini"):
            with self.subTest(bind=bind), tempfile.TemporaryDirectory(prefix="mre",
                                                                     dir="/tmp") as folder:
                root = Path(folder)
                state, client, incus, log = self.prepared(root)
                result, sentinel = self.run_runner(root, state, client, incus, "--opt-in",
                                                   "--remote-opt-in", bind=bind)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing --bind-address", result.stderr)
                self.assertFalse(log.exists() or sentinel.exists()
                                 or (root / "report.json").exists())

    def test_private_and_cgnat_bind_addresses_are_accepted(self):
        for bind in ("100.105.58.2", "192.168.1.137", "10.0.0.2", "fd00::2"):
            self.assertEqual(remote.bind_address(bind), bind)

    def test_the_ordinary_client_configuration_and_state_are_refused(self):
        with tempfile.TemporaryDirectory(prefix="mre", dir="/tmp") as folder:
            root = Path(folder)
            state, client = started_state(root)
            incus, log = workload_tests.fake_incus(root, "https://127.0.0.1:61000")
            for label, chosen_state, chosen_client in (
                    ("client", state, Path.home() / ".config" / "incus"),
                    ("state", Path.home() / ".tama" / "incus-mac", client)):
                with self.subTest(label=label):
                    result, _ = self.run_runner(root, chosen_state, chosen_client, incus,
                                                "--opt-in", "--remote-opt-in")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Refusing", result.stderr)
                    self.assertFalse(log.exists() or (root / "report.json").exists())

    def test_the_client_must_run_on_a_separate_incus_server(self):
        gateways = {"https://127.0.0.1:61000", "https://100.105.58.2:61000"}
        refused = {
            "missing": {},
            "socket": {"elsewhere": {"Addrs": ["unix:///run/incus.sock"], "Protocol": "incus"}},
            "image server": {"elsewhere": {"Addrs": ["https://images.example.net"],
                                           "Protocol": "simplestreams"}},
            "loopback": {"elsewhere": {"Addrs": ["https://127.0.0.1:8443"], "Protocol": "incus"}},
            "this gateway": {"elsewhere": {"Addrs": ["https://100.105.58.2:61000"],
                                           "Protocol": "incus"}},
        }
        for label, remotes in refused.items():
            with self.subTest(label=label), self.assertRaises(SystemExit):
                remote.client_remote(remotes, "elsewhere", gateways)
        accepted = {"elsewhere": {"Addrs": ["https://incus.example.net:443"], "Protocol": "incus"}}
        self.assertEqual(remote.client_remote(accepted, "elsewhere", gateways),
                         ["https://incus.example.net:443"])

    def test_the_probe_fingerprints_a_certificate(self):
        with tempfile.TemporaryDirectory(prefix="mre", dir="/tmp") as folder:
            key, certificate = Path(folder) / "k", Path(folder) / "c"
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                            "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1", "-subj",
                            "/CN=probe", "-keyout", str(key), "-out", str(certificate)],
                           check=True, capture_output=True, timeout=60)
            result = subprocess.run([sys.executable, "-I", str(PROBE), "fingerprint",
                                     str(certificate)], text=True, capture_output=True, timeout=60)
            der = subprocess.run(["/usr/bin/openssl", "x509", "-in", str(certificate), "-outform",
                                  "DER"], check=True, capture_output=True, timeout=60).stdout
            import hashlib
            self.assertEqual(json.loads(result.stdout)["sha256"], hashlib.sha256(der).hexdigest())
            self.assertEqual(remote.pem_fingerprint(certificate.read_text()),
                             hashlib.sha256(der).hexdigest())

    def test_the_remote_checks_cover_the_task(self):
        for check in ("separate_client", "tls_identity", "native_enrollment",
                      "single_use_enrollment", "scoped_combined_access", "bearer_revocation",
                      "native_revocation", "enrollment_token_revocation", "loopback_restored",
                      "client_removed", "guest_unaffected"):
            self.assertIn(check, remote.REMOTE_CHECKS)


if __name__ == "__main__":
    unittest.main()
