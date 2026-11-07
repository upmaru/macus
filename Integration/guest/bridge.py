#!/usr/bin/python3
"""Host-CID-only vsock streams; no workload API translation or command endpoint."""
import collections
import concurrent.futures
import http.client
import json
import os
import errno
import struct
import time
import traceback
import socket
import threading

INCUS_SOCKET = '/var/lib/incus/unix.socket'
relay_ready = threading.Event()
flow_ready = threading.Event()

# Flow-controlled relay (vsock port 8445). Virtualization.framework services every vsock
# connection on one serial queue that blocks writing into a full host descriptor, so the
# host must always drain each connection. Credit bounds what either side may have in
# flight: a sender has at most WINDOW unacknowledged payload bytes, and a receiver grants
# credit only after writing bytes to its local peer.
FLOW_PORT = 8445
FLOW_VERSION = 1
WINDOW = 262144
MAX_PAYLOAD = 65536
CREDIT_THRESHOLD = WINDOW // 4
DATA, CREDIT, END = 1, 2, 3
HEADER = struct.Struct('>BI')


def host_peer(peer):
    return peer[0] == 2


def incus_health():
    connection = http.client.HTTPConnection('localhost', timeout=2)
    connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.sock.settimeout(2)
    connection.sock.connect(INCUS_SOCKET)
    try:
        connection.request('GET', '/internal/ready')
        ready = connection.getresponse()
        ready.read(1048576)
        if ready.status != 200:
            raise RuntimeError('Incus startup tasks have not completed')
        connection.request('GET', '/1.0')
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError('Incus is unavailable')
        metadata = json.loads(response.read(1048576))['metadata']
        return {
            'protocol_version': 1,
            'incus_version': metadata['environment']['server_version'],
            'api_extensions': metadata['api_extensions'],
            'kvm': os.access('/dev/kvm', os.R_OK | os.W_OK),
        }
    finally:
        connection.close()


def relay(client):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as incus:
        incus.connect(INCUS_SOCKET)
        # Each direction handles partial writes/backpressure in sendall; no HTTP parsing.
        def pump(source, target):
            try:
                while True:
                    data = source.recv(65536)
                    if not data:
                        target.shutdown(socket.SHUT_WR)
                        return
                    target.sendall(data)
            except OSError:
                for stream in (source, target):
                    try:
                        stream.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        thread = threading.Thread(target=pump, args=(client, incus))
        thread.start()
        pump(incus, client)
        thread.join()


class ProtocolError(Exception):
    pass


def frame(kind, payload=b''):
    return HEADER.pack(kind, len(payload)) + payload


class FlowConnection:
    """One framed vsock stream relayed to one Incus Unix socket connection."""

    def __init__(self, vsock, incus):
        self.vsock = vsock
        self.incus = incus
        self.state = threading.Condition()
        self.send_lock = threading.Lock()
        self.inbound = collections.deque()
        self.inbound_bytes = 0  # received from the host, not yet written to Incus
        self.owed = 0  # written to Incus, not yet credited to the host
        self.credit = WINDOW  # payload bytes we may still send to the host
        self.end_received = False
        self.end_sent = False
        self.aborted = False

    def abort(self):
        with self.state:
            self.aborted = True
            self.state.notify_all()
        for stream in (self.vsock, self.incus):
            try:
                stream.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def send(self, kind, payload=b''):
        with self.send_lock:
            self.vsock.sendall(frame(kind, payload))

    def read_exact(self, size, allow_eof=False):
        data = bytearray()
        while len(data) < size:
            chunk = self.vsock.recv(size - len(data))
            if not chunk:
                if allow_eof and not data:
                    return None
                raise ProtocolError('vsock closed inside a frame')
            data.extend(chunk)
        return bytes(data)

    def read_frames(self):
        """Always drains vsock; data is bounded by the window the host must respect."""
        while True:
            header = self.read_exact(HEADER.size, allow_eof=True)
            if header is None:
                with self.state:
                    if not (self.end_sent and self.end_received):
                        raise ProtocolError('vsock closed before end of stream')
                return
            kind, length = HEADER.unpack(header)
            if kind == DATA:
                if not 1 <= length <= MAX_PAYLOAD:
                    raise ProtocolError('invalid data length')
                payload = self.read_exact(length)
                with self.state:
                    if self.end_received:
                        raise ProtocolError('data after end')
                    if self.inbound_bytes + self.owed + length > WINDOW:
                        raise ProtocolError('window exceeded')
                    self.inbound.append(payload)
                    self.inbound_bytes += length
                    self.state.notify_all()
            elif kind == CREDIT:
                if length != 4:
                    raise ProtocolError('invalid credit length')
                (count,) = struct.unpack('>I', self.read_exact(4))
                with self.state:
                    if not 1 <= count <= WINDOW or self.credit + count > WINDOW:
                        raise ProtocolError('invalid credit')
                    self.credit += count
                    self.state.notify_all()
            elif kind == END:
                if length != 0:
                    raise ProtocolError('invalid end length')
                with self.state:
                    if self.end_received:
                        raise ProtocolError('duplicate end')
                    self.end_received = True
                    self.state.notify_all()
            else:
                raise ProtocolError('unknown frame type')

    def write_incus(self):
        try:
            while True:
                with self.state:
                    while not self.inbound and not self.end_received and not self.aborted:
                        self.state.wait()
                    if self.aborted:
                        return
                    if not self.inbound:
                        break
                    chunk = self.inbound.popleft()
                self.incus.sendall(chunk)
                with self.state:
                    self.inbound_bytes -= len(chunk)
                    self.owed += len(chunk)
                    grant = 0
                    # No credit is needed once the host has ended its stream.
                    if self.end_received:
                        self.owed = 0
                    elif self.owed >= CREDIT_THRESHOLD or not self.inbound:
                        grant, self.owed = self.owed, 0
                if grant:
                    self.send_credit(grant)
            self.incus.shutdown(socket.SHUT_WR)
        except OSError:
            self.abort()

    def send_credit(self, grant):
        try:
            self.send(CREDIT, struct.pack('>I', grant))
        except OSError:
            # After our END is delivered the host may close normally while credit is in
            # flight; the frame reader decides from the host's end of stream.
            with self.state:
                delivered = self.end_sent
            if not delivered:
                self.abort()

    def read_incus(self):
        try:
            while True:
                with self.state:
                    while self.credit == 0 and not self.aborted:
                        self.state.wait()
                    if self.aborted:
                        return
                    allowed = min(MAX_PAYLOAD, self.credit)
                data = self.incus.recv(allowed)
                if not data:
                    self.send(END)
                    with self.state:
                        self.end_sent = True
                    return
                with self.state:
                    self.credit -= len(data)
                self.send(DATA, data)
        except OSError:
            self.abort()

    def run(self):
        workers = [threading.Thread(target=self.write_incus, daemon=True),
                   threading.Thread(target=self.read_incus, daemon=True)]
        for worker in workers:
            worker.start()
        try:
            self.read_frames()
        except (OSError, ProtocolError):
            self.abort()
        for worker in workers:
            worker.join()


