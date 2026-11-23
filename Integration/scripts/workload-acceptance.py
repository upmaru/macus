#!/usr/bin/env python3
"""Opt-in native Incus and MCP workload acceptance on an isolated, started Macus (task 11.3).

Runs against a state that start-acceptance.py already started, with the
installed pair and the isolated INCUS_CONF that run registered. Without
--opt-in it refuses before reading, creating or running anything. With
--opt-in it validates the report path, refuses ordinary state, prefix and
client configuration, and checks the installed pair. Nothing touches the
guest without --hardware as well, and nothing does until the client's remote
is proved to be exactly this state's published gateway.

With --hardware, through the standard incus client and the gateway:

  * a system container (created once, then reused and kept for later tasks);
  * native exec: stdout, stderr, exit status and stdin;
  * native console: an attached console receives what the instance writes
    to /dev/console, and detaches cleanly;
  * native events: a lifecycle event for a snapshot made during `incus monitor`;
  * binary transfers: random bytes pushed, hashed in the guest and pulled back;
  * MCP `search`/`execute` over shared Incus and Macus runtime operations,
    each with only the scopes it needs (tokens revoked afterwards);
  * denials that must not affect the guest: no, unknown and revoked bearer
    tokens, a token lacking the scope, missing and wrong confirmations, a
    gateway-untrusted client certificate and a bearer token on native routes.
    The guest's marker file, snapshots and runtime are compared before and
    after.

The VM is never stopped, restarted, or force-stopped, and nothing is deleted
except the snapshot this run creates for the confirmed-delete check.
Failure artifacts are retained.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import signal
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("start_acceptance", ROOT / "Integration/scripts/start-acceptance.py")
start = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(start)

PROTOCOL = "2026-07-28"
MARKER = "/root/macus-acceptance-marker"
GUEST_CHECKS = (
    "workload", "native_exec", "native_console", "native_events", "binary_transfers",
    "mcp_shared_operations", "mcp_runtime_operations", "denied_bearer_credentials",
    "denied_scopes", "denied_confirmations", "denied_native_credentials", "guest_unaffected",
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
    parser.add_argument("--image", default="images:alpine/3.22")
    parser.add_argument("--hardware", action="store_true")
    parser.add_argument("--opt-in", action="store_true")
    return parser.parse_args()


class CheckFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


class Mcp:
    """Stateless MCP Streamable HTTP calls to /mcp, pinned to the published certificate."""

    def __init__(self, endpoint):
        parsed = urllib.parse.urlsplit(endpoint["url"])
        self.host, self.port = parsed.hostname, parsed.port
        self.context = ssl.create_default_context(cadata=endpoint["certificate"])

    def call(self, token, name, arguments):
        body = {"jsonrpc": "2.0", "id": "acceptance", "method": "tools/call", "params": {
            "name": name, "arguments": arguments, "_meta": {
                "io.modelcontextprotocol/protocolVersion": PROTOCOL,
                "io.modelcontextprotocol/clientCapabilities": {},
                "io.modelcontextprotocol/clientInfo": {"name": "macus-acceptance", "version": "1"}}}}
        headers = {"mcp-protocol-version": PROTOCOL, "mcp-method": "tools/call", "mcp-name": name,
                   "content-type": "application/json",
                   "accept": "application/json, text/event-stream"}
        if token is not None:
            headers["authorization"] = f"Bearer {token}"
        connection = http.client.HTTPSConnection(self.host, self.port, context=self.context,
                                                 timeout=90)
        try:
            connection.request("POST", "/mcp", json.dumps(body), headers)
            response = connection.getresponse()
            data = response.read()
        finally:
            connection.close()
        try:
            decoded = json.loads(data) if data else {}
        except ValueError:
            decoded = {}
        result = decoded.get("result") or {}
        return response.status, bool(result.get("isError")), result.get("structuredContent") or {}

    def execute(self, token, operation, payload, cassette="opsmaru_incus"):
        return self.call(token, "execute", {"cassette": cassette, "operation_id": operation,
                                            "input": payload})


def error_kind(body):
    """execute's error: `error` (an object with `kind`, or a string) or `operation_error`."""
    error = body.get("error")
    if isinstance(error, dict):
        return error.get("kind")
    if error:
        return error
    return "operation_error" if body.get("operation_error") else None


