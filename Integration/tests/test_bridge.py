"""Listener regressions run without vsock or a guest VM."""
import errno
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import unittest
from unittest import mock

BRIDGE = Path(__file__).resolve().parents[1] / 'guest' / 'bridge.py'
spec = importlib.util.spec_from_file_location('bridge', BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def test_transient_accept_errors_retry_but_fatal_errors_propagate(self):
        listener = mock.MagicMock()
        listener.__enter__.return_value = listener
        listener.accept.side_effect = [OSError(errno.EINTR, 'interrupted'),
                                       OSError(errno.EMFILE, 'busy'),
                                       OSError(errno.EINVAL, 'fatal')]
        ready = bridge.threading.Event()
        with mock.patch.object(bridge.socket, 'AF_VSOCK', 40, create=True), \
                mock.patch.object(bridge.socket, 'VMADDR_CID_ANY', -1, create=True), \
                mock.patch.object(bridge.socket, 'socket', return_value=listener), \
                mock.patch.object(bridge.time, 'sleep') as sleep:
            with self.assertRaises(OSError):
                bridge.serve(8443, lambda _: None, ready)
        self.assertEqual(listener.accept.call_count, 3)
        sleep.assert_called_once_with(0.1)
        self.assertFalse(ready.is_set())

    def test_health_waits_for_relay_listener_and_advertises_flow_relay(self):
        client = mock.Mock()
        client.recv.return_value = b'GET /health HTTP/1.1\r\n\r\n'
        bridge.relay_ready.clear()
        try:
            with mock.patch.object(bridge, 'incus_health',
                                   side_effect=lambda: {'protocol_version': 1}) as probe:
                bridge.health(client)
                self.assertTrue(client.sendall.call_args.args[0].startswith(b'HTTP/1.1 503'))
                probe.assert_not_called()
                bridge.relay_ready.set()
                bridge.health(client)
                response = client.sendall.call_args.args[0]
                self.assertTrue(response.startswith(b'HTTP/1.1 200'))
                body = json.loads(response.split(b'\r\n\r\n', 1)[1])
                self.assertEqual(body, {'protocol_version': 1, 'flow_relay_version': 1})
        finally:
            bridge.relay_ready.clear()

    def test_flow_relay_uses_the_incus_relay_port(self):
        self.assertEqual(bridge.RELAY_PORT, 8443)

    def test_fatal_listener_exits_even_with_blocked_worker(self):
        # A real subprocess catches executor context-manager shutdown deadlocks.
        script = f'''
import importlib.util, errno, threading
from unittest import mock
spec = importlib.util.spec_from_file_location("bridge", {str(BRIDGE)!r})
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
blocked = threading.Event()
entered = threading.Event()
client = mock.MagicMock()
listener = mock.MagicMock()
listener.__enter__.return_value = listener
def handler(_):
    entered.set()
    blocked.wait()
def accept():
    if not entered.is_set():
        # Submit exactly one indefinitely blocked stream.
        listener.accept.side_effect = fatal
        return client, (2, 123)
def fatal():
    assert entered.wait(2)
    raise OSError(errno.EINVAL, "permanent accept failure")
listener.accept.side_effect = accept
with mock.patch.object(b.socket, "AF_VSOCK", 40, create=True), mock.patch.object(b.socket, "VMADDR_CID_ANY", -1, create=True), mock.patch.object(b.socket, "socket", return_value=listener):
    b.run_or_exit(8443, handler)
'''
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stderr.decode())
        self.assertIn(b'permanent accept failure', result.stderr)

    def test_bind_failure_exits_process(self):
        script = f'''
import importlib.util
spec = importlib.util.spec_from_file_location("bridge", {str(BRIDGE)!r})
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
def fail(*_):
    raise OSError("bind failure")
b.serve = fail
b.run_or_exit(8444, b.health)
'''
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'bind failure', result.stderr)



class HostPeer:
    """Stands in for the Macus host relay on the vsock side of a flow connection."""

    def __init__(self, sock):
        self.sock = sock
        self.sock.settimeout(5)
        self.buffer = b''

    def send(self, kind, payload=b''):
        self.sock.sendall(bridge.frame(kind, payload))

    def credit(self, count):
        self.send(bridge.CREDIT, struct.pack('>I', count))

    def read_frame(self):
        while len(self.buffer) < 5:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buffer += chunk
        kind, length = bridge.HEADER.unpack(self.buffer[:5])
        while len(self.buffer) < 5 + length:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise AssertionError('closed inside a frame')
            self.buffer += chunk
        payload = self.buffer[5:5 + length]
        self.buffer = self.buffer[5 + length:]
        return kind, payload


def read_all(sock):
    data = bytearray()
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return bytes(data)
        data.extend(chunk)


