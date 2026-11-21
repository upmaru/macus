"""Packaging guards run without installing packages or booting hardware."""
import argparse
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[2] / "Packaging/homebrew/candidate.py"
SPEC = importlib.util.spec_from_file_location("candidate", FILE)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)

LOCK = ('%{\n  "opsmaru_incus": {:hex, :opsmaru_incus, "0.2.4", "' + "1" * 64 + '", [:mix], '
        '[{:mint, "~> 1.6", [hex: :mint, repo: "hexpm", optional: false]}], "hexpm", "' + "2" * 64 + '"},\n}\n')


class CandidateTests(unittest.TestCase):
    def repo(self, root):
        repo = root / "source"
        repo.mkdir()
        for arguments in (["init", "-b", "main"], ["config", "user.name", "Fixture"],
                          ["config", "user.email", "fixture@localhost"]):
            candidate.run(["git", *arguments], cwd=repo)
        (repo / "Package.swift").write_text("// fixture\n")
        (repo / "server").mkdir()
        (repo / "server/mix.exs").write_text('  def project do\n    [\n      app: :macus,\n      version: "0.1.0",\n')
        (repo / "server/mix.lock").write_text(LOCK)
        template = repo / "Packaging/homebrew/Formula/macus.rb.in"
        template.parent.mkdir(parents=True)
        template.write_text(candidate.TEMPLATE.read_text())
        candidate.run(["git", "add", "."], cwd=repo)
        candidate.run(["git", "commit", "--no-gpg-sign", "-m", "Fixture"], cwd=repo)
        return repo

    def fake_release(self, revision=None, version="0.1.0", library="0.2.4"):
        """Stands in for the source installer's release build."""
        def build(repo, root, cassette):
            commit = candidate.run(["git", "rev-parse", "HEAD"], cwd=repo)
            release = root / "server-build/libexec/macus"
            (release / f"lib/opsmaru_incus-{library}").mkdir(parents=True)
            (release / "bin").mkdir()
            (release / "bin/macus").write_text("#!/bin/sh\necho macus 0.1.0\n")
            (release / "macus-build.json").write_text(json.dumps({
                "schema_version": 1, "version": version, "revision": revision or commit,
                "opsmaru_incus": {"version": library, "checksum": "2" * 64,
                                  "cassette": {"file": f"opsmaru_incus-{library}.tama-cassette",
                                               "sha256": "3" * 64}},
                "erts": {"version": "15.2.7.12", "target": "aarch64-apple-darwin"},
                "distribution": "none"}))
            return release
        return build

    def prepared(self, root, release=None):
        with patch.object(candidate, "run", wraps=candidate.run) as command, \
                patch.object(candidate, "build_release", release or self.fake_release()):
            def execute(arguments, **kwargs):
                if arguments == ["swift", "--version"]:
                    return "Swift 6.4 fixture"
                return command._mock_wraps(arguments, **kwargs)
            command.side_effect = execute
            return candidate.prepare(root / "output", repo=self.repo(root), stamp="20261008000000")

    def test_clean_provenance_and_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            self.assertEqual(candidate.load(root)[1], data)
            self.assertIn(data["source_commit"][:12], data["version"])
            self.assertNotIn("@SOURCE", (root / "tap/Formula/macus.rb").read_text())
            (root / data["source_file"]).write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError, "integrity"):
                candidate.load(root)

    def test_the_server_release_is_recorded_and_rendered_with_one_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            release = data["server_release"]
            archive = root / release["file"]
            self.assertEqual(release["sha256"], candidate.digest(archive))
            self.assertEqual(data["macus_version"], "0.1.0")
            # The library is recorded by its own version and checksum, not the Macus commit.
            self.assertEqual(release["opsmaru_incus"]["version"], "0.2.4")
            self.assertEqual(release["opsmaru_incus"]["checksum"], "2" * 64)
            self.assertFalse((root / "server-build").exists())
            names = candidate.run(["tar", "-tzf", str(archive)]).splitlines()
            self.assertIn(f"macus-server-{data['version']}/macus-build.json", names)
            formula = (root / "tap/Formula/macus.rb").read_text()
            self.assertNotRegex(formula, r"@[A-Z_]+@")
            for value in (release["url"], release["sha256"], data["source_commit"], '"0.1.0"', '"0.2.4"'):
                self.assertIn(value, formula)
            archive.write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError, "server release integrity"):
                candidate.load(root)

    def test_a_release_from_another_build_or_library_is_refused(self):
        cases = ({"revision": "f" * 40}, {"version": "9.9.9"}, {"library": "0.2.3"})
        for case in cases:
            with tempfile.TemporaryDirectory() as directory, self.subTest(case=case):
                with self.assertRaisesRegex(ValueError, "not Macus|locked opsmaru_incus"):
                    self.prepared(Path(directory), release=self.fake_release(**case))
                self.assertFalse((Path(directory) / "output/candidate.json").exists())

    def test_an_unknown_template_placeholder_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            template = root / "other.rb.in"
            template.write_text(candidate.TEMPLATE.read_text() + "# @UNFILLED@\n")
            with self.assertRaisesRegex(ValueError, "unknown placeholder"):
                candidate.render(data, template=template)

    def test_the_installed_pair_must_match_the_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            prefix = Path(directory) / "keg"
            release = prefix / "libexec/macus"
            (release / "lib/opsmaru_incus-0.2.4").mkdir(parents=True)
            record = {"schema_version": 1, "version": "0.1.0", "revision": data["source_commit"],
                      "opsmaru_incus": data["server_release"]["opsmaru_incus"]}
            (release / "macus-build.json").write_text(json.dumps(record))
            identity = ("0.1.0", data["source_commit"])

            def check(embedded=identity, launcher="macus 0.1.0"):
                with patch.object(candidate, "verify_binary"), \
                        patch.object(candidate, "embedded_identity", return_value=embedded), \
                        patch.object(candidate, "run", return_value=launcher):
                    candidate.verify_package(prefix, data)

            check()
            with self.assertRaisesRegex(ValueError, "embed"):
                check(embedded=("0.1.0", "f" * 40))
            with self.assertRaisesRegex(ValueError, "launcher"):
                check(launcher="")
            for change in ({"revision": "f" * 40}, {"opsmaru_incus": {"version": "0.2.4", "checksum": "4" * 64}}):
                (release / "macus-build.json").write_text(json.dumps({**record, **change}))
                with self.assertRaisesRegex(ValueError, "server release"):
                    check()

    def dylib(self, folder, name="libfixture.dylib"):
        """A real signed dylib whose install name is a build path, like exqlite's NIF."""
        source = folder / "fixture.c"
        source.write_text("int fixture(void) { return 42; }\n")
        path = folder / name
        candidate.run(["/usr/bin/xcrun", "clang", "-dynamiclib", "-install_name", f"/build/{name}",
                       "-o", str(path), str(source)])
        return path

    def relink(self, path, name):
        """What Homebrew does to a bundled dylib: a new install name, signed again ad hoc."""
        candidate.run(["/usr/bin/xcrun", "install_name_tool", "-id", name, str(path)])
        candidate.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)])

    def test_only_an_opt_install_name_and_new_signature_may_differ(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            original = self.dylib(folder).read_bytes()
            installed = folder / "installed.dylib"
            installed.write_bytes(original)
            self.relink(installed, "/brew/opt/macus/libexec/macus/lib/libfixture.dylib")
            self.assertNotEqual(installed.read_bytes(), original)
            self.assertTrue(candidate.relinked_by_homebrew(
                original, installed, "/brew/opt/macus/libexec/macus/lib/libfixture.dylib"))
            # Another install name, a changed code byte, or a non-Mach-O file is not a relink.
            self.assertFalse(candidate.relinked_by_homebrew(original, installed, "/elsewhere/libfixture.dylib"))
            layout = candidate.macho_layout(original)[0]
            code = next(chunk for chunk in layout[4] if chunk)
            start = original.index(code)
            tampered = bytearray(original)
            tampered[start] ^= 0xFF
            self.assertFalse(candidate.relinked_by_homebrew(
                bytes(tampered), installed, "/brew/opt/macus/libexec/macus/lib/libfixture.dylib"))
            self.assertFalse(candidate.relinked_by_homebrew(b"text", installed, "/brew/opt/macus/libexec/macus/lib/libfixture.dylib"))

    def release_tree(self, folder):
        release = folder / "release"
        (release / "bin").mkdir(parents=True)
        (release / "bin/macus").write_text("#!/bin/sh\n")
        (release / "bin/macus").chmod(0o755)
        (release / "releases/0.1.0").mkdir(parents=True)
        (release / "releases/0.1.0/env.sh").write_text("export RELEASE_DISTRIBUTION=none\n")
        (release / "lib/empty").mkdir(parents=True)
        (release / "lib/nif").mkdir()
        self.dylib(release / "lib/nif", "nif.so")
        (release / "lib/nif/fixture.c").unlink()
        (release / "current").symlink_to("releases/0.1.0")
        archive = folder / "macus-server.tar.gz"
        candidate.run(["tar", "--no-mac-metadata", "-czf", str(archive), "-s", ",^release,macus-server-fixture,S",
                       "-C", str(folder), "release"])
        return release, archive

    def test_the_installed_release_must_be_its_archive(self):
        stable = Path("/brew/opt/macus/libexec/macus")
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            release, archive = self.release_tree(folder)
            payload = candidate.verify_payload(release, archive, stable)
            self.assertEqual((payload["relinked_install_names"], payload["pruned_empty_directories"]), ([], []))
            # Homebrew's own changes: an opt install name and a pruned empty directory.
            self.relink(release / "lib/nif/nif.so", str(stable / "lib/nif/nif.so"))
            (release / "lib/empty").rmdir()
            payload = candidate.verify_payload(release, archive, stable)
            self.assertEqual(payload["relinked_install_names"], ["lib/nif/nif.so"])
            self.assertEqual(payload["pruned_empty_directories"], ["lib/empty"])
            self.assertEqual(payload["archive_sha256"], candidate.digest(archive))

        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            release, _ = self.release_tree(folder)
            metadata = folder / "metadata.tar.gz"
            candidate.run(["tar", "--mac-metadata", "-czf", str(metadata), "-C", str(folder), "release"])
            candidate.run(["/usr/bin/xattr", "-w", "org.fixture", "1", str(release / "bin/macus")])
            candidate.run(["tar", "--mac-metadata", "-czf", str(metadata), "-C", str(folder), "release"])
            with self.assertRaisesRegex(ValueError, "AppleDouble"):
                candidate.verify_payload(release, metadata, stable)

        changes = {
            "extra": lambda release: (release / "lib/extra.beam").write_text("x"),
            "missing": lambda release: (release / "releases/0.1.0/env.sh").unlink(),
            "changed": lambda release: (release / "releases/0.1.0/env.sh").write_text("export RELEASE_DISTRIBUTION=sname\n"),
            "executable": lambda release: (release / "bin/macus").chmod(0o644),
            "link": lambda release: ((release / "current").unlink(), (release / "current").symlink_to("bin")),
            "relinked elsewhere": lambda release: self.relink(release / "lib/nif/nif.so", "/elsewhere/nif.so"),
        }
        for label, change in changes.items():
            with tempfile.TemporaryDirectory() as directory, self.subTest(change=label):
                release, archive = self.release_tree(Path(directory))
                change(release)
                with self.assertRaisesRegex(ValueError, "differs from its archive|changed|executable bit"):
                    candidate.verify_payload(release, archive, stable)

    def bundled(self, folder):
        """A release laid out with the payload the candidate records."""
        release = folder / "libexec/macus"
        for name in ("erts-15.2.7.12/bin", "lib/opsmaru_incus-0.2.4", "lib/tama_dex-0.1.0",
                     "lib/exqlite-0.43.0", "lib/macus-0.1.0/priv/cassettes", "releases/0.1.0"):
            (release / name).mkdir(parents=True)
        for tool in ("erl", "beam.smp"):
            (release / "erts-15.2.7.12/bin" / tool).write_text("")
            (release / "erts-15.2.7.12/bin" / tool).chmod(0o755)
        cassette = release / "lib/macus-0.1.0/priv/cassettes/opsmaru_incus-0.2.4.tama-cassette"
        cassette.write_bytes(b"cassette")
        (release / "releases/0.1.0/env.sh").write_text("#!/bin/sh\nexport RELEASE_DISTRIBUTION=none\n")
        (release / "macus-build.json").write_text("{}")
        (release / "macus-build.json").chmod(0o444)
        manifest = {"macus_version": "0.1.0", "server_release": {
            "erts": {"version": "15.2.7.12"}, "tama_dex": {"version": "0.1.0"}, "exqlite": {"version": "0.43.0"},
            "opsmaru_incus": {"version": "0.2.4", "cassette": {"file": cassette.name, "sha256": candidate.digest(cassette)}}}}
        return release, manifest

    def test_the_full_recorded_payload_is_installed(self):
        with tempfile.TemporaryDirectory() as directory:
            release, manifest = self.bundled(Path(directory))
            candidate.release_contents(release, manifest)
        changes = {
            "ERTS": lambda release: (release / "erts-15.2.7.11").mkdir(),
            "launcher": lambda release: (release / "erts-15.2.7.12/bin/beam.smp").chmod(0o644),
            "library": lambda release: (release / "lib/tama_dex-0.0.9").mkdir(),
            "cassette": lambda release: (release / "lib/macus-0.1.0/priv/cassettes/other.tama-cassette").write_text(""),
            "pin": lambda release: (release / "lib/macus-0.1.0/priv/cassettes/opsmaru_incus-0.2.4.tama-cassette").write_text("other"),
            "record": lambda release: (release / "macus-build.json").chmod(0o644),
            "distribution": lambda release: (release / "releases/0.1.0/env.sh").write_text("#!/bin/sh\n"),
        }
        for label, change in changes.items():
            with tempfile.TemporaryDirectory() as directory, self.subTest(change=label):
                release, manifest = self.bundled(Path(directory))
                change(release)
                with self.assertRaisesRegex(ValueError, "server release"):
                    candidate.release_contents(release, manifest)

    def homebrew(self, folder, version="0.0.0-dev.fixture"):
        """A Homebrew prefix with the keg, its opt link and its linked executable."""
        brew = folder / "brew"
        keg = brew / "Cellar/macus" / version
        (keg / "bin").mkdir(parents=True)
        (keg / "bin/macus").write_text("")
        (keg / "libexec/macus/bin").mkdir(parents=True)
        (keg / "libexec/macus/bin/macus").write_text("")
        (keg / "INSTALL_RECEIPT.json").write_text(json.dumps({"runtime_dependencies": [], "poured_from_bottle": True}))
        (brew / "opt").mkdir()
        (brew / "opt/macus").symlink_to(f"../Cellar/macus/{version}")
        (brew / "bin").mkdir()
        (brew / "bin/macus").symlink_to(f"../Cellar/macus/{version}/bin/macus")
        return keg.resolve(), brew / "opt/macus", brew

    def test_stable_opt_paths_and_no_added_service_or_dependency(self):
        def check(keg, opt, brew):
            with patch.object(candidate, "verify_package") as package, \
                    patch.object(candidate, "release_contents"), \
                    patch.object(candidate, "macho_files", return_value=[]), \
                    patch.object(candidate, "verify_payload", return_value={"entries": 1}) as payload:
                evidence = candidate.verify_installation(keg, opt, brew, {"server_release": {"file": "r.tar.gz"}}, Path("/c"))
            # The launcher is run through the opt path both jobs record.
            self.assertEqual(package.call_args.args[2], opt)
            self.assertEqual(payload.call_args.args[2], opt / "libexec/macus")
            return evidence

        with tempfile.TemporaryDirectory() as directory:
            keg, opt, brew = self.homebrew(Path(directory))
            evidence = check(keg, opt, brew)
            self.assertEqual((evidence["opt_prefix"], evidence["runtime_dependencies"], evidence["homebrew_service"]),
                             (str(opt), [], False))
            self.assertTrue(evidence["receipt"]["poured_from_bottle"])

        def stale_opt(keg, opt, brew):
            (brew / "Cellar/macus/old/bin").mkdir(parents=True)
            opt.unlink()
            opt.symlink_to("../Cellar/macus/old")

        changes = {
            "opt": (stale_opt, "stable path"),
            "linked": (lambda keg, opt, brew: ((brew / "bin/macus").unlink(), (brew / "bin/macus").write_text("")),
                       "linked macus"),
            "dependency": (lambda keg, opt, brew: (keg / "INSTALL_RECEIPT.json").write_text(
                json.dumps({"runtime_dependencies": [{"full_name": "erlang"}]})), "other formulae"),
            "service": (lambda keg, opt, brew: (keg / "homebrew.mxcl.macus.plist").write_text(""), "Homebrew service"),
        }
        for label, (change, message) in changes.items():
            with tempfile.TemporaryDirectory() as directory, self.subTest(change=label):
                keg, opt, brew = self.homebrew(Path(directory))
                change(keg, opt, brew)
                with self.assertRaisesRegex((ValueError, OSError), message):
                    check(keg, opt, brew)

    def test_passivity_covers_both_jobs_and_a_homebrew_service(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"HOME": directory}):
            agents = Path(directory) / "Library/LaunchAgents"
            agents.mkdir(parents=True)
            jobs = ["PID\tStatus\tLabel", "-\t0\tcom.apple.fixture"]

            def snapshot():
                listing = subprocess.CompletedProcess([], 0, "\n".join(jobs) + "\n", "")
                with patch.object(candidate.subprocess, "run", return_value=listing):
                    return candidate.passive_snapshot()

            before = snapshot()
            (agents / "com.example.other.plist").write_text("")
            self.assertEqual(snapshot(), before)
            for name in ("com.upmaru.macus.server.plist", "homebrew.mxcl.macus.plist"):
                (agents / name).write_text("")
                self.assertNotEqual(snapshot(), before)
                (agents / name).unlink()
            jobs.append("123\t0\tcom.upmaru.macus.server")
            self.assertNotEqual(snapshot(), before)

    def test_source_and_bottle_evidence_are_kept_apart(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            evidence = {"installed_keg": "/brew/Cellar/macus/x", "payload": {"entries": 1}}
            stack = contextlib.ExitStack()
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            self.addCleanup(stack.close)
            candidate.write_evidence(root, "source-build-acceptance.json", data, evidence,
                                     evidence_kind="source-build", poured_from_bottle=False)
            candidate.write_evidence(root, "package-acceptance.json", data, evidence,
                                     evidence_kind="poured-bottle", poured_from_bottle=True)
            source = json.loads((root / "source-build-acceptance.json").read_text())
            poured = json.loads((root / "package-acceptance.json").read_text())
            self.assertEqual((source["evidence_kind"], source["poured_from_bottle"]), ("source-build", False))
            self.assertEqual((poured["evidence_kind"], poured["poured_from_bottle"]), ("poured-bottle", True))
            self.assertFalse(source["hardware_ran"])
            with self.assertRaises(FileExistsError):
                candidate.write_evidence(root, "source-build-acceptance.json", data, evidence, evidence_kind="again")
            self.assertEqual(json.loads((root / "source-build-acceptance.json").read_text()), source)

    def test_the_formula_adds_no_service_hook_or_toolchain(self):
        """Installation stays passive: macus start owns the only two jobs."""
        template = candidate.TEMPLATE.read_text()
        for forbidden in ("service do", "post_install", "launchctl", "plist_options",
                          'depends_on "erlang"', 'depends_on "elixir"', 'depends_on "openssl'):
            self.assertNotIn(forbidden, template)

    def test_dirty_source_and_existing_output_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = self.repo(root)
            (repo / "uncommitted").write_text("work")
            with self.assertRaisesRegex(ValueError, "clean committed"):
                candidate.prepare(root / "output", repo=repo)
            self.assertFalse((root / "output").exists())
            (repo / "uncommitted").unlink()
            (root / "output").mkdir()
            with self.assertRaisesRegex(ValueError, "reuse"):
                candidate.prepare(root / "output", repo=repo)

    def test_symlink_output_and_artifact_traversal_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "alias").symlink_to(folder, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                candidate.safe_path(folder / "alias/output")
            root, data = self.prepared(folder)
            data["source_file"] = "../outside.tar.gz"
            (root / "candidate.json").write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "integrity"):
                candidate.load(root)

    def test_mutations_require_opt_in_before_executing(self):
        for action in (candidate.build, candidate.install, candidate.cleanup):
            with patch.object(candidate, "run") as command:
                with self.assertRaisesRegex(ValueError, "opt-in"):
                    action(argparse.Namespace(opt_in=False, candidate=Path("/missing")))
                command.assert_not_called()

    def test_conflict_does_not_replace_package(self):
        result = subprocess.CompletedProcess([], 0, "macus 0.1\n", "")
        with patch.object(candidate.subprocess, "run", return_value=result) as command:
            with self.assertRaisesRegex(ValueError, "existing Macus"):
                candidate.refuse_package_conflict()
            self.assertEqual(command.call_count, 1)

    def test_cleanup_refuses_foreign_receipt_without_uninstall(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            prefix = root / data['version']
            prefix.mkdir()
            (prefix / 'INSTALL_RECEIPT.json').write_text(json.dumps({'source': {'tap': 'other/tap'}}))
            with patch.object(candidate, 'run', return_value=str(prefix)) as command:
                with self.assertRaisesRegex(ValueError, 'unrelated installed'):
                    candidate.cleanup(argparse.Namespace(candidate=root, opt_in=True))
                self.assertEqual(command.call_args_list, [unittest.mock.call(['brew', '--prefix', candidate.FORMULA])])
            self.assertTrue(prefix.exists())

    def test_real_digests_arm64_tags_and_ruby_interpolation(self):
        for value in ("", "0" * 64, "not-a-digest"):
            with self.assertRaises(ValueError):
                candidate.checked_sha(value)
        self.assertIn("\\#{", candidate.ruby_string('#{raise "injected"}'))
        manifest = {"source_url": "file:///fixture.tar.gz", "version": "fixture",
                    "source_sha256": "ab" * 32, "bottle_root": "file:///fixture",
                    "bottles": {"all": {"cellar": "any", "sha256": "cd" * 32}}}
        with self.assertRaisesRegex(ValueError, "ARM64"):
            candidate.render(manifest)

    def test_export_refuses_local_urls_before_network_or_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            bottle = root / "macus.bottle.tar.gz"
            bottle.write_bytes(b"fixture-bottle")
            data["bottles"] = {"arm64_fixture": {"filename": bottle.name,
                              "local_filename": bottle.name, "sha256": candidate.digest(bottle), "cellar": "any"}}
            candidate.save(root, data)
            destination = root / "exported.rb"
            args = argparse.Namespace(candidate=root, source_url=data["source_url"],
                                      release_url=data["server_release"]["url"],
                                      bottle_root=root.as_uri(), destination=destination)
            with patch.object(candidate, "urlopen") as network:
                with self.assertRaisesRegex(ValueError, "immutable HTTPS"):
                    candidate.export(args)
                network.assert_not_called()
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
