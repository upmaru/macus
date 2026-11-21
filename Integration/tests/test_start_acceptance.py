"""The start acceptance runner must refuse ordinary user state and retain failures."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "scripts" / "start-acceptance.py"
SPEC = importlib.util.spec_from_file_location("start_acceptance", RUNNER)
start_acceptance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(start_acceptance)
REVISION = "a" * 40
VERSION = "0.1.0"

# A real Mach-O with an embedded Macus identity. It appends its arguments to
# $MACUS_ACCEPTANCE_SENTINEL, then runs $MACUS_ACCEPTANCE_SCRIPT with them (or exits 1).
STUB = r"""
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
  const char *sentinel = getenv("MACUS_ACCEPTANCE_SENTINEL");
  if (sentinel) {
    FILE *log = fopen(sentinel, "a");
    for (int i = 1; i < argc; i++) fprintf(log, "%s\n", argv[i]);
    fclose(log);
  }
  const char *script = getenv("MACUS_ACCEPTANCE_SCRIPT");
  if (script) { execv(script, argv); return 127; }
  return 1;
}
"""


def installed_pair(prefix, revision=REVISION, release_revision=REVISION, library=None,
                   cassette=None):
    """A fake installed pair: an identity-carrying executable and a release record."""
    locked = start_acceptance.locked_opsmaru_incus()
    library = library or locked
    (prefix / "bin").mkdir(parents=True)
    identity = prefix / "identity.plist"
    identity.write_bytes(plistlib.dumps({"MacusVersion": VERSION, "MacusSourceRevision": revision}))
    subprocess.run(
        ["/usr/bin/xcrun", "clang", "-x", "c", "-", "-o", str(prefix / "bin/macus"),
         f"-Wl,-sectcreate,__TEXT,__info_plist,{identity}"],
        input=STUB, text=True, check=True, capture_output=True)
    identity.unlink()
    release = prefix / "libexec/macus"
    (release / f"lib/opsmaru_incus-{library}").mkdir(parents=True)
    cassettes = release / f"lib/macus-{VERSION}/priv/cassettes"
    cassettes.mkdir(parents=True)
    name = cassette or f"opsmaru_incus-{locked}.tama-cassette"
    (cassettes / name).write_bytes(b"cassette")
    record = release / "macus-build.json"
    record.write_text(json.dumps({
        "schema_version": 1, "version": VERSION, "revision": release_revision,
        "opsmaru_incus": {"version": library, "cassette": {
            "file": name, "sha256": hashlib.sha256(b"cassette").hexdigest()}},
    }))
    record.chmod(0o444)
    return prefix


def run_runner(*arguments, env=None):
    return subprocess.run([sys.executable, str(RUNNER), *arguments], env=env, text=True,
                          capture_output=True, timeout=60)


class StartAcceptanceTests(unittest.TestCase):
    def test_refuses_ordinary_state_and_does_not_execute(self):
        with tempfile.TemporaryDirectory(prefix="macus-start-accept-") as folder:
            root = Path(folder)
            sentinel = root / "executed"
            macus = root / "macus"
            macus.write_text("#!/bin/sh\ntouch \"$MACUS_ACCEPTANCE_SENTINEL\"\n")
            macus.chmod(0o755)
            report = root / "report.json"
            env = dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel))
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--opt-in", "--state-dir",
                 str(Path.home() / ".tama" / "incus-mac"), "--prefix", str(root / "prefix"),
                 "--macus", str(macus), "--report", str(report)],
                env=env, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing", result.stderr)
            self.assertFalse(sentinel.exists())
            self.assertFalse(report.exists())

    def test_without_opt_in_reads_creates_and_runs_nothing(self):
        with tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
            root = Path(folder)
            prefix = installed_pair(root / "prefix")
            sentinel = root / "executed"
            for extra in ([], ["--hardware"]):
                with self.subTest(extra=extra):
                    result = run_runner(
                        *extra, "--state-dir", str(root / "state"), "--prefix", str(prefix),
                        "--report", str(root / "report.json"),
                        env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("without --opt-in", result.stderr)
                    self.assertFalse(sentinel.exists())
                    self.assertFalse((root / "state").exists())
                    self.assertFalse((root / "report.json").exists())

    def test_without_hardware_checks_the_pair_without_running_it(self):
        with tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
            root = Path(folder)
            prefix = installed_pair(root / "prefix")
            state = root / "state"
            sentinel = root / "executed"
            report = root / "report.json"
            result = run_runner(
                "--opt-in", "--state-dir", str(state), "--prefix", str(prefix),
                "--report", str(report),
                env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("Hardware acceptance was not run", result.stderr)
            self.assertFalse(sentinel.exists())
            self.assertFalse(state.exists())
            data = json.loads(report.read_text())
            self.assertFalse(data["hardware_ran"])
            self.assertFalse(data["guest_verified"])
            self.assertFalse(data["brew_install_ran"])
            self.assertNotIn("success", data)
            self.assertNotIn("incus_conf", data)
            for check in ("paired_artifacts", "pinned_dependency", "two_service_labels",
                          "refused_without_hardware_opt_in"):
                self.assertIs(data["checks"][check], True, check)
            self.assertEqual(data["pair"]["revision"], REVISION)
            runtime, server = data["service_label"], data["server_label"]
            self.assertNotIn(runtime, start_acceptance.DEFAULT_LABELS)
            self.assertNotIn(server, start_acceptance.DEFAULT_LABELS)
            self.assertEqual(server, runtime.replace("com.upmaru.macus.", "com.upmaru.macus.server.", 1))

    def test_unpaired_or_unpinned_pairs_are_refused_before_running(self):
        locked = start_acceptance.locked_opsmaru_incus()
        cases = {
            "Unpaired artifacts": dict(release_revision="b" * 40),
            "pinned opsmaru_incus": dict(library="0.0.1"),
            "pinned opsmaru_incus-": dict(cassette=f"opsmaru_incus-{locked}-other.tama-cassette"),
        }
        for message, options in cases.items():
            with self.subTest(message=message), tempfile.TemporaryDirectory(
                    prefix="msa", dir="/tmp") as folder:
                root = Path(folder)
                prefix = installed_pair(root / "prefix", **options)
                sentinel = root / "executed"
                report = root / "report.json"
                result = run_runner(
                    "--opt-in", "--hardware", "--state-dir", str(root / "state"),
                    "--prefix", str(prefix), "--report", str(report),
                    env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel)))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(sentinel.exists())
                self.assertFalse((root / "state").exists())
                data = json.loads(report.read_text())
                self.assertFalse(data["success"])
                self.assertFalse(data["hardware_ran"])

    def test_an_executable_outside_the_pair_is_refused(self):
        with tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
            root = Path(folder)
            prefix = installed_pair(root / "prefix")
            other = root / "macus"
            other.write_text("#!/bin/sh\ntouch \"$MACUS_ACCEPTANCE_SENTINEL\"\n")
            other.chmod(0o755)
            result = run_runner(
                "--opt-in", "--hardware", "--state-dir", str(root / "state"), "--prefix",
                str(prefix), "--macus", str(other), "--report", str(root / "report.json"),
                env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(root / "executed")))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside the installed pair", result.stderr)
            self.assertFalse((root / "executed").exists())
            self.assertFalse((root / "report.json").exists())

    def test_hardware_failure_is_isolated_and_preserved(self):
        with tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
            root = Path(folder)
            prefix = installed_pair(root / "prefix")
            state = root / "state"
            marker = state / "keep"
            state.mkdir()
            marker.write_text("preserve\n")
            sentinel = root / "executed"
            seen = root / "seen"
            script = root / "fail.sh"
            script.write_text(
                f"#!/bin/sh\nprintf '%s\\n' \"$INCUS_CONF\" \"${{MACUS_FIXTURE_GUEST_DIR-unset}}\" > '{seen}'\n"
                "echo failed >&2\nexit 1\n")
            script.chmod(0o755)
            report = root / "failed.json"
            result = run_runner(
                "--opt-in", "--hardware", "--state-dir", str(state), "--prefix", str(prefix),
                "--report", str(report),
                env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel),
                         MACUS_ACCEPTANCE_SCRIPT=str(script), MACUS_FIXTURE_GUEST_DIR="/tmp/x"))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(), "preserve\n")
            arguments = sentinel.read_text().splitlines()
            self.assertEqual(arguments[:2], ["--state-dir", str(state.resolve())])
            self.assertIn("start", arguments)
            incus_conf, guest = seen.read_text().splitlines()
            self.assertNotEqual(Path(incus_conf).resolve(),
                                (Path.home() / ".config/incus").resolve())
            self.assertEqual(guest, "unset")
            data = json.loads(report.read_text())
            self.assertFalse(data["success"])
            self.assertTrue(data["hardware_ran"])
            self.assertFalse(data["guest_verified"])
            self.assertEqual(data["incus_conf"], str(Path(incus_conf).resolve()))
            gateway = json.loads((state / "server/gateway.json").read_text())
            self.assertEqual(gateway, {"schema_version": 1, "port": data["gateway_port"]})
            self.assertNotEqual(gateway["port"], 8443)
            self.assertEqual((state / "server/gateway.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual((state / "server").stat().st_mode & 0o777, 0o700)

    def test_hardware_success_requires_isolated_jobs_and_credentials(self):
        with tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
            root = Path(folder)
            prefix = installed_pair(root / "prefix")
            state = root / "state"
            runtime, server = start_acceptance.service_labels(state.resolve())
            binary, release = prefix / "bin/macus", prefix / "libexec/macus"

            def job_script(server_revision):
                plists = {
                    runtime: {"Label": runtime, "ProgramArguments": [
                        str(binary), "serve", "--state-dir", str(state.resolve())]},
                    server: {"Label": server, "ProgramArguments": [
                        str(release / "bin/macus"), "start"], "EnvironmentVariables": {
                        "MACUS_STATE_DIR": str(state.resolve()),
                        "MACUS_EXPECTED_REVISION": server_revision}},
                }
                body = {"ready": True, "connected": True, "service_label": runtime,
                        "server_label": server}
                return (
                    f"#!{sys.executable}\nimport json, os, pathlib, plistlib\n"
                    f"state = pathlib.Path({str(state)!r})\n"
                    "port = json.loads((state / 'server/gateway.json').read_text())['port']\n"
                    "(state / 'launchd').mkdir(exist_ok=True)\n"
                    f"for label, data in {plists!r}.items():\n"
                    "    (state / 'launchd' / (label + '.plist')).write_bytes(plistlib.dumps(data))\n"
                    "for name in ('gateway.crt', 'gateway.key', 'endpoint.json'):\n"
                    "    path = state / 'server' / name\n"
                    "    path.write_text('x')\n"
                    "    path.chmod(0o600)\n"
                    f"body = {body!r}\n"
                    "body['server_endpoint'] = {'url': 'https://127.0.0.1:%d' % port}\n"
                    "print(json.dumps(body))\n")

            for revision, succeeds in ((REVISION, True), ("c" * 40, False)):
                with self.subTest(revision=revision):
                    script = root / "start.py"
                    script.write_text(job_script(revision))
                    script.chmod(0o755)
                    report = root / f"report-{succeeds}.json"
                    result = run_runner(
                        "--opt-in", "--hardware", "--state-dir", str(state), "--prefix",
                        str(prefix), "--report", str(report),
                        env=dict(os.environ, MACUS_ACCEPTANCE_SCRIPT=str(script)))
                    data = json.loads(report.read_text())
                    self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                    self.assertEqual(data["success"], succeeds)
                    self.assertTrue(data["hardware_ran"])
                    if succeeds:
                        for check in ("isolated_labels_reported", "isolated_gateway_port",
                                      "jobs_registered_for_state", "isolated_credentials",
                                      "default_jobs_and_endpoint_unchanged"):
                            self.assertIs(data["checks"][check], True, check)
                    else:
                        self.assertIn("paired release", data["note"])

    def test_report_inside_runtime_does_not_destroy_data_or_run(self):
        sentinel = b"INCUS-DATA-SENTINEL\n"
        for hardware in (False, True):
            with self.subTest(hardware=hardware), tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
                root = Path(folder)
                state = root / "state"
                disk = state / "runtime" / "data.raw"
                disk.parent.mkdir(parents=True)
                disk.write_bytes(sentinel)
                executed = root / "executed"
                macus = root / "macus"
                macus.write_text("#!/bin/sh\ntouch \"$MACUS_ACCEPTANCE_SENTINEL\"\n")
                macus.chmod(0o755)
                command = [
                    sys.executable, str(RUNNER), "--opt-in", "--state-dir", str(state),
                    "--prefix", str(root / "prefix"), "--macus", str(macus),
                    "--report", str(disk),
                ]
                if hardware:
                    command.append("--hardware")
                result = subprocess.run(
                    command, env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(executed)),
                    text=True, capture_output=True, timeout=15)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("Refusing", result.stderr)
                self.assertEqual(disk.read_bytes(), sentinel)
                self.assertFalse(executed.exists())
                self.assertFalse((root / "prefix").exists())

    def test_symlink_report_is_rejected_before_mutation(self):
        with tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
            root = Path(folder)
            state = root / "state"
            disk = state / "runtime" / "data.raw"
            disk.parent.mkdir(parents=True)
            disk.write_bytes(b"INCUS-DATA-SENTINEL\n")
            link = root / "report-link"
            link.symlink_to(disk)
            macus = root / "macus"
            macus.write_text("#!/bin/sh\nexit 0\n")
            macus.chmod(0o755)
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--opt-in", "--state-dir", str(state),
                 "--prefix", str(root / "prefix"), "--macus", str(macus), "--report", str(link)],
                text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink", result.stderr)
            self.assertEqual(disk.read_bytes(), b"INCUS-DATA-SENTINEL\n")
            self.assertFalse(link.is_file() and link.read_bytes().startswith(b"{"))


if __name__ == "__main__":
    unittest.main()
