#!/usr/bin/env python3
"""Explicit installed-bottle hardware phases; failures retain the isolated appliance."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import sys
import time

MODULE = Path(__file__).resolve().parents[2] / "Packaging/homebrew/candidate.py"
SPEC = importlib.util.spec_from_file_location("homebrew_candidate", MODULE)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)
START = Path(__file__).resolve().parent / "start-acceptance.py"
START_SPEC = importlib.util.spec_from_file_location("start_acceptance", START)
start_acceptance = importlib.util.module_from_spec(START_SPEC)
START_SPEC.loader.exec_module(start_acceptance)


def fixture_paths(root, first=False):
    if not Path(root).is_absolute():
        raise ValueError("Use an absolute short isolated test root")
    root = candidate.safe_path(root)
    state, client = candidate.safe_path(root / "state"), candidate.safe_path(root / "client")
    candidate.safe_path(root / "hardware.json")
    if len(str(state)) > 80:
        raise ValueError("Use an absolute short isolated test root")
    if root == Path.home() or root == Path("/"):
        raise ValueError("Refusing an ordinary test root")
    if first and root.exists() and any(root.iterdir()):
        raise ValueError("First acceptance requires a fresh empty test root")
    return root, state, client


# Runtime disks and settings, compared by file identity: a booted guest rewrites their contents.
DISKS = ("runtime/root.raw", "runtime/data.raw", "runtime/efi.bin")
# Settings, server credentials and trust, compared by content. endpoint.json is rewritten by every start.
SETTINGS = ("config.json",)
CREDENTIALS = ("server/gateway.crt", "server/gateway.key", "server/gateway.json", "server/bearer-tokens.json",
               "server/local-cli.token", "server/trusted-certificates.json", "server/trust-tokens.json",
               "server/trust-token-redemptions.json")


def service_label(state):
    # Foundation standardizes Darwin's /private/tmp and /private/var aliases.
    path = str(state)
    for alias in ("/private/tmp/", "/private/var/"):
        if path.startswith(alias):
            path = path.removeprefix("/private")
            break
    return "com.upmaru.macus." + hashlib.sha256(path.encode()).hexdigest()[:12]


def service_labels(state):
    """(runtime, server): the two jobs macus start owns for an isolated state, one hash on both."""
    runtime = service_label(state)
    return runtime, runtime.replace("com.upmaru.macus.", "com.upmaru.macus.server.", 1)


def isolated_gateway_port(state):
    """This state's own gateway port in STATE/server/gateway.json, never the default 8443.

    Without it the isolated server would bind the default port, which an ordinary runtime on the
    same host already holds, and crash-loop on eaddrinuse instead of serving the isolated state.
    """
    return start_acceptance.gateway_port(state, None)


def owned_plist(state, label):
    """The plist of one of this state's two jobs, only if it is that job for this state."""
    path = candidate.safe_path(state / "launchd" / f"{label}.plist")
    if not path.exists():
        return None
    data = plistlib.loads(path.read_bytes())
    arguments = data.get("ProgramArguments") or []
    targets = (data.get("EnvironmentVariables") or {}).get("MACUS_STATE_DIR") == str(state) or (
        "--state-dir" in arguments and str(state) in arguments)
    if data.get("Label") != label or not targets:
        raise ValueError(f"Refusing a plist that is not this state's {label}")
    return path


def loaded(label):
    return subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"],
                          capture_output=True, timeout=10).returncode == 0


def wait_unloaded(labels, seconds=60):
    deadline = time.monotonic() + seconds
    while any(loaded(label) for label in labels):
        if time.monotonic() > deadline:
            raise ValueError("A Macus job is still loaded after bootout")
        time.sleep(1)


def keyed(salt, data):
    """A digest only this fixture can reproduce: the report never holds a secret or a plain hash of one."""
    return hashlib.blake2b(data, key=bytes.fromhex(salt), digest_size=32).hexdigest()


def retained(state, client, salt):
    """What every package transition must keep: disks, settings, credentials and client configuration."""
    snapshot = {"disks": {}, "content": {}}
    for name in DISKS:
        path = state / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"The isolated runtime has no {name}")
        info = path.stat()
        snapshot["disks"][name] = [info.st_ino, info.st_size]
    if not (state / "server/gateway.crt").is_file():
        raise ValueError("The isolated server has no gateway identity")
    files = [state / name for name in SETTINGS + CREDENTIALS]
    # The client's configuration, identity and pinned server certificates, not caches it may add.
    files += [client / name for name in ("config.yml", "client.crt", "client.key")]
    files += sorted((client / "servercerts").glob("*.crt"))
    for path in files:
        if path.is_symlink():
            raise ValueError(f"Refusing a linked retained file: {path}")
        if path.is_file():
            label = str(path.relative_to(state)) if path.is_relative_to(state) else "client/" + str(path.relative_to(client))
            snapshot["content"][label] = keyed(salt, path.read_bytes())
    certificate = (state / "server/gateway.crt").read_bytes()
    snapshot["gateway_certificate_sha256"] = hashlib.sha256(certificate).hexdigest()
    return snapshot


