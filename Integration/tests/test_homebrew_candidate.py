"""Packaging guards run without installing packages or booting hardware."""
import argparse
import importlib.util
import json
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
