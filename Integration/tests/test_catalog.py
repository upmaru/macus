import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_catalog", ROOT / "Integration/scripts/check-catalog.py")
CATALOG = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CATALOG)
LTS = ROOT / "Integration/catalog/alpine-3.24.2.json"


class CatalogTests(unittest.TestCase):
    def test_shipped_lts_matches_swift(self):
        entry = CATALOG.load_catalog([LTS])
        self.assertEqual(entry["channel"], "lts")
        self.assertEqual(CATALOG.SWIFT.read_text().split(CATALOG.MARKER)[1], CATALOG.render(entry))

    def test_invalid_release_pins_are_rejected(self):
        entry = CATALOG.load_catalog([LTS])
        url = entry["archive_url"]
        invalid = [
            ("archive_url", url.replace("upmaru/", "another-owner/")),
            ("archive_url", url.replace(f'/{entry["id"]}/', "/wrong-tag/")),
            ("image_format", 2),
            ("image_format", True),
            ("raw_sha256", "0" * 64),
            ("qualified_packages", dict(entry["qualified_packages"], incus="7.0.1")),
        ]
        for field, value in invalid:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                CATALOG.validate(dict(entry, **{field: value}))

    def test_duplicate_channel_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate catalog channel"):
            CATALOG.load_catalog([LTS, LTS])
