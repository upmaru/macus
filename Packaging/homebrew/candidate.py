#!/usr/bin/env python3
"""Generate traceable Homebrew candidates; package mutations always require opt-in."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlparse
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "Packaging/homebrew/Formula/macus.rb.in"
TAP = "upmaru/macus-local"
FORMULA = TAP + "/macus"
SYSTEM_LIBRARIES = ("/usr/lib/", "/System/Library/")
# The two jobs macus start owns, and the label a Homebrew service block would add.
SERVICE_LABELS = ("com.upmaru.macus", "homebrew.mxcl.macus")
LC_ID_DYLIB, LC_SEGMENT_64, LC_CODE_SIGNATURE = 0xD, 0x19, 0x1D


def run(arguments, cwd=None, log=None, timeout=1800):
    environment = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_INSTALL_CLEANUP="1")
    if log:
        log = safe_path(log)
        with log.open("ab") as output:
            process = subprocess.Popen(arguments, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True, env=environment)
            try:
                status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise ValueError(f"Command timed out; retained log: {log}")
        if status:
            raise ValueError(f"Command failed ({status}); retained log: {log}")
        return ""
    return subprocess.run(arguments, cwd=cwd, check=True, capture_output=True,
                          text=True, timeout=timeout, env=environment).stdout.strip()


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def ruby_string(value):
    return json.dumps(value).replace("#{", "\\#{")


def safe_path(path):
    path = Path(os.path.abspath(path))
    for node in (path, *path.parents):
        if node.is_symlink() and node not in (Path("/tmp"), Path("/var")):
            raise ValueError(f"Refusing symlink path: {node}")
    return path


def write_text(path, text):
    path = safe_path(path)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(text)


def checked_sha(value):
    if not re.fullmatch(r"[0-9a-f]{64}", value) or len(set(value)) == 1:
        raise ValueError("Missing, invalid or placeholder SHA-256")
    return value


def render(manifest, bottle_root=None, source_url=None, template=None, release_url=None):
    bottle = ""
    if manifest.get("bottles"):
        lines = ["  bottle do", f"    root_url {ruby_string(bottle_root or manifest['bottle_root'])}"]
        rebuild = manifest.get("bottle_rebuild", 0)
        if type(rebuild) is not int or rebuild < 0:
            raise ValueError("Invalid Homebrew bottle rebuild")
        if rebuild:
            lines.append(f"    rebuild {rebuild}")
        for tag, info in sorted(manifest["bottles"].items()):
            if not re.fullmatch(r"arm64_[a-z0-9_]+", tag):
                raise ValueError("Bottles must use an ARM64 macOS tag")
            cellar = info["cellar"]
            cellar = ":" + cellar if cellar in ("any", "any_skip_relocation") else ruby_string(cellar)
            lines.append(f"    sha256 cellar: {cellar}, {tag}: {ruby_string(checked_sha(info['sha256']))}")
        lines.extend(["  end", ""])
        bottle = "\n".join(lines)
    text = (template or TEMPLATE).read_text()
    release = manifest["server_release"]
    for key, value in {"SOURCE_URL": ruby_string(source_url or manifest["source_url"]),
                       "VERSION": ruby_string(manifest["version"]),
                       "SOURCE_SHA256": ruby_string(checked_sha(manifest["source_sha256"])),
                       "RELEASE_URL": ruby_string(release_url or release["url"]),
                       "RELEASE_SHA256": ruby_string(checked_sha(release["sha256"])),
                       "MACUS_VERSION": ruby_string(manifest["macus_version"]),
                       "SOURCE_COMMIT": ruby_string(manifest["source_commit"]),
                       "OPSMARU_INCUS_VERSION": ruby_string(release["opsmaru_incus"]["version"]),
                       "BOTTLE": bottle}.items():
        text = text.replace("@" + key + "@", value)
    if re.search(r"@[A-Z_]+@", text):
        raise ValueError("The formula template has an unknown placeholder")
    return text


def save(root, manifest):
    write_text(root / "candidate.json", json.dumps(manifest, indent=2) + "\n")
    write_text(root / "tap/Formula/macus.rb", render(manifest, template=root / "formula.rb.in"))


def load(root):
    root = safe_path(root)
    data = json.loads((root / "candidate.json").read_text())
    if data.get("schema_version") != 2 or not re.fullmatch(r"[0-9a-f]{40}", data["source_commit"]):
        raise ValueError("Invalid candidate provenance")
    if not re.fullmatch(r"[0-9A-Za-z.+_-]{1,64}", data["macus_version"]):
        raise ValueError("Invalid Macus package version")
    if not re.fullmatch(r"0\.0\.0-dev\.[0-9]{14}\.[0-9a-f]{12}", data["version"]):
        raise ValueError("Invalid development version")
    if not data["version"].endswith(data["source_commit"][:12]):
        raise ValueError("Candidate version does not identify its source commit")
    template = safe_path(root / "formula.rb.in")
    if digest(template) != checked_sha(data["formula_template_sha256"]):
        raise ValueError("Candidate formula template integrity failed")
    source = root / data["source_file"]
    if source.parent != root or source.is_symlink() or digest(source) != checked_sha(data["source_sha256"]):
        raise ValueError("Candidate source integrity failed")
    release = root / data["server_release"]["file"]
    if (release.parent != root or release.is_symlink()
            or digest(release) != checked_sha(data["server_release"]["sha256"])):
        raise ValueError("Candidate server release integrity failed")
    for info in data.get("bottles", {}).values():
        path = root / info["local_filename"]
        if path.parent != root or path.is_symlink() or digest(path) != checked_sha(info["sha256"]):
            raise ValueError("Candidate bottle integrity failed")
    return root, data


def locked_opsmaru_incus(lock):
    """The locked version and outer (last) checksum, as Macus.Build reads them."""
    for line in lock.splitlines():
        found = re.match(r'\s*"opsmaru_incus": \{:hex, :opsmaru_incus, "([^"]+)", .*"([0-9a-f]{64})"\},?$', line)
        if found:
            return {"version": found.group(1), "checksum": found.group(2)}
    raise ValueError("server/mix.lock does not lock opsmaru_incus from Hex")


def build_release(repo, root, cassette):
    """Assembles and verifies the release with the source installer; returns its directory."""
    arguments = ["sh", "Packaging/install-local.sh", "--prefix", str(root / "server-build")]
    if cassette:
        arguments += ["--cassette", str(Path(cassette).resolve())]
    run(arguments, cwd=repo, log=root / "release.log", timeout=3600)
    return root / "server-build/libexec/macus"


def server_record(release, commit, macus_version, locked):
    """The release's own build record, checked against the commit and its lock."""
    record = json.loads((release / "macus-build.json").read_text())
    if record.get("schema_version") != 1 or (record.get("version"), record.get("revision")) != (macus_version, commit):
        raise ValueError(f"The server release is not Macus {macus_version} ({commit})")
    library = record.get("opsmaru_incus", {})
    if {"version": library.get("version"), "checksum": library.get("checksum")} != locked:
        raise ValueError(f"The server release does not bundle the locked opsmaru_incus {locked['version']}")
    if record.get("distribution") != "none":
        raise ValueError("The server release does not keep distribution off")
    return record


