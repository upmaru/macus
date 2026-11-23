#!/usr/bin/env python3
"""Opt-in server-only restart acceptance on an isolated, started Macus (task 11.4).

Runs against a state that start-acceptance.py started and workload-acceptance.py
gave a kept workload, with the installed pair and the isolated INCUS_CONF those
runs registered. Without --opt-in it refuses before reading, creating or running
anything. With --opt-in it validates the report path, refuses ordinary state,
prefix and client configuration, and checks the installed pair. Nothing touches
the guest or either job without --hardware as well, and nothing does until the
client's remote is proved to be exactly this state's published gateway.

With --hardware, only this state's server job is restarted, three ways:

  * crash: SIGKILL while an MCP tool call is in flight; launchd relaunches it;
  * explicit: `launchctl kickstart -k` of the server job;
  * missing job: the server job is booted out and `macus start` recovers it.

Around each restart the retained identity is compared: the runtime job's pid
and uptime, the guest kernel's boot id, the kept instance's volatile UUID and
init pid, and its marker file. Only the server pid may change, and new native
and MCP requests (with tokens issued before the restart) must reconnect.

Interrupted calls: a zero-wait snapshot reports its native operation as running
and is polled by that identity; an exec in flight when the server is killed gets
no completion claim, its first effect happens exactly once, nothing is replayed
after the relaunch, and its native operation is looked up by identity. The
runtime job is never stopped, restarted or relaunched. The snapshot this run
creates and its exec log are removed afterwards. Failure artifacts are retained.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


workload = load("workload_acceptance", "Integration/scripts/workload-acceptance.py")
start = workload.start
require, CheckFailure = workload.require, workload.CheckFailure

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
GUEST_CHECKS = (
    "retained_workload", "running_operation_identity", "interrupted_call", "crash_restart",
    "explicit_restart", "missing_job_recovery", "no_mutation_replay", "two_jobs_loopback_only",
    "default_jobs_and_endpoint_unchanged", "guest_unaffected",
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--incus-conf", type=Path, required=True,
                        help="the isolated INCUS_CONF start-acceptance.py registered")
    parser.add_argument("--incus", type=Path, required=True)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--instance", default="macus-accept")
    parser.add_argument("--hardware", action="store_true")
    parser.add_argument("--opt-in", action="store_true")
    return parser.parse_args()


def operation_summary(entry):
    metadata = entry.get("metadata") or {}
    return {"id": entry.get("id"), "class": entry.get("class"), "status": entry.get("status"),
            "err": entry.get("err"), "command": metadata.get("command"),
            "return": metadata.get("return")}


def count_lines(text, word):
    return sum(1 for line in (text or "").splitlines() if line.strip() == word)


class Restart(workload.Acceptance):
    def __init__(self, args, report, run, endpoint, labels, tokens):
        super().__init__(args, report, run, endpoint)
        self.labels, self.tokens = labels, tokens
        self.gateway = start.Gateway(endpoint)
        self.read = tokens.issue("runtime.read")
        self.incus_read = tokens.issue("incus.read")
        self.domain = f"gui/{os.getuid()}"

    # Identity that a server-only restart must not change (the server pid aside).
    def identity(self):
        status = self.run.macus(["--json", "runtime", "status"], json_output=True)
        instance = json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                      f"{self.args.instance}").stdout)
        state = json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                   f"{self.args.instance}/state").stdout)
        boot = self.ok("exec", self.target, "--", "cat", "/proc/sys/kernel/random/boot_id")
        marker = self.incus_command("exec", self.target, "--", "cat", workload.MARKER)
        return {
            "runtime_pid": start.job_pid(self.labels[0]),
            "server_pid": start.job_pid(self.labels[1]),
            "runtime_state": status.get("state"),
            "uptime_seconds": status.get("uptime_seconds"),
            "guest_boot_id": boot.stdout.strip(),
            "instance_uuid": (instance.get("config") or {}).get("volatile.uuid"),
            "instance_status": state.get("status"),
            "instance_pid": state.get("pid"),
            "marker": marker.stdout if marker.returncode == 0 else None,
        }

    def retained(self, before, after, label):
        """Everything but the server pid is unchanged; uptime only grows."""
        steady = ("runtime_pid", "runtime_state", "guest_boot_id", "instance_uuid",
                  "instance_status", "instance_pid", "marker")
        changed = {key: [before[key], after[key]] for key in steady if before[key] != after[key]}
        require(not changed, f"{label} changed retained identity: {changed}")
        require(after["server_pid"] and after["server_pid"] != before["server_pid"],
                f"{label} did not relaunch the server ({before['server_pid']} -> "
                f"{after['server_pid']})")
        require(isinstance(after["uptime_seconds"], int)
                and after["uptime_seconds"] >= before["uptime_seconds"],
                f"{label} reset the runtime uptime {before['uptime_seconds']} -> "
                f"{after['uptime_seconds']}")

    def wait_for_server(self, old_pid, timeout=120):
        """A relaunched server answers runtime status with a token issued before the restart."""
        started = time.monotonic()
        while time.monotonic() - started < timeout:
            pid = start.job_pid(self.labels[1])
            if pid and pid != old_pid:
                try:
                    status, body = self.gateway.request("GET", "/runtime/status", self.read)
                    if status == 200 and body.get("state") == "ready":
                        return {"pid": pid, "seconds": round(time.monotonic() - started, 1)}
                except OSError:
                    pass
            time.sleep(1)
        raise CheckFailure(f"the server did not come back within {timeout} s")

    def reconnects(self):
        """New native and MCP requests reach the existing guest after the restart."""
        self.ok("list", f"{self.args.remote}:", "--format", "csv", "-c", "n")
        _, error, listed = self.mcp.execute(self.incus_read, "incus_instance_list", {})
        require(not error and f'"{self.args.instance}"' in json.dumps(listed.get("result")),
                f"MCP list after restart gave {listed}")
        return True

    def retained_workload(self):
        identity = self.identity()
        require(identity["instance_status"] == "Running" and identity["runtime_state"] == "ready"
                and identity["marker"] and identity["guest_boot_id"] and identity["server_pid"],
                f"no kept, running workload to restart around: {identity}")
        self.baseline = identity
        return identity

    def running_operation_identity(self):
        """A zero-wait mutation reports the native operation as running, then polls by its id."""
        write = self.tokens.issue("incus.write")
        snapshots = self.snapshot_names()
        _, error, made = self.mcp.execute(write, "incus_instance_snapshot_create", {
            "instance": self.args.instance, "wait_seconds": 0})
        result = made.get("result") or {}
        operation = result.get("operation_id") or ""
        require(not error and result.get("status") == "running" and UUID.match(operation),
                f"zero-wait snapshot gave {made}")
        deadline, polled = time.monotonic() + 60, None
        while time.monotonic() < deadline:
            _, error, polled = self.mcp.execute(self.incus_read, "incus_operation_get",
                                                {"operation_id": operation})
            native = (polled.get("result") or {})
            native = native.get("operation", native)
            if not error and native.get("status") in ("Success", "Failure", "Cancelled"):
                break
            time.sleep(0.5)
        native = (polled.get("result") or {})
        native = native.get("operation", native)
        require(native.get("id") == operation and native.get("status") == "Success",
                f"polling {operation} gave {polled}")
        added = sorted(set(self.snapshot_names()) - set(snapshots))
        require(len(added) == 1, f"one snapshot expected, found new {added}")
        self.snapshot = added[0]
        return {"operation_id": operation, "reported": result.get("status"),
                "waited_seconds": result.get("waited_seconds"), "polled": native.get("status"),
                "snapshot": self.snapshot}

    def snapshot_names(self):
        listed = json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                    f"{self.args.instance}/snapshots").stdout)
        return sorted(entry.rsplit("/", 1)[1] for entry in listed)

    def guest_log(self):
        result = self.incus_command("exec", self.target, "--", "cat", self.log)
        return result.stdout if result.returncode == 0 else ""

    def crash_during_call(self):
        """SIGKILL the server while an MCP exec runs in the guest; launchd relaunches it."""
        execute = self.tokens.issue("incus.exec")
        self.log = f"/root/macus-11.4-{int(time.time())}.log"
        before = self.identity()
        outcome = {}

        def call():
            try:
                status, error, body = self.mcp.execute(execute, "incus_instance_exec", {
                    "instance": self.args.instance, "timeout_seconds": 60,
                    "command": ["sh", "-c", f"echo started >> {self.log}; sleep 20; "
                                            f"echo finished >> {self.log}"]})
                outcome.update(status=status, is_error=error, body=body)
            except Exception as failure:  # The interruption itself, as the client saw it.
                outcome.update(exception=f"{type(failure).__name__}: {failure}")

        thread = threading.Thread(target=call, daemon=True)
        thread.start()
        deadline = time.monotonic() + 30
        while count_lines(self.guest_log(), "started") == 0:
            require(time.monotonic() < deadline, "the exec never started in the guest")
            time.sleep(0.5)
        # The call's native identity, as any caller can see it while it runs.
        running = self.exec_operation()
        killed = subprocess.run(["/bin/launchctl", "kill", "SIGKILL",
                                 f"{self.domain}/{self.labels[1]}"],
                                capture_output=True, text=True, timeout=30)
        require(killed.returncode == 0, f"launchctl kill exited {killed.returncode}")
        thread.join(120)
        require(not thread.is_alive(), "the interrupted call never returned")
        recovered = self.wait_for_server(before["server_pid"])
        # The same identity, read through the relaunched server with a token issued before it.
        _, error, polled = self.mcp.execute(self.incus_read, "incus_operation_get",
                                            {"operation_id": running.get("id", "")})
        native = (polled.get("result") or {})
        native = native.get("operation", native)
        self.reconnects()
        after = self.identity()
        self.retained(before, after, "crash")
        self.crash = {"before": before, "after": after, "recovered": recovered,
                      "client_saw": outcome, "operation_while_running": running,
                      "operation_after_relaunch": operation_summary(native) if not error
                      else {"error_kind": workload.error_kind(polled)}}
        return self.crash

    def exec_operation(self):
        """The native exec operation running this run's interrupted command."""
        _, error, listed = self.mcp.execute(self.incus_read, "incus_operation_list", {"limit": 500})
        found = [entry for entry in (listed.get("result") or {}).get("items", [])
                 if self.log in json.dumps((entry.get("metadata") or {}).get("command"))
                 and "sleep 20" in json.dumps((entry.get("metadata") or {}).get("command"))]
        require(not error and len(found) == 1 and found[0].get("status") == "Running"
                and UUID.match(found[0].get("id", "")),
                f"the interrupted exec's native operation: {found or listed}")
        return operation_summary(found[0])

    def interrupted_call(self):
        """The interrupted call claims no completion; its effect is once; its id is findable."""
        outcome = self.crash["client_saw"]
        body = outcome.get("body") or {}
        claimed = (outcome.get("status") == 200 and not outcome.get("is_error")
                   and (body.get("result") or {}).get("status") == "completed")
        require(not claimed, f"an interrupted call claimed completion: {outcome}")
        # The command's own sleep ends in 20 s; give it time to finish if Incus kept it.
        time.sleep(25)
        text = self.guest_log()
        started, finished = count_lines(text, "started"), count_lines(text, "finished")
        running, after = self.crash["operation_while_running"], self.crash["operation_after_relaunch"]
        require(started == 1 and finished <= 1,
                f"the interrupted command ran {started} times, finished {finished}")
        # Polled after the relaunch, the identity is either the same operation or no longer
        # retained by Incus; it is never a different or resubmitted one.
        require(after.get("id") == running["id"] or after.get("error_kind") == "not_found",
                f"the operation after the relaunch was {after}, not {running['id']}")
        self.effects = {"started": started, "finished": finished}
        return {"client_saw": outcome.get("exception") or {
                    key: outcome.get(key) for key in ("status", "is_error")},
                "error_kind": workload.error_kind(body) if body else None,
                "dispatched": workload.dispatched(body) if body else None,
                "operation_while_running": running, "operation_after_relaunch": after,
                "guest_effects": self.effects}

    def explicit_restart(self):
        before = self.identity()
        restarted = subprocess.run(["/bin/launchctl", "kickstart", "-k",
                                    f"{self.domain}/{self.labels[1]}"],
                                   capture_output=True, text=True, timeout=60)
        require(restarted.returncode == 0, f"kickstart -k exited {restarted.returncode}")
        recovered = self.wait_for_server(before["server_pid"])
        self.reconnects()
        after = self.identity()
        self.retained(before, after, "explicit restart")
        return {"before": before, "after": after, "recovered": recovered}

    def missing_job_recovery(self):
        before = self.identity()
        target = f"{self.domain}/{self.labels[1]}"
        booted = subprocess.run(["/bin/launchctl", "bootout", target],
                                capture_output=True, text=True, timeout=60)
        require(booted.returncode == 0, f"bootout exited {booted.returncode}: {booted.stderr}")
        deadline = time.monotonic() + 60
        while start.job_pid(self.labels[1]) is not None or subprocess.run(
                ["/bin/launchctl", "print", target], capture_output=True, timeout=30).returncode == 0:
            require(time.monotonic() < deadline, "the server job stayed loaded after bootout")
            time.sleep(1)
        try:
            # The client never falls back to the private runtime socket: without the server it
            # reports unavailable and names `macus start`, while the runtime job keeps running.
            status = self.run.command([self.run.binary, "--state-dir", str(self.run.state), "--json",
                                       "runtime", "status"], 60, "macus")
            try:
                missing = json.loads(status.stderr).get("error") or {}
            except ValueError:
                missing = {}
            runtime_pid = start.job_pid(self.labels[0])
            require(status.returncode != 0 and missing.get("code") == "unavailable"
                    and "macus start" in missing.get("message", "")
                    and runtime_pid == before["runtime_pid"],
                    f"without its server job: status exited {status.returncode} with {missing}, "
                    f"runtime pid {runtime_pid}")
        finally:
            # Whatever the check found, the job is registered again before going on.
            recovered = self.run.macus(["--json", "--progress", "none", "--timeout", "600", "start",
                                        "--remote", self.args.remote, "--incus", self.incus],
                                       timeout=660, json_output=True)
        require(recovered.get("ready") is True, f"macus start gave {recovered}")
        self.wait_for_server(before["server_pid"])
        self.reconnects()
        after = self.identity()
        self.retained(before, after, "missing-job recovery")
        return {"before": before, "after": after,
                "without_server": {"status_error": missing.get("code"), "runtime_pid": runtime_pid},
                "start": {key: recovered.get(key) for key in ("ready", "connected", "server_label",
                                                              "service_label")}}

    def no_mutation_replay(self):
        """After three relaunches: still one new snapshot and one run of the interrupted exec."""
        added = sorted(set(self.snapshot_names()) - set(self.guest_before["snapshots_names"]))
        text = self.guest_log()
        effects = {"started": count_lines(text, "started"), "finished": count_lines(text, "finished")}
        require(added == [self.snapshot] and effects == self.effects,
                f"after restarts: new snapshots {added}, exec effects {effects} "
                f"(expected [{self.snapshot}], {self.effects})")
        return {"new_snapshots": added, "exec_effects": effects}

    def footprint(self, port):
        found = start.service_footprint(self.labels, (start.job_pid(self.labels[0]),
                                                      start.job_pid(self.labels[1])), port)
        require(found["labels"] == sorted(self.labels)
                and found["server_listeners"] == [f"127.0.0.1:{port}"]
                and not found["runtime_network_sockets"], f"service footprint {found}")
        return found

    def clean_up(self):
        """Removes only this run's snapshot and exec log."""
        removed = {}
        if getattr(self, "snapshot", None):
            delete = self.tokens.issue("incus.delete")
            _, error, deleted = self.mcp.execute(delete, "incus_instance_snapshot_delete", {
                "instance": self.args.instance, "name": self.snapshot,
                "confirm": f"{self.args.instance}/{self.snapshot}", "wait_seconds": 30})
            removed["snapshot"] = not error and self.snapshot not in self.snapshot_names()
        if getattr(self, "log", None):
            removed["exec_log"] = self.incus_command("exec", self.target, "--", "rm", "-f",
                                                     self.log).returncode == 0
        return removed


