#!/usr/bin/env python3
"""Opt-in two-job upgrade, rollback and removal acceptance of installed packages (task 11.6).

Runs against a state that start-acceptance.py started and workload-acceptance.py
gave a kept workload, with the isolated INCUS_CONF those runs registered. Two
verified candidate packages, each an installed pair (`bin/macus` and
`libexec/macus`), are poured into an isolated package root laid out as Homebrew
lays out a keg, without running Homebrew:

  ROOT/Cellar/macus/<version>_<revision>/{bin/macus,libexec/macus}
  ROOT/opt/macus -> ../../Cellar/macus/<version>_<revision>

so the runtime job's plist names the stable `ROOT/opt/macus/bin/macus`, exactly
as it names `opt/macus` under Homebrew. Without --opt-in it refuses before
reading, creating or running anything. With --opt-in it validates the report
path, refuses ordinary state, package and client paths, and checks both pairs
against their own revision's server/mix.lock. Nothing is stopped, unloaded or
installed without --hardware as well.

With --hardware it follows the documented sequence (Packaging/homebrew/README.md,
"Upgrade, rollback and removal") through these transitions, in order:

  adopt          the running pair -> the old candidate in the package root
                 (both plists removed: the old runtime plist names a path
                 outside the package root);
  upgrade        old -> new (only the server plist removed);
  rollback       new -> old (only the server plist removed);
  upgrade_again  old -> new;
  removal        both plists and the package removed, nothing started;
  reinstall      the new candidate poured again and started.

Each package change stops the runtime through the server, unloads the server
job and then the runtime job, removes only owned plists and records what must
be kept: runtime disks (by file identity), settings, server credentials and
trust, and the client configuration. After each start it requires those
unchanged, the server plist registered for the installed revision, the runtime
plist naming the stable opt path (byte-identical across transitions), the
kept workload with the same identity and data, the client still trusted without
re-enrolling, and bearer tokens issued before the first transition still
accepted. On the new candidate it also re-proves product fixes the old pair
lacks. The first failure stops the sequence: state, package root, plists,
workload and diagnostics are kept as they are, and nothing is reset.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


workload = load("workload_acceptance", "Integration/scripts/workload-acceptance.py")
start = workload.start
homebrew = load("homebrew_acceptance", "Integration/scripts/homebrew-acceptance.py")
remote = load("remote_acceptance", "Integration/scripts/remote-acceptance.py")
require, CheckFailure = workload.require, workload.CheckFailure

TRANSITIONS = (
    ("adopt", "old"), ("upgrade", "new"), ("rollback", "old"),
    ("upgrade_again", "new"), ("removal", None), ("reinstall", "new"),
)
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
UPGRADE_MARKER = "/root/macus-upgrade-marker"
LAUNCH_PROBE = "macus-launch-116"
# Places a package root must never be: Homebrew's own prefixes and ordinary user data.
FORBIDDEN_ROOTS = ("/opt/homebrew", "/usr/local", "/usr", "/opt", "/Applications", "/Library")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--package-root", type=Path, required=True,
                        help="isolated root that receives Cellar/macus and opt/macus")
    parser.add_argument("--old-candidate", type=Path, required=True,
                        help="the earlier verified installed pair (bin/macus, libexec/macus)")
    parser.add_argument("--new-candidate", type=Path, required=True)
    parser.add_argument("--old-lock", type=Path, required=True,
                        help="server/mix.lock of the old candidate's revision")
    parser.add_argument("--new-lock", type=Path,
                        help="server/mix.lock of the new candidate's revision (default: this checkout's)")
    parser.add_argument("--incus-conf", type=Path, required=True)
    parser.add_argument("--incus", type=Path, required=True)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--instance", default="macus-accept")
    parser.add_argument("--launch-image", default="images:alpine/3.22")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--hardware", action="store_true")
    parser.add_argument("--opt-in", action="store_true")
    return parser.parse_args()


def package_root(path):
    """An absolute, short, isolated root: never Homebrew's prefix, a system path or home itself."""
    if not path.is_absolute():
        raise SystemExit("Refusing a relative --package-root")
    if path.is_symlink():
        raise SystemExit("Refusing a symlinked --package-root")
    resolved = path.resolve()
    home = Path.home().resolve()
    if resolved in (Path("/"), home) or len(str(resolved)) > 80:
        raise SystemExit(f"Refusing --package-root {path}: use a short isolated directory")
    for forbidden in FORBIDDEN_ROOTS:
        if resolved == Path(forbidden) or resolved.is_relative_to(forbidden):
            raise SystemExit(f"Refusing --package-root {path}: it is inside {forbidden}")
    for ordinary in (home / ".tama", home / ".config", home / "Library", home / ".local"):
        if resolved == ordinary or resolved.is_relative_to(ordinary):
            raise SystemExit(f"Refusing --package-root {path}: it is ordinary user data")
    return path


