#!/usr/bin/env python3
"""Boot an assembled Macus server release in isolation and check what task 9.1 promises.

Usage: release-smoke.py --release PATH [--keep]

The release (from `MIX_ENV=prod mix release macus`) is copied into a fresh
prefix at `libexec/macus`. That proves it does not depend on its build
location. It is then started the way launchd starts it, but with an empty
environment. PATH holds only the system directories, HOME is a new
directory, and the state directory is new.

Checks:
  * the payload: macus-build.json, and every Mach-O links only system
    libraries, so no Homebrew, mise or other host Erlang/OpenSSL is used;
  * no `erl`, `elixir` or `mix` is reachable on the server's PATH;
  * boot: the gateway publishes its endpoint, serves TLS 1.3 with the
    published certificate, and refuses an unauthenticated runtime request;
  * the pinned cassette is imported and the local runtime cassette loads;
  * the server's only listener is the gateway port. No Erlang distribution
    flag is passed, even when the environment asks for distribution, and no
    EPMD connection is made;
  * shutdown: SIGTERM stops the server alone, with exit status 0. A stand-in
    for the Swift runtime service, which holds `runtime.sock`, keeps
    running, and the runtime files and the server's credentials remain.

Nothing outside the temporary root is touched, and no VM is booted. On
failure the root is kept, and its path is printed.
"""

import argparse
import hashlib
import json
import os
import shutil
import signal
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import time
import http.client

SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
SYSTEM_LIBRARIES = ("/usr/lib/", "/System/Library/")


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def macho_files(root):
    for directory, _, names in os.walk(root):
        for name in names:
            path = os.path.join(directory, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as handle:
                magic = handle.read(4)
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                yield path


def foreign_links(path):
    """Linked libraries outside the system, excluding the file's own install name."""
    output = subprocess.run(
        ["/usr/bin/otool", "-L", path], capture_output=True, text=True, check=True
    ).stdout.splitlines()[1:]
    own = subprocess.run(
        ["/usr/bin/otool", "-D", path], capture_output=True, text=True, check=True
    ).stdout.splitlines()[1:]
    links = [line.strip().split(" (")[0] for line in output if line.strip()]
    return [link for link in links if link not in own and not link.startswith(SYSTEM_LIBRARIES)]


def listeners(pid):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
        capture_output=True, text=True,
    )
    return sorted(line[1:] for line in result.stdout.splitlines() if line.startswith("n"))


def connections(pid):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-i", "-Fn"],
        capture_output=True, text=True,
    )
    return [line[1:] for line in result.stdout.splitlines() if line.startswith("n")]