def prepare(output, repo=ROOT, stamp=None, cassette=None):
    if run(["git", "status", "--porcelain"], cwd=repo):
        raise ValueError("Candidate generation requires a clean committed checkout")
    commit = run(["git", "rev-parse", "HEAD"], cwd=repo)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Candidate generation requires an immutable commit")
    root = safe_path(output)
    if root.exists():
        raise ValueError("Refusing to reuse an existing candidate directory")
    root.mkdir(parents=True, mode=0o700)
    stamp = stamp or datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    version = f"0.0.0-dev.{stamp}.{commit[:12]}"
    source = root / f"macus-{version}.tar.gz"
    run(["git", "archive", "--format=tar.gz", f"--prefix=macus-{version}/", "-o", str(source), commit], cwd=repo)
    template_text = run(["git", "show", f"{commit}:Packaging/homebrew/Formula/macus.rb.in"], cwd=repo) + "\n"
    write_text(root / "formula.rb.in", template_text)
    found = re.search(r'^ *version: "([^"]+)",$', run(["git", "show", f"{commit}:server/mix.exs"], cwd=repo), re.M)
    if not found:
        raise ValueError("server/mix.exs records no package version")
    macus_version = found.group(1)
    locked = locked_opsmaru_incus(run(["git", "show", f"{commit}:server/mix.lock"], cwd=repo))
    # The release from this commit, archived as the formula's server-release resource.
    built = build_release(repo, root, cassette)
    record = server_record(built, commit, macus_version, locked)
    release = root / f"macus-server-{version}.tar.gz"
    # No AppleDouble entries: Homebrew's stage turns them back into attributes, not files.
    run(["tar", "--no-mac-metadata", "-czf", str(release), "-s", f",^macus,macus-server-{version},S",
         "-C", str(built.parent), "macus"])
    shutil.rmtree(root / "server-build")
    (root / "tap/Formula").mkdir(parents=True)
    manifest = {"schema_version": 2, "source_commit": commit, "version": version,
                "macus_version": macus_version,
                "source_file": source.name, "source_url": source.as_uri(),
                "source_sha256": digest(source),
                "server_release": {"file": release.name, "url": release.as_uri(), "sha256": digest(release),
                                   "opsmaru_incus": record["opsmaru_incus"], "tama_dex": record.get("tama_dex"),
                                   "exqlite": record.get("exqlite"), "erts": record.get("erts")},
                "bottle_root": root.as_uri(),
                "formula_template_sha256": digest(root / "formula.rb.in"),
                "signing_mode": "ad-hoc-development", "architecture": platform.machine(),
                "host_macos": platform.mac_ver()[0], "deployment_target": "15.0",
                "swift_version": run(["swift", "--version"]), "bottles": {}}
    save(root, manifest)
    run(["git", "init", "-b", "main"], cwd=root / "tap")
    run(["git", "add", "Formula/macus.rb"], cwd=root / "tap")
    run(["git", "-c", "user.name=Macus packaging", "-c", "user.email=packaging@localhost",
         "commit", "--no-gpg-sign", "-m", "Prepare local Macus candidate"], cwd=root / "tap")
    return root, manifest


