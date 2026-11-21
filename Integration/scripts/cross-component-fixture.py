#!/usr/bin/env python3
"""Run the installed Swift and server processes with the standard Incus CLI against a fixture guest.

Usage: cross-component-fixture.py (--prefix ABSOLUTE_PATH | --cassette ABSOLUTE_PATH)
                                  --incus ABSOLUTE_PATH [--report PATH] [--keep]
                                  [--incus-socket ABSOLUTE_PATH [--exec-instance NAME]]

Task 10.2. `--prefix` names a prefix that Packaging/install-local.sh installed; with
`--cassette` the script installs into its own temporary prefix first. Everything else lives
in one new owner-private directory beneath /private/tmp:

  * the installed `macus serve` runs with MACUS_FIXTURE_GUEST_DIR. Its guest's vsock ports
    are Unix sockets served here by the real guest bridge (Integration/guest/bridge.py), in
    front of the Elixir Incus fixture (Integration/scripts/incus-fixture.exs);
  * `macus start` runs with MACUS_FIXTURE_LAUNCHCTL, a stand-in that records each launchctl
    call, answers `print` in launchctl's format and launches the plists macus wrote under the
    state. The user's launchd domain, LaunchAgents and Incus configuration are not used;
  * the standard `incus` CLI uses an isolated INCUS_CONF.

With `--incus-socket`, the guest bridge forwards to that running Incus API socket (for
example an existing installation's `incus.sock`) instead of the fixture. Only reads reach it:
`/1.0`, the instance list, the event stream and the refused requests, which must never
connect. `incus exec` runs only in the instance `--exec-instance` names. The report records
the backend; it is still fixture evidence, since no Macus appliance boots.

Checks: runtime mapping, native upgrades (exec channels and the event stream), auth before
the backend, one public endpoint, and partial-startup recovery (a server lost during boot,
and a server down at a later start). The report records fixture evidence only: no VM boots,
and hardware, package and remote acceptance stay open. On failure the root is kept.
"""

import argparse
import importlib.util
import json
import os
import plistlib
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import http.client
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[2]
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
REMOTE = "macus-fixture"


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def wait_for(predicate, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise Failure(message)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def tcp(pid, *selection):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), *selection, "-Fn"],
        capture_output=True, text=True,
    )
    return sorted(line[1:] for line in result.stdout.splitlines() if line.startswith("n"))