class Package:
    """A Homebrew-shaped package root: kegs under Cellar/macus and the stable opt/macus link."""

    def __init__(self, root):
        self.root = root
        self.cellar = root / "Cellar" / "macus"
        self.opt = root / "opt" / "macus"

    @property
    def binary(self):
        return self.opt / "bin" / "macus"

    def keg(self, pair):
        return self.cellar / f"{pair['version']}_{pair['revision'][:12]}"

    def install(self, candidate, pair, lock):
        """Pour the candidate into its keg (once) and point opt/macus at it atomically."""
        keg = self.keg(pair)
        if not keg.exists():
            self.cellar.mkdir(parents=True, exist_ok=True)
            staging = Path(tempfile.mkdtemp(prefix=".pour-", dir=self.cellar))
            for part in ("bin", "libexec"):
                shutil.copytree(candidate / part, staging / part, symlinks=True)
            staging.rename(keg)
        poured = start.installed_pair(keg, lock)
        require(poured["revision"] == pair["revision"], f"{keg} is not revision {pair['revision']}")
        self.opt.parent.mkdir(parents=True, exist_ok=True)
        link = self.opt.parent / ".macus.link"
        if link.is_symlink():
            link.unlink()
        os.symlink(os.path.relpath(keg, self.opt.parent), link)
        os.replace(link, self.opt)
        installed = start.installed_pair(self.opt, lock)
        require(Path(installed["binary"]).resolve() == (keg / "bin/macus").resolve(),
                "opt/macus does not resolve to the poured keg")
        return {**installed, "binary": str(self.binary), "release": str(self.opt / "libexec/macus"),
                "keg": str(keg)}

    def remove(self):
        """Uninstall: the opt link and every keg, never anything outside the package root."""
        if self.opt.is_symlink():
            self.opt.unlink()
        if self.cellar.exists():
            require(self.cellar.resolve().is_relative_to(self.root.resolve()),
                    "Refusing to remove a Cellar outside the package root")
            shutil.rmtree(self.cellar)
        for directory in (self.opt.parent, self.cellar.parent):
            if directory.is_dir() and not any(directory.iterdir()):
                directory.rmdir()

    def installed(self):
        return self.opt.exists() or self.opt.is_symlink() or self.cellar.exists()


def plist_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def refused(url):
    """True when nothing accepts a TCP connection at the gateway any more."""
    parsed = urllib.parse.urlsplit(url)
    try:
        with socket.create_connection((parsed.hostname, parsed.port), timeout=5):
            return False
    except OSError:
        return True