class FlowRelayTests(unittest.TestCase):
    def setUp(self):
        self.host, vsock = socket.socketpair()
        self.incus_peer, incus = socket.socketpair()
        self.incus_peer.settimeout(5)
        self.connection = bridge.FlowConnection(vsock, incus)
        self.thread = threading.Thread(target=self.connection.run, daemon=True)
        self.peer = HostPeer(self.host)
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.connection.abort()
        if self.thread.is_alive():
            self.thread.join(5)
        for sock in (self.host, self.incus_peer, self.connection.vsock, self.connection.incus):
            sock.close()

    def frames_until_end(self):
        data, credits = bytearray(), 0
        while True:
            item = self.peer.read_frame()
            self.assertIsNotNone(item, 'closed before end of stream')
            kind, payload = item
            if kind == bridge.DATA:
                data.extend(payload)
                self.peer.credit(len(payload))
            elif kind == bridge.CREDIT:
                credits += struct.unpack('>I', payload)[0]
            elif kind == bridge.END:
                return bytes(data), credits

    def test_relays_binary_and_half_close_both_ways(self):
        self.thread.start()
        request = bytes([0, 255, 128, 10, 13, 0, 42])
        self.peer.send(bridge.DATA, request)
        self.peer.send(bridge.END)
        self.assertEqual(read_all(self.incus_peer), request)
        response = b'response-after-host-half-close'
        self.incus_peer.sendall(response)
        self.incus_peer.shutdown(socket.SHUT_WR)
        data, _ = self.frames_until_end()
        self.assertEqual(data, response)
        self.host.shutdown(socket.SHUT_RDWR)
        self.thread.join(5)
        self.assertFalse(self.thread.is_alive())
        self.assertFalse(self.connection.aborted)

    def test_credit_follows_delivery_to_incus(self):
        self.thread.start()
        self.peer.send(bridge.DATA, b'x' * 100)
        self.assertEqual(self.incus_peer.recv(100), b'x' * 100)
        kind, payload = self.peer.read_frame()
        self.assertEqual((kind, struct.unpack('>I', payload)[0]), (bridge.CREDIT, 100))

    def test_guest_never_exceeds_the_window_without_credit(self):
        self.thread.start()
        payload = bytes(range(256)) * (3 * bridge.WINDOW // 256)
        writer = threading.Thread(target=lambda: (self.incus_peer.sendall(payload),
                                                  self.incus_peer.shutdown(socket.SHUT_WR)))
        writer.start()
        received = bytearray()
        while len(received) < bridge.WINDOW:
            kind, chunk = self.peer.read_frame()
            self.assertEqual(kind, bridge.DATA)
            received.extend(chunk)
        self.assertEqual(len(received), bridge.WINDOW)
        self.host.settimeout(0.3)
        with self.assertRaises(socket.timeout):
            self.peer.read_frame()
        self.host.settimeout(5)
        self.peer.credit(bridge.WINDOW)
        rest, _ = self.frames_until_end()
        self.assertEqual(bytes(received) + rest, payload)
        writer.join(5)

    def test_window_violation_aborts(self):
        self.incus_peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        self.thread.start()
        for _ in range(bridge.WINDOW // bridge.MAX_PAYLOAD):
            self.peer.send(bridge.DATA, b'a' * bridge.MAX_PAYLOAD)
        self.peer.send(bridge.DATA, b'b')
        self.thread.join(5)
        self.assertTrue(self.connection.aborted)

    def test_protocol_violations_abort(self):
        for bad in (bridge.frame(bridge.END) + bridge.frame(bridge.DATA, b'late'),
                    bridge.frame(9),
                    bridge.frame(bridge.CREDIT, struct.pack('>I', 1)),
                    bridge.HEADER.pack(bridge.DATA, bridge.MAX_PAYLOAD + 1)):
            with self.subTest(bad=bad[:5]):
                host, vsock = socket.socketpair()
                incus_peer, incus = socket.socketpair()
                connection = bridge.FlowConnection(vsock, incus)
                thread = threading.Thread(target=connection.run, daemon=True)
                thread.start()
                host.sendall(bad)
                thread.join(5)
                self.assertFalse(thread.is_alive())
                self.assertTrue(connection.aborted)
                for sock in (host, incus_peer, vsock, incus):
                    sock.close()

    def test_host_close_before_end_aborts_incus_stream(self):
        self.thread.start()
        self.peer.send(bridge.DATA, b'partial')
        self.assertEqual(self.incus_peer.recv(7), b'partial')
        self.host.shutdown(socket.SHUT_RDWR)
        self.thread.join(5)
        self.assertTrue(self.connection.aborted)
        self.assertEqual(read_all(self.incus_peer), b'')


if __name__ == '__main__':
    unittest.main()
