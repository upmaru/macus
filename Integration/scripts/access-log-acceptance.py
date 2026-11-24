#!/usr/bin/env python3
"""Hardware acceptance for add-gateway-access-log task 5.1. Opt-in.

Runs against a state that start-acceptance.py already started, with that run's
installed pair, isolated INCUS_CONF (its report's incus_conf) and remote. It
creates one throwaway instance and leaves it and the runtime in place.

Drives the standard incus client through the gateway of an already started
isolated state, plus one request from an untrusted certificate, then reads the
access log with `macus server logs` and checks it. Never touches the default
Incus client configuration: every child gets the isolated INCUS_CONF.
"""
import argparse
import hashlib
import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

KEYS = {"v", "id", "time", "protocol", "method", "path", "project", "target", "all_projects",
        "operation", "peer", "certificate", "admitted_as", "status", "outcome", "reason",
        "duration_ms", "request_bytes", "response_bytes", "dropped_before"}
NEVER = ["Bearer ", "Basic ", "authorization", "secret", "?", "-----BEGIN"]


def main():
    p = argparse.ArgumentParser()
    for name in ("state-dir", "prefix", "incus-conf", "incus", "remote", "url", "certificate",
                 "report"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--opt-in", action="store_true")
    p.add_argument("--instance", default="al-acc")
    p.add_argument("--image", default="images:alpine/3.22")
    a = p.parse_args()
    if not a.opt_in:
        raise SystemExit("Refusing to run without --opt-in")
    home = Path.home()
    ordinary = [home / ".tama" / "incus-mac", home / ".config" / "incus",
                home / "Library" / "Application Support" / "incus"]
    for chosen in (a.state_dir, a.incus_conf):
        if any(Path(chosen).resolve() == path.resolve() for path in ordinary):
            raise SystemExit(f"Refusing the ordinary state or client configuration: {chosen}")

    env = {k: v for k, v in os.environ.items() if k not in ("MACUS_STATE_DIR",)}
    env["INCUS_CONF"] = a.incus_conf
    macus = [str(Path(a.prefix) / "bin" / "macus"), "--state-dir", a.state_dir]
    target = f"{a.remote}:{a.instance}"
    steps, failures = [], []

    def run(label, argv, timeout=600, check=True, stdin=subprocess.DEVNULL):
        started = time.time()
        done = subprocess.run(argv, env=env, stdin=stdin, capture_output=True, text=True,
                              timeout=timeout)
        steps.append({"step": label, "argv": argv, "exit": done.returncode,
                      "seconds": round(time.time() - started, 2),
                      "stdout": done.stdout[-2000:], "stderr": done.stderr[-2000:]})
        print(f"[{label}] exit {done.returncode} ({steps[-1]['seconds']}s)", flush=True)
        if check and done.returncode != 0:
            print(done.stdout[-1500:], done.stderr[-1500:], sep="\n", flush=True)
            raise SystemExit(finish(1))
        return done

    def logs():
        out = run("server logs --json", macus + ["server", "logs", "--json", "--lines", "100000"])
        return [json.loads(line) for line in out.stdout.splitlines() if line.strip()], out.stdout

    def finish(code):
        Path(a.report).write_text(json.dumps(
            {"task": "add-gateway-access-log 5.1", "state_dir": a.state_dir, "prefix": a.prefix,
             "endpoint": a.url, "passed": code == 0, "failures": failures, "steps": steps,
             "evidence": evidence}, indent=2))
        return code

    evidence = {}
    before, _ = logs()
    evidence["records_before"] = len(before)

    # 1-4: list, launch, exec, file push through the standard client.
    run("incus list", [a.incus, "list", f"{a.remote}:", "--format", "json"])
    run("incus launch", [a.incus, "launch", a.image, target], timeout=900)
    executed = run("incus exec", [a.incus, "exec", target, "--", "sh", "-c",
                                  "echo access-log-acceptance; uname -s"])
    with tempfile.TemporaryDirectory(prefix="macus-al-") as folder:
        blob = Path(folder) / "blob"
        data = os.urandom(2 * 1024 * 1024)
        blob.write_bytes(data)
        run("incus file push", [a.incus, "file", "push", str(blob), f"{target}/root/blob"])
        hashed = run("incus exec sha256", [a.incus, "exec", target, "--", "sha256sum",
                                           "/root/blob"])
        evidence["pushed_sha256_matches"] = hashed.stdout.split()[0] == hashlib.sha256(
            data).hexdigest()

        # 5: an SFTP mount. `incus file mount --listen` serves SSH locally and opens
        # the instance's SFTP channel through the gateway for each session.
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        mount = subprocess.Popen([a.incus, "file", "mount", target, "--listen",
                                  f"127.0.0.1:{port}", "--no-auth"], env=env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.time() + 30
            while time.time() < deadline:
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.3)
            batch = Path(folder) / "batch"
            batch.write_text("ls -l /root/blob\n")
            sftp = run("sftp ls over the mount", [
                "/usr/bin/sftp", "-P", str(port), "-b", str(batch),
                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PreferredAuthentications=none,password", "-o", "BatchMode=yes",
                "root@127.0.0.1"], timeout=60, check=False)
            evidence["sftp_listed_blob"] = sftp.returncode == 0 and "blob" in sftp.stdout
        finally:
            mount.terminate()
            try:
                mount_out = mount.communicate(timeout=15)[0]
            except subprocess.TimeoutExpired:
                mount.kill()
                mount_out = mount.communicate()[0]
            steps.append({"step": "incus file mount --listen", "exit": mount.returncode,
                          "stdout": mount_out[-1500:]})

        # 6: one request from a certificate the gateway does not trust.
        key, cert = Path(folder) / "client.key", Path(folder) / "client.crt"
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-days", "1", "-subj", "/CN=macus-access-log-untrusted", "-keyout",
                        str(key), "-out", str(cert)], check=True, capture_output=True,
                       stdin=subprocess.DEVNULL, timeout=30)
        der = ssl.PEM_cert_to_DER_cert(cert.read_text())
        stranger = hashlib.sha256(der).hexdigest()
        context = ssl.create_default_context(cadata=Path(a.certificate).read_text())
        context.load_cert_chain(str(cert), str(key))
        parsed = urllib.parse.urlsplit(a.url)
        connection = http.client.HTTPSConnection(parsed.hostname, parsed.port, context=context,
                                                 timeout=30)
        connection.request("GET", "/1.0/instances?project=default&filter=QUERYMARK7f3a",
                           headers={"authorization": "Bearer BEARERMARK55aa",
                                    "x-acceptance": "HEADERMARK1d4e"})
        untrusted_status = connection.getresponse().status
        connection.close()
        evidence["untrusted_status"] = untrusted_status

    client_cert = Path(a.incus_conf) / "client.crt"
    trusted = hashlib.sha256(ssl.PEM_cert_to_DER_cert(client_cert.read_text())).hexdigest()

    # Streams are recorded when they end; give the observers a moment.
    time.sleep(3)
    records, raw = logs()
    new = records[len(before):]
    evidence["records_after"] = len(records)
    evidence["new_records"] = len(new)
    human = run("server logs", macus + ["server", "logs", "--lines", "200"])
    evidence["human_tail"] = human.stdout.splitlines()[-25:]

    def check(name, ok, detail=""):
        evidence[name] = bool(ok)
        if not ok:
            failures.append(f"{name}: {detail}")

    def find(**want):
        return [r for r in new if all(
            (v(r.get(k)) if callable(v) else r.get(k) == v) for k, v in want.items())]

    inst = f"/1.0/instances/{a.instance}"
    listing = find(method="GET", path="/1.0/instances", admitted_as="caller", status=200)
    check("list_recorded", listing and all(r["certificate"] == trusted for r in listing),
          f"{len(listing)} records")
    created = find(method="POST", path="/1.0/instances", admitted_as="caller")
    check("launch_recorded", created and created[0]["outcome"] == "ok"
          and created[0]["request_bytes"] > 0, json.dumps(created[:1]))
    execs = find(method="POST", path=inst + "/exec")
    check("exec_recorded", len(execs) >= 2 and all(r["outcome"] == "ok" for r in execs),
          f"{len(execs)} records")
    streams = find(protocol="websocket", status=101,
                   path=lambda p: p and p.startswith("/1.0/operations/") and p.endswith(
                       "/websocket"))
    check("exec_streams_recorded_at_end", streams and all(
        r["operation"] and r["duration_ms"] is not None for r in streams),
          f"{len(streams)} records")
    # This client pushes files over the instance's SFTP channel, so the push and
    # the mount are both raw upgrades: the push carries the 2 MiB in.
    sftp_records = find(protocol="raw", path=inst + "/sftp", status=101)
    push = [r for r in sftp_records if r["request_bytes"] >= 2 * 1024 * 1024]
    check("file_push_recorded", len(push) == 1, json.dumps(push[:1]))
    check("sftp_mount_recorded", len(sftp_records) >= 2, f"{len(sftp_records)} raw records")
    check("sftp_recorded", sftp_records and all(
        r["request_bytes"] > 0 and r["response_bytes"] > 0 and r["admitted_as"] == "caller"
        for r in sftp_records), f"{len(sftp_records)} records")
    refused = find(certificate=stranger)
    check("untrusted_recorded", untrusted_status == 403 and len(refused) == 1
          and refused[0]["status"] == 403 and refused[0]["outcome"] == "not_sent"
          and refused[0]["reason"] == "unauthorized" and refused[0]["admitted_as"] is None
          and refused[0]["path"] == "/1.0/instances", json.dumps(refused))
    check("pushed_sha256_matches", evidence.get("pushed_sha256_matches"))
    check("sftp_listed_blob", evidence.get("sftp_listed_blob"))

    # Identity: one boot value, SEQ strictly increasing in file order per boot, no gap.
    ids = [r["id"].split("-") for r in new]
    seqs = [int(s) for _, s in ids]
    check("one_boot", len({b for b, _ in ids}) == 1, str({b for b, _ in ids}))
    check("ids_unique", len(set(map(tuple, ids))) == len(ids))
    check("no_gap", sorted(seqs) == list(range(min(seqs), max(seqs) + 1)),
          f"{min(seqs)}..{max(seqs)} with {len(seqs)} records")
    check("no_drops", not any("dropped_before" in r for r in new))

    # Redaction over the whole file.
    unknown = sorted({k for r in records for k in r} - KEYS)
    check("documented_keys_only", not unknown, str(unknown))
    marks = ["QUERYMARK7f3a", "BEARERMARK55aa", "HEADERMARK1d4e"]
    found = [m for m in NEVER + marks if m in raw]
    check("no_secret_in_log", not found, str(found))
    client_key = (Path(a.incus_conf) / "client.key").read_text().splitlines()[1]
    check("no_key_or_cert_body", client_key not in raw
          and client_cert.read_text().splitlines()[1] not in raw)

    log_dir = Path(a.state_dir) / "logs"
    modes = {p.name: oct(p.stat().st_mode & 0o777) for p in log_dir.glob("gateway-access.log*")}
    evidence["log_modes"] = modes
    evidence["logs_dir_mode"] = oct(log_dir.stat().st_mode & 0o777)
    check("log_private", all(m == "0o600" for m in modes.values())
          and evidence["logs_dir_mode"] == "0o700", json.dumps(modes))
    evidence["by_protocol"] = {p: len(find(protocol=p)) for p in ("http", "websocket", "raw")}
    evidence["exec_stdout"] = executed.stdout.strip()

    code = finish(1 if failures else 0)
    print(json.dumps({k: v for k, v in evidence.items() if k != "human_tail"}, indent=1))
    print("\n".join(evidence["human_tail"]))
    print("FAILURES:", failures if failures else "none")
    return code


if __name__ == "__main__":
    sys.exit(main())