def require_opt_in(args):
    if not args.opt_in:
        raise ValueError("Homebrew mutations require --opt-in")


def refuse_package_conflict():
    result = subprocess.run(["brew", "list", "--versions", "macus"], capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.strip():
        raise ValueError("Refusing an existing Macus package; use a dedicated package environment")
    executable = shutil.which("macus")
    if executable:
        raise ValueError(f"Refusing an existing macus executable on PATH: {executable}")


def attach_local(root):
    taps = run(["brew", "tap"]).splitlines()
    if TAP in taps:
        location = Path(run(["brew", "--repository", TAP]))
        if run(["git", "remote", "get-url", "origin"], cwd=location) != str(root / "tap"):
            raise ValueError("Refusing an unrelated existing local tap")
    else:
        run(["brew", "tap", TAP, str(root / "tap")], log=root / "build.log")
    run(["brew", "trust", "--formula", FORMULA], log=root / "build.log")
    return Path(run(["brew", "--repository", TAP]))


def embedded_identity(binary):
    """The (MacusVersion, MacusSourceRevision) an executable embeds in its Info.plist."""
    with tempfile.TemporaryDirectory() as directory:
        plist = Path(directory) / "identity.plist"
        run(["/usr/bin/segedit", str(binary), "-extract", "__TEXT", "__info_plist", str(plist)])
        info = plistlib.loads(plist.read_bytes())
    return info.get("MacusVersion"), info.get("MacusSourceRevision")


def verify_package(prefix, manifest, opt=None):
    """The installed pair: the entitled executable and the release, one identity, the recorded library."""
    verify_binary(prefix / "bin/macus")
    identity = (manifest["macus_version"], manifest["source_commit"])
    if embedded_identity(prefix / "bin/macus") != identity:
        raise ValueError("The installed macus does not embed the candidate's Macus identity")
    release = prefix / "libexec/macus"
    record = json.loads((release / "macus-build.json").read_text())
    if (record.get("version"), record.get("revision")) != identity:
        raise ValueError("The installed server release is not the candidate's Macus build")
    expected = manifest["server_release"]["opsmaru_incus"]
    if record.get("opsmaru_incus") != expected or not (release / f"lib/opsmaru_incus-{expected['version']}").is_dir():
        raise ValueError("The installed server release does not bundle the recorded opsmaru_incus")
    launcher = (opt or prefix) / "libexec/macus/bin/macus"
    if run([str(launcher), "version"], cwd=release) != f"macus {manifest['macus_version']}":
        raise ValueError("The installed server release launcher failed")


def release_contents(release, manifest):
    """The full bundled payload the record names: one ERTS, the locked libraries and the pinned cassette."""
    recorded = manifest["server_release"]
    names = sorted(entry.name for entry in release.iterdir())
    erts = [name for name in names if name.startswith("erts-")]
    if erts != [f"erts-{recorded['erts']['version']}"] or not all(
            os.access(release / erts[0] / "bin" / tool, os.X_OK) for tool in ("erl", "beam.smp")):
        raise ValueError("The installed server release does not bundle exactly the recorded ERTS")
    libraries = sorted(entry.name for entry in (release / "lib").iterdir())
    for name in ("opsmaru_incus", "tama_dex", "exqlite"):
        if [entry for entry in libraries if entry.startswith(name + "-")] != [f"{name}-{recorded[name]['version']}"]:
            raise ValueError(f"The installed server release does not bundle exactly the locked {name}")
    cassette = recorded["opsmaru_incus"]["cassette"]
    folder = release / f"lib/macus-{manifest['macus_version']}/priv/cassettes"
    if (sorted(entry.name for entry in folder.iterdir()) != [cassette["file"]]
            or (folder / cassette["file"]).is_symlink() or digest(folder / cassette["file"]) != cassette["sha256"]):
        raise ValueError("The installed server release does not bundle only the pinned cassette")
    if (release / "macus-build.json").stat().st_mode & 0o222:
        raise ValueError("The installed server release build record is writable")
    env = release / f"releases/{manifest['macus_version']}/env.sh"
    if "export RELEASE_DISTRIBUTION=none" not in env.read_text().splitlines():
        raise ValueError("The installed server release does not keep distribution off")


def macho_files(root):
    for directory, _, names in os.walk(root):
        for name in names:
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            with path.open("rb") as handle:
                if handle.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                    yield path


def foreign_links(path):
    """Linked libraries outside the system, excluding the file's own install name."""
    links = [line.strip().split(" (")[0] for line in run(["/usr/bin/otool", "-L", str(path)]).splitlines()[1:]]
    own = run(["/usr/bin/otool", "-D", str(path)]).splitlines()[1:]
    return [link for link in links if link and link not in own and not link.startswith(SYSTEM_LIBRARIES)]


def macho_layout(data):
    """A thin 64-bit Mach-O's load commands and section/link-edit bytes, without its install name
    and code signature, plus that install name."""
    magic, cputype, _, filetype, ncmds, _, flags = struct.unpack_from("<7I", data)
    if magic != 0xFEEDFACF:
        raise ValueError("Not a thin 64-bit Mach-O")
    commands, contents, install_name, signature, linkedit = [], [], None, len(data), None
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<2I", data, offset)
        body = bytearray(data[offset:offset + size])
        offset += size
        if cmd == LC_ID_DYLIB:
            start = struct.unpack_from("<I", body, 8)[0]
            install_name = bytes(body[start:]).split(b"\0")[0].decode()
            continue
        if cmd == LC_CODE_SIGNATURE:
            signature = struct.unpack_from("<I", body, 8)[0]
            continue
        if cmd == LC_SEGMENT_64:
            if bytes(body[8:24]).rstrip(b"\0") == b"__LINKEDIT":
                # Its size grows with the signature; its start and contents must not move.
                linkedit = struct.unpack_from("<Q", body, 40)[0]
                struct.pack_into("<Q", body, 32, 0)
                struct.pack_into("<Q", body, 48, 0)
            for index in range(struct.unpack_from("<I", body, 64)[0]):
                size_, file_offset = struct.unpack_from("<QI", body, 72 + 80 * index + 40)
                kind = struct.unpack_from("<I", body, 72 + 80 * index + 64)[0] & 0xFF
                if file_offset and kind not in (0x1, 0xC, 0x12):  # zero-fill sections have no bytes
                    contents.append(data[file_offset:file_offset + size_])
        commands.append(bytes(body))
    if linkedit is not None:
        contents.append(data[linkedit:signature])
    return (cputype, filetype, flags, commands, contents), install_name


def relinked_by_homebrew(original, installed, expected_name):
    """Homebrew points a bundled dylib's install name at its opt path and signs it again ad hoc.
    That is the only change allowed: code, data, linked libraries and symbols stay the archived bytes."""
    try:
        before, _ = macho_layout(original)
        after, name = macho_layout(installed.read_bytes())
    except (ValueError, struct.error):
        return False
    if name != expected_name or before != after:
        return False
    run(["/usr/bin/codesign", "--verify", "--strict", str(installed)])
    return True


def release_archive(archive):
    """{relative path: entry} for the archived release, under its single top-level folder."""
    entries, top = {}, None
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            parts = Path(member.name).parts
            if not parts or Path(member.name).is_absolute() or ".." in parts or (top and parts[0] != top):
                raise ValueError("Unsafe server release archive entry")
            if parts[-1].startswith("._"):
                raise ValueError(f"The server release archive carries AppleDouble metadata: {member.name}")
            top = parts[0]
            relative = str(Path(*parts[1:])) if len(parts) > 1 else "."
            if member.isdir():
                entries[relative] = ("dir",)
            elif member.issym():
                entries[relative] = ("link", member.linkname)
            elif member.isfile():
                data = bundle.extractfile(member).read()
                entries[relative] = ("file", hashlib.sha256(data).hexdigest(), bool(member.mode & 0o111), data)
            else:
                raise ValueError("Unexpected server release archive entry")
    entries.pop(".", None)
    return entries


def installed_tree(root):
    entries = {}
    for directory, folders, names in os.walk(root):
        for name in folders + names:
            path = Path(directory) / name
            relative = str(path.relative_to(root))
            if path.is_symlink():
                entries[relative] = ("link", os.readlink(path))
            elif path.is_dir():
                entries[relative] = ("dir",)
            else:
                entries[relative] = ("file", digest(path), os.access(path, os.X_OK))
    return entries


def verify_payload(release, archive, stable_release):
    """The installed release is the candidate's archived release, entry for entry. Homebrew may
    prune empty directories and point bundled dylib install names at the stable opt path."""
    archived, installed = release_archive(archive), installed_tree(release)
    parents = {str(Path(name).parent) for name in archived}
    pruned = sorted(name for name, entry in archived.items()
                    if entry[0] == "dir" and name not in parents and name not in installed)
    extra = sorted(set(installed) - set(archived))
    missing = sorted(set(archived) - set(installed) - set(pruned))
    if extra or missing:
        raise ValueError(f"The installed server release differs from its archive: extra {extra[:5]}, missing {missing[:5]}")
    relinked = []
    for name, entry in sorted(archived.items()):
        if name in pruned:
            continue
        found = installed[name]
        if entry[0] != found[0] or (entry[0] == "link" and entry != found):
            raise ValueError(f"The installed server release changed {name}")
        if entry[0] != "file":
            continue
        if entry[2] and not found[2]:
            raise ValueError(f"The installed server release lost the executable bit on {name}")
        if entry[1] != found[1]:
            if not relinked_by_homebrew(entry[3], release / name, str(stable_release / name)):
                raise ValueError(f"The installed server release changed {name}")
            relinked.append(name)
    return {"archive_sha256": digest(archive), "entries": len(archived), "relinked_install_names": relinked,
            "pruned_empty_directories": pruned}


def verify_installation(keg, opt, homebrew_prefix, manifest, root):
    """Full payload, stable opt paths and no added service or runtime dependency; returns the evidence."""
    verify_package(keg, manifest, opt)
    release_contents(keg / "libexec/macus", manifest)
    foreign = {str(path.relative_to(keg)): links for path in macho_files(keg) if (links := foreign_links(path))}
    if foreign:
        raise ValueError(f"Installed Mach-O files link outside the system: {foreign}")
    payload = verify_payload(keg / "libexec/macus", root / manifest["server_release"]["file"],
                             opt / "libexec/macus")
    # macus start writes the opt path into both jobs, so it must keep naming this keg.
    for name in ("bin/macus", "libexec/macus/bin/macus"):
        if (opt / name).resolve() != keg / name or not (keg / name).is_file():
            raise ValueError(f"The stable path {opt / name} does not resolve into the installed keg")
    if (homebrew_prefix / "bin/macus").resolve() != keg / "bin/macus":
        raise ValueError("The linked macus does not resolve into the installed keg")
    receipt = json.loads((keg / "INSTALL_RECEIPT.json").read_text())
    if receipt.get("runtime_dependencies") != []:
        raise ValueError("The installed package depends on other formulae at runtime")
    services = sorted(path.name for path in keg.glob("homebrew.*"))
    if services:
        raise ValueError(f"The installed package declares a Homebrew service: {services}")
    return {"installed_keg": str(keg), "opt_prefix": str(opt), "payload": payload,
            "runtime_dependencies": [], "homebrew_service": False, "system_linked_only": True,
            "receipt": {key: receipt.get(key) for key in ("poured_from_bottle", "built_as_bottle")}}


def installed_prefixes():
    """(keg, opt, Homebrew prefix) for the installed candidate formula."""
    opt = Path(run(["brew", "--prefix", FORMULA]))
    return opt.resolve(strict=True), opt, Path(run(["brew", "--prefix"]))


def keg_processes(*paths):
    lines = run(["/bin/ps", "-axww", "-o", "pid=,command="]).splitlines()
    return [line.strip() for line in lines if any(str(path) in line for path in paths)]


def verify_binary(binary):
    run(["/usr/bin/codesign", "--verify", "--strict", str(binary)])
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(binary)],
                            check=True, capture_output=True, text=True)
    if "com.apple.security.virtualization" not in result.stdout + result.stderr:
        raise ValueError("Installed binary is missing its virtualization entitlement")
    if "serve" not in run([str(binary), "--help"], cwd=binary.parent) or "apple-vz" not in run([str(binary), "capabilities", "--json"], cwd=binary.parent):
        raise ValueError("Installed executable smoke checks failed")


