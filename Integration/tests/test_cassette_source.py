"""Only the release build obtains the opsmaru_incus cassette; installed components never fetch it."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Everything that ships in the installed package or runs at startup.
INSTALLED = ("server/lib", "server/config", "server/rel", "Sources/Macus")
FETCHING = re.compile(r"releases/download|release download|attestation verify|api\.github\.com|objects\.githubusercontent")
# The appliance image is a different, separately pinned download; only cassette fetching is ruled out.
CASSETTE = re.compile(r"opsmaru-incus|opsmaru_incus-|tama-cassette")


class CassetteSourceTests(unittest.TestCase):
    def test_installed_components_never_fetch_the_cassette(self):
        found = []
        for folder in INSTALLED:
            for path in sorted((ROOT / folder).rglob("*")):
                if not path.is_file() or path.suffix not in (".ex", ".exs", ".eex", ".swift", ".sh"):
                    continue
                text = path.read_text(errors="replace")
                if not CASSETTE.search(text):
                    continue
                for number, line in enumerate(text.splitlines(), 1):
                    if FETCHING.search(line):
                        found.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(found, [])

    def test_the_release_build_fetches_only_the_locked_version_from_opsmaru_incus(self):
        installer = (ROOT / "Packaging/install-local.sh").read_text()
        self.assertIn("cassette_repo=upmaru/opsmaru-incus", installer)
        self.assertIn('gh release download "v$locked" --repo "$cassette_repo"', installer)
        self.assertIn('gh attestation verify "$cassette" --repo "$cassette_repo"', installer)
        # The pin passed to the build is the verified sidecar's hash.
        self.assertIn('MACUS_CASSETTE_SHA256="$pin" MACUS_CASSETTE_PATH="$cassette"', installer)


if __name__ == "__main__":
    unittest.main()