class Upgrade(workload.Acceptance):
    def __init__(self, args, report, run, endpoint, labels, package, pairs, tokens):
        super().__init__(args, report, run, endpoint)
        self.labels, self.package, self.pairs, self.tokens = labels, package, pairs, tokens
        self.state = args.state_dir.resolve()
        # Plists name the state as macus was given it (/tmp, not /private/tmp), and ownership
        # is checked against that spelling.
        self.named_state = Path(os.path.abspath(args.state_dir))
        self.conf = args.incus_conf.resolve()
        self.runtime_plist = self.state / "launchd" / f"{labels[0]}.plist"
        self.server_plist = self.state / "launchd" / f"{labels[1]}.plist"
        self.stable_runtime_plist = None
        self.kept = None

    # What must survive every transition.
    def instance(self):
        return json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/{self.args.instance}").stdout)

    def baseline(self):
        self.read_token = self.tokens.issue("runtime.read")
        self.list_token = self.tokens.issue("incus.read")
        self.marker = secrets.token_hex(8)
        self.ok("exec", self.target, "--", "sh", "-c", f"printf %s {self.marker} > {UPGRADE_MARKER}")
        instance = self.instance()
        trusted = remote.trust_entries(self.endpoint["url"], self.endpoint["certificate"], self.conf)
        self.before = {
            "uuid": instance["config"].get("volatile.uuid"),
            "autostart": instance["config"].get("boot.autostart"),
            "acceptance_marker": self.ok("exec", self.target, "--", "cat", workload.MARKER).stdout,
            "fingerprint": self.endpoint_fingerprint(),
            "trusted": sorted(trusted),
        }
        require(bool(UUID.match(self.before["uuid"] or "")), "the kept workload has no volatile.uuid")
        return {**self.before, "tokens_issued": ["runtime.read", "incus.read"],
                "running_binary": self.run.binary}

    def endpoint_fingerprint(self):
        endpoint = json.loads((self.state / "server" / "endpoint.json").read_text())
        return hashlib.sha256(ssl.PEM_cert_to_DER_cert(endpoint["certificate"])).hexdigest()

    # The documented sequence.
    def stop_and_unload(self, transition):
        stopped = self.run.macus(["--json", "runtime", "stop"], timeout=600, json_output=True)
        status = self.run.macus(["--json", "runtime", "status"], json_output=True)
        require(status.get("state") == "stopped", f"runtime is {status.get('state')} after stop")
        runtime_label, server_label = self.labels
        for label in (server_label, runtime_label):
            if homebrew.loaded(label):
                result = self.run.command(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}"],
                                          120, "launchctl")
                require(result.returncode == 0, f"bootout {label} exited {result.returncode}")
        homebrew.wait_unloaded(self.labels)
        removed = [server_label]
        # adopt: the running runtime plist names a path outside the package root, which start
        # would refuse as a conflict, so that owned plist goes too (as the README says for an
        # older plist naming a versioned keg path).
        if transition in ("adopt", "removal"):
            removed.append(runtime_label)
        for label in removed:
            path = homebrew.owned_plist(self.named_state, label)
            if path:
                path.unlink()
        salt = secrets.token_hex(32)
        self.kept = {"retention_salt": salt, "retained": homebrew.retained(self.state, self.conf, salt)}
        return {"stop": stopped.get("state"), "removed_plists": removed}

    def start(self, pair):
        self.run.binary = pair["binary"]
        result = self.run.macus(["--json", "--progress", "none", "--incus", self.incus, "start",
                                 "--remote", self.args.remote], timeout=1900, json_output=True)
        require(result.get("ready") is True and result.get("connected") is True,
                f"start was not ready and connected: {result}")
        require((result.get("service_label"), result.get("server_label")) == self.labels,
                "start reported other labels")
        return result

    def registration(self, pair, transition):
        start.registered_jobs(self.state, self.labels, pair)
        runtime = plistlib.loads(self.runtime_plist.read_bytes())
        require(runtime["ProgramArguments"][0] == str(self.package.binary),
                f"the runtime plist names {runtime['ProgramArguments'][0]}, not the stable opt path")
        digest = plist_digest(self.runtime_plist)
        if transition == "adopt":
            self.stable_runtime_plist = digest
        require(digest == self.stable_runtime_plist,
                "the runtime plist changed although it names the stable opt path")
        server = plistlib.loads(self.server_plist.read_bytes())
        revision = server["EnvironmentVariables"].get("MACUS_EXPECTED_REVISION")
        require(revision == pair["revision"], f"the server plist names revision {revision}")
        programs = {label: (start.job_pid(label), self.job_program(label)) for label in self.labels}
        require(all(pid for pid, _ in programs.values()), f"a job is not running: {programs}")
        require(programs[self.labels[0]][1] == str(self.package.binary),
                f"the runtime job runs {programs[self.labels[0]][1]}")
        return {"runtime_program": str(self.package.binary), "server_revision": revision,
                "runtime_plist_sha256": digest, "pids": {k: v[0] for k, v in programs.items()}}

    def job_program(self, label):
        result = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"],
                                capture_output=True, text=True, timeout=30)
        for line in result.stdout.splitlines():
            if line.strip().startswith("program = "):
                return line.split("=", 1)[1].strip()
        return None

    def retained(self):
        homebrew.require_retained(self.kept, self.state, self.conf)
        require(self.endpoint_fingerprint() == self.before["fingerprint"],
                "the gateway serves another certificate")
        return {"disks_settings_credentials_client": True, "fingerprint": self.before["fingerprint"]}

    def workload_kept(self):
        instance = self.instance()
        started = False
        if instance.get("status") != "Running":
            self.ok("start", self.target, timeout=300)
            started = True
        deadline = time.monotonic() + 120
        while json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                 f"{self.args.instance}/state").stdout).get("status") != "Running":
            require(time.monotonic() < deadline, "the kept workload did not run again")
            time.sleep(2)
        require(instance["config"].get("volatile.uuid") == self.before["uuid"],
                "the kept workload's identity changed")
        upgrade_marker = self.ok("exec", self.target, "--", "cat", UPGRADE_MARKER).stdout
        acceptance_marker = self.ok("exec", self.target, "--", "cat", workload.MARKER).stdout
        require(upgrade_marker == self.marker and acceptance_marker == self.before["acceptance_marker"],
                "the kept workload's data changed")
        return {"uuid": self.before["uuid"], "started_after_boot": started,
                "markers": "unchanged"}

    def access_kept(self):
        listed = self.ok("list", f"{self.args.remote}:", "--format", "csv", "-c", "n").stdout.split()
        require(self.args.instance in listed, "the client no longer lists the kept workload")
        trusted = remote.trust_entries(self.endpoint["url"], self.endpoint["certificate"], self.conf)
        require(sorted(trusted) == self.before["trusted"], "gateway trust changed")
        gateway = start.Gateway(json.loads((self.state / "server" / "endpoint.json").read_text()))
        status, body = gateway.request("GET", "/runtime/status", self.read_token)
        require(status == 200 and body.get("state") == "ready",
                f"a bearer token issued before the transitions got {status}")
        status, error, listed = self.mcp.execute(self.list_token, "incus_instance_list", {})
        require(status == 200 and not error and self.args.instance in json.dumps(listed),
                f"MCP no longer lists the kept workload ({status})")
        return {"client_trusted_without_reenrollment": True, "trust_unchanged": True,
                "bearer_tokens_accepted": True}

    def fixes(self):
        """Product fixes the old pair lacks, now on hardware with the new candidate."""
        found = {}
        query = self.ok("query", f"{self.args.remote}:/1.0/certificates?recursion=1")
        found["incus_query_trust"] = len(json.loads(query.stdout))
        trust = self.ok("config", "trust", "list", f"{self.args.remote}:", "--format", "json")
        found["incus_config_trust_list"] = len(json.loads(trust.stdout))
        shown = self.run.macus(["--json", "server", "config", "show"], json_output=True)
        stored = (shown.get("gateway") or {}).get("file")
        require(stored and Path(stored).resolve() == self.state / "server" / "gateway.json",
                f"server config show reported {stored}")
        found["server_config_show_stored_file"] = True
        existing = self.incus_command("query", f"{self.args.remote}:/1.0/instances/{LAUNCH_PROBE}")
        require(existing.returncode != 0, f"refusing: {LAUNCH_PROBE} already exists")
        launched = self.incus_command("launch", self.args.launch_image,
                                      f"{self.args.remote}:{LAUNCH_PROBE}", timeout=900)
        try:
            require(launched.returncode == 0, f"incus launch exited {launched.returncode}: "
                                              f"{launched.stderr[-400:]}")
            state = json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                       f"{LAUNCH_PROBE}/state").stdout)
            require(state.get("status") == "Running", f"the launched instance is {state.get('status')}")
            found["incus_launch"] = "running"
        finally:
            if self.incus_command("query", f"{self.args.remote}:/1.0/instances/{LAUNCH_PROBE}").returncode == 0:
                self.ok("delete", "--force", f"{self.args.remote}:{LAUNCH_PROBE}", timeout=300)
        return found

    def removed(self):
        require(not any(homebrew.loaded(label) for label in self.labels), "a job is still loaded")
        require(not self.runtime_plist.exists() and not self.server_plist.exists(),
                "an owned plist remains")
        require(not self.package.installed(), "the package is still installed")
        homebrew.require_retained(self.kept, self.state, self.conf)
        require(refused(self.endpoint["url"]), "the gateway still accepts connections")
        disk = self.state / "runtime" / "root.raw"
        holders = subprocess.run(["/usr/sbin/lsof", "-t", str(disk)], capture_output=True, text=True)
        require(not holders.stdout.strip(), "a process still holds the runtime disk")
        return {"jobs_unloaded": True, "plists_removed": True, "package_removed": True,
                "disks_settings_credentials_client": True, "gateway_closed": True,
                "runtime_disk_released": True}

    def transition(self, name, which):
        if name == "reinstall":
            # Removal already stopped, unloaded and uninstalled everything; what reinstall must
            # keep is the snapshot recorded then.
            require(self.kept and not self.package.installed(), "reinstall requires a completed removal")
            steps = {"stop": "already removed"}
        else:
            steps = {"stop": self.stop_and_unload(name)}
        if name == "removal":
            self.package.remove()
            steps["removed"] = self.removed()
            return steps
        candidate = self.args.old_candidate if which == "old" else self.args.new_candidate
        lock = self.args.old_lock if which == "old" else self.args.new_lock
        pair = self.package.install(candidate, self.pairs[which], lock)
        steps["installed"] = {"revision": pair["revision"], "keg": pair["keg"]}
        steps["start"] = {key: value for key, value in self.start(pair).items()
                          if key in ("ready", "connected", "service_label", "server_label")}
        # Retention is compared before anything here writes to the state.
        steps["retained"] = self.retained()
        steps["registration"] = self.registration(pair, name)
        steps["workload"] = self.workload_kept()
        steps["access"] = self.access_kept()
        if which == "new":
            steps["fixes"] = self.fixes()
        return steps

    def diagnostics(self):
        logs = {}
        for path in sorted((self.state / "logs").glob("*")):
            if path.is_file():
                logs[path.name] = path.read_text(errors="replace")[-4000:]
        return {"logs": logs, "package_root": str(self.package.root),
                "loaded": {label: homebrew.loaded(label) for label in self.labels}}


