#!/usr/bin/env python3
"""Opt-in remote-client acceptance on an isolated, started Macus (task 11.5).

Runs against a state that start-acceptance.py started and workload-acceptance.py
gave a kept workload, with the installed pair and the isolated INCUS_CONF those
runs registered. Without --opt-in it refuses before reading, creating or running
anything. With --opt-in it validates the report path, refuses ordinary state,
prefix and client configuration, checks the installed pair, the bind address
and both remotes. Nothing is rebound, launched or enrolled without
--remote-opt-in as well.

The separate client is a throwaway container on another Incus server, reached
through --client-remote with the operator's own incus client. It is created
only under a name that does not exist yet, gets the standard incus client and
Python from its distribution, and is deleted afterwards (only if it is still
the instance this run created). Nothing else on that server is touched.

With --remote-opt-in:

  * the gateway is rebound to --bind-address (a private or CGNAT address, never
    a wildcard) with a throwaway certificate naming it, and only the server job
    is restarted;
  * from the separate client: TLS 1.3 identity pinned to that certificate,
    anonymous discovery, native enrollment with a single-use token through the
    standard `incus remote add`, native workload access, one bearer token
    combining `incus.read` and `runtime.read` across /mcp and /runtime with
    its scope limits, then revocation of the bearer token, of the enrolled
    certificate (an open exec ends) and of an unredeemed enrollment token;
  * the gateway is returned to its original loopback configuration and the
    client can no longer connect.

The VM, the runtime job and the kept workload are never stopped or restarted;
their identity is compared before and after. Remote evidence is recorded
under `evidence.remote`, apart from loopback evidence. Failure artifacts and
Incus data are retained, and the gateway configuration is always restored.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "Integration/scripts/remote-client-probe.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


restart = load("restart_acceptance", "Integration/scripts/restart-acceptance.py")
workload = restart.workload
start = workload.start
require, CheckFailure = workload.require, workload.CheckFailure

REMOTE_CHECKS = (
    "separate_client", "remote_listener_only", "tls_identity", "native_enrollment",
    "single_use_enrollment", "native_workload_access", "scoped_combined_access",
    "bearer_revocation", "native_revocation", "enrollment_token_revocation",
    "loopback_restored", "client_removed", "guest_unaffected",
    "default_jobs_and_endpoint_unchanged",
)
CGNAT = ipaddress.ip_network("100.64.0.0/10")
CLIENT_PACKAGES = ("incus-client", "python3")


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
    parser.add_argument("--bind-address", required=True,
                        help="this Mac's private or CGNAT address the client can reach")
    parser.add_argument("--client-remote", required=True,
                        help="the operator's incus remote for the server hosting the client")
    parser.add_argument("--client-name", default="macus-remote-115")
    parser.add_argument("--client-image", default="images:alpine/3.22")
    parser.add_argument("--lock", type=Path,
                        help="the server/mix.lock of the installed pair's own revision "
                             "(default: this checkout's)")
    parser.add_argument("--remote-opt-in", action="store_true")
    parser.add_argument("--opt-in", action="store_true")
    return parser.parse_args()


def bind_address(raw):
    """A unicast private or CGNAT address: never loopback, a wildcard or a public address."""
    try:
        address = ipaddress.ip_address(raw)
    except ValueError:
        raise SystemExit(f"Refusing --bind-address {raw}: not an IP address")
    if address.is_loopback or address.is_unspecified or address.is_multicast:
        raise SystemExit(f"Refusing --bind-address {raw}: remote acceptance needs a unicast, "
                         "non-loopback address")
    if not (address.is_private or (address.version == 4 and address in CGNAT)):
        raise SystemExit(f"Refusing --bind-address {raw}: only private or CGNAT addresses")
    return str(address)


def client_remote(remotes, name, gateway_urls):
    """The client's host remote must be another Incus server, never this Macus or a socket."""
    entry = remotes.get(name)
    if not entry:
        raise SystemExit(f"Refusing: the client remote {name} does not exist")
    addresses = entry.get("Addrs") or ([entry["Addr"]] if entry.get("Addr") else [])
    if entry.get("Protocol") != "incus" or not addresses:
        raise SystemExit(f"Refusing: the client remote {name} is not an Incus server")
    for address in addresses:
        parsed = urllib.parse.urlsplit(address)
        host = parsed.hostname or ""
        if parsed.scheme != "https" or host in ("localhost",) or address in gateway_urls:
            raise SystemExit(f"Refusing: the client remote {name} ({address}) is not a "
                             "separate Incus server")
        try:
            if ipaddress.ip_address(host).is_loopback:
                raise SystemExit(f"Refusing: the client remote {name} ({address}) is loopback")
        except ValueError:
            pass
    return addresses