def wait_for(predicate, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    raise Failure(message)


def digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def snapshot(directory):
    found = {}
    for root, _, names in os.walk(directory):
        for name in names:
            path = os.path.join(root, name)
            found[os.path.relpath(path, directory)] = None if os.path.islink(path) else digest(path)
    return found


def run(release, keep):
    root = tempfile.mkdtemp(prefix="macus-rel-", dir="/private/tmp")
    server = None
    swift = None
    ok = False
    try:
        prefix = os.path.join(root, "prefix")
        target = os.path.join(prefix, "libexec", "macus")
        shutil.copytree(release, target, symlinks=True)
        manifest = json.load(open(os.path.join(target, "macus-build.json")))
        check(manifest.get("schema_version") == 1, "macus-build.json is not schema 1")
        check(manifest.get("distribution") == "none", "the manifest does not record distribution off")
        mode = os.stat(os.path.join(target, "macus-build.json")).st_mode & 0o777
        check(mode & 0o222 == 0, "macus-build.json is writable (mode %o)" % mode)

        machos = list(macho_files(target))
        check(machos, "the release has no Mach-O files")
        foreign = {os.path.relpath(path, target): links for path in machos if (links := foreign_links(path))}
        check(not foreign, "Mach-O files link outside the system: %s" % foreign)
        nif = os.path.join(
            target, "lib", "exqlite-%s" % manifest["exqlite"]["version"], "priv", "sqlite3_nif.so"
        )
        check(digest(nif) == manifest["exqlite"]["nif_sha256"], "the NIF differs from the manifest")

        home = os.path.join(root, "home")
        state = os.path.join(root, "state")
        os.makedirs(home, mode=0o700)
        os.makedirs(os.path.join(state, "server"), mode=0o700)
        os.chmod(state, 0o700)
        port = free_port()
        with open(os.path.join(state, "server", "gateway.json"), "w") as handle:
            json.dump({"schema_version": 1, "bind_address": "127.0.0.1", "port": port}, handle)
        os.chmod(os.path.join(state, "server", "gateway.json"), 0o600)

        # A stand-in for the Swift runtime service: it owns runtime.sock and runtime files.
        os.makedirs(os.path.join(state, "runtime"), mode=0o700)
        with open(os.path.join(state, "runtime", "disk.marker"), "w") as handle:
            handle.write("guest data\n")
        swift = subprocess.Popen(
            [sys.executable, "-I", "-c",
             "import socket,sys,time\n"
             "s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)\n"
             "time.sleep(600)\n",
             os.path.join(state, "runtime.sock")],
        )
        wait_for(lambda: os.path.exists(os.path.join(state, "runtime.sock")), 10, "stand-in did not bind")
        runtime_before = snapshot(os.path.join(state, "runtime"))

        environment = {
            "HOME": home,
            "PATH": SYSTEM_PATH,
            "LANG": "en_US.UTF-8",
            "MACUS_STATE_DIR": state,
            "MACUS_SERVE": "1",
            "MACUS_EXPECTED_REVISION": manifest["revision"],
            # Asked for, and still refused by env.sh.
            "RELEASE_DISTRIBUTION": "sname",
        }
        for tool in ("erl", "elixir", "mix", "iex"):
            check(shutil.which(tool, path=SYSTEM_PATH) is None, "%s is on the system PATH" % tool)

        log = open(os.path.join(root, "server.log"), "wb")
        server = subprocess.Popen(
            [os.path.join(target, "bin", "macus"), "start"],
            env=environment, cwd=home, stdout=log, stderr=subprocess.STDOUT,
        )
        endpoint_path = os.path.join(state, "server", "endpoint.json")
        wait_for(
            lambda: os.path.exists(endpoint_path) or server.poll() is not None, 90, "no endpoint"
        )
        check(server.poll() is None, "the server exited with %s" % server.returncode)
        endpoint = json.load(open(endpoint_path))
        pid = int(endpoint["pid"])
        check(pid == server.pid, "the published pid %s is not the launched process %s" % (pid, server.pid))
        check(endpoint["build"]["revision"] == manifest["revision"], "the endpoint names another build")

        command = subprocess.run(
            ["/bin/ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True
        ).stdout
        check("beam.smp" in command and target in command, "the server is not the bundled ERTS: %s" % command)
        check(" -sname " not in command and " -name " not in command, "distribution is on: %s" % command)

        bound = listeners(pid)
        check(bound == ["127.0.0.1:%d" % port], "listeners are %s, not only the gateway" % bound)
        check(not any(":4369" in entry for entry in connections(pid)), "the server contacted EPMD")

        context = ssl.create_default_context(cafile=os.path.join(state, "server", "gateway.crt"))
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        client = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=10)
        client.request("GET", "/runtime/status")
        response = client.getresponse()
        response.read()
        der = client.sock.getpeercert(binary_form=True)
        check(client.sock.version() == "TLSv1.3", "TLS is %s" % client.sock.version())
        check(
            hashlib.sha256(der).hexdigest() == endpoint["certificate_fingerprint"],
            "the served certificate is not the published one",
        )
        check(response.status == 401, "an unauthenticated status request got %s" % response.status)
        client.close()

        index = os.path.join(state, "server", "tama-dex.sqlite3")

        def cassettes():
            if not os.path.exists(index):
                return None
            try:
                with sqlite3.connect("file:%s?mode=ro" % index, uri=True) as db:
                    rows = db.execute("select name, kind, version, file_sha256 from cassettes").fetchall()
            except sqlite3.Error:
                return None
            names = {row[0] for row in rows}
            return rows if {"opsmaru_incus", "macus"} <= names else None

        rows = {row[0]: row for row in wait_for(cassettes, 60, "the cassettes were not indexed")}
        library = manifest["opsmaru_incus"]
        check(
            rows["opsmaru_incus"][1:] == ("imported", library["version"], library["cassette"]["sha256"]),
            "opsmaru_incus cassette row is %s" % (rows["opsmaru_incus"],),
        )
        check(rows["macus"][1] == "local", "macus cassette row is %s" % (rows["macus"],))
        check(server.poll() is None, "the server stopped during the checks")

        credentials = {
            name: digest(os.path.join(state, "server", name))
            for name in ("gateway.crt", "gateway.key", "gateway.json")
        }
        server.send_signal(signal.SIGTERM)
        try:
            status = server.wait(30)
        except subprocess.TimeoutExpired:
            raise Failure("the server did not stop within 30 seconds of SIGTERM")
        check(status == 0, "the server exited with %s after SIGTERM" % status)
        check(swift.poll() is None, "the runtime stand-in stopped with the server")
        check(os.path.exists(os.path.join(state, "runtime.sock")), "runtime.sock is gone")
        check(snapshot(os.path.join(state, "runtime")) == runtime_before, "runtime files changed")
        for name, value in credentials.items():
            check(digest(os.path.join(state, "server", name)) == value, "%s changed" % name)

        print(json.dumps({
            "release": manifest["version"],
            "revision": manifest["revision"],
            "erts": manifest["erts"],
            "opsmaru_incus": library["version"],
            "cassette_sha256": library["cassette"]["sha256"],
            "exqlite_nif_sha256": manifest["exqlite"]["nif_sha256"],
            "listeners": bound,
            "macho_files": len(machos),
            "shutdown_status": status,
        }, indent=2))
        print("release smoke passed: isolated boot, one listener, server-only shutdown")
        ok = True
    finally:
        for process in (server, swift):
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
        if ok and not keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print("kept test root: %s" % root, file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--release", required=True)
    parser.add_argument("--keep", action="store_true")
    arguments = parser.parse_args()
    try:
        run(os.path.abspath(arguments.release), arguments.keep)
    except Failure as failure:
        print("release smoke failed: %s" % failure, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