def main():
    args = parse_args()
    if not args.opt_in:
        raise SystemExit("Refusing to run without --opt-in")
    state = args.state_dir
    root = package_root(args.package_root)
    start.validate_report(args.report, state, root, None, client=args.incus_conf)
    start.refuse_user_paths(state, root, None)
    start.refuse_user_client(args.incus_conf)
    args.new_lock = args.new_lock or ROOT / "server" / "mix.lock"
    report = {
        "schema_version": 1,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Opt-in two-job upgrade, rollback and removal of installed packages",
        "hardware_ran": False, "state_dir": str(state.resolve()), "package_root": str(root),
        "incus_conf": str(args.incus_conf.resolve()), "checks": {}, "transitions": {},
    }

    def save():
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")

    save()
    try:
        pairs = {"old": start.installed_pair(args.old_candidate, args.old_lock),
                 "new": start.installed_pair(args.new_candidate, args.new_lock)}
        require(pairs["old"]["revision"] != pairs["new"]["revision"],
                "the two candidates are the same revision")
    except (start.PairFailure, CheckFailure, OSError, ValueError, KeyError) as error:
        report["success"], report["failure"] = False, str(error)
        save()
        raise SystemExit(f"Candidate check failed: {error}")
    report["evidence"] = {"package": {which: {key: pair[key] for key in
                                              ("version", "revision", "opsmaru_incus", "cassette_sha256")}
                                      for which, pair in pairs.items()}}
    save()
    if not args.hardware:
        report["note"] = "Hardware acceptance was not run; nothing was stopped or installed."
        save()
        raise SystemExit("Hardware acceptance was not run; pass --hardware to change packages")
    try:
        labels = start.service_labels(state.resolve())
        require(all(homebrew.loaded(label) for label in labels),
                "this state's two jobs are not running: start it first")
        endpoint = json.loads((state / "server" / "endpoint.json").read_text())
        runtime = plistlib.loads((state / "launchd" / f"{labels[0]}.plist").read_bytes())
        running_binary = runtime["ProgramArguments"][0]
    except (CheckFailure, OSError, ValueError, KeyError) as error:
        report["success"], report["failure"] = False, str(error)
        save()
        raise SystemExit(f"Started state check failed: {error}")
    env = dict(os.environ, INCUS_CONF=str(args.incus_conf.resolve()), MACUS_BREW_FALLBACK="0")
    for variable in ("MACUS_STATE_DIR", "MACUS_FIXTURE_GUEST_DIR", "MACUS_FIXTURE_LAUNCHCTL"):
        env.pop(variable, None)
    run = start.Run(running_binary, state.resolve(), env, report)
    remotes = run.command([str(args.incus), "remote", "list", "--format", "json"], 60, "incus")
    entry = json.loads(remotes.stdout).get(args.remote, {}) if remotes.returncode == 0 else {}
    addresses = entry.get("Addrs") or ([entry["Addr"]] if entry.get("Addr") else [])
    if addresses != [endpoint["url"]]:
        report["success"] = False
        report["failure"] = f"remote {args.remote} is {addresses}, not this state's {endpoint['url']}"
        save()
        raise SystemExit("Refusing: the client's remote is not this state's gateway")
    report["hardware_ran"] = True
    footprint = start.default_footprint()
    tokens = start.Tokens(run, Path(tempfile.mkdtemp(prefix="macus-upgrade-tokens-")))
    package = Package(root)
    acceptance = Upgrade(args, report, run, endpoint, labels, package, pairs, tokens)
    checks = report["checks"]
    failed = False
    try:
        try:
            report["baseline"] = acceptance.baseline()
            checks["baseline"] = True
        except Exception as error:
            checks["baseline"], failed = False, True
            report["baseline"] = {"error": f"{type(error).__name__}: {error}"}
        save()
        for name, which in TRANSITIONS:
            if failed:
                break
            try:
                report["transitions"][name] = acceptance.transition(name, which)
                checks[name] = True
            except Exception as error:  # The first failure stops the sequence; nothing is undone.
                checks[name], failed = False, True
                report["transitions"][name] = {"error": f"{type(error).__name__}: {error}"}
            save()
    finally:
        if failed:
            report["diagnostics"] = acceptance.diagnostics()
            report["note"] = "Stopped at the first failure; state, package root and workload are kept."
        if homebrew.loaded(labels[1]):
            tokens.revoke_all(report)
        else:
            report["tokens_revoked"] = False
            report["tokens_left"] = "the server is not running; revoke the run's tokens after start"
        checks["default_jobs_and_endpoint_unchanged"] = start.default_footprint() == footprint
        report["success"] = all(checks.get(name) for name, _ in TRANSITIONS) and all(checks.values())
        save()
    print(args.report)
    if not report["success"]:
        raise SystemExit("Upgrade acceptance failed; inspect the retained report")


if __name__ == "__main__":
    main()
