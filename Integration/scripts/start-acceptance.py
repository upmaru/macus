#!/usr/bin/env python3
"""Opt-in macus start acceptance of an installed Macus pair.

Runs only the installed pair: `<prefix>/bin/macus` and the server release at
`<prefix>/libexec/macus`. Without --opt-in it refuses before reading,
creating or running anything. With --opt-in it validates the report path,
refuses ordinary state and client configuration, and checks the installed
pair without running it:

  * paired artifacts: the executable's embedded identity equals the
    release's macus-build.json;
  * pinned dependency: the release bundles exactly the opsmaru_incus that
    server/mix.lock locks, with the recorded cassette;
  * two service labels: this state's runtime and server jobs, both distinct
    from the default jobs.

Hardware (VZ) runs only with --hardware as well. It then uses a fresh
INCUS_CONF, its own gateway port in `<state>/server/gateway.json`, and checks
that both jobs were registered for this state only, that the server's
credentials are owner-private beneath the state, and that the default jobs
and the default endpoint are unchanged. Failure artifacts are retained;
nothing is reset.
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
import socket
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LABELS = ("com.upmaru.macus", "com.upmaru.macus.server")
DEFAULT_PORT = 8443


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True,
                        help="installed prefix holding bin/macus and libexec/macus")
    parser.add_argument("--macus", type=Path,
                        help="defaults to <prefix>/bin/macus; any other executable is refused")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--incus", type=Path)
    parser.add_argument("--remote", default="macus")
    parser.add_argument("--port", type=int, help="gateway port for this state (default: a free one)")
    parser.add_argument("--hardware", action="store_true")
    parser.add_argument("--opt-in", action="store_true")
    return parser.parse_args()


def lexical(path):
    return Path(os.path.abspath(path))


def is_within(child, parent):
    try:
        lexical(child).relative_to(lexical(parent))
        return True
    except ValueError:
        return False


def is_platform_alias(path):
    if path not in (Path("/tmp"), Path("/var")):
        return False
    try:
        return os.readlink(path) in ("private" + str(path), "/private" + str(path))
    except OSError:
        return False


def reject_report_ancestry(report):
    node = lexical(report)
    seen = []
    while True:
        seen.append(node)
        if node.parent == node:
            break
        node = node.parent
    for candidate in reversed(seen):
        if candidate == lexical(report) and not os.path.lexists(candidate):
            continue
        if not os.path.lexists(candidate):
            continue
        if os.path.islink(candidate):
            if is_platform_alias(candidate):
                continue
            raise SystemExit(f"Refusing symlink report ancestry: {candidate}")
        if candidate != lexical(report) and not os.path.isdir(candidate):
            raise SystemExit(f"Report ancestry is not a directory: {candidate}")


def validate_report(report, state, prefix, macus):
    """Reject destinations that could replace runtime, install, or client data.

    This runs before any directory creation, report write, or executable invocation.
    """
    if not Path(report).is_absolute():
        raise SystemExit("Report path must be absolute")
    reject_report_ancestry(report)
    if os.path.islink(report):
        raise SystemExit("Refusing a symlink report destination")
    if os.path.lexists(report) and not os.path.isfile(report):
        raise SystemExit("Report destination must be a regular file")
    protected = [
        lexical(state),
        lexical(prefix),
        lexical(Path.home() / ".tama" / "incus-mac"),
        lexical(Path.home() / ".config" / "incus"),
    ]
    if macus:
        protected.append(lexical(macus))
    destination = lexical(report)
    for root in protected:
        if destination == root or is_within(destination, root):
            raise SystemExit(
                "Refusing a report destination inside runtime, installation, or client data")
    resolved_state = Path(state).resolve()
    resolved_prefix = Path(prefix).resolve()
    try:
        resolved_report = Path(report).resolve()
    except OSError as error:
        raise SystemExit(f"Cannot resolve report destination: {error}") from error
    for root in (resolved_state, resolved_prefix):
        try:
            resolved_report.relative_to(root)
        except ValueError:
            continue
        raise SystemExit(
            "Refusing a report destination that resolves inside runtime or installation data")



def refuse_user_paths(state, prefix, binary):
    home_state = (Path.home() / ".tama" / "incus-mac").resolve()
    resolved = state.resolve()
    if resolved == home_state or ".tama/incus-mac" in str(resolved):
        raise SystemExit("Refusing the normal ~/.tama/incus-mac state directory")
    if len(str(resolved)) > 80:
        raise SystemExit("Refusing a state path that is not short enough for Unix sockets")
    if prefix.resolve() == home_state or prefix.resolve() == Path.home():
        raise SystemExit("Refusing an ordinary installation prefix")
    if binary is not None and lexical(binary) != lexical(prefix / "bin" / "macus"):
        raise SystemExit(
            "Refusing an executable outside the installed pair: use <prefix>/bin/macus")


def refuse_user_client(client):
    if client.resolve() == (Path.home() / ".config" / "incus").resolve():
        raise SystemExit("Refusing the normal Incus client configuration")


class PairFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PairFailure(message)


def locked_opsmaru_incus(lock=None):
    text = (lock or ROOT / "server" / "mix.lock").read_text()
    found = re.findall(r'"opsmaru_incus": \{:hex, :opsmaru_incus, "([^"]+)"', text)
    require(len(found) == 1, "server/mix.lock does not lock opsmaru_incus from Hex")
    return found[0]


def file_digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def embedded_identity(binary):
    candidate = load_module("homebrew_candidate", ROOT / "Packaging/homebrew/candidate.py")
    try:
        return candidate.embedded_identity(binary)
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        raise PairFailure(f"{binary} embeds no Macus identity") from error


def service_labels(state):
    """(runtime, server) for this state: the labels LaunchAgentPlan derives."""
    module = load_module("homebrew_acceptance", ROOT / "Integration/scripts/homebrew-acceptance.py")
    return module.service_labels(state)


def installed_pair(prefix, lock=None):
    """Checks the installed pair without running it; returns its identity and checks."""
    binary = prefix / "bin" / "macus"
    release = prefix / "libexec" / "macus"
    require(not binary.is_symlink() and binary.is_file() and os.access(binary, os.X_OK),
            f"No installed macus executable at {binary}")
    record_path = release / "macus-build.json"
    require(release.is_dir() and not record_path.is_symlink() and record_path.is_file(),
            f"No installed server release with macus-build.json at {release}")
    require(not record_path.stat().st_mode & 0o222,
            "The installed server release build record is writable")
    record = json.loads(record_path.read_text())
    require(record.get("schema_version") == 1, "Unknown macus-build.json schema")
    version, revision = embedded_identity(binary)
    require(bool(version) and bool(revision), f"{binary} embeds no Macus identity")
    require((record.get("version"), record.get("revision")) == (version, revision),
            f"Unpaired artifacts: macus is {version} ({revision}) but the server release is "
            f"{record.get('version')} ({record.get('revision')})")
    locked = locked_opsmaru_incus(lock)
    library = record.get("opsmaru_incus") or {}
    bundled = sorted(entry.name for entry in (release / "lib").iterdir()
                     if entry.name.startswith("opsmaru_incus-"))
    require(library.get("version") == locked and bundled == [f"opsmaru_incus-{locked}"],
            f"The server release does not bundle the pinned opsmaru_incus {locked}: "
            f"records {library.get('version')}, bundles {bundled}")
    cassette = library.get("cassette") or {}
    folder = release / "lib" / f"macus-{version}" / "priv" / "cassettes"
    expected = f"opsmaru_incus-{locked}.tama-cassette"
    require(cassette.get("file") == expected and folder.is_dir()
            and sorted(entry.name for entry in folder.iterdir()) == [expected]
            and not (folder / expected).is_symlink()
            and file_digest(folder / expected) == cassette.get("sha256"),
            f"The server release does not bundle only the pinned {expected}")
    return {
        "version": version, "revision": revision, "opsmaru_incus": locked,
        "cassette_sha256": cassette["sha256"], "binary": str(binary), "release": str(release),
    }


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise SystemExit(f"Refusing a state directory that is not this user's: {path}")
    os.chmod(path, 0o700)


def gateway_port(state, requested):
    """This state's own gateway port: an existing gateway.json is kept, never the default port."""
    server = state / "server"
    config = server / "gateway.json"
    if config.is_symlink():
        raise SystemExit(f"Refusing a symlinked gateway configuration: {config}")
    if config.exists():
        port = json.loads(config.read_text()).get("port")
        if not isinstance(port, int) or port == DEFAULT_PORT or (requested and port != requested):
            raise SystemExit(f"{config} does not select this state's own gateway port")
        return port
    port = requested or free_port()
    if port == DEFAULT_PORT:
        raise SystemExit("Refusing the default gateway port for isolated acceptance")
    private_directory(server)
    descriptor = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump({"schema_version": 1, "port": port}, handle)
    return port


