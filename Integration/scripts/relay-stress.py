"""Opt-in relay regressions against an already ready isolated runtime.

Idle streams: 80 open Incus streams must not delay control, health or Incus requests.
Stalled reader: one Incus stream whose client stops reading must not delay other new or
existing Incus connections, control requests or health probes, and must drain afterwards.
"""
import argparse
import http.client
import json
from pathlib import Path
import socket
import statistics
import time
from datetime import datetime, timezone

PIPELINED_REQUESTS = 400
STALL_SECONDS = 10.0
PROBE_LIMIT_SECONDS = 1.0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--export-image', metavar='FINGERPRINT',
                        help='also record relay throughput by exporting this local image')
    return parser.parse_args(argv)


def connect(state, endpoint, timeout=3):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(str(state / endpoint))
    return sock


def get(state, endpoint, path):
    connection = http.client.HTTPConnection('localhost', timeout=3)
    connection.sock = connect(state, endpoint)
    try:
        began = time.monotonic()
        connection.request('GET', path)
        response = connection.getresponse()
        result = json.loads(response.read())
        assert response.status == 200, (path, response.status, result)
        return result, time.monotonic() - began
    finally:
        connection.close()


def keep_alive(connection):
    began = time.monotonic()
    connection.request('GET', '/1.0')
    response = connection.getresponse()
    result = json.loads(response.read())
    assert response.status == 200, result
    return result, time.monotonic() - began


def idle_streams(state):
    peers = []
    try:
        for _ in range(80):
            peer = connect(state, 'incus.sock')
            peer.sendall(b'GET /1.0 HTTP/1.1\r\nHost: localhost\r\n')
            peers.append(peer)
        time.sleep(1)
        samples = []
        for _ in range(20):
            status, elapsed = get(state, 'runtime.sock', '/v1/runtime/status')
            assert status['state'] == 'ready', status
            samples.append(elapsed)
            health, elapsed = get(state, 'runtime.sock', '/v1/runtime/health')
            assert health['protocol_version'] == 1, health
            samples.append(elapsed)
            _, elapsed = get(state, 'incus.sock', '/1.0')
            samples.append(elapsed)
        return {'idle_incus_streams': len(peers),
                'successful_control_health_and_incus_requests': len(samples),
                'maximum_response_seconds': max(samples),
                'median_response_seconds': statistics.median(samples)}
    finally:
        for peer in peers:
            peer.close()


def stalled_reader(state):
    health, _ = get(state, 'runtime.sock', '/v1/runtime/health')
    existing = http.client.HTTPConnection('localhost', timeout=PROBE_LIMIT_SECONDS)
    existing.sock = connect(state, 'incus.sock', PROBE_LIMIT_SECONDS)
    keep_alive(existing)
    stalled = connect(state, 'incus.sock', 10)
    stalled.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    request = b'GET /1.0 HTTP/1.1\r\nHost: localhost\r\n\r\n'
    final = b'GET /1.0 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'
    stalled.sendall(request * (PIPELINED_REQUESTS - 1) + final)
    probes = [('incus_new', lambda: get(state, 'incus.sock', '/1.0')),
              ('incus_existing', lambda: keep_alive(existing)),
              ('runtime_status', lambda: get(state, 'runtime.sock', '/v1/runtime/status')),
              ('runtime_health', lambda: get(state, 'runtime.sock', '/v1/runtime/health'))]
    samples, failures = [], []
    began = time.monotonic()
    try:
        while time.monotonic() - began < STALL_SECONDS:
            for name, probe in probes:
                try:
                    _, elapsed = probe()
                    samples.append(elapsed)
                    if elapsed > PROBE_LIMIT_SECONDS:
                        failures.append({'probe': name, 'seconds': elapsed})
                except (OSError, AssertionError, http.client.HTTPException, ValueError) as error:
                    failures.append({'probe': name, 'error': type(error).__name__})
            time.sleep(0.25)
        drained, drain_error = bytearray(), None
        try:
            while True:
                chunk = stalled.recv(1 << 20)
                if not chunk:
                    break
                drained.extend(chunk)
        except OSError as error:
            # A relay that never resumes is the regression this check exists to catch;
            # keep the probe results instead of losing them with the exception.
            drain_error = type(error).__name__
    finally:
        existing.close()
        stalled.close()
    responses = drained.count(b'HTTP/1.1 200 OK')
    return {'pipelined_requests': PIPELINED_REQUESTS, 'stall_seconds': STALL_SECONDS,
            'flow_relay_version': health.get('flow_relay_version'),
            'probes': len(samples), 'failure_count': len(failures), 'failures': failures[:20],
            'maximum_response_seconds': max(samples) if samples else None,
            'drained_bytes': len(drained), 'drained_responses': responses,
            'drain_error': drain_error,
            'passed': not failures and drain_error is None and responses == PIPELINED_REQUESTS}


def export_throughput(state, fingerprint, seconds=10.0):
    moved, began = 0, time.monotonic()
    connection = http.client.HTTPConnection('localhost', timeout=10)
    connection.sock = connect(state, 'incus.sock', 10)
    try:
        while time.monotonic() - began < seconds:
            connection.request('GET', f'/1.0/images/{fingerprint}/export')
            response = connection.getresponse()
            assert response.status == 200, response.status
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                moved += len(chunk)
    finally:
        connection.close()
    elapsed = time.monotonic() - began
    return {'image': fingerprint, 'bytes': moved, 'seconds': elapsed,
            'mebibytes_per_second': moved / elapsed / 1048576}


def main(argv=None):
    args = parse_args(argv)
    state = args.state_dir.resolve()
    report = {'tested_at': datetime.now(timezone.utc).isoformat()}
    stage = 'idle_streams'
    try:
        report.update(idle_streams(state))
        stage = 'stalled_reader'
        report['stalled_reader'] = stalled_reader(state)
        if args.export_image:
            stage = 'export_throughput'
            report['export_throughput'] = export_throughput(state, args.export_image)
        report['status'] = 'passed' if report['stalled_reader']['passed'] else 'failed'
    except (OSError, AssertionError, http.client.HTTPException, ValueError) as error:
        # Always leave a failed report behind; partial results stay in place.
        report['status'] = 'failed'
        report['error'] = {'stage': stage, 'type': type(error).__name__}
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