def pem_fingerprint(pem):
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def trust_entries(url, server_pem, conf):
    """Gateway trust as `GET /1.0/certificates?recursion=1` with an owner's client certificate.

    The standard `incus config trust list` adds an empty `filter=`, and `incus query` sends a
    JSON body (`""`) that opsmaru_incus refused before 0.2.8 (upmaru/opsmaru-incus#91). This
    plain native request has neither, so it also works against pairs built before those fixes.
    """
    parsed = urllib.parse.urlsplit(url)
    context = ssl.create_default_context(cadata=server_pem)
    context.load_cert_chain(str(conf / "client.crt"), str(conf / "client.key"))
    connection = http.client.HTTPSConnection(parsed.hostname, parsed.port, context=context,
                                             timeout=60)
    try:
        connection.request("GET", "/1.0/certificates?recursion=1")
        response = connection.getresponse()
        body = json.loads(response.read() or b"{}")
    finally:
        connection.close()
    require(response.status == 200 and isinstance(body.get("metadata"), list),
            f"listing gateway trust gave {response.status}: {body.get('error')}")
    return {entry["fingerprint"]: entry.get("name") for entry in body["metadata"]}


class Client:
    """The throwaway client container, driven through the operator's own incus client."""

    def __init__(self, args, report):
        self.args, self.report = args, report
        self.target = f"{args.client_remote}:{args.client_name}"
        self.env = {key: value for key, value in os.environ.items() if key != "INCUS_CONF"}
        self.uuid = None

    def command(self, *arguments, timeout=180, check=False):
        result = subprocess.run([str(self.args.incus), *arguments], env=self.env, text=True,
                                capture_output=True, stdin=subprocess.DEVNULL, timeout=timeout)
        self.report.setdefault("commands", []).append({
            "tool": "client", "arguments": list(arguments), "exit_code": result.returncode,
            "stdout": result.stdout[-4000:], "stderr": result.stderr[-4000:]})
        require(not check or result.returncode == 0,
                f"client incus {' '.join(arguments[:3])} exited {result.returncode}: "
                f"{result.stderr.strip()[-300:]}")
        return result

    def exists(self):
        return self.command("query", f"{self.args.client_remote}:/1.0/instances/"
                                     f"{self.args.client_name}", timeout=60).returncode == 0

    def instances(self):
        listed = self.command("list", f"{self.args.client_remote}:", "--format", "csv", "-c", "n",
                              timeout=60, check=True)
        return sorted(listed.stdout.split())

    def run(self, *arguments, timeout=180, check=False):
        return self.command("exec", self.target, "--", *arguments, timeout=timeout, check=check)

    def incus(self, conf, *arguments, timeout=120):
        """The client's own standard incus client, with one of its private configurations."""
        return self.run("env", f"INCUS_CONF=/root/{conf}", "incus", *arguments, timeout=timeout)

    def push(self, source, destination, mode="0600"):
        self.command("file", "push", "--mode", mode, str(source), f"{self.target}{destination}",
                     timeout=60, check=True)

    def probe(self, *arguments):
        result = self.run("python3", "-I", "/root/probe.py", *arguments, timeout=180, check=True)
        return json.loads(result.stdout)

    def fingerprint(self, path):
        """The certificate's SHA-256, or None when the client never wrote it."""
        try:
            return self.probe("fingerprint", path)["sha256"]
        except (CheckFailure, ValueError, KeyError):
            return None

    def create(self, bind):
        require(not self.exists(), f"{self.target} already exists; the run never reuses or "
                                   "replaces an instance it did not create")
        self.command("launch", self.args.client_image, self.target, "--ephemeral", timeout=600,
                     check=True)
        config = json.loads(self.command("query", f"{self.args.client_remote}:/1.0/instances/"
                                                  f"{self.args.client_name}", check=True).stdout)
        self.uuid = (config.get("config") or {}).get("volatile.uuid")
        deadline = time.monotonic() + 120
        while self.run("ping", "-c", "1", "-W", "2", bind, timeout=30).returncode != 0:
            require(time.monotonic() < deadline, f"the client never reached {bind}")
            time.sleep(2)
        for attempt in range(3):
            if self.run("apk", "add", "--no-cache", *CLIENT_PACKAGES, timeout=600).returncode == 0:
                break
            require(attempt < 2, "the client could not install its packages")
            time.sleep(5)
        self.push(PROBE, "/root/probe.py", mode="0644")

    def describe(self):
        def out(*arguments):
            return self.run(*arguments, check=True).stdout.strip()

        release = dict(line.split("=", 1) for line in out("cat", "/etc/os-release").splitlines()
                       if "=" in line)
        address = out("sh", "-c", "ip -4 -o addr show eth0 | awk '{print $4}'")
        return {"remote": self.args.client_remote, "remote_addresses": self.remote_addresses,
                "instance": self.args.client_name, "uuid": self.uuid,
                "image": self.args.client_image, "kernel": out("uname", "-srm"),
                "os": release.get("PRETTY_NAME", "").strip('"'),
                "incus_client": out("incus", "version").splitlines()[0], "address": address}

    def delete(self):
        """Deletes the client only if it is still the instance this run created."""
        if not self.exists():
            return {"deleted": True, "existed": False}
        config = json.loads(self.command("query", f"{self.args.client_remote}:/1.0/instances/"
                                                  f"{self.args.client_name}", check=True).stdout)
        found = (config.get("config") or {}).get("volatile.uuid")
        require(self.uuid and found == self.uuid,
                f"{self.target} is not the instance this run created ({found} != {self.uuid}); "
                "it was left in place")
        self.command("delete", "--force", self.target, timeout=300, check=True)
        return {"deleted": not self.exists(), "existed": True}


