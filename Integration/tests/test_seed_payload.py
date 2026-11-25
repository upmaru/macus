"""Both seed writers deliver exactly the guest files the payload revision covers."""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load_sync():
    spec = importlib.util.spec_from_file_location(
        "sync_guest_payload", ROOT / "Integration/scripts/sync-guest-payload.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def python_entries():
    text = (ROOT / "Integration/scripts/prepare-appliance.py").read_text()
    block = text[text.index("entries = ["):text.index("]", text.index("entries = ["))]
    return re.findall(r"\('([^']+)', '([^']+)', '([0-7]+)'\)", block)


def swift_entries():
    text = (ROOT / "Sources/Macus/Bootstrap/SeedPreparation.swift").read_text()
    return re.findall(r'\("([^"]+)", "(/[^"]+)", "([0-7]+)"\)', text)


class SeedPayloadTests(unittest.TestCase):
    def test_dev_seed_delivers_every_revisioned_file(self):
        files = set(load_sync().FILES)
        self.assertEqual({name for name, _, _ in python_entries()}, files)

    def test_both_seed_writers_agree(self):
        swift = swift_entries()
        self.assertEqual({name for name, _, _ in swift}, set(load_sync().FILES))
        self.assertEqual(sorted(python_entries()), sorted(swift))


if __name__ == "__main__":
    unittest.main()
