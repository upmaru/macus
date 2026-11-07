# Proposal

## Why

One Incus stream whose client stops reading stalls every Incus connection through `incus.sock`. Hardware observation on the `alpine-3.24.2-incus-v1` appliance (Macus `64a2ec0`, 2026-11-08):

- Reading one pipelined image export through `incus.sock` without consuming it causes every new connection to close with zero bytes after about 2.15–2.2 seconds. That is the 2-second `GuestConnectionAttempt` deadline.
- An already-open keep-alive connection receives no response for 6 seconds, then answers as soon as the stuck stream is drained.
- Bulk exports that are consumed promptly run at about 480 MiB/s while new probes stay below 80 ms.
- A thread sample of `com.apple.Virtualization.VirtualMachine` taken during the stall shows its single serial `com.apple.virtualization.virtio.vsock-device:0` queue blocked in `writev` for the entire 2-second sample.

Virtualization.framework delivers guest bytes into each connection's host descriptor with a blocking write on one serial device queue. When the host relay applies backpressure by not reading one `VZVirtioSocketConnection` descriptor, the whole virtio-vsock device stops. Guest-to-host data for all connections stops, as do responses to new connection requests and the guest's credit updates for host-to-guest data. Incus migrations that relay one stream into another through Macus deadlock this way. A stalled device also makes health probes fail, so `refresh()` can mark a healthy runtime failed. This violates the existing "Relay availability" requirement, whose idle-stream regression did not include a stalled reader on a real VM.

Copying bytes faster cannot fix this. The host must keep every guest descriptor drained, and bounded memory then requires end-to-end, per-connection flow control between the host relay and the guest bridge.

## What Changes

- Add a flow-controlled Incus relay protocol on a new guest vsock port, 8445. Each direction carries typed frames (data, credit, end of stream) with a fixed per-connection window of 256 KiB. A sender never has more than one window of unacknowledged data in flight. A receiver grants credit only after delivering bytes to its local peer.
- The host relay always reads guest descriptors, holds at most one window of client-bound data per connection and enforces the protocol. Malformed frames, window violations and data after end of stream abort only that connection.
- The guest bridge serves the framed protocol. For each connection it reads vsock eagerly into bounded buffers, writes to the Incus socket from a separate worker and returns credit after each write. It preserves byte transparency, WebSocket upgrades and half-close.
- Guest health adds `flow_relay_version: 1`. `incus.sock` uses the framed port only when live health advertises version 1. Older appliances keep the existing raw relay on port 8443 unchanged.
- New appliances embed the updated guest payload, which gives it a new payload revision. Existing appliances are not patched in place.
- Add hardware acceptance for a stalled reader: new and existing connections, control requests and health probes must keep completing while one stream is unread.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `incus-transport`: transparent proxy over a flow-controlled framed vsock transport, the helper's additional fixed port, and relay availability with stalled readers.

## Impact

Affected files:

- `Sources/Macus/Support/SocketRelay.swift`, plus a new framed relay.
- `Sources/Macus/API/APIServer.swift`.
- `Sources/Macus/Application/RuntimeService.swift` and `RuntimeState.swift` (the health field).
- `Integration/guest/bridge.py` and the regenerated `EmbeddedGuestPayload.swift`.
- Swift and Python transport tests, `Integration/scripts/relay-stress.py`, and documentation.

There are no changes to the Incus API, workloads, storage or control routes. The raw relay remains for appliances without the new payload. Hardware acceptance stays opt-in, uses isolated state directories and is recorded separately from unit test success.