def require_retained(report, state, client):
    recorded = report.get("retained")
    if not recorded or not report.get("retention_salt"):
        raise ValueError("No retained data was recorded at stop")
    current = retained(state, client, report["retention_salt"])
    changed = sorted(name for kind in ("disks", "content")
                     for name in set(recorded[kind]) | set(current[kind])
                     if recorded[kind].get(name) != current[kind].get(name))
    if changed or recorded["gateway_certificate_sha256"] != current["gateway_certificate_sha256"]:
        raise ValueError(f"The package transition did not retain {changed or ['the gateway certificate']}")


def stop_and_unload(binary, state, client, labels, transition, env, report):
    """Stop the runtime, unload the server job and then the runtime job, and remove only owned plists."""
    execute([binary, "--state-dir", str(state), "--json", "runtime", "stop"], env, report)
    status = json.loads(execute([binary, "--state-dir", str(state), "--json", "runtime", "status"], env, report))
    if status.get("state") != "stopped":
        raise ValueError("Runtime did not stop before package change")
    runtime, server = labels
    plists = {label: owned_plist(state, label) for label in labels}
    for label in (server, runtime):
        if loaded(label):
            execute(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}"], env, report)
    wait_unloaded(labels)
    # The server plist names the package revision; the runtime plist names the stable opt path.
    for label in ((server, runtime) if transition == "removal" else (server,)):
        if plists[label]:
            plists[label].unlink()
    report["retention_salt"] = report.get("retention_salt") or secrets.token_hex(32)
    report["retained"] = retained(state, client, report["retention_salt"])
    report["checks"]["stopped_and_unloaded"] = True
    report["transition"] = transition


def require_upgrade(report, manifest):
    stopped = report.get("stopped_version")
    if not report.get("checks", {}).get("stopped_and_unloaded") or not stopped:
        raise ValueError("Resume requires a recorded successful stop and unload")
    if report.get("transition", "upgrade") != "upgrade":
        raise ValueError("Resume requires a stop recorded for an upgrade or rollback")
    if stopped == manifest["version"]:
        raise ValueError("Resume requires a different installed package candidate")


def require_reregistered(state, server, manifest):
    path = owned_plist(state, server)
    revision = plistlib.loads(path.read_bytes())["EnvironmentVariables"].get("MACUS_EXPECTED_REVISION") if path else None
    if revision != manifest["source_commit"]:
        raise ValueError("The server job was not registered again for the installed revision")


def require_removed(report, state, client, labels):
    if report.get("transition") != "removal" or not report.get("checks", {}).get("stopped_and_unloaded"):
        raise ValueError("Removal requires a recorded stop for removal")
    if any(loaded(label) for label in labels):
        raise ValueError("A Macus job is still loaded after removal")
    if any(owned_plist(state, label) for label in labels):
        raise ValueError("An owned plist remains after removal")
    if not any(client.iterdir()):
        raise ValueError("Removal did not preserve the Incus client configuration")
    require_retained(report, state, client)


def execute(arguments, env, report, timeout=1800):
    result = subprocess.run(arguments, env=env, text=True, capture_output=True, timeout=timeout)
    report.setdefault("commands", []).append({"tool": Path(arguments[0]).name,
        "arguments": arguments[1:], "exit_code": result.returncode,
        "stdout": result.stdout[-4000:], "stderr": result.stderr[-4000:]})
    if result.returncode:
        raise ValueError(f"{Path(arguments[0]).name} failed; inspect retained hardware report")
    return result.stdout.strip()


