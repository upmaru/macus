"""Argument handling for the opt-in relay stress script; no runtime is contacted."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'relay-stress.py'
spec = importlib.util.spec_from_file_location('relay_stress', SCRIPT)
relay_stress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay_stress)


class RelayStressArgumentTests(unittest.TestCase):
    def test_requires_explicit_state_and_report(self):
        for argv in (['--report', '/tmp/report.json'], ['--state-dir', '/tmp/state']):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    relay_stress.parse_args(argv)

    def test_export_throughput_is_optional(self):
        args = relay_stress.parse_args(['--state-dir', '/tmp/s', '--report', '/tmp/r.json'])
        self.assertIsNone(args.export_image)
        args = relay_stress.parse_args(['--state-dir', '/tmp/s', '--report', '/tmp/r.json',
                                        '--export-image', 'abc123'])
        self.assertEqual(args.export_image, 'abc123')

    def test_stalled_reader_outlasts_the_flow_window(self):
        # 400 pipelined /1.0 responses (~20 KiB each) far exceed one 256 KiB window.
        self.assertGreater(relay_stress.PIPELINED_REQUESTS * 16384, 4 * 262144)
        self.assertGreaterEqual(relay_stress.STALL_SECONDS, 10)


if __name__ == '__main__':
    unittest.main()