def dispatched(body):
    """Whether the operation ran: beside `operation_error`, or inside the `error` object."""
    if "dispatched" in body:
        return body["dispatched"]
    error = body.get("error")
    return error.get("dispatched") if isinstance(error, dict) else None


class Acceptance:
    def __init__(self, args, report, run, endpoint):
        self.args, self.report, self.run, self.endpoint = args, report, run, endpoint
        self.incus = str(args.incus)
        self.target = f"{args.remote}:{args.instance}"
        self.mcp = Mcp(endpoint)

    def incus_command(self, *arguments, timeout=180, stdin=None, binary=False):
        command = [self.incus, *arguments]
        try:
            # Never the runner's own stdin: some incus commands (snapshot create, create) read
            # YAML from a non-terminal stdin and would wait on it forever.
            stream = {"input": stdin} if stdin is not None else {"stdin": subprocess.DEVNULL}
            result = subprocess.run(command, env=self.run.env, capture_output=True,
                                    text=not binary, timeout=timeout, **stream)
        except subprocess.TimeoutExpired as error:
            self.report.setdefault("commands", []).append(
                {"tool": "incus", "arguments": list(arguments), "exit_code": "timeout",
                 "stderr": str(error.stderr or "")[-2000:]})
            raise CheckFailure(f"incus {' '.join(arguments)} did not finish in {timeout} s")
        record = {"tool": "incus", "arguments": list(arguments), "exit_code": result.returncode}
        if not binary:
            record.update(stdout=result.stdout[-2000:], stderr=result.stderr[-2000:])
        self.report.setdefault("commands", []).append(record)
        return result

    def ok(self, *arguments, **options):
        result = self.incus_command(*arguments, **options)
        require(result.returncode == 0, f"incus {' '.join(arguments)} exited {result.returncode}: "
                                        f"{(result.stderr or b'')[-400:]!r}")
        return result

    # The guest's observable state, compared around every denial.
    def guest_state(self):
        marker = self.incus_command("exec", self.target, "--", "cat", MARKER)
        snapshots = self.ok("query", f"{self.args.remote}:/1.0/instances/{self.args.instance}/snapshots")
        status = self.run.macus(["--json", "runtime", "status"], json_output=True)
        instance = json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                      f"{self.args.instance}").stdout)
        return {"marker": marker.stdout if marker.returncode == 0 else None,
                "snapshots": sorted(json.loads(snapshots.stdout)),
                "instance_status": instance.get("status"),
                "runtime_state": status.get("state")}

    def workload(self):
        existing = self.incus_command("query", f"{self.args.remote}:/1.0/instances/{self.args.instance}")
        created = existing.returncode != 0
        if created:
            # Not `incus launch`: the client always sends "start": true and starts the instance
            # again unless the server advertises instance_create_start, which pairs built before
            # opsmaru_incus 0.2.7 do not (upmaru/opsmaru-incus#88), so launch would report
            # "already running" after a successful start on them.
            self.ok("create", self.args.image, self.target, timeout=900)
            self.ok("start", self.target, timeout=300)
        deadline = time.monotonic() + 120
        while True:
            state = json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                       f"{self.args.instance}/state").stdout)
            if state.get("status") == "Running":
                break
            require(time.monotonic() < deadline, f"instance is {state.get('status')}")
            time.sleep(2)
        self.ok("exec", self.target, "--", "sh", "-c", f"echo macus-11.3 > {MARKER}")
        instance = json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                      f"{self.args.instance}").stdout)
        return {"name": self.args.instance, "created": created, "type": instance.get("type"),
                "image": instance.get("config", {}).get("image.description"),
                "status": instance.get("status")}

    def diagnosed(self, *arguments, timeout=60):
        """Runs incus with --debug; if it stalls, keeps its log, a goroutine dump and a fresh
        TLS probe of the gateway, so an intermittent stall can be diagnosed."""
        process = subprocess.Popen([self.incus, *arguments, "--debug"], env=self.run.env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            _, stderr = process.communicate(timeout=timeout)
            self.report.setdefault("commands", []).append(
                {"tool": "incus", "arguments": list(arguments), "exit_code": process.returncode})
            require(process.returncode == 0, f"incus {' '.join(arguments)} exited "
                                             f"{process.returncode}: {stderr[-400:]}")
            return
        except subprocess.TimeoutExpired:
            probe = self.tls_probe()
            process.send_signal(signal.SIGQUIT)
            try:
                _, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                _, stderr = process.communicate()
        lines = (stderr or "").splitlines()
        self.report.setdefault("stalls", []).append({
            "arguments": list(arguments), "gateway_tls_probe": probe,
            "debug": [line[:300] for line in lines if "level=" in line][-40:],
            "goroutines": [line[:300] for line in lines if "level=" not in line][:400]})
        self.report.setdefault("commands", []).append(
            {"tool": "incus", "arguments": list(arguments), "exit_code": "stalled"})
        raise CheckFailure(f"incus {' '.join(arguments)} stalled for {timeout} s (diagnostics kept)")

    def tls_probe(self):
        parsed = urllib.parse.urlsplit(self.endpoint["url"])
        started = time.monotonic()
        try:
            context = ssl.create_default_context(cadata=self.endpoint["certificate"])
            connection = http.client.HTTPSConnection(parsed.hostname, parsed.port,
                                                     context=context, timeout=5)
            connection.request("GET", "/")
            status = connection.getresponse().status
            connection.close()
            return {"status": status, "seconds": round(time.monotonic() - started, 3)}
        except Exception as error:
            return {"error": f"{type(error).__name__}: {error}",
                    "seconds": round(time.monotonic() - started, 3)}

    def native_exec(self):
        result = self.incus_command("exec", self.target, "--", "sh", "-c",
                                    "echo out; echo err >&2; exit 3")
        echoed = self.ok("exec", self.target, "--", "cat", stdin="stdin-through-gateway\n")
        require(result.returncode == 3 and result.stdout == "out\n" and result.stderr == "err\n",
                f"exec gave {result.returncode} {result.stdout!r} {result.stderr!r}")
        require(echoed.stdout == "stdin-through-gateway\n", f"stdin echoed {echoed.stdout!r}")
        return {"exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
                "stdin_echo": echoed.stdout}

    def native_console(self):
        token = f"macus-console-{os.getpid()}-{int(time.time())}"
        pid, descriptor = pty.fork()
        if pid == 0:
            os.execve(self.incus, [self.incus, "console", self.target], self.run.env)
        received = b""

        def drain(seconds):
            nonlocal received
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                ready, _, _ = select.select([descriptor], [], [], 0.5)
                if ready:
                    try:
                        chunk = os.read(descriptor, 65536)
                    except OSError:
                        return
                    if not chunk:
                        return
                    received += chunk
                    if token.encode() in received:
                        return

        try:
            drain(5)
            self.ok("exec", self.target, "--", "sh", "-c", f"echo {token} > /dev/console")
            drain(20)
            seen = token.encode() in received
            # The client's escape is <ctrl>+a then q, read as separate keystrokes.
            for key in (b"\x01", b"q"):
                os.write(descriptor, key)
                time.sleep(0.5)
            detached = None
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    detached = os.waitstatus_to_exitcode(status)
                    break
                drain(0.5)
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            os.close(descriptor)
        self.report.setdefault("commands", []).append(
            {"tool": "incus", "arguments": ["console", self.target], "exit_code": detached,
             "bytes_received": len(received)})
        require(seen, f"the console did not show the instance's output ({len(received)} bytes)")
        require(detached == 0, f"console detach exited {detached}")
        return {"marker_seen": seen, "detach_exit_code": detached, "bytes": len(received)}

    def native_events(self):
        snapshot = f"events-{int(time.time())}"
        monitor = subprocess.Popen([self.incus, "monitor", f"{self.args.remote}:", "--type",
                                    "lifecycle", "--format", "json"], env=self.run.env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        events = []

        def read():
            for line in monitor.stdout:
                if line.strip():  # events are separated by blank lines
                    events.append(json.loads(line))

        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        try:
            time.sleep(2)
            self.diagnosed("snapshot", "create", self.target, snapshot)
            deadline = time.monotonic() + 20
            wanted = None
            while time.monotonic() < deadline and not wanted:
                wanted = next((event for event in list(events)
                               if event.get("metadata", {}).get("action") == "instance-snapshot-created"
                               and snapshot in event.get("metadata", {}).get("source", "")), None)
                time.sleep(0.5)
        finally:
            monitor.terminate()
            monitor.wait(10)
        self.ok("snapshot", "delete", self.target, snapshot)
        require(wanted, f"no instance-snapshot-created event among {len(events)}")
        return {"action": wanted["metadata"]["action"], "source": wanted["metadata"]["source"]}

    def binary_transfers(self):
        with tempfile.TemporaryDirectory(prefix="macus-accept-blob-") as folder:
            blob = Path(folder) / "blob"
            blob.write_bytes(os.urandom(8 * 1024 * 1024 + 7))
            digest = hashlib.sha256(blob.read_bytes()).hexdigest()
            self.ok("file", "push", str(blob), f"{self.target}/root/macus-blob")
            remote = self.ok("exec", self.target, "--", "sha256sum", "/root/macus-blob").stdout.split()[0]
            pulled = Path(folder) / "pulled"
            self.ok("file", "pull", f"{self.target}/root/macus-blob", str(pulled))
            back = hashlib.sha256(pulled.read_bytes()).hexdigest()
        self.ok("exec", self.target, "--", "rm", "-f", "/root/macus-blob")
        require(remote == digest and back == digest, "transferred bytes changed")
        return {"bytes": 8 * 1024 * 1024 + 7, "sha256": digest, "guest_sha256": remote,
                "pulled_sha256": back}

    def mcp_shared(self, tokens):
        read = tokens.issue("incus.read")
        execute = tokens.issue("incus.exec")
        write = tokens.issue("incus.write")
        _, error, found = self.mcp.call(read, "search", {"query": "instance", "limit": 20,
                                                         "include_schemas": False})
        operations = sorted(result["operation_id"] for result in found.get("results", []))
        require(not error and "incus_instance_list" in operations, f"search found {operations}")
        require("incus_instance_delete" not in operations and "incus_instance_exec" not in operations,
                "search showed operations the token's scopes hide")
        _, error, listed = self.mcp.execute(read, "incus_instance_list", {})
        require(not error and f'"{self.args.instance}"' in json.dumps(listed.get("result")),
                f"instance list gave {listed}")
        _, error, ran = self.mcp.execute(execute, "incus_instance_exec", {
            "instance": self.args.instance, "command": ["cat", MARKER]})
        output = ran.get("result") or {}
        require(not error and "macus-11.3" in json.dumps(output), f"exec gave {ran}")
        snapshot = f"mcp-{int(time.time())}"
        _, error, made = self.mcp.execute(write, "incus_instance_snapshot_create", {
            "instance": self.args.instance, "name": snapshot, "wait_seconds": 30})
        require(not error and (made.get("result") or {}).get("status") == "completed",
                f"snapshot create gave {made}")
        self.created_snapshot = snapshot
        return {"search": operations, "listed": True, "exec_result_keys": sorted(output),
                "snapshot": snapshot,
                "snapshot_operation": (made.get("result") or {}).get("operation_id")}

    def mcp_runtime(self, tokens):
        read = tokens.issue("runtime.read")
        write = tokens.issue("runtime.write")
        _, error, found = self.mcp.call(read, "search", {"cassette": "macus", "limit": 20,
                                                         "include_schemas": False})
        operations = sorted(result["operation_id"] for result in found.get("results", []))
        require(not error and "macus_runtime_status" in operations
                and "macus_runtime_start" not in operations, f"search found {operations}")
        _, error, status = self.mcp.execute(read, "macus_runtime_status", {}, cassette="macus")
        require(not error and '"ready"' in json.dumps(status.get("result")), f"status gave {status}")
        before = self.run.macus(["--json", "runtime", "status"], json_output=True)
        _, error, started = self.mcp.execute(write, "macus_runtime_start", {}, cassette="macus")
        after = self.run.macus(["--json", "runtime", "status"], json_output=True)
        require(not error and after.get("state") == "ready"
                and after.get("uptime_seconds", -1) >= before.get("uptime_seconds", 1 << 30),
                f"start on a ready runtime gave {started}")
        return {"search": operations, "status_result_keys": sorted(status.get("result") or {}),
                "start_result_keys": sorted(started.get("result") or {}),
                "uptime_seconds": [before.get("uptime_seconds"), after.get("uptime_seconds")]}

    def denied_bearer(self, tokens):
        revoked = tokens.issue("incus.read")
        tokens.revoke(revoked)
        outcomes = {}
        for label, token in (("none", None), ("unknown", "macus.0000000000000000." + "A" * 43),
                             ("revoked", revoked)):
            status, _, _ = self.mcp.execute(token, "incus_instance_list", {})
            outcomes[label] = status
        require(all(status == 401 for status in outcomes.values()), f"bearer refusals {outcomes}")
        return outcomes

    def denied_scopes(self, tokens):
        read = tokens.issue("incus.read")
        runtime_read = tokens.issue("runtime.read")
        outcomes = {}
        for label, token, cassette, operation, payload in (
                ("exec_with_read", read, "opsmaru_incus", "incus_instance_exec",
                 {"instance": self.args.instance, "command": ["sh", "-c", f"echo denied > {MARKER}"]}),
                ("delete_with_read", read, "opsmaru_incus", "incus_instance_delete",
                 {"name": self.args.instance, "confirm": self.args.instance}),
                ("native_without_native_scope", read, "opsmaru_incus", "incus_native_delete_instance",
                 {"name": self.args.instance, "confirm": self.args.instance}),
                ("stop_with_runtime_read", runtime_read, "macus", "macus_runtime_stop", {})):
            _, error, body = self.mcp.execute(token, operation, payload, cassette=cassette)
            outcomes[label] = [error_kind(body), dispatched(body)]
        require(all(outcome == ["not_found", False] for outcome in outcomes.values()),
                f"scope refusals {outcomes}")
        return outcomes

    def denied_confirmations(self, tokens):
        delete = tokens.issue("incus.delete")
        force = tokens.issue("runtime.delete")
        snapshot = self.created_snapshot
        target = f"{self.args.instance}/{snapshot}"
        outcomes = {}
        for label, token, cassette, operation, payload in (
                ("snapshot_delete_missing", delete, "opsmaru_incus", "incus_instance_snapshot_delete",
                 {"instance": self.args.instance, "name": snapshot}),
                ("snapshot_delete_empty", delete, "opsmaru_incus", "incus_instance_snapshot_delete",
                 {"instance": self.args.instance, "name": snapshot, "confirm": ""}),
                ("snapshot_delete_wrong", delete, "opsmaru_incus", "incus_instance_snapshot_delete",
                 {"instance": self.args.instance, "name": snapshot, "confirm": "not-" + target}),
                ("instance_delete_wrong", delete, "opsmaru_incus", "incus_instance_delete",
                 {"name": self.args.instance, "confirm": self.args.instance + "-not"}),
                ("force_stop_missing", force, "macus", "macus_runtime_force_stop", {}),
                ("force_stop_wrong", force, "macus", "macus_runtime_force_stop", {"confirm": "stop"})):
            _, error, body = self.mcp.execute(token, operation, payload, cassette=cassette)
            outcomes[label] = [error_kind(body), dispatched(body)]
        snapshots = sorted(json.loads(self.ok("query", f"{self.args.remote}:/1.0/instances/"
                                              f"{self.args.instance}/snapshots").stdout))
        kept = any(entry.endswith("/" + snapshot) for entry in snapshots)
        require(outcomes["snapshot_delete_missing"] == ["confirmation_required", False]
                and outcomes["snapshot_delete_empty"] == ["confirmation_required", False]
                and outcomes["force_stop_missing"][1] is False
                and outcomes["force_stop_wrong"][1] is False
                and outcomes["snapshot_delete_wrong"][0] == "operation_error"
                and outcomes["instance_delete_wrong"][0] == "operation_error" and kept,
                f"confirmation refusals {outcomes}, snapshot kept: {kept}")
        # The confirmed delete is the one mutation that removes something: this run's snapshot.
        _, error, deleted = self.mcp.execute(delete, "incus_instance_snapshot_delete", {
            "instance": self.args.instance, "name": snapshot, "confirm": target, "wait_seconds": 30})
        gone = not any(entry.endswith("/" + snapshot) for entry in json.loads(
            self.ok("query", f"{self.args.remote}:/1.0/instances/{self.args.instance}/snapshots").stdout))
        require(not error and gone, f"the confirmed snapshot delete gave {deleted}")
        outcomes["snapshot_delete_confirmed"] = [None, True]
        return outcomes

    def denied_native(self, tokens):
        token = tokens.issue("incus.read")
        parsed = urllib.parse.urlsplit(self.endpoint["url"])
        with tempfile.TemporaryDirectory(prefix="macus-accept-cert-") as folder:
            key, cert = Path(folder) / "client.key", Path(folder) / "client.crt"
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048",
                            "-nodes", "-days", "1", "-subj",
                            "/CN=macus-acceptance-untrusted", "-keyout", str(key), "-out", str(cert)],
                           check=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
            outcomes = {}
            for label, certificate, bearer in (("untrusted_certificate", (cert, key), None),
                                               ("bearer_token", None, token)):
                context = ssl.create_default_context(cadata=self.endpoint["certificate"])
                if certificate:
                    context.load_cert_chain(*map(str, certificate))
                headers = {"content-type": "application/json"}
                if bearer:
                    headers["authorization"] = f"Bearer {bearer}"
                results = []
                for method, path, body in (
                        ("GET", "/1.0/instances", None),
                        ("POST", f"/1.0/instances/{self.args.instance}/exec",
                         json.dumps({"command": ["sh", "-c", f"echo native-denied > {MARKER}"],
                                     "wait-for-websocket": False, "interactive": False})),
                        ("DELETE", f"/1.0/instances/{self.args.instance}", None)):
                    connection = http.client.HTTPSConnection(parsed.hostname, parsed.port,
                                                             context=context, timeout=30)
                    try:
                        connection.request(method, path, body, headers)
                        results.append(connection.getresponse().status)
                    finally:
                        connection.close()
                outcomes[label] = results
        require(all(status in (401, 403) for results in outcomes.values() for status in results),
                f"native refusals {outcomes}")
        return outcomes


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
        "scope": "Opt-in native Incus and MCP workload acceptance on an isolated, started Macus",
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
    except (start.PairFailure, OSError, ValueError, KeyError) as error:
        report["success"], report["failure"] = False, str(error)
        save()
        raise SystemExit(f"Installed pair or started state check failed: {error}")
    report["pair"] = pair
    report["evidence"]["package"] = {"paired_artifacts": True, "pinned_dependency": True}
    save()
    if not args.hardware:
        report["note"] = "Hardware acceptance was not run; nothing reached the guest."
        save()
        raise SystemExit("Hardware acceptance was not run; pass --hardware to exercise the guest")
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
    acceptance = Acceptance(args, report, run, endpoint)
    tokens = start.Tokens(run, Path(tempfile.mkdtemp(prefix="macus-accept-tokens-")))
    tokens.revoke = lambda token: (run.macus(["server", "token", "revoke", token.split(".")[1]]),
                                   tokens.ids.remove(token.split(".")[1]))
    checks, details = report["checks"], report.setdefault("details", {})

    def attempt(name, function, *arguments):
        try:
            details[name] = function(*arguments)
            checks[name] = True
        except Exception as error:  # Each check is recorded; later checks still run.
            checks[name] = False
            details[name] = {"error": f"{type(error).__name__}: {error}"}
        save()

    try:
        attempt("workload", acceptance.workload)
        if checks["workload"]:
            before = acceptance.guest_state()
            report["guest_before"] = before
            attempt("native_exec", acceptance.native_exec)
            attempt("native_console", acceptance.native_console)
            attempt("native_events", acceptance.native_events)
            attempt("binary_transfers", acceptance.binary_transfers)
            attempt("mcp_shared_operations", acceptance.mcp_shared, tokens)
            attempt("mcp_runtime_operations", acceptance.mcp_runtime, tokens)
            attempt("denied_bearer_credentials", acceptance.denied_bearer, tokens)
            attempt("denied_scopes", acceptance.denied_scopes, tokens)
            if checks.get("mcp_shared_operations"):
                attempt("denied_confirmations", acceptance.denied_confirmations, tokens)
            attempt("denied_native_credentials", acceptance.denied_native, tokens)
            after = acceptance.guest_state()
            report["guest_after"] = after
            checks["guest_unaffected"] = after == before
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