class Owner:
    """The owner's incus client (a private copy of the isolated INCUS_CONF) on the rebound URL."""

    def __init__(self, args, report, url, fingerprint, server_pem):
        self.args, self.report, self.url, self.server_pem = args, report, url, server_pem
        self.folder = Path(tempfile.mkdtemp(prefix="macus-remote-owner-", dir="/private/tmp"))
        os.chmod(self.folder, 0o700)
        self.conf = self.folder / "incus"
        shutil.copytree(args.incus_conf, self.conf)
        self.env = dict(os.environ, INCUS_CONF=str(self.conf))
        self.command("remote", "add", "owner-115", url, "--accept-certificate", check=True)
        pinned = (self.conf / "servercerts" / "owner-115.crt").read_text()
        require(pem_fingerprint(pinned) == fingerprint,
                "the owner's client pinned another certificate for the rebound gateway")

    def command(self, *arguments, timeout=120, check=False):
        result = subprocess.run([str(self.args.incus), *arguments], env=self.env, text=True,
                                capture_output=True, stdin=subprocess.DEVNULL, timeout=timeout)
        self.report.setdefault("commands", []).append({
            "tool": "owner", "arguments": list(arguments), "exit_code": result.returncode,
            "stdout": result.stdout[-4000:], "stderr": result.stderr[-4000:]})
        require(not check or result.returncode == 0,
                f"owner incus {' '.join(arguments[:3])} exited {result.returncode}: "
                f"{result.stderr.strip()[-300:]}")
        return result

    def trusted(self):
        return trust_entries(self.url, self.server_pem, self.conf)

    def standard_list(self):
        """What the standard `incus config trust list` does against the gateway (recorded)."""
        listed = self.command("config", "trust", "list", "owner-115:", "--format", "json")
        return {"exit_code": listed.returncode, "error": listed.stderr.strip()[-300:]}

    def remove(self, fingerprint):
        self.command("config", "trust", "remove", f"owner-115:{fingerprint}", check=True)

    def close(self):
        shutil.rmtree(self.folder, ignore_errors=True)