def passive_snapshot():
    """Ordinary runtime/client state and every Macus or Homebrew-service launchd registration."""
    snapshot = []
    for path in (Path.home() / ".tama/incus-mac", Path.home() / ".config/incus"):
        info = path.lstat() if os.path.lexists(path) else None
        snapshot.append((info.st_mode, info.st_size, info.st_mtime_ns) if info else None)
    agents = Path.home() / "Library/LaunchAgents"
    names = sorted(entry.name for entry in agents.iterdir()) if agents.is_dir() else []
    snapshot.append([(name, (agents / name).lstat().st_mtime_ns) for name in names if name.startswith(SERVICE_LABELS)])
    jobs = subprocess.run(["/bin/launchctl", "list"], capture_output=True, text=True, timeout=10).stdout
    snapshot.append(sorted(line.split()[-1] for line in jobs.splitlines()[1:]
                           if line.split() and line.split()[-1].startswith(SERVICE_LABELS)))
    return snapshot


def write_evidence(root, name, manifest, evidence, **fields):
    """Each install path keeps its own report; neither replaces the other."""
    path = safe_path(root / name)
    report = {"schema_version": 3, "source_commit": manifest["source_commit"], "version": manifest["version"],
              "macus_version": manifest["macus_version"], "server_release": manifest["server_release"],
              "formula": FORMULA, **fields, **evidence, "signature_verified": True,
              "virtualization_entitlement": True, "hardware_ran": False,
              "host_macos": platform.mac_ver()[0], "success": True}
    with path.open("x") as output:
        output.write(json.dumps(report, indent=2) + "\n")
    print(path)