def ensure_marker(incus, instance, env, report, state):
    token = hashlib.sha256(str(state).encode()).hexdigest()
    key = "user.macus.homebrew-acceptance"
    # `incus list` takes the remote alone ("remote:"), then filters; "remote:name" is read as a
    # filter on the default remote, which an isolated client configuration does not have.
    remote, _, name = instance.partition(":")
    instances = json.loads(execute([incus, "list", remote + ":", "--format=json"], env, report))
    matches = [value for value in instances if value.get("name") == name]
    if matches:
        if len(matches) != 1 or matches[0].get("config", {}).get(key) != token:
            raise ValueError("Refusing an unrelated existing marker instance")
        if matches[0].get("status") == "Stopped":
            execute([incus, "start", instance], env, report)
    else:
        execute([incus, "launch", "images:alpine/3.24", instance, "-c", "boot.autostart=true",
                 "-c", key + "=" + token], env, report)
    execute([incus, "exec", instance, "--", "sh", "-c",
             "printf macus-brew-persistence > /root/macus-marker"], env, report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--phase", choices=["start", "retry-start", "stop", "resume", "removed"], required=True)
    parser.add_argument("--transition", choices=["upgrade", "removal"], default="upgrade",
                        help="for --phase stop: upgrade/rollback keeps the runtime plist, removal removes both")
    parser.add_argument("--opt-in", action="store_true")
    parser.add_argument("--hardware", action="store_true")
    args = parser.parse_args()
    if not args.opt_in or not args.hardware:
        raise ValueError("Requires explicit --opt-in --hardware before any mutation")
    root, state, client = fixture_paths(args.root, first=args.phase == "start")
    _, manifest = candidate.load(args.candidate)
    labels = service_labels(state)
    label = labels[0]
    if args.phase == "start":
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        client.mkdir(mode=0o700)
        report = {"schema_version": 2, "hardware_ran": True, "state": str(state),
                  "incus_conf": str(client), "service_label": label, "server_label": labels[1], "checks": {}}
        report["gateway_port"] = isolated_gateway_port(state)
    else:
        report = json.loads((root / "hardware.json").read_text())
        identity = (report.get("state"), report.get("incus_conf"), report.get("service_label"), report.get("server_label"))
        if identity != (str(state), str(client), label, labels[1]):
            raise ValueError("Hardware report does not match isolated fixture identity")
        if report.get("gateway_port") != isolated_gateway_port(state):
            raise ValueError("Hardware report does not match the isolated gateway port")
    if args.phase == "resume":
        require_upgrade(report, manifest)
    env = dict(os.environ, INCUS_CONF=str(client), MACUS_STATE_DIR=str(state), HOMEBREW_NO_AUTO_UPDATE="1")
    remote = "macus-brew"
    instance = remote + ":macus-brew-marker"
    incus = shutil.which("incus")
    if not incus:
        raise ValueError("Install the standard Incus client before hardware acceptance")
    report.setdefault("candidate_history", []).append({"phase": args.phase, "version": manifest["version"],
                                                       "source_commit": manifest["source_commit"]})
    try:
        if args.phase == "removed":
            installed = subprocess.run(["brew", "list", "--versions", "macus"], capture_output=True, text=True)
            if installed.returncode == 0 and installed.stdout.strip():
                raise ValueError("Macus is still installed")
            require_removed(report, state, client, labels)
            report["checks"]["uninstall_preserves_data"] = True
        else:
            stamp = time.strftime("%Y%m%d%H%M%S", time.gmtime())
            candidate.verify(args.candidate, report=f"package-verify-{args.phase}-{stamp}.json")
            prefix = Path(candidate.run(["brew", "--prefix", candidate.FORMULA])).resolve(strict=True)
            binary = str(prefix / "bin/macus")
            report["installed_binary"] = binary
            if args.phase in ("start", "retry-start", "resume"):
                command = [binary, "--state-dir", str(state), "--json", "--progress", "none",
                           "--incus", incus, "start", "--remote", remote]
                for attempt in range(2 if args.phase in ("start", "retry-start") else 1):
                    result = json.loads(execute(command, env, report))
                    if (result.get("ready") is not True or result.get("connected") is not True
                            or result.get("service_label") != label or result.get("server_label") != labels[1]):
                        raise ValueError("Installed startup did not reach isolated live readiness")
                    endpoint = (result.get("server_endpoint") or {}).get("url", "")
                    if not endpoint.rstrip("/").endswith(f":{report['gateway_port']}"):
                        raise ValueError("Installed startup did not serve the isolated gateway port")
                report["checks"]["isolated_gateway_port"] = True
                execute([incus, "list", remote + ":", "--format=json"], env, report)
                if args.phase in ("start", "retry-start") and not report["checks"].get("first_and_repeated_start"):
                    ensure_marker(incus, instance, env, report, state)
                    report["checks"]["first_and_repeated_start"] = True
                marker = execute([incus, "exec", instance, "--", "cat", "/root/macus-marker"], env, report)
                if marker != "macus-brew-persistence":
                    raise ValueError("Workload marker did not survive package transition")
                report["checks"]["marker_" + args.phase] = True
                if args.phase == "resume":
                    require_retained(report, state, client)
                    require_reregistered(state, labels[1], manifest)
                    report["checks"]["retained_disks_and_credentials"] = True
            else:
                stop_and_unload(binary, state, client, labels, args.transition, env, report)
                report["stopped_version"] = manifest["version"]
        report["last_phase_success"] = True
        # A retried phase that now succeeds must not carry the earlier attempt's failure.
        report.pop("failure", None)
    except Exception as error:
        report["last_phase_success"] = False
        report["failure"] = str(error)
        raise
    finally:
        candidate.write_text(root / "hardware.json", json.dumps(report, indent=2) + "\n")
    print(root / "hardware.json")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        raise SystemExit(str(error))
