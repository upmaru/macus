"""Argument handling for the opt-in relay stress script; no runtime is contacted."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest import mock

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


class FakeStalledStream:
    def __init__(self, chunks):
        self.chunks = list(chunks)

    def setsockopt(self, *args):
        pass

    def sendall(self, data):
        pass

    def recv(self, size):
        item = self.chunks.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    def close(self):
        pass


class RelayStressReportTests(unittest.TestCase):
    def stalled_reader(self, stream):
        health = ({'protocol_version': 1, 'flow_relay_version': 1}, 0.01)
        with mock.patch.object(relay_stress, 'STALL_SECONDS', 0), \
                mock.patch.object(relay_stress, 'get', return_value=health), \
                mock.patch.object(relay_stress, 'keep_alive', return_value=({}, 0.01)), \
                mock.patch.object(relay_stress, 'connect', side_effect=[mock.Mock(), stream]):
            return relay_stress.stalled_reader(Path('/nonexistent'))

    def test_drain_timeout_is_reported_as_a_failure(self):
        result = self.stalled_reader(FakeStalledStream([b'HTTP/1.1 200 OK\r\n', socket.timeout()]))
        self.assertFalse(result['passed'])
        self.assertEqual(result['drain_error'], 'TimeoutError')
        self.assertEqual(result['drained_responses'], 1)

    def test_complete_drain_passes(self):
        body = b'HTTP/1.1 200 OK\r\n' * relay_stress.PIPELINED_REQUESTS
        result = self.stalled_reader(FakeStalledStream([body, b'']))
        self.assertTrue(result['passed'])
        self.assertIsNone(result['drain_error'])

    def test_stage_failure_still_writes_a_failed_report(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'report.json'
            idle = {'idle_incus_streams': 80}
            with mock.patch.object(relay_stress, 'idle_streams', return_value=idle), \
                    mock.patch.object(relay_stress, 'stalled_reader',
                                      side_effect=ConnectionResetError()), \
                    contextlib.redirect_stdout(io.StringIO()):
                status = relay_stress.main(['--state-dir', directory, '--report', str(report)])
            written = json.loads(report.read_text())
        self.assertEqual(status, 1)
        self.assertEqual(written['status'], 'failed')
        self.assertEqual(written['error'], {'stage': 'stalled_reader',
                                            'type': 'ConnectionResetError'})
        self.assertEqual(written['idle_incus_streams'], 80)


if __name__ == '__main__':
    unittest.main()
