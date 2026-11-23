"""Only an upgrade seed may carry a storage adoption record."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare-appliance.py'
ADOPT_PATH = '  - path: /etc/tama-storage/adopt\n'


class PrepareApplianceAdoptionTests(unittest.TestCase):
    def prepare(self, directory, *extra):
        root = Path(directory) / 'root.raw'
        if not root.exists():
            root.write_bytes(b'\0' * 4096)
        output = Path(directory) / 'out'
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--root-disk', str(root), '--output', str(output), *extra],
            text=True, capture_output=True)
        user_data = output / 'seed/user-data'
        return result, user_data.read_text() if user_data.exists() else ''

    def test_creation_seed_has_no_adoption_record(self):
        with tempfile.TemporaryDirectory() as directory:
            result, user_data = self.prepare(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('  - path: /etc/macus-guest\n', user_data)
            self.assertNotIn(ADOPT_PATH, user_data)
            self.assertNotIn('pool_guid=', user_data)

    def test_upgrade_seed_names_the_pool_and_a_later_creation_seed_drops_it(self):
        with tempfile.TemporaryDirectory() as directory:
            result, user_data = self.prepare(directory, '--adopt-pool-guid', '1234567890123456789')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                ADOPT_PATH + '    permissions: "0600"\n    content: |\n'
                '      pool_guid=1234567890123456789\n      layout=zfs-v1\n', user_data)
            # Reusing the output directory for a creation seed must not keep the record.
            result, user_data = self.prepare(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(ADOPT_PATH, user_data)

    def test_invalid_guid_is_refused_before_writing(self):
        for guid in ('', 'abc', '12 3', '1' * 21, '-1'):
            with self.subTest(guid=guid), tempfile.TemporaryDirectory() as directory:
                result, user_data = self.prepare(directory, f'--adopt-pool-guid={guid}')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('numeric pool GUID', result.stderr)
                self.assertEqual(user_data, '')
                self.assertFalse((Path(directory) / 'out').exists())


if __name__ == '__main__':
    unittest.main()