def flow_relay(client):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as incus:
        incus.connect(INCUS_SOCKET)
        FlowConnection(client, incus).run()


def health(client):
    client.settimeout(3)
    request = bytearray()
    while b'\r\n\r\n' not in request:
        chunk = client.recv(4096)
        if not chunk or len(request) + len(chunk) > 16384:
            return
        request.extend(chunk)
    if not request.startswith(b'GET /health HTTP/1.1\r\n'):
        code, result = '404 Not Found', {'error': 'unknown health route'}
    else:
        try:
            if not relay_ready.is_set() or not flow_ready.is_set():
                raise RuntimeError('Incus relay listener is unavailable')
            result = incus_health()
            result['flow_relay_version'] = FLOW_VERSION
            code = '200 OK'
        except (OSError, ValueError, KeyError, RuntimeError) as error:
            code, result = '503 Service Unavailable', {'error': str(error)}
    body = json.dumps(result, separators=(',', ':')).encode()
    client.sendall(f'HTTP/1.1 {code}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode() + body)


def serve(port, handler, ready=None):
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
        listener.bind((socket.VMADDR_CID_ANY, port))
        listener.listen(128)
        if ready is not None:
            ready.set()
        slots = threading.BoundedSemaphore(128)
        def handle(client):
            try:
                with client:
                    handler(client)
            except (OSError, ValueError):
                pass
            finally:
                slots.release()
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=128)
        try:
            while True:
                try:
                    client, peer = listener.accept()
                except OSError as error:
                    if error.errno == errno.EINTR:
                        continue
                    if error.errno in (errno.ECONNABORTED, errno.EMFILE, errno.ENFILE,
                                       errno.ENOBUFS, errno.ENOMEM):
                        time.sleep(0.1)
                        continue
                    raise
                if not host_peer(peer) or not slots.acquire(blocking=False):
                    client.close()
                    continue
                try:
                    pool.submit(handle, client)
                except BaseException:
                    client.close()
                    slots.release()
                    raise
        finally:
            if ready is not None:
                ready.clear()
            # Do not await blocked stream workers before the supervisor can restart us.
            pool.shutdown(wait=False, cancel_futures=True)


def run_or_exit(port, handler, ready=None):
    """Either listener failing invalidates the entire helper, including health."""
    try:
        serve(port, handler, ready)
    except BaseException:
        traceback.print_exc()
    finally:
        os._exit(1)


if __name__ == '__main__':
    threading.Thread(target=run_or_exit, args=(8443, relay, relay_ready), daemon=True).start()
    threading.Thread(target=run_or_exit, args=(FLOW_PORT, flow_relay, flow_ready),
                     daemon=True).start()
    run_or_exit(8444, health)