def build(args):
    require_opt_in(args)
    root, manifest = load(args.candidate)
    refuse_package_conflict()
    before = passive_snapshot()
    tap = attach_local(root)
    run(["brew", "install", "--build-bottle", FORMULA], log=root / "build.log")
    keg, opt, homebrew_prefix = installed_prefixes()
    receipt = json.loads((keg / "INSTALL_RECEIPT.json").read_text())
    if receipt.get("poured_from_bottle") or not receipt.get("built_as_bottle"):
        raise ValueError("The source build was not built from source as a bottle")
    evidence = verify_installation(keg, opt, homebrew_prefix, manifest, root)
    passive = passive_snapshot() == before and not keg_processes(keg, opt)
    if not passive:
        raise ValueError("The source build changed ordinary runtime/client/service state or left a process running")
    run(["brew", "test", FORMULA], log=root / "build.log")
    # Source-fallback evidence, kept apart from the poured-bottle report.
    write_evidence(root, "source-build-acceptance.json", manifest, evidence, evidence_kind="source-build",
                   built_from_source=True, poured_from_bottle=False, passive_installation=True)
    run(["brew", "bottle", "--json", "--root-url=" + root.as_uri(), FORMULA], cwd=root, log=root / "build.log")
    records = list(root.glob("*.bottle.json"))
    if len(records) != 1:
        raise ValueError("Expected exactly one Homebrew bottle JSON record")
    record = json.loads(records[0].read_text())[FORMULA]
    if record["formula"]["pkg_version"] != manifest["version"]:
        raise ValueError("Bottle version does not match candidate")
    manifest["bottle_rebuild"] = record["bottle"]["rebuild"]
    manifest["bottles"] = {tag: {"filename": info["filename"], "local_filename": info["local_filename"],
                               "sha256": info["sha256"], "cellar": record["bottle"]["cellar"]}
                            for tag, info in record["bottle"]["tags"].items()}
    save(root, manifest)
    load(root)
    for info in manifest["bottles"].values():
        # Homebrew emits a double-hyphen local filename and a single-hyphen URL filename.
        destination = safe_path(root / info["filename"])
        if destination.parent != root:
            raise ValueError("Unsafe bottle URL filename")
        if not destination.exists():
            with destination.open("xb") as output, (root / info["local_filename"]).open("rb") as source:
                shutil.copyfileobj(source, output)
        if digest(destination) != info["sha256"]:
            raise ValueError("Conflicting bottle URL filename")
    write_text(tap / "Formula/macus.rb", render(manifest, template=root / "formula.rb.in"))
    run(["brew", "style", FORMULA], log=root / "style.log")
    run(["brew", "audit", "--strict", FORMULA], log=root / "audit.log")
    print(root / "candidate.json")