# The launchctl stand-in. It is written beside its records and run by `macus start` with the
# exact arguments it would give /bin/launchctl. Jobs it launches get launchd's minimal
# environment plus their plist's EnvironmentVariables; the runtime job also gets the fixture
# guest directory, so the production plists stay unchanged.
STAND_IN = r'''
import json, os, plistlib, subprocess, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JOBS = os.path.join(ROOT, "launchd-jobs")
CONFIG = json.load(open(os.path.join(ROOT, "launchctl.json")))
with open(os.path.join(ROOT, "launchctl-calls.jsonl"), "a") as log:
    log.write(json.dumps({"argv": sys.argv[1:], "caller": os.environ.get("FIXTURE_CALLER", "macus")}) + "\n")

def record(label):
    path = os.path.join(JOBS, label + ".json")
    return json.load(open(path)) if os.path.exists(path) else None

def running(job):
    if not job or not job.get("pid"):
        return False
    try:
        os.kill(job["pid"], 0)
    except OSError:
        return False
    state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(job["pid"])], capture_output=True, text=True).stdout
    return bool(state.strip()) and not state.strip().startswith("Z")

def spawn(job):
    plist = job["plist"]
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": CONFIG["home"], "LANG": "en_US.UTF-8"}
    environment.update(plist.get("EnvironmentVariables", {}))
    if plist["ProgramArguments"][1:2] == ["serve"]:
        environment["MACUS_FIXTURE_GUEST_DIR"] = CONFIG["guest"]
    out = open(plist.get("StandardOutPath", os.devnull), "ab")
    err = open(plist.get("StandardErrorPath", os.devnull), "ab")
    process = subprocess.Popen(
        plist["ProgramArguments"], env=environment, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
        cwd=plist.get("WorkingDirectory", CONFIG["home"]), start_new_session=True)
    job["pid"] = process.pid
    job["environment"] = environment
    job["launches"] = job.get("launches", 0) + 1
    json.dump(job, open(os.path.join(JOBS, plist["Label"] + ".json"), "w"))

def domain_label(target):
    prefix = "gui/%d/" % os.getuid()
    if not target.startswith(prefix):
        sys.exit(64)
    return target[len(prefix):]

command = sys.argv[1:]
if command[:1] == ["print"] and len(command) == 2:
    label = domain_label(command[1])
    job = record(label)
    if job is None:
        sys.stderr.write("Bad request.\nCould not find service \"%s\" in domain for user gui: %d\n" % (label, os.getuid()))
        sys.exit(113)
    plist = job["plist"]
    lines = ["%s = {" % command[1], "\tactive count = %d" % (1 if running(job) else 0),
             "\tpath = %s" % job["path"], "\ttype = LaunchAgent",
             "\tstate = %s" % ("running" if running(job) else "not running"), "",
             "\tprogram = %s" % plist["ProgramArguments"][0], "\targuments = {"]
    lines += ["\t\t%s" % argument for argument in plist["ProgramArguments"]]
    lines += ["\t}", "", "\tenvironment = {"]
    lines += ["\t\t%s => %s" % item for item in sorted(job.get("environment", {}).items())]
    lines += ["\t}", ""]
    if running(job):
        lines.append("\tpid = %d" % job["pid"])
    lines.append("}")
    print("\n".join(lines))
elif command[:1] == ["bootstrap"] and len(command) == 3 and command[1] == "gui/%d" % os.getuid():
    plist = plistlib.load(open(command[2], "rb"))
    if record(plist["Label"]) is not None:
        sys.stderr.write("Bootstrap failed: 5: Input/output error\n")
        sys.exit(5)
    spawn({"path": command[2], "plist": plist})
elif command[:1] == ["kickstart"] and len(command) == 2:
    job = record(domain_label(command[1]))
    if job is None:
        sys.stderr.write("Could not find service\n")
        sys.exit(113)
    if not running(job):
        spawn(job)
else:
    sys.stderr.write("launchctl stand-in: unsupported %s\n" % command)
    sys.exit(64)
'''


class FixtureGuest:
    """The fixture guest's vsock ports, served by the real guest bridge's handlers."""

    def __init__(self, directory, incus_socket):
        spec = importlib.util.spec_from_file_location(
            "guest_bridge", REPOSITORY / "Integration" / "guest" / "bridge.py")
        self.bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.bridge)
        self.bridge.INCUS_SOCKET = str(incus_socket)
        self.bridge.relay_ready.set()
        self.booted = threading.Event()
        self.accepts = {8443: 0, 8444: 0}
        self.health_outcomes = {}
        self.lock = threading.Lock()
        self.listeners = []
        self.directory = directory
        for port, handler in ((8443, self.bridge.flow_relay), (8444, self.health)):
            path = directory / ("vsock-%d.sock" % port)
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(path))
            os.chmod(path, 0o600)
            listener.listen(128)
            self.listeners.append(listener)
            threading.Thread(target=self.accept, args=(listener, port, handler), daemon=True).start()

    def health(self, client):
        # Until "booted", the guest bridge is not up yet: health connections close at once.
        if not self.booted.is_set():
            self.tally("refused_before_boot")
            return
        try:
            self.bridge.health(client)
            self.tally("answered")
        except BaseException as error:
            self.tally("failed: %s" % type(error).__name__)
            raise

    def tally(self, outcome):
        with self.lock:
            self.health_outcomes[outcome] = self.health_outcomes.get(outcome, 0) + 1

    def accept(self, listener, port, handler):
        while True:
            try:
                client, _ = listener.accept()
            except OSError:
                return
            with self.lock:
                self.accepts[port] += 1

            def serve(client=client):
                try:
                    with client:
                        handler(client)
                except (OSError, ValueError):
                    pass

            threading.Thread(target=serve, daemon=True).start()

    def count(self, port):
        with self.lock:
            return self.accepts[port]

    def close(self):
        for listener in self.listeners:
            listener.close()


