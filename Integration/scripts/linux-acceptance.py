#!/usr/bin/env python3
"""Opt-in Linux/Incus boot and workload acceptance through the public gateway (task 11.7).

Runs against a state that an installed Macus package started, with the isolated
INCUS_CONF whose remote names this state's public HTTPS gateway. Without
--opt-in it refuses before reading, creating or running anything. With --opt-in
it validates the report path, refuses ordinary state, prefix and client
configuration, checks the installed pair and the fixture. Nothing is stopped,
created or launched without --hardware as well.

With --hardware, every Incus request goes through the gateway with the standard
`incus` client:

  * Linux/Incus boot: the runtime is stopped and started again from the
    installed package; the guest kernel's boot id changes, and the guest's
    Linux kernel and Incus server report ready through the gateway;
  * in a project of this run's own (refused if it already exists), each
    fixture workload (Integration/fixtures/linux-acceptance.json) is launched
    and must reach Running and pass its fixture-defined readiness command:
    a system container, an OCI container and a nested virtual machine;
  * a workload whose capability the runtime does not report (`vm`, `oci`) is
    recorded as an explicit skip with that reason, never as a pass.

Boot evidence (`evidence.boot`), readiness (`evidence.readiness`), gateway
HTTP/MCP checks (`evidence.gateway`) and reported capabilities
(`evidence.capabilities`) are kept apart. On success the run's workloads, its
project and OCI remote are removed; on any failure they, the state and the
diagnostics are kept.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "Integration/fixtures/linux-acceptance.json"
KINDS = {"system-container": [], "oci-container": [], "virtual-machine": ["--vm"]}
PROJECT_MARKER = "user.macus.acceptance"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


workload = load("workload_acceptance", "Integration/scripts/workload-acceptance.py")
start = workload.start
require, CheckFailure = workload.require, workload.CheckFailure


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True,
                        help="the installed package (bin/macus, libexec/macus), e.g. ROOT/opt/macus")
    parser.add_argument("--lock", type=Path, help="server/mix.lock of the installed revision")
    parser.add_argument("--incus-conf", type=Path, required=True)
    parser.add_argument("--incus", type=Path, required=True)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--fixture", type=Path, default=FIXTURE)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--hardware", action="store_true")
    parser.add_argument("--opt-in", action="store_true")
    return parser.parse_args()


def fixture(path):
    """The workloads and their readiness, validated before anything runs."""
    data = json.loads(Path(path).read_text())
    require(data.get("schema_version") == 1, "unknown fixture schema")
    project = data.get("project") or ""
    require(project.startswith("macus-") and project != "default", "the fixture must name its own project")
    names = set()
    for entry in data.get("workloads") or []:
        require(entry.get("kind") in KINDS, f"unknown workload kind {entry.get('kind')}")
        require(entry.get("name", "").startswith("macus-") and entry["name"] not in names,
                f"workload names must be unique and start with macus-: {entry.get('name')}")
        names.add(entry["name"])
        readiness = entry.get("readiness") or {}
        require(isinstance(readiness.get("command"), list) and readiness.get("expect")
                and isinstance(readiness.get("timeout_seconds"), int),
                f"{entry['name']} has no complete readiness check")
        if entry["kind"] == "oci-container":
            remote = (data.get("oci_remote") or {}).get("name")
            require(remote and entry["image"].startswith(remote + ":"),
                    f"{entry['name']} must use the fixture's own OCI remote")
    require({entry["kind"] for entry in data["workloads"]} == set(KINDS),
            "the fixture must define a system container, an OCI container and a virtual machine")
    return data


def workloads_complete(spec, checks, skipped):
    """Every workload booted and became ready, or was skipped because the runtime does not
    report the capability the fixture says it requires (nested VMs on an unsupported host)."""
    for entry in spec["workloads"]:
        name = entry["kind"].replace("-", "_")
        if name in skipped and entry.get("requires_capability"):
            continue
        if not (checks.get(name + "_boot") and checks.get(name + "_readiness")):
            return False
    return True


class Linux(workload.Acceptance):
    def __init__(self, args, report, run, endpoint, spec, labels):
        args.instance = "-"
        super().__init__(args, report, run, endpoint)
        self.spec, self.labels = spec, labels
        self.project = spec["project"]
        self.created = []
        self.added_remote = None

    def in_project(self, *arguments, **options):
        extra = ["--project", self.project] if self.project else []
        return self.ok(*arguments, *extra, **options)

    def project_query(self, path):
        separator = "&" if "?" in path else "?"
        suffix = f"{separator}project={self.project}" if self.project else ""
        return json.loads(self.ok("query", f"{self.args.remote}:{path}{suffix}").stdout)

    def boot_id(self, target, project=None):
        extra = ["--project", project] if project else []
        result = self.incus_command("exec", target, *extra, "--", "cat", "/proc/sys/kernel/random/boot_id")
        return result.stdout.strip() if result.returncode == 0 else None

    def server(self):
        metadata = json.loads(self.ok("query", f"{self.args.remote}:/1.0").stdout)
        environment = metadata.get("environment") or {}
        return {"auth": metadata.get("auth"), "kernel": environment.get("kernel"),
                "kernel_version": environment.get("kernel_version"),
                "kernel_architecture": environment.get("kernel_architecture"),
                "os_name": environment.get("os_name"), "os_version": environment.get("os_version"),
                "server_version": environment.get("server_version"),
                "drivers": environment.get("driver"), "storage": environment.get("storage")}

    def linux_boot(self):
        """Stop the runtime and start it again from the installed package: a fresh guest boot."""
        probe = self.spec.get("boot_probe", "macus-accept")
        before = self.boot_id(f"{self.args.remote}:{probe}")
        self.run.macus(["--json", "runtime", "stop"], timeout=600, json_output=True)
        stopped = self.run.macus(["--json", "runtime", "status"], json_output=True)
        require(stopped.get("state") == "stopped", f"runtime is {stopped.get('state')} after stop")
        began = time.monotonic()
        started = self.run.macus(["--json", "--progress", "none", "--incus", self.incus, "start",
                                  "--remote", self.args.remote], timeout=1900, json_output=True)
        ready_after = round(time.monotonic() - began, 1)
        require(started.get("ready") is True and started.get("connected") is True,
                f"start was not ready and connected: {started}")
        self.report["evidence"]["capabilities"] = started.get("capabilities")
        status = self.run.macus(["--json", "runtime", "status"], json_output=True)
        server = self.server()
        require(server["kernel"] == "Linux" and server["auth"] == "trusted",
                f"the guest server reports {server}")
        after = None
        deadline = time.monotonic() + 180
        while before and after is None and time.monotonic() < deadline:
            after = self.boot_id(f"{self.args.remote}:{probe}")
            if after is None:
                state = json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/{probe}/state").stdout)
                if state.get("status") == "Stopped":
                    self.ok("start", f"{self.args.remote}:{probe}", timeout=300)
                time.sleep(3)
        require(before is None or (after and after != before),
                f"the guest boot id did not change ({before} -> {after})")
        return {"ready_after_seconds": ready_after, "runtime_state": status.get("state"),
                "uptime_seconds": status.get("uptime_seconds"),
                "guest_boot_id": {"before": before, "after": after}, "server": server}

    def create_project(self):
        advertised = (json.loads(self.ok("query", f"{self.args.remote}:/1.0").stdout)
                      .get("api_extensions") or [])
        if "projects" not in advertised:
            # The standard client refuses --project and `project create` unless the server
            # advertises `projects`. The state itself is isolated; the run's workloads then use
            # its default project under names that must not exist yet.
            wanted = self.project
            self.project = None
            for entry in self.spec["workloads"]:
                existing = self.incus_command("query", f"{self.args.remote}:/1.0/instances/{entry['name']}")
                require(existing.returncode != 0, f"refusing: instance {entry['name']} already exists")
            self.report.setdefault("findings", []).append(
                f"The gateway does not advertise the `projects` API extension, so the standard client "
                f"cannot create or select project {wanted}; workloads ran in the isolated state's "
                f"default project.")
            return {"project": None, "requested": wanted, "reason": "projects extension not advertised",
                    "advertised_extensions": advertised}
        existing = self.incus_command("query", f"{self.args.remote}:/1.0/projects/{self.project}")
        require(existing.returncode != 0, f"refusing: project {self.project} already exists")
        self.ok("project", "create", f"{self.args.remote}:{self.project}",
                "-c", "features.images=false", "-c", "features.profiles=false",
                "-c", f"{PROJECT_MARKER}=11.7")
        return {"project": self.project}

    def oci_remote(self):
        remote = self.spec["oci_remote"]
        remotes = json.loads(self.ok("remote", "list", "--format", "json").stdout)
        require(remote["name"] not in remotes, f"refusing: remote {remote['name']} already exists")
        self.ok("remote", "add", remote["name"], remote["url"], "--protocol=oci")
        self.added_remote = remote["name"]
        return {"remote": remote["name"], "url": remote["url"]}

    def launch(self, entry):
        target = f"{self.args.remote}:{entry['name']}"
        arguments = ["launch", entry["image"], target, *KINDS[entry["kind"]]]
        for device, value in (entry.get("devices") or {}).items():
            arguments += ["-d", f"{device},{value}"]
        for key, value in (entry.get("config") or {}).items():
            arguments += ["-c", f"{key}={value}"]
        began = time.monotonic()
        self.created.append(entry["name"])
        self.in_project(*arguments, timeout=1800)
        deadline = time.monotonic() + 300
        while True:
            state = self.project_query(f"/1.0/instances/{entry['name']}/state")
            if state.get("status") == "Running":
                break
            require(time.monotonic() < deadline, f"{entry['name']} is {state.get('status')}")
            time.sleep(2)
        running_after = round(time.monotonic() - began, 1)
        instance = self.project_query(f"/1.0/instances/{entry['name']}")
        return {"kind": entry["kind"], "image": entry["image"], "type": instance.get("type"),
                "base_image": instance.get("config", {}).get("volatile.base_image"),
                "status": "Running", "running_after_seconds": running_after}

    def ready(self, entry):
        readiness = entry["readiness"]
        target = f"{self.args.remote}:{entry['name']}"
        began = time.monotonic()
        last = None
        while time.monotonic() - began < readiness["timeout_seconds"]:
            extra = ["--project", self.project] if self.project else []
            result = self.incus_command("exec", target, *extra, "--", *readiness["command"], timeout=60)
            last = {"exit_code": result.returncode, "stdout": result.stdout[-400:],
                    "stderr": result.stderr[-400:]}
            if result.returncode == 0 and readiness["expect"] in result.stdout:
                return {"ready_after_seconds": round(time.monotonic() - began, 1),
                        "command": readiness["command"], "expect": readiness["expect"],
                        "output": result.stdout.strip()[-200:]}
            time.sleep(3)
        raise CheckFailure(f"{entry['name']} did not pass readiness in "
                           f"{readiness['timeout_seconds']} s: {last}")

    def gateway(self, tokens):
        token = tokens.issue("runtime.read")
        gateway = start.Gateway(self.endpoint)
        status, body = gateway.request("GET", "/runtime/status", token)
        require(status == 200 and body.get("state") == "ready", f"/runtime/status gave {status}")
        listed = self.project_query("/1.0/instances")
        names = sorted(path.rsplit("/", 1)[-1].split("?")[0] for path in listed
                       if path.rsplit("/", 1)[-1].split("?")[0] in self.created)
        return {"runtime_status": status, "runtime_state": body.get("state"),
                "project_instances": names}

    def clean_up(self):
        for name in self.created:
            self.in_project("delete", "--force", f"{self.args.remote}:{name}", timeout=600)
        if self.project:
            self.ok("project", "delete", f"{self.args.remote}:{self.project}")
        # Only a remote this run added is removed; a skipped OCI workload never
        # checked for, or added, one of that name.
        remote = self.added_remote
        if remote and remote in json.loads(self.ok("remote", "list", "--format", "json").stdout):
            self.ok("remote", "remove", remote)
        return {"removed": self.created, "project_removed": self.project, "oci_remote_removed": remote}


def main():
    args = parse_args()
    if not args.opt_in:
        raise SystemExit("Refusing to run without --opt-in")
    state, prefix = args.state_dir, args.prefix
    start.validate_report(args.report, state, prefix, None, client=args.incus_conf)
    start.refuse_user_paths(state, prefix, None)
    start.refuse_user_client(args.incus_conf)
    report = {
        "schema_version": 1,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Opt-in Linux/Incus boot, system/OCI container and nested VM through the public gateway",
        "hardware_ran": False, "state_dir": str(state.resolve()), "prefix": str(prefix),
        "incus_conf": str(args.incus_conf.resolve()), "checks": {},
        "evidence": {"boot": {}, "readiness": {}, "gateway": {}, "capabilities": None},
        "skipped": {},
    }

    def save():
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")

    save()
    try:
        spec = fixture(args.fixture)
        pair = start.installed_pair(prefix, args.lock)
    except (start.PairFailure, CheckFailure, OSError, ValueError, KeyError) as error:
        report["success"], report["failure"] = False, str(error)
        save()
        raise SystemExit(f"Installed pair or fixture check failed: {error}")
    report["pair"] = pair
    report["fixture"] = {"project": spec["project"],
                         "workloads": [{k: e[k] for k in ("name", "kind", "image")} for e in spec["workloads"]]}
    save()
    if not args.hardware:
        report["note"] = "Hardware acceptance was not run; nothing was stopped, created or launched."
        save()
        raise SystemExit("Hardware acceptance was not run; pass --hardware to boot workloads")
    env = dict(os.environ, INCUS_CONF=str(args.incus_conf.resolve()), MACUS_BREW_FALLBACK="0")
    for variable in ("MACUS_STATE_DIR", "MACUS_FIXTURE_GUEST_DIR", "MACUS_FIXTURE_LAUNCHCTL"):
        env.pop(variable, None)
    endpoint = json.loads((state / "server" / "endpoint.json").read_text())
    run = start.Run(pair["binary"], state.resolve(), env, report)
    remotes = run.command([str(args.incus), "remote", "list", "--format", "json"], 60, "incus")
    entry = json.loads(remotes.stdout).get(args.remote, {}) if remotes.returncode == 0 else {}
    addresses = entry.get("Addrs") or ([entry["Addr"]] if entry.get("Addr") else [])
    if addresses != [endpoint["url"]]:
        report["success"] = False
        report["failure"] = f"remote {args.remote} is {addresses}, not this state's {endpoint['url']}"
        save()
        raise SystemExit("Refusing: the client's remote is not this state's public gateway")
    report["hardware_ran"] = True
    labels = start.service_labels(state.resolve())
    footprint = start.default_footprint()
    linux = Linux(args, report, run, endpoint, spec, labels)
    tokens = start.Tokens(run, Path(tempfile.mkdtemp(prefix="macus-linux-tokens-")))
    checks, evidence = report["checks"], report["evidence"]

    def attempt(name, function, *arguments, into=None):
        try:
            result = function(*arguments)
            if into is not None:
                into[name] = result
            else:
                report.setdefault("details", {})[name] = result
            checks[name] = True
            return True
        except Exception as error:  # Each check is recorded; workloads are kept on failure.
            checks[name] = False
            (into if into is not None else report.setdefault("details", {}))[name] = {
                "error": f"{type(error).__name__}: {error}"}
            return False
        finally:
            save()

    try:
        if attempt("linux_incus_boot", linux.linux_boot, into=evidence["boot"]):
            capabilities = (evidence["capabilities"] or {}).get("capabilities") or {}
            if attempt("project", linux.create_project):
                for entry in spec["workloads"]:
                    needed = entry.get("requires_capability")
                    name = entry["kind"].replace("-", "_")
                    if needed and not capabilities.get(needed):
                        report["skipped"][name] = (f"the runtime does not report the {needed} capability "
                                                   f"(capabilities: {capabilities})")
                        continue
                    if entry["kind"] == "oci-container" and not attempt("oci_remote", linux.oci_remote):
                        continue
                    if attempt(name + "_boot", linux.launch, entry, into=evidence["boot"]):
                        attempt(name + "_readiness", linux.ready, entry, into=evidence["readiness"])
                attempt("gateway_http", linux.gateway, tokens, into=evidence["gateway"])
    finally:
        tokens.revoke_all(report)
        checks["default_jobs_and_endpoint_unchanged"] = start.default_footprint() == footprint
        report["success"] = (all(checks.values()) and "gateway_http" in checks
                             and workloads_complete(spec, checks, report["skipped"]))
        if report["success"]:
            attempt("clean_up", linux.clean_up)
            report["success"] = checks["clean_up"]
        else:
            report["note"] = "Workloads, the project, the OCI remote and the state are kept for diagnosis."
            logs = {}
            for path in sorted((state / "logs").glob("*")):
                if path.is_file():
                    logs[path.name] = path.read_text(errors="replace")[-4000:]
            report["diagnostics"] = {"logs": logs}
        save()
    print(args.report)
    if not report["success"]:
        raise SystemExit("Linux acceptance failed; inspect the retained report")


if __name__ == "__main__":
    main()