def main():
    args = parse_args()
    if not args.opt_in:
        raise SystemExit("Refusing to run without --opt-in")
    start.validate_report(args.report, args.state_dir, args.prefix, None, client=args.incus_conf)
    state, prefix = args.state_dir, args.prefix
    start.refuse_user_paths(state, prefix, None)
    start.refuse_user_client(args.incus_conf)
    report = {
        "schema_version": 1,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Opt-in server-only restart acceptance on an isolated, started Macus",
        "hardware_ran": False, "state_dir": str(state.resolve()), "prefix": str(prefix.resolve()),
        "incus_conf": str(args.incus_conf.resolve()), "checks": {}, "evidence": {},
    }

    def save():
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")

    save()
    try:
        pair = start.installed_pair(prefix)
        endpoint = json.loads((state / "server" / "endpoint.json").read_text())
        port = json.loads((state / "server" / "gateway.json").read_text())["port"]
    except (start.PairFailure, OSError, ValueError, KeyError) as error:
        report["success"], report["failure"] = False, str(error)
        save()
        raise SystemExit(f"Installed pair or started state check failed: {error}")
    report["pair"] = pair
    report["evidence"]["package"] = {"paired_artifacts": True, "pinned_dependency": True}
    save()
    if not args.hardware:
        report["note"] = "Hardware acceptance was not run; nothing was restarted."
        save()
        raise SystemExit("Hardware acceptance was not run; pass --hardware to restart the server")
    env = dict(os.environ, INCUS_CONF=str(args.incus_conf.resolve()), MACUS_BREW_FALLBACK="0")
    for variable in ("MACUS_STATE_DIR", "MACUS_FIXTURE_GUEST_DIR", "MACUS_FIXTURE_LAUNCHCTL"):
        env.pop(variable, None)
    run = start.Run(pair["binary"], state.resolve(), env, report)
    remotes = run.command([str(args.incus), "remote", "list", "--format", "json"], 60, "incus")
    entry = json.loads(remotes.stdout).get(args.remote, {}) if remotes.returncode == 0 else {}
    addresses = entry.get("Addrs") or ([entry["Addr"]] if entry.get("Addr") else [])
    if addresses != [endpoint["url"]]:
        report["success"] = False
        report["failure"] = f"remote {args.remote} is {addresses}, not this state's {endpoint['url']}"
        save()
        raise SystemExit("Refusing: the client's remote is not this state's gateway")
    report["hardware_ran"] = True
    labels = start.service_labels(state)
    report["labels"] = list(labels)
    default_before = start.default_footprint()
    tokens = start.Tokens(run, Path(tempfile.mkdtemp(prefix="macus-accept-tokens-")))
    checks, details = report["checks"], report.setdefault("details", {})

    def attempt(name, function, *arguments):
        try:
            details[name] = function(*arguments)
            checks[name] = True
        except Exception as error:  # Each check is recorded; later checks still run.
            checks[name] = False
            details[name] = {"error": f"{type(error).__name__}: {error}"}
        save()

    acceptance = None
    try:
        acceptance = Restart(args, report, run, endpoint, labels, tokens)
        attempt("retained_workload", acceptance.retained_workload)
        if checks["retained_workload"]:
            before = acceptance.guest_state()
            before["snapshots_names"] = acceptance.snapshot_names()
            acceptance.guest_before = before
            report["guest_before"] = before
            attempt("running_operation_identity", acceptance.running_operation_identity)
            attempt("crash_restart", acceptance.crash_during_call)
            if checks["crash_restart"]:
                attempt("interrupted_call", acceptance.interrupted_call)
            attempt("explicit_restart", acceptance.explicit_restart)
            attempt("missing_job_recovery", acceptance.missing_job_recovery)
            if checks["running_operation_identity"] and checks.get("interrupted_call"):
                attempt("no_mutation_replay", acceptance.no_mutation_replay)
            attempt("two_jobs_loopback_only", acceptance.footprint, port)
            attempt("clean_up", acceptance.clean_up)
            before = {key: value for key, value in before.items() if key != "snapshots_names"}

            def unaffected():
                after = acceptance.guest_state()
                report["guest_after"] = after
                require(after == before and all((details["clean_up"] or {}).values())
                        and checks["clean_up"], f"guest {after} (before {before}), "
                                                f"clean-up {details['clean_up']}")
                final = acceptance.identity()
                kept = ("runtime_pid", "guest_boot_id", "instance_uuid", "instance_pid", "marker")
                require(all(final[key] == acceptance.baseline[key] for key in kept),
                        f"identity after the run {final}, before {acceptance.baseline}")
                return final

            attempt("guest_unaffected", unaffected)
        default_after = start.default_footprint()
        report["default_footprint"] = {"before": default_before, "after": default_after}
        checks["default_jobs_and_endpoint_unchanged"] = default_after == default_before
        report["evidence"]["guest"] = {name: checks.get(name, False) for name in GUEST_CHECKS}
        report["success"] = all(checks.get(name) for name in GUEST_CHECKS)
    except Exception as error:
        report["success"] = False
        report["note"] = f"Acceptance failed and artifacts were preserved: {error}"
    finally:
        tokens.revoke_all(report)
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        save()
    if not report.get("success"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