class Harness:
    def __init__(self, root, prefix, incus, incus_socket=None, exec_instance=None):
        self.root = root
        self.incus_socket = incus_socket
        self.exec_instance = exec_instance
        self.prefix = prefix
        self.macus = prefix / "bin" / "macus"
        self.incus = incus
        self.state = root / "state"
        self.home = root / "home"
        self.guest_dir = root / "guest"
        self.conf = root / "incus-conf"
        for directory in (self.state, self.home, self.guest_dir, self.conf, root / "bin",
                          root / "launchd-jobs"):
            directory.mkdir(mode=0o700)
        self.stand_in = root / "bin" / "launchctl"
        self.stand_in.write_text("#!%s -I\n%s" % (sys.executable, STAND_IN))
        self.stand_in.chmod(0o700)
        self.backend_log = root / "incus-requests.jsonl"
        self.backend_log.touch(mode=0o600)
        self.processes = []
        self.findings = []
        self.report = {
            "kind": "cross-component-fixture",
            "evidence": "fixture",
            "hardware_acceptance": False,
            "package_acceptance": False,
            "remote_acceptance": False,
            "vm_booted": False,
            "checks": {},
        }

    # Environment and commands.

    def environment(self, **extra):
        values = {
            "PATH": SYSTEM_PATH, "HOME": str(self.home), "LANG": "en_US.UTF-8",
            "INCUS_CONF": str(self.conf), "MACUS_BREW_FALLBACK": "0",
            "MACUS_FIXTURE_LAUNCHCTL": str(self.stand_in),
        }
        values.update(extra)
        return values

    def macus_command(self, *arguments, timeout=60):
        return subprocess.run(
            [str(self.macus), "--state-dir", str(self.state), *arguments],
            env=self.environment(), capture_output=True, text=True, timeout=timeout)

    def macus_json(self, *arguments):
        result = self.macus_command("--json", *arguments)
        check(result.returncode == 0, "macus %s failed: %s" % (" ".join(arguments), result.stderr))
        return json.loads(result.stdout)

    def incus_command(self, *arguments, timeout=30, stdin=subprocess.DEVNULL):
        return subprocess.run(
            [str(self.incus), *arguments], env=self.environment(), stdin=stdin,
            capture_output=True, text=True, timeout=timeout)

    def launchctl(self, *arguments):
        return subprocess.run(
            [str(self.stand_in), *arguments], env=self.environment(FIXTURE_CALLER="harness"),
            capture_output=True, text=True, timeout=10)

    def calls(self, caller="macus"):
        path = self.root / "launchctl-calls.jsonl"
        if not path.exists():
            return []
        entries = [json.loads(line) for line in path.read_text().splitlines()]
        return [entry["argv"] for entry in entries if entry["caller"] == caller]

    def job(self, label):
        path = self.root / "launchd-jobs" / (label + ".json")
        return json.loads(path.read_text()) if path.exists() else None

    def soft(self, condition, message):
        """A failed check that does not stop the remaining, independent checks."""
        if not condition:
            self.findings.append(message)

    def backend_requests(self):
        return [json.loads(line) for line in self.backend_log.read_text().splitlines()]

    def direct(self, path):
        """GET `path` from the backend's Incus socket itself, bypassing every Macus process."""
        connection = http.client.HTTPConnection("localhost", timeout=10)
        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.sock.settimeout(10)
        connection.sock.connect(str(self.incus_socket or self.root / "incus.sock"))
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            check(response.status == 200, "the backend answered %s for %s" % (response.status, path))
            return json.loads(response.read())["metadata"]
        finally:
            connection.close()

    # Fixture pieces.

    def start_backend(self):
        socket_path = self.root / "incus.sock"
        environment = dict(os.environ, MIX_ENV="test")
        process = subprocess.Popen(
            ["mise", "exec", "--", "mix", "run", "--no-start",
             str(REPOSITORY / "Integration" / "scripts" / "incus-fixture.exs"),
             str(socket_path), str(self.backend_log)],
            cwd=REPOSITORY / "server", env=environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=open(self.root / "incus-fixture.log", "wb"), text=True)
        self.processes.append(process)
        line = ""
        deadline = time.monotonic() + 300
        while line.strip() != "ready":
            check(time.monotonic() < deadline and process.poll() is None,
                  "the Incus fixture did not start; see incus-fixture.log")
            line = process.stdout.readline()
        self.backend = process
        return socket_path

    def seed_runtime(self):
        runtime = self.state / "runtime"
        runtime.mkdir(mode=0o700)
        for name in ("root.raw", "data.raw"):
            (runtime / name).write_text("disk-sentinel")
        manifest = self.root / "manifest.json"
        manifest.write_text("{}")
        # A complete configuration, as `macus serve` decodes it; nothing in it is ever booted.
        (self.state / "config.json").write_text(json.dumps({
            "schema_version": 1, "cpu_count": 2, "memory_mib": 2048, "data_disk_gib": 8,
            "appliance_manifest_path": str(manifest), "nested_virtualization": False,
            "shares": [], "readiness_timeout_seconds": 600, "shutdown_timeout_seconds": 60,
        }))
        for path in (self.state / "config.json", runtime / "root.raw", runtime / "data.raw"):
            path.chmod(0o600)

    def preserved(self):
        return {
            name: (self.state / name).read_bytes()
            for name in ("config.json", "runtime/root.raw", "runtime/data.raw")
        }

    def labels(self):
        jobs = sorted((self.state / "launchd").glob("*.plist"))
        labels = {}
        for path in jobs:
            plist = plistlib.load(open(path, "rb"))
            role = "server" if plist["ProgramArguments"][1:] == ["start"] else "runtime"
            labels[role] = plist["Label"]
        return labels

    def run(self, port):
        checks = self.report["checks"]
        if self.incus_socket:
            info = os.lstat(self.incus_socket)
            check(stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid(),
                  "--incus-socket is not a Unix socket owned by this user")
            incus_socket = self.incus_socket
            version = self.direct("/1.0")["environment"]["server_version"]
            self.report["backend"] = {"kind": "running-incus", "socket": str(incus_socket),
                                      "server_version": version}
        else:
            incus_socket = self.start_backend()
            self.report["backend"] = {"kind": "incus-fixture", "server_version": "7.0"}
        self.guest = FixtureGuest(self.guest_dir, incus_socket)
        self.seed_runtime()
        before = self.preserved()
        configured = self.macus_command("server", "config", "set", "--port", str(port))
        check(configured.returncode == 0, "server config set failed: %s" % configured.stderr)

        (self.root / "launchctl.json").write_text(
            json.dumps({"home": str(self.home), "guest": str(self.guest_dir)}))

        # 1. A first start whose server is lost while the guest boots.
        start = subprocess.Popen(
            [str(self.macus), "--state-dir", str(self.state), "--json", "--progress", "plain",
             "--timeout", "240", "start", "--remote", REMOTE, "--incus", str(self.incus)],
            env=self.environment(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(start)
        labels = wait_for(lambda: len(self.labels()) == 2 and self.labels(), 120,
                          "macus start did not write both plists")
        wait_for(lambda: self.guest.count(8444) > 0 or start.poll() is not None, 120,
                 "the runtime never probed the fixture guest's health")
        if start.poll() is not None:
            raise Failure("macus start ended early: %s" % start.stderr.read())
        runtime_job = self.job(labels["runtime"])
        check(runtime_job["environment"].get("MACUS_FIXTURE_GUEST_DIR") == str(self.guest_dir),
              "the runtime job was launched without the fixture guest")
        server_before = self.job(labels["server"])["pid"]
        os.kill(server_before, signal.SIGKILL)
        wait_for(lambda: not alive(server_before), 10, "the server survived SIGKILL")
        time.sleep(1)
        # launchd's KeepAlive relaunch of the crashed server.
        relaunch = self.launchctl("kickstart", "gui/%d/%s" % (os.getuid(), labels["server"]))
        check(relaunch.returncode == 0, "the stand-in could not relaunch the server")
        time.sleep(2)
        self.guest.booted.set()
        stdout, stderr = start.communicate(timeout=240)
        check(start.returncode == 0, "macus start did not recover the lost server (exit %s): %s %s"
              % (start.returncode, stdout[-2000:], stderr[-2000:]))
        result = json.loads(stdout)
        check(result.get("ready") is True and result.get("connected") is True,
              "macus start did not report ready and connected: %s" % result)
        runtime_pid = self.job(labels["runtime"])["pid"]
        check(self.job(labels["runtime"])["launches"] == 1, "the runtime job was launched twice")
        check(self.job(labels["server"])["launches"] == 2, "the server was not relaunched once")
        uid = os.getuid()
        expected_first = [
            ["print", "gui/%d/%s" % (uid, labels["server"])],
            ["print", "gui/%d/%s" % (uid, labels["runtime"])],
            ["bootstrap", "gui/%d" % uid, self.job(labels["runtime"])["path"]],
            ["bootstrap", "gui/%d" % uid, self.job(labels["server"])["path"]],
        ]
        check(self.calls() == expected_first, "macus gave launchctl %s" % self.calls())
        checks["lost_server_during_boot"] = {
            "recovered": True, "boot_resent": False, "runtime_launches": 1, "server_launches": 2,
            "launchctl": self.calls(),
        }

        # 2. Runtime mapping through the public endpoint.
        status = self.macus_json("runtime", "status")
        check(status.get("state") == "ready", "runtime status is %s" % status)
        endpoint = json.loads((self.state / "server" / "endpoint.json").read_text())
        query = self.incus_command("query", "%s:/1.0" % REMOTE)
        check(query.returncode == 0, "incus query failed: %s" % query.stderr)
        server_info = json.loads(query.stdout)
        version = self.report["backend"]["server_version"]
        check(server_info["environment"]["server_version"] == version,
              "/1.0 did not come from the guest's Incus: %s" % server_info["environment"])
        check(server_info["auth"] == "trusted", "the enrolled client is not trusted")
        project = "default"
        if self.incus_socket:
            # A project that holds instances, read from the running Incus itself.
            urls = self.direct("/1.0/instances?all-projects=true")
            projects = sorted({url.split("project=")[-1] if "project=" in url else "default"
                               for url in urls})
            project = projects[0] if projects else "default"
            expected = sorted(url.split("?")[0].rsplit("/", 1)[-1]
                              for url in self.direct("/1.0/instances?project=%s" % project))
        else:
            expected = ["c1", "c2"]
        extensions = set(self.direct("/1.0")["api_extensions"])
        check(set(server_info["api_extensions"]) <= extensions,
              "the gateway advertises extensions the backend lacks")

        def listed(*columns):
            result = self.incus_command(
                "list", "%s:" % REMOTE, "--project", project, "--format", "json", *columns)
            check(result.returncode == 0, "incus list failed: %s" % result.stderr)
            return sorted(item["name"] for item in json.loads(result.stdout))

        # The name column alone needs no per-instance state, snapshots or backups.
        names = listed("--columns", "n")
        check(names == expected, "incus list -c n returned %s, the backend has %s" % (names, expected))
        # The default columns need instance_get_full (upmaru/opsmaru-incus#85): without it the
        # client falls back to per-instance reads that stop at container_backup and drop every
        # instance. The gateway must advertise both listing extensions the backend reports.
        listing = {"api_filtering", "instance_get_full"}
        missing = listing & extensions - set(server_info["api_extensions"])
        self.soft(not missing, "the gateway does not advertise %s, which the backend reports"
                  % sorted(missing))
        default_columns = listed()
        self.soft(default_columns == expected,
                  "incus list with its default columns returned %s, the backend has %s"
                  % (default_columns, expected))
        checks["runtime_mapping"] = {
            "runtime_state": status["state"], "server_version": version, "project": project,
            "instances": names, "default_columns_instances": default_columns,
            "remote": REMOTE, "endpoint": endpoint["url"] if "url" in endpoint else None,
        }

        # 3. Native upgrades: exec's channels and the event stream.
        checks["native_upgrades"] = (
            self.upgrades_running() if self.incus_socket else self.upgrades_fixture())

        # 4. Authentication before any backend connection.
        relay_before = self.guest.count(8443)
        requests_before = len(self.backend_requests())
        refused = {}

        def https(name, path, headers=None, certificate=None):
            context = ssl.create_default_context(cafile=str(self.state / "server" / "gateway.crt"))
            if certificate:
                context.load_cert_chain(*certificate)
            connection = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=10)
            try:
                connection.request("GET", path, headers=headers or {})
                response = connection.getresponse()
                response.read()
                refused[name] = response.status
            except (ssl.SSLError, ConnectionError) as error:
                refused[name] = "tls: %s" % type(error).__name__
            finally:
                connection.close()

        stranger = self.root / "stranger"
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                        "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "%s.key" % stranger,
                        "-out", "%s.crt" % stranger, "-days", "2", "-subj", "/CN=stranger"],
                       check=True, capture_output=True)
        token_file = self.root / "runtime-read.token"
        issued = self.macus_command("server", "token", "issue", "--principal", "fixture",
                                    "--scope", "runtime.read", "--output", str(token_file))
        check(issued.returncode == 0, "token issue failed: %s" % issued.stderr)
        token = token_file.read_text().strip()
        https("anonymous", "/1.0/instances")
        https("untrusted_certificate", "/1.0/instances",
              certificate=("%s.crt" % stranger, "%s.key" % stranger))
        https("runtime_read_token", "/1.0/instances", {"Authorization": "Bearer " + token})
        https("anonymous_websocket", "/1.0/events", {
            "Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13",
            "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="})
        time.sleep(1)
        for name, outcome in refused.items():
            check(outcome in (401, 403) or str(outcome).startswith("tls"),
                  "%s was not refused: %s" % (name, outcome))
        check(self.guest.count(8443) == relay_before, "a refused request reached the guest relay")
        # Guest health checks reach Incus on their own port; none of the refused paths may.
        reached = [entry for entry in self.backend_requests()[requests_before:]
                   if entry.get("path") in ("/1.0/instances", "/1.0/events")]
        check(not reached, "a refused request reached Incus: %s" % reached)
        allowed = self.incus_command("query", "%s:/1.0/instances" % REMOTE)
        check(allowed.returncode == 0 and self.guest.count(8443) > relay_before,
              "an authorized request did not reach the guest relay")
        checks["auth_before_backend"] = {"refused": refused, "backend_connections": 0}

        # 5. One public endpoint.
        server_pid = self.job(labels["server"])["pid"]
        listening = tcp(server_pid, "-iTCP", "-sTCP:LISTEN")
        check(listening == ["127.0.0.1:%d" % port], "server listeners are %s" % listening)
        check(tcp(runtime_pid, "-i") == [], "macus serve has network sockets: %s" % tcp(runtime_pid, "-i"))
        checks["one_public_endpoint"] = {"server": listening, "runtime_network_sockets": []}

        # 6. A later start with the server down recovers it alone.
        uptime = self.macus_json("runtime", "status")["uptime_seconds"]
        os.kill(server_pid, signal.SIGKILL)
        wait_for(lambda: not alive(server_pid), 10, "the server survived SIGKILL")
        first_calls = len(self.calls())
        again = self.macus_command("--json", "--progress", "plain", "--timeout", "120", "start",
                                   "--remote", REMOTE, "--incus", str(self.incus), timeout=180)
        check(again.returncode == 0, "the recovering start failed: %s" % again.stderr)
        check(json.loads(again.stdout).get("ready") is True, "the recovering start was not ready")
        later = self.calls()[first_calls:]
        check(["kickstart", "gui/%d/%s" % (uid, labels["server"])] in later,
              "the server was not kickstarted: %s" % later)
        check(not any(call[0] == "bootstrap" for call in later), "a job was bootstrapped again")
        check(["kickstart", "gui/%d/%s" % (uid, labels["runtime"])] not in later,
              "the runtime job was kickstarted")
        check(self.job(labels["runtime"])["pid"] == runtime_pid, "the runtime process changed")
        check(self.macus_json("runtime", "status")["uptime_seconds"] >= uptime,
              "the runtime restarted")
        check(listed("--columns", "n") == expected, "incus list differs after recovery")
        check(self.preserved() == before, "runtime configuration or disks changed")
        checks["server_down_at_start"] = {"launchctl": later, "runtime_pid_unchanged": True}
        checks["disks_preserved"] = True
        self.report["findings"] = self.findings
        check(not self.findings, "%d check(s) failed: %s" % (len(self.findings), self.findings))
        self.report["success"] = True

    def monitor_line(self, arguments, trigger=None):
        monitor = subprocess.Popen(
            [str(self.incus), "monitor", "%s:" % REMOTE, *arguments, "--format", "json"],
            env=self.environment(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(monitor)
        event = {}
        reader = threading.Thread(
            target=lambda: event.update(line=monitor.stdout.readline()), daemon=True)
        reader.start()
        deadline = time.monotonic() + 20
        while reader.is_alive() and time.monotonic() < deadline:
            if trigger:
                trigger()
            reader.join(1)
        monitor.terminate()
        check(event.get("line"), "incus monitor printed no event")
        return json.loads(event["line"])

    def upgrades_fixture(self):
        exec_before = len(self.backend_requests())
        executed = self.incus_command("exec", "%s:c1" % REMOTE, "--", "true")
        check(executed.returncode == 0, "incus exec failed: %s" % executed.stderr)
        check(executed.stdout == "hello world\n" and executed.stderr == "warn\n",
              "incus exec output was %r / %r" % (executed.stdout, executed.stderr))
        channels = sorted(entry["secret"] for entry in self.backend_requests()[exec_before:]
                          if entry["kind"] == "channel")
        check(channels == ["s0", "s1", "s2", "sc"], "exec channels were %s" % channels)
        lifecycle = self.monitor_line(["--type", "lifecycle"])
        check(lifecycle["metadata"]["action"] == "instance-started", "monitor printed %s" % lifecycle)
        return {"exec_channels": channels, "event": lifecycle["metadata"]}

    def upgrades_running(self):
        # The running Incus logs each API request it handles; a read triggers one.
        logged = self.monitor_line(
            ["--type", "logging"],
            trigger=lambda: self.incus_command("query", "%s:/1.0" % REMOTE))
        check(logged.get("type") == "logging", "monitor printed %s" % logged)
        result = {"event_type": logged["type"]}
        if self.exec_instance:
            marker = "macus-fixture-%d" % os.getpid()
            executed = self.incus_command(
                "exec", "%s:%s" % (REMOTE, self.exec_instance), "--", "echo", marker)
            check(executed.returncode == 0, "incus exec failed: %s" % executed.stderr)
            check(executed.stdout == marker + "\n", "incus exec printed %r" % executed.stdout)
            result["exec"] = {"instance": self.exec_instance, "stdout": executed.stdout}
        else:
            result["exec"] = "not run: pass --exec-instance to name an instance"
        return result

    def stop(self):
        for label in self.labels().values() if (self.state / "launchd").exists() else []:
            job = self.job(label)
            if job and job.get("pid") and alive(job["pid"]):
                os.kill(job["pid"], signal.SIGTERM)
                try:
                    wait_for(lambda: not alive(job["pid"]), 30, "")
                except Failure:
                    os.kill(job["pid"], signal.SIGKILL)
        for process in self.processes:
            if process.poll() is None:
                if process.stdin:
                    process.stdin.close()
                try:
                    process.wait(10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        if getattr(self, "guest", None):
            self.guest.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--prefix", type=Path)
    source.add_argument("--cassette", type=Path)
    parser.add_argument("--incus", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--incus-socket", type=Path)
    parser.add_argument("--exec-instance")
    arguments = parser.parse_args()
    if arguments.exec_instance and not arguments.incus_socket:
        parser.error("--exec-instance needs --incus-socket")
    for value in (arguments.prefix, arguments.cassette, arguments.incus, arguments.incus_socket):
        if value is not None and not value.is_absolute():
            parser.error("paths must be absolute: %s" % value)
    root = Path(tempfile.mkdtemp(prefix="macus-x-", dir="/private/tmp"))
    harness = None
    try:
        prefix = arguments.prefix
        if prefix is None:
            prefix = root / "prefix"
            subprocess.run(["sh", str(REPOSITORY / "Packaging" / "install-local.sh"), "--prefix",
                            str(prefix), "--cassette", str(arguments.cassette)], check=True)
        harness = Harness(root, prefix, arguments.incus, arguments.incus_socket,
                          arguments.exec_instance)
        harness.run(free_port())
    except (Failure, subprocess.SubprocessError, OSError, KeyError, ValueError) as failure:
        if harness:
            harness.report["success"] = False
            harness.report["failure"] = str(failure)
            harness.report["findings"] = harness.findings
            if getattr(harness, "guest", None):
                harness.report["guest_health_at_failure"] = dict(harness.guest.health_outcomes)
                harness.report["guest_accepts_at_failure"] = dict(harness.guest.accepts)
            try:
                observed = harness.macus_command("--json", "runtime", "status", timeout=15)
                harness.report["runtime_status_at_failure"] = observed.stdout or observed.stderr
            except (subprocess.SubprocessError, OSError) as error:
                harness.report["runtime_status_at_failure"] = str(error)
        print("cross-component fixture failed: %s" % failure, file=sys.stderr)
    finally:
        if harness:
            harness.stop()
    report = harness.report if harness else {"success": False}
    text = json.dumps(report, indent=2)
    if arguments.report:
        arguments.report.write_text(text + "\n")
    print(text)
    if report.get("success") and not arguments.keep:
        shutil.rmtree(root, ignore_errors=True)
        print("cross-component fixture passed (fixture evidence; no VM booted)")
    else:
        print("kept fixture root: %s" % root, file=sys.stderr)
    sys.exit(0 if report.get("success") else 1)


if __name__ == "__main__":
    main()