def stat_identity(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    return [info.st_ino, info.st_size, info.st_mtime_ns]


def default_footprint(launchctl="/bin/launchctl"):
    """Read-only view of the default jobs and endpoint; isolated acceptance must not change it."""
    home = Path.home()
    jobs = {}
    for label in DEFAULT_LABELS:
        result = subprocess.run([launchctl, "print", f"gui/{os.getuid()}/{label}"],
                                capture_output=True, text=True, timeout=30)
        pid = re.search(r"^\tpid = (\d+)$", result.stdout, re.MULTILINE)
        jobs[label] = {"loaded": result.returncode == 0, "pid": pid and int(pid.group(1)),
                       "plist": stat_identity(home / "Library/LaunchAgents" / f"{label}.plist")}
    endpoint = stat_identity(home / ".tama/incus-mac/server/endpoint.json")
    return {"jobs": jobs, "endpoint": endpoint}


def registered_jobs(state, labels, pair):
    """Both plists live in this state's launchd directory, name its state and the installed pair."""
    runtime_label, server_label = labels
    resolved = str(state.resolve())
    found = {}
    for label in labels:
        path = state / "launchd" / f"{label}.plist"
        if path.is_symlink() or not path.is_file():
            raise PairFailure(f"No plist for {label} in this state's launchd directory")
        if (Path.home() / "Library/LaunchAgents" / f"{label}.plist").exists():
            raise PairFailure(f"{label} was written to ~/Library/LaunchAgents")
        found[label] = plistlib.loads(path.read_bytes())
        if found[label].get("Label") != label:
            raise PairFailure(f"{path} does not name {label}")
    runtime, server = found[runtime_label], found[server_label]
    arguments = runtime.get("ProgramArguments") or []
    if (len(arguments) != 4 or arguments[1:3] != ["serve", "--state-dir"]
            or Path(arguments[0]).resolve() != Path(pair["binary"]).resolve()
            or Path(arguments[3]).resolve() != Path(resolved)):
        raise PairFailure("The runtime job does not run the installed macus for this state")
    environment = server.get("EnvironmentVariables") or {}
    launcher = (server.get("ProgramArguments") or [""])[0]
    if (Path(launcher).resolve() != (Path(pair["release"]) / "bin/macus").resolve()
            or Path(environment.get("MACUS_STATE_DIR", "/")).resolve() != Path(resolved)
            or environment.get("MACUS_EXPECTED_REVISION") != pair["revision"]):
        raise PairFailure("The server job does not run the paired release for this state")


def private_credentials(state):
    server = state / "server"
    info = os.lstat(server)
    if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.getuid():
        raise PairFailure("The server credential directory is not owner-private")
    for name in ("gateway.crt", "gateway.key", "endpoint.json"):
        entry = os.lstat(server / name)
        if not stat.S_ISREG(entry.st_mode) or entry.st_mode & 0o077:
            raise PairFailure(f"server/{name} is not an owner-private file")


def main():
    args = parse_args()
    if not args.opt_in:
        raise SystemExit("Refusing to run without --opt-in")
    # Validate the report before creating client directories, state, or running macus.
    validate_report(args.report, args.state_dir, args.prefix, args.macus)
    state = args.state_dir
    prefix = args.prefix
    refuse_user_paths(state, prefix, args.macus)
    report = {
        "schema_version": 2,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Opt-in macus start of the installed pair with isolated state, credentials, "
                 "INCUS_CONF, gateway port and service labels",
        "hardware_ran": False,
        "guest_verified": False,
        "brew_install_ran": False,
        "state_dir": str(state.resolve()),
        "prefix": str(prefix.resolve()),
        "checks": {},
    }
    report_path = args.report

    def save():
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n")

    save()
    # The installed pair is checked by reading it; nothing runs and no state is created.
    try:
        pair = installed_pair(prefix)
        labels = service_labels(state.resolve())
        if set(labels) & set(DEFAULT_LABELS) or labels[0] == labels[1]:
            raise PairFailure("This state's service labels are not distinct isolated labels")
    except (PairFailure, OSError, ValueError, KeyError) as error:
        report["success"] = False
        report["failure"] = str(error)
        save()
        raise SystemExit(f"Installed pair check failed: {error}")
    report["pair"] = pair
    report["service_label"], report["server_label"] = labels
    report["checks"].update(paired_artifacts=True, pinned_dependency=True, two_service_labels=True)
    save()
    if not args.hardware:
        report["checks"]["refused_without_hardware_opt_in"] = True
        report["note"] = ("Hardware acceptance was not run. Package, fixture or unit success is not "
                          "physical first-use evidence.")
        save()
        raise SystemExit("Hardware acceptance was not run; pass --hardware to execute macus start")
    client = Path(tempfile.mkdtemp(prefix="macus-start-incus-conf-"))
    refuse_user_client(client)
    report["incus_conf"] = str(client.resolve())
    private_directory(state)
    port = gateway_port(state, args.port)
    report["gateway_port"] = port
    before = default_footprint()
    report["default_footprint_before"] = before
    env = dict(os.environ, INCUS_CONF=str(client), MACUS_BREW_FALLBACK="0")
    for variable in ("MACUS_STATE_DIR", "MACUS_FIXTURE_GUEST_DIR", "MACUS_FIXTURE_LAUNCHCTL"):
        env.pop(variable, None)
    command = [
        pair["binary"], "--state-dir", str(state.resolve()), "--json", "--progress", "plain",
        "--timeout", "1800", "start", "--remote", args.remote,
    ]
    if args.incus:
        command[1:1] = ["--incus", str(args.incus.resolve(strict=True))]
    # Nondefault state keeps both jobs under <state>/launchd, never ~/Library/LaunchAgents.
    try:
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=1800)
        report.setdefault("commands", []).append({
            "tool": "macus", "arguments": command[1:], "exit_code": result.returncode,
            "stdout": result.stdout[-4000:], "stderr": result.stderr[-4000:],
        })
        report["hardware_ran"] = True
        if result.returncode == 0:
            body = json.loads(result.stdout)
            checks = report["checks"]
            checks["ready"] = body.get("ready") is True
            checks["connected"] = body.get("connected") is True
            checks["isolated_labels_reported"] = (
                body.get("service_label"), body.get("server_label")) == tuple(labels)
            url = (body.get("server_endpoint") or {}).get("url", "")
            checks["isolated_gateway_port"] = url.rstrip("/").endswith(f":{port}")
            registered_jobs(state, labels, pair)
            checks["jobs_registered_for_state"] = True
            private_credentials(state)
            checks["isolated_credentials"] = True
            after = default_footprint()
            report["default_footprint_after"] = after
            checks["default_jobs_and_endpoint_unchanged"] = after == before
            report["guest_verified"] = checks["ready"] and checks["connected"]
            report["success"] = all(checks.get(name) for name in (
                "ready", "connected", "isolated_labels_reported", "isolated_gateway_port",
                "default_jobs_and_endpoint_unchanged"))
        else:
            report["success"] = False
            report["note"] = "Start failed. State, logs and this report were preserved."
    except Exception as error:
        report["success"] = False
        report["note"] = f"Acceptance failed and artifacts were preserved: {error}"
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        save()
    if not report.get("success"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