def install(args):
    require_opt_in(args)
    root, manifest = load(args.candidate)
    if not manifest["bottles"]:
        raise ValueError("Build a verified bottle before installation acceptance")
    refuse_package_conflict()
    before = passive_snapshot()
    tap = attach_local(root)
    write_text(tap / "Formula/macus.rb", render(manifest, template=root / "formula.rb.in"))
    run(["brew", "install", "--force-bottle", FORMULA], log=root / "install.log")
    keg, opt, _ = installed_prefixes()
    if passive_snapshot() != before or keg_processes(keg, opt):
        raise ValueError("Package installation changed ordinary runtime/client/service state or left a process running")
    verify(root, passive=True)


def verify(root, passive=None, report="package-acceptance.json"):
    root, manifest = load(root)
    keg, opt, homebrew_prefix = installed_prefixes()
    receipt = json.loads((keg / "INSTALL_RECEIPT.json").read_text())
    if not receipt.get("poured_from_bottle") or receipt.get("source", {}).get("tap") != TAP:
        raise ValueError("Installed receipt is not a poured candidate from the expected tap")
    if keg.name != manifest["version"]:
        raise ValueError("Installed package version does not match candidate")
    evidence = verify_installation(keg, opt, homebrew_prefix, manifest, root)
    # passive_installation stays null when verify runs on its own, without a before/after snapshot.
    write_evidence(root, report, manifest, evidence, evidence_kind="poured-bottle",
                   bottles=manifest["bottles"], built_from_source=False, poured_from_bottle=True,
                   passive_installation=passive)