class Remote(restart.Restart):
    def __init__(self, args, report, run, endpoint, labels, tokens, client, port, bind):
        super().__init__(args, report, run, endpoint, labels, tokens)
        self.client, self.port, self.bind = client, port, bind
        self.url = f"https://{bind}:{port}"
        self.original_endpoint = endpoint
        self.trust_tokens, self.client_fingerprints = [], set()
        self.folder = Path(tempfile.mkdtemp(prefix="macus-remote-", dir="/private/tmp"))
        os.chmod(self.folder, 0o700)

    # The rebound gateway and its throwaway identity.
    def identity_files(self):
        key, certificate = self.folder / "gateway.key", self.folder / "gateway.crt"
        # A named curve, as TLS 1.3 requires; macOS's LibreSSL `req -newkey ec` would write
        # explicit curve parameters. P-384 matches the generated identity.
        for arguments in (["ecparam", "-name", "secp384r1", "-param_enc", "named_curve",
                           "-genkey", "-noout", "-out", str(key)],
                          ["req", "-x509", "-new", "-key", str(key), "-sha384", "-days", "2",
                           "-subj", f"/CN=macus-remote-acceptance {self.bind}", "-addext",
                           f"subjectAltName=IP:{self.bind}", "-out", str(certificate)]):
            subprocess.run(["/usr/bin/openssl", *arguments], check=True, capture_output=True,
                           stdin=subprocess.DEVNULL, timeout=60)
        named = subprocess.run(["/usr/bin/openssl", "x509", "-in", str(certificate), "-noout",
                                "-text"], check=True, capture_output=True, text=True, timeout=60)
        require("ASN1 OID: secp384r1" in named.stdout,
                "the throwaway certificate does not name its curve")
        os.chmod(key, 0o600)
        os.chmod(certificate, 0o644)
        self.certificate = certificate
        self.fingerprint = pem_fingerprint(certificate.read_text())
        return key, certificate

    def relaunch(self, url, fingerprint, timeout=120):
        """Restarts only the server job and waits for it to publish `url` with `fingerprint`."""
        old = start.job_pid(self.labels[1])
        restarted = subprocess.run(["/bin/launchctl", "kickstart", "-k",
                                    f"{self.domain}/{self.labels[1]}"],
                                   capture_output=True, text=True, timeout=60)
        require(restarted.returncode == 0, f"kickstart -k exited {restarted.returncode}")
        started, endpoint, last = time.monotonic(), {}, None
        while time.monotonic() - started < timeout:
            pid = start.job_pid(self.labels[1])
            try:
                endpoint = json.loads((self.run.state / "server" / "endpoint.json").read_text())
            except (OSError, ValueError):
                endpoint = {}
            if (pid and pid != old and str(endpoint.get("pid")) == str(pid)
                    and endpoint.get("url") == url
                    and endpoint.get("certificate_fingerprint") == fingerprint):
                try:
                    status, body = start.Gateway(endpoint).request("GET", "/runtime/status",
                                                                   self.read)
                    if status == 200 and body.get("state") == "ready":
                        return endpoint, {"pid": pid,
                                          "seconds": round(time.monotonic() - started, 1)}
                    last = [status, body]
                except OSError as error:
                    last = f"{type(error).__name__}: {error}"
            else:
                last = {"job_pid": pid, "endpoint_pid": endpoint.get("pid")}
            time.sleep(1)
        raise CheckFailure(f"the server did not publish {url} within {timeout} s "
                           f"(endpoint {endpoint.get('url')}, last {last})")

    def rebind(self):
        key, certificate = self.identity_files()
        self.run.macus(["server", "config", "set", "--bind-address", self.bind, "--port",
                        str(self.port), "--advertised-url", self.url, "--certificate-file",
                        str(certificate), "--key-file", str(key)])
        self.endpoint, recovered = self.relaunch(self.url, self.fingerprint)
        self.owner = Owner(self.args, self.report, self.url, self.fingerprint,
                           self.certificate.read_text())
        return {"url": self.url, "certificate_sha256": self.fingerprint, "server": recovered,
                "gateway_json": json.loads((self.run.state / "server" / "gateway.json")
                                           .read_text())}

    def restore(self, original):
        """Back to the original loopback configuration and generated identity."""
        self.run.macus(["server", "config", "reset"])
        self.run.macus(["server", "config", "set", "--port", str(self.port)])
        path = self.run.state / "server" / "gateway.json"
        rewritten = False
        if json.loads(path.read_text()) != json.loads(original):
            path.write_text(original)
            os.chmod(path, 0o600)
            rewritten = True
        endpoint, recovered = self.relaunch(self.original_endpoint["url"],
                                            self.original_endpoint["certificate_fingerprint"])
        return {"server": recovered, "endpoint": endpoint["url"], "rewritten": rewritten}

    def listeners(self, expected):
        found = start.service_footprint(self.labels, (start.job_pid(self.labels[0]),
                                                      start.job_pid(self.labels[1])), self.port)
        require(found["labels"] == sorted(self.labels) and found["server_listeners"] == [expected]
                and not found["runtime_network_sockets"], f"service footprint {found}")
        return found

    # Checks from the separate client.
    def separate_client(self):
        self.client.create(self.bind)
        described = self.client.describe()
        here = os.uname()
        require(described["kernel"].startswith("Linux") and here.sysname == "Darwin",
                f"the client is not a separate Linux machine: {described}")
        self.client.push(self.certificate, "/root/gateway.crt", mode="0644")
        return described

    def tls_identity(self):
        probed = self.client.probe("tls", self.url, "/root/gateway.crt")
        require(probed.get("connected") and probed.get("version") == "TLSv1.3"
                and probed.get("peer_sha256") == self.fingerprint
                == self.endpoint["certificate_fingerprint"]
                and str(probed.get("other_name", "")).startswith("refused")
                and (probed.get("anonymous") or {}).get("status") == 200
                and (probed.get("anonymous") or {}).get("auth") == "untrusted"
                and not (probed.get("anonymous") or {}).get("has_environment"),
                f"TLS identity from the client: {probed}")
        return probed

    def issue_trust_token(self, label):
        path = self.folder / f"{label}.trust-token"
        existing = {entry["id"] for entry in self.trust_list()}
        self.run.macus(["server", "trust", "token", "issue", "--name", self.args.client_name,
                        "--address", f"{self.bind}:{self.port}", "--server-certificate",
                        str(self.certificate), "--expires-in", "15m", "--output", str(path)])
        listed = self.trust_list()
        mine = [entry for entry in listed if entry["id"] not in existing]
        require(len(mine) == 1, f"the new enrollment token's record: {mine}")
        self.trust_tokens.append(mine[0]["id"])
        self.client.push(path, f"/root/{label}.trust-token")
        path.unlink()
        return mine[0]["id"]

    def trust_list(self):
        return self.run.macus(["--json", "server", "trust", "token", "list"],
                              json_output=True)["trust_tokens"]

    def redeem(self, conf, remote, label):
        return self.client.run("sh", "-c", f'INCUS_CONF=/root/{conf} incus remote add {remote} '
                                           f'"$(cat /root/{label}.trust-token)"', timeout=120)

    def native_enrollment(self):
        trusted_before = self.owner.trusted()
        self.report.setdefault("findings", {})["standard_trust_list"] = self.owner.standard_list()
        token_id = self.issue_trust_token("enroll")
        added = self.redeem("c1", "macus-115", "enroll")
        require(added.returncode == 0, f"incus remote add exited {added.returncode}: "
                                       f"{added.stderr.strip()[-300:]}")
        remotes = json.loads(self.client.incus("c1", "remote", "list", "--format", "json").stdout)
        entry = remotes.get("macus-115", {})
        addresses = entry.get("Addrs") or ([entry["Addr"]] if entry.get("Addr") else [])
        pinned = self.client.fingerprint("/root/c1/servercerts/macus-115.crt")
        self.enrolled = self.client.fingerprint("/root/c1/client.crt")
        self.client_fingerprints.add(self.enrolled)
        record = next(entry for entry in self.trust_list() if entry["id"] == token_id)
        trusted = self.owner.trusted()
        new = {fingerprint: name for fingerprint, name in trusted.items()
               if fingerprint not in trusted_before}
        require(addresses == [self.url] and pinned == self.fingerprint
                and record.get("redeemed_by") == self.enrolled and record.get("redeemed_at")
                and new == {self.enrolled: self.args.client_name},
                f"enrollment: remote {addresses}, pinned {pinned}, record {record}, "
                f"new gateway trust {new}")
        return {"remote_addresses": addresses, "pinned_server_certificate": pinned,
                "client_certificate": self.enrolled, "token": record,
                "gateway_trust_added": new}

    def single_use_enrollment(self):
        trusted = self.owner.trusted()
        again = self.redeem("c2", "again", "enroll")
        other = self.client.fingerprint("/root/c2/client.crt")
        self.client_fingerprints.add(other)
        after = self.owner.trusted()
        require(again.returncode != 0 and after == trusted and other not in after,
                f"a redeemed token enrolled again: exit {again.returncode}, trust {after}")
        return {"exit_code": again.returncode, "error": again.stderr.strip()[-300:],
                "gateway_trust_unchanged": True}

    def native_workload_access(self):
        listed = json.loads(self.client.incus("c1", "list", "macus-115:", "--format",
                                              "json").stdout or "[]")
        names = sorted(entry.get("name") for entry in listed)
        marker = self.client.incus("c1", "exec", f"macus-115:{self.args.instance}", "--", "cat",
                                   workload.MARKER)
        server = json.loads(self.client.incus("c1", "query", "macus-115:/1.0").stdout or "{}")
        environment = server.get("environment") or {}
        certificate = environment.get("certificate") or ""
        require(self.args.instance in names and marker.stdout.strip() == "macus-11.3"
                and server.get("auth") == "trusted"
                and environment.get("addresses") == [f"{self.bind}:{self.port}"]
                and certificate and pem_fingerprint(certificate) == self.fingerprint,
                f"native access: instances {names}, marker {marker.stdout!r}, auth "
                f"{server.get('auth')}, addresses {environment.get('addresses')}")
        return {"instances": names, "marker": marker.stdout.strip(), "auth": server.get("auth"),
                "addresses": environment.get("addresses"),
                "server_certificate_sha256": pem_fingerprint(certificate)}

    def requests(self, plan):
        path = self.folder / "plan.json"
        path.write_text(json.dumps(plan))
        self.client.push(path, "/root/plan.json", mode="0644")
        return self.client.probe("requests", self.url, "/root/gateway.crt", "/root/plan.json")

    def combined_plan(self, token_file):
        def mcp(label, name, arguments, token=token_file):
            return {"label": label, "kind": "mcp", "name": name, "arguments": arguments,
                    "token_file": token}

        def execute(label, operation, payload, cassette="opsmaru_incus", token=token_file):
            return mcp(label, "execute", {"cassette": cassette, "operation_id": operation,
                                          "input": payload}, token)

        return [
            {"label": "runtime_status", "kind": "http", "method": "GET", "path": "/runtime/status",
             "token_file": token_file},
            mcp("search_incus", "search", {"query": "instance", "limit": 20,
                                           "include_schemas": False}),
            mcp("search_runtime", "search", {"cassette": "macus", "limit": 20,
                                             "include_schemas": False}),
            execute("instance_list", "incus_instance_list", {}),
            execute("runtime_status_mcp", "macus_runtime_status", {}, cassette="macus"),
            execute("exec_without_scope", "incus_instance_exec",
                    {"instance": self.args.instance, "command": ["true"]}),
            execute("runtime_start_without_scope", "macus_runtime_start", {}, cassette="macus"),
            # Refused by scope before the body is read; the empty body could never apply anyway.
            {"label": "runtime_write_without_scope", "kind": "http", "method": "PUT",
             "path": "/runtime/config", "body": {}, "token_file": token_file},
            {"label": "native_with_bearer", "kind": "http", "method": "GET",
             "path": "/1.0/instances", "token_file": token_file},
            {"label": "runtime_without_token", "kind": "http", "method": "GET",
             "path": "/runtime/status"},
            execute("mcp_without_token", "incus_instance_list", {}, token=None),
        ]

    def scoped_combined_access(self):
        path = self.folder / "combined.token"
        self.run.macus(["server", "token", "issue", "--principal", self.args.client_name,
                        "--scope", "incus.read", "--scope", "runtime.read", "--expires-in", "1h",
                        "--output", str(path)])
        token = path.read_text().strip()
        self.combined = token.split(".")[1]
        self.tokens.ids.append(self.combined)
        self.client.push(path, "/root/combined.token")
        path.unlink()
        results = self.requests(self.combined_plan("/root/combined.token"))

        def operations(label):
            return sorted(entry["operation_id"]
                          for entry in (results[label].get("body") or {}).get("results", []))

        def refused(label):
            body = results[label].get("body") or {}
            return [workload.error_kind(body), workload.dispatched(body)]

        incus_ops, runtime_ops = operations("search_incus"), operations("search_runtime")
        summary = {
            "runtime_status": [results["runtime_status"]["status"],
                               (results["runtime_status"].get("body") or {}).get("state")],
            "search_incus": incus_ops, "search_runtime": runtime_ops,
            "instance_list": [results["instance_list"]["status"],
                              results["instance_list"]["is_error"],
                              f'"{self.args.instance}"' in json.dumps(
                                  results["instance_list"].get("body"))],
            "runtime_status_mcp": [results["runtime_status_mcp"]["status"],
                                   results["runtime_status_mcp"]["is_error"],
                                   '"ready"' in json.dumps(results["runtime_status_mcp"]
                                                           .get("body"))],
            "exec_without_scope": refused("exec_without_scope"),
            "runtime_start_without_scope": refused("runtime_start_without_scope"),
            "runtime_write_without_scope": results["runtime_write_without_scope"]["status"],
            "native_with_bearer": results["native_with_bearer"]["status"],
            "runtime_without_token": results["runtime_without_token"]["status"],
            "mcp_without_token": results["mcp_without_token"]["status"],
        }
        require(summary["runtime_status"] == [200, "ready"]
                and "incus_instance_list" in incus_ops and "incus_instance_exec" not in incus_ops
                and "macus_runtime_status" in runtime_ops
                and "macus_runtime_start" not in runtime_ops
                and summary["instance_list"] == [200, False, True]
                and summary["runtime_status_mcp"] == [200, False, True]
                and summary["exec_without_scope"] == ["not_found", False]
                and summary["runtime_start_without_scope"] == ["not_found", False]
                and summary["runtime_write_without_scope"] == 403
                and summary["native_with_bearer"] in (401, 403)
                and summary["runtime_without_token"] == 401
                and summary["mcp_without_token"] == 401,
                f"combined scoped access from the client: {summary}")
        return summary

    def bearer_revocation(self):
        plan = [step for step in self.combined_plan("/root/combined.token")
                if step["label"] in ("runtime_status", "instance_list")]
        self.run.macus(["server", "token", "revoke", self.combined])
        self.tokens.ids.remove(self.combined)
        started = time.monotonic()
        while True:
            results = self.requests(plan)
            statuses = {label: result["status"] for label, result in results.items()}
            if all(status == 401 for status in statuses.values()):
                break
            require(time.monotonic() - started < 15, f"after revocation the client got {statuses}")
            time.sleep(1)
        return {"statuses": statuses, "seconds": round(time.monotonic() - started, 1)}

    def native_revocation(self):
        command = [str(self.client.args.incus), "exec", self.client.target, "--", "env",
                   "INCUS_CONF=/root/c1", "incus", "exec", f"macus-115:{self.args.instance}",
                   "--", "sleep", "120"]
        session = subprocess.Popen(command, env=self.client.env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(5)
            require(session.poll() is None, "the client's exec ended before the revocation")
            self.owner.remove(self.enrolled)
            removed = time.monotonic()
            try:
                session.wait(timeout=30)
            except subprocess.TimeoutExpired:
                raise CheckFailure("the client's open exec survived the revocation for 30 s")
            ended = round(time.monotonic() - removed, 1)
        finally:
            if session.poll() is None:
                session.kill()
                session.wait(10)
        listed = self.client.incus("c1", "list", "macus-115:", "--format", "csv", "-c", "n")
        # Before opsmaru_incus 0.2.8, anonymous discovery refused the JSON body `incus query`
        # sends, so the client's standing is read with a plain `GET /1.0` and the same certificate.
        seen = self.client.probe("identity", self.url, "/root/gateway.crt", "/root/c1")
        trusted = self.owner.trusted()
        require(listed.returncode != 0 and seen.get("auth") == "untrusted"
                and self.enrolled not in trusted,
                f"after removal: list exited {listed.returncode} ({listed.stderr.strip()}), "
                f"gateway sees {seen}; exec ended after {ended} s")
        return {"open_exec_ended_seconds": ended, "open_exec_exit": session.returncode,
                "list_exit": listed.returncode, "list_error": listed.stderr.strip(),
                "auth": seen.get("auth")}

    def enrollment_token_revocation(self):
        token_id = self.issue_trust_token("revoked")
        self.run.macus(["server", "trust", "token", "revoke", token_id])
        trusted = self.owner.trusted()
        redeemed = self.redeem("c3", "revoked", "revoked")
        other = self.client.fingerprint("/root/c3/client.crt")
        self.client_fingerprints.add(other)
        record = next(entry for entry in self.trust_list() if entry["id"] == token_id)
        after = self.owner.trusted()
        require(redeemed.returncode != 0 and record.get("revoked_at")
                and not record.get("redeemed_at") and after == trusted,
                f"a revoked enrollment token: exit {redeemed.returncode}, record {record}")
        return {"exit_code": redeemed.returncode, "token": record}

    def loopback_restored(self):
        listeners = self.listeners(f"127.0.0.1:{self.port}")
        self.reconnects()
        probed = self.client.probe("tls", self.url, "/root/gateway.crt")
        require(not probed.get("connected"), f"the client still reaches {self.url}: {probed}")
        return {"listeners": listeners["server_listeners"],
                "client_after_restore": probed.get("error")}

    def clean_up_trust(self):
        """Nothing this run enrolled or issued stays usable, whatever failed earlier."""
        left = {}
        trusted = set(trust_entries(self.original_endpoint["url"],
                                    self.original_endpoint["certificate"], self.args.incus_conf))
        for fingerprint in sorted(self.client_fingerprints & trusted):
            removed = self.run.command([str(self.args.incus), "config", "trust", "remove",
                                        f"{self.args.remote}:{fingerprint}"], 60, "incus")
            left[fingerprint] = removed.returncode == 0
        for entry in self.trust_list():
            if entry["id"] in self.trust_tokens and not entry.get("redeemed_at") \
                    and not entry.get("revoked_at"):
                self.run.macus(["server", "trust", "token", "revoke", entry["id"]])
                left[entry["id"]] = True
        still = set(trust_entries(self.original_endpoint["url"],
                                  self.original_endpoint["certificate"], self.args.incus_conf))
        require(not self.client_fingerprints & still,
                f"client certificates still trusted: {sorted(self.client_fingerprints & still)}")
        return {"removed_after_failure": left, "client_certificates_trusted": False,
                "gateway_trust": sorted(still)}

    def close(self):
        if getattr(self, "owner", None):
            self.owner.close()
        shutil.rmtree(self.folder, ignore_errors=True)


def main():
    args = parse_args()
    if not args.opt_in:
        raise SystemExit("Refusing to run without --opt-in")
    start.validate_report(args.report, args.state_dir, args.prefix, None)
    state, prefix = args.state_dir, args.prefix
    start.refuse_user_paths(state, prefix, None)
    start.refuse_user_client(args.incus_conf)
    bind = bind_address(args.bind_address)
    report = {
        "schema_version": 1,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Opt-in remote-client acceptance on an isolated, started Macus: a separate "
                 "client on another Incus server, not loopback and not Linux workload evidence",
        "remote_ran": False, "loopback_evidence": False, "state_dir": str(state.resolve()),
        "prefix": str(prefix.resolve()), "incus_conf": str(args.incus_conf.resolve()),
        "bind_address": bind, "lock": str(args.lock.resolve()) if args.lock else None,
        "checks": {}, "evidence": {},
    }

    def save():
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")

    save()
    try:
        pair = start.installed_pair(prefix, args.lock)
        endpoint = json.loads((state / "server" / "endpoint.json").read_text())
        original = (state / "server" / "gateway.json").read_text()
        port = json.loads(original)["port"]
    except (start.PairFailure, OSError, ValueError, KeyError) as error:
        report["success"], report["failure"] = False, str(error)
        save()
        raise SystemExit(f"Installed pair or started state check failed: {error}")
    report["pair"] = pair
    report["evidence"]["package"] = {"paired_artifacts": True, "pinned_dependency": True}
    save()
    env = dict(os.environ, INCUS_CONF=str(args.incus_conf.resolve()), MACUS_BREW_FALLBACK="0")
    for variable in ("MACUS_STATE_DIR", "MACUS_FIXTURE_GUEST_DIR", "MACUS_FIXTURE_LAUNCHCTL"):
        env.pop(variable, None)
    run = start.Run(pair["binary"], state.resolve(), env, report)
    remotes = run.command([str(args.incus), "remote", "list", "--format", "json"], 60, "incus")
    entry = json.loads(remotes.stdout).get(args.remote, {}) if remotes.returncode == 0 else {}
    addresses = entry.get("Addrs") or ([entry["Addr"]] if entry.get("Addr") else [])
    if addresses != [endpoint["url"]] or not endpoint["url"].startswith("https://127.0.0.1:"):
        report["success"] = False
        report["failure"] = f"remote {args.remote} is {addresses}, not this state's loopback " \
                            f"{endpoint['url']}"
        save()
        raise SystemExit("Refusing: the client's remote is not this state's loopback gateway")
    if not args.remote_opt_in:
        report["note"] = "Remote acceptance was not run; nothing was rebound, launched or enrolled."
        save()
        raise SystemExit("Remote acceptance was not run; pass --remote-opt-in to use a separate "
                         "client")
    client = Client(args, report)
    user_remotes = client.command("remote", "list", "--format", "json", timeout=60)
    try:
        client.remote_addresses = client_remote(json.loads(user_remotes.stdout or "{}"),
                                                args.client_remote,
                                                {endpoint["url"], f"https://{bind}:{port}"})
    except SystemExit as refusal:
        report["success"], report["failure"] = False, str(refusal)
        save()
        raise
    report["remote_ran"] = True
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
        return checks[name]

    remote = None
    try:
        remote = Remote(args, report, run, endpoint, labels, tokens, client, port, bind)
        baseline = remote.retained_workload()
        guest_before = remote.guest_state()
        report["guest_before"] = guest_before
        other_instances = client.instances()
        report["client_host_instances_before"] = other_instances
        rebound = False
        try:
            rebound = attempt("rebind", remote.rebind)
            if rebound:
                attempt("remote_listener_only", remote.listeners, f"{bind}:{port}")
                if attempt("separate_client", remote.separate_client):
                    attempt("tls_identity", remote.tls_identity)
                    if attempt("native_enrollment", remote.native_enrollment):
                        attempt("single_use_enrollment", remote.single_use_enrollment)
                        attempt("native_workload_access", remote.native_workload_access)
                    if attempt("scoped_combined_access", remote.scoped_combined_access):
                        attempt("bearer_revocation", remote.bearer_revocation)
                    if checks.get("native_enrollment"):
                        attempt("native_revocation", remote.native_revocation)
                    attempt("enrollment_token_revocation", remote.enrollment_token_revocation)
        finally:
            # Always back to loopback, whatever happened above.
            attempt("restore", remote.restore, original)
        if checks["restore"] and checks.get("separate_client"):
            attempt("loopback_restored", remote.loopback_restored)
        if checks["restore"]:
            attempt("trust_cleaned", remote.clean_up_trust)

        def removed():
            deleted = client.delete()
            left = client.instances()
            require(deleted["deleted"] and left == other_instances,
                    f"client host instances {left} (before {other_instances}), {deleted}")
            return {**deleted, "client_host_instances": left}

        attempt("client_removed", removed)

        def unaffected():
            after = remote.guest_state()
            report["guest_after"] = after
            final = remote.identity()
            kept = ("runtime_pid", "guest_boot_id", "instance_uuid", "instance_pid", "marker")
            require(after == guest_before
                    and all(final[key] == baseline[key] for key in kept),
                    f"guest {after} (before {guest_before}); identity {final} "
                    f"(before {baseline})")
            return {"before": baseline, "after": final}

        attempt("guest_unaffected", unaffected)
        default_after = start.default_footprint()
        report["default_footprint"] = {"before": default_before, "after": default_after}
        checks["default_jobs_and_endpoint_unchanged"] = default_after == default_before
        report["evidence"]["remote"] = {name: checks.get(name, False) for name in REMOTE_CHECKS}
        report["success"] = (all(checks.get(name) for name in REMOTE_CHECKS)
                             and checks.get("rebind") and checks.get("restore")
                             and checks.get("trust_cleaned"))
    except Exception as error:
        report["success"] = False
        report["note"] = f"Acceptance failed and artifacts were preserved: {error}"
    finally:
        tokens.revoke_all(report)
        if remote is not None:
            remote.close()
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        save()
    if not report.get("success"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