def cleanup(args):
    """Remove only this candidate's package and tap, never an unrelated installation."""
    require_opt_in(args)
    root, manifest = load(args.candidate)
    prefix = Path(run(["brew", "--prefix", FORMULA]))
    if prefix.exists():
        installed = prefix.resolve(strict=True)
        receipt = json.loads((installed / "INSTALL_RECEIPT.json").read_text())
        if installed.name != manifest["version"] or receipt.get("source", {}).get("tap") != TAP:
            raise ValueError("Refusing cleanup of an unrelated installed package")
        run(["brew", "uninstall", FORMULA], log=root / "cleanup.log")
    if TAP in run(["brew", "tap"]).splitlines():
        tap = Path(run(["brew", "--repository", TAP]))
        if run(["git", "remote", "get-url", "origin"], cwd=tap) != str(root / "tap"):
            raise ValueError("Refusing cleanup of an unrelated local tap")
        run(["brew", "untap", TAP], log=root / "cleanup.log")


def export(args):
    root, manifest = load(args.candidate)
    if not manifest["bottles"]:
        raise ValueError("Cannot export an unbottled candidate")
    urls = [(args.source_url, manifest["source_sha256"]),
            (args.release_url, manifest["server_release"]["sha256"])]
    for info in manifest["bottles"].values():
        urls.append((args.bottle_root.rstrip("/") + "/" + info["filename"], info["sha256"]))
    for url, expected in urls:
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.username or parsed.password or manifest["version"] not in parsed.path:
            raise ValueError("Shared formula requires version-specific immutable HTTPS asset URLs")
        with urlopen(url, timeout=60) as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != checked_sha(expected):
            raise ValueError(f"Remote artifact checksum mismatch: {url}")
    destination = safe_path(args.destination)
    if destination.exists():
        raise ValueError("Refusing to replace an existing exported formula")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("x") as output:
        output.write(render(manifest, args.bottle_root, args.source_url, root / "formula.rb.in",
                            args.release_url))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preparing = commands.add_parser("prepare")
    preparing.add_argument("--output", type=Path, required=True)
    preparing.add_argument("--cassette", type=Path,
                           help="the pinned opsmaru_incus cassette, beside its .sha256 (default: downloaded and verified by the release build)")
    for name in ("build", "install", "verify", "export", "cleanup"):
        sub = commands.add_parser(name)
        sub.add_argument("--candidate", type=Path, required=True)
        if name in ("build", "install", "cleanup"):
            sub.add_argument("--opt-in", action="store_true")
        if name == "export":
            sub.add_argument("--source-url", required=True)
            sub.add_argument("--release-url", required=True)
            sub.add_argument("--bottle-root", required=True)
            sub.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        root, _ = prepare(args.output, cassette=args.cassette)
        print(root / "candidate.json")
    elif args.command == "verify":
        # A rerun keeps its own report beside the installation's.
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
        verify(args.candidate, report=f"package-verify-{stamp}.json")
    else:
        globals()[args.command](args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        raise SystemExit(str(error))
