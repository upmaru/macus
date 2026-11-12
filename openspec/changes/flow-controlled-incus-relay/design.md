# Design

## Context

See `proposal.md` for the observed failure and the delta spec for the contract.

**Host side today:**
- `APIServer` accepts each `incus.sock` client and opens a `VZVirtioSocketConnection` to guest port 8443.
- `SocketRelay` copies bytes with nonblocking Dispatch sources and at most 64 KiB buffered per direction. While a write is pending it suspends the opposite read.

**Guest side today:** `Integration/guest/bridge.py` accepts host CID 2 on port 8443. For each connection it opens `/var/lib/incus/unix.socket` and pumps both directions with blocking `recv`/`sendall` threads.

**Why the suspended read stalls everything:** Virtualization.framework services the whole virtio-vsock device on one serial dispatch queue. That queue writes guest data into each host descriptor with a blocking `writev`. A slow `incus.sock` client therefore stalls every vsock connection, plus every new connection request.

## Goals / Non-Goals

**Goals:**
- No single Incus stream can stall the vsock device.
- Memory per connection stays bounded.
- Byte transparency, WebSocket/upgrade lifetimes and half-close keep working.
- New appliances get the fix through their embedded payload. Existing appliances fail readiness with an explicit instruction to recreate them instead of misreading frames as Incus bytes.

**Non-Goals:**
- No TCP or virtio-net listener.
- No Incus HTTP parsing or URL rewriting.
- No multiplexing several clients over one vsock connection.
- No in-place patching of an existing appliance's root disk.
- No unframed fallback relay or second relay port.
- No new Incus or runtime control routes.

## Decisions

### 1. Per-connection credit protocol on the existing relay port

The guest bridge serves only the flow-controlled protocol on the existing Incus relay port, vsock **8443**. The unframed relay is removed from both sides, so there is one relay socket and one relay implementation.

An old guest still serves unframed bytes on 8443, and a framed host would corrupt its streams. Guest health therefore reports `flow_relay_version: 1`, and the host only becomes ready for a guest that reports it (decision 2).

**Frames.** Each frame has a 5-byte header: a type byte, then a big-endian unsigned 32-bit payload length.

| Type | Name | Payload | Meaning |
|---|---|---|---|
| `0x01` | DATA | 1–65,536 bytes | Opaque stream bytes |
| `0x02` | CREDIT | 4 bytes, big-endian `n`, 1 ≤ `n` ≤ 262,144 | The receiver delivered `n` more bytes to its local peer |
| `0x03` | END | empty | The sender's local peer finished writing (half-close) |

**Window rules.**
- Each direction has a fixed window, W = 262,144 bytes, and starts with W of credit. There is no handshake frame.
- A sender MUST NOT have more than W DATA payload bytes outstanding (sent minus credited).
- A receiver grants CREDIT only for bytes it has written to its local peer. It does so whenever at least W/4 bytes are owed, or when its local output buffer becomes empty. This guarantees progress whenever the sender is blocked on credit.
- CREDIT is not sent after the peer's END. No DATA follows the sender's own END.

**Violations.** Each of these is a protocol violation:
- an unknown type;
- a bad length;
- DATA after END;
- received data exceeding W;
- credit that would raise the sender's available credit above W.

A violation aborts only that connection: both local descriptors are shut down.

**Normal close.** A side finishes normally once it has:
1. sent END;
2. received END;
3. flushed all buffered output;
4. shut down its local peer's write side.

Then it closes the vsock connection. EOF on vsock before both ENDs is an abort. After both ENDs, a write error on vsock (a late CREDIT) is ignored.

Window size versus memory: 256 KiB per direction keeps worst-case buffering at about 64 MiB for the guest's 128-connection limit. The window also covers vsock round trips at the observed 480 MiB/s. Fixed constants keep both sides simple. Changing them needs a new protocol version.

**Alternatives rejected:**
- *Eager host draining into larger buffers:* memory becomes unbounded, or the stall returns once the cap is reached.
- *Per-connection virtio-net TCP:* adds a network listener the transport spec forbids.
- *Retrying vsock connects:* does not address the blocked device queue.

### 2. Host framed relay

Replace `SocketRelay` with `FlowControlledRelay`. It is queue-confined, has one serial queue per connection, and keeps the existing descriptor-lifetime pattern: cancellation handlers retain the owners.

**Reading guest frames:**
- The guest descriptor's read source is never suspended for backpressure. It is cancelled only when the relay finishes.
- Parsed DATA goes to a client-bound buffer, bounded by W through window enforcement.
- CREDIT increases send credit. END schedules a client write shutdown once the buffer drains.

**Writing to the client:**
- Writes to the client use a write source.
- Bytes written accrue as owed credit. A CREDIT frame is queued under the coalescing rule above.

**Reading from the client:**
- The client read source runs only while send credit is positive, no DATA frame is waiting to be written to the guest, and END has not been sent.
- Each read takes up to min(64 KiB, credit) and becomes one DATA frame. Client EOF queues END.

**Guest-bound buffer:** the guest write buffer holds at most one DATA frame plus small control frames.

**When it stops:**
- *Normal completion* shuts down both descriptors.
- *Abort* covers a client error, a guest error, EOF before both ENDs, a protocol violation or task cancellation. It shuts down both descriptors immediately.

**Guest compatibility:**
- `RuntimeService.openIncusStream()` always opens port 8443, and `APIServer` always runs the framed relay.
- `GuestHealth.flowRelayVersion` is optional, so health from older appliances still decodes. Readiness, the already-ready start path and `refresh()` require `flowRelayVersion == 1`.
- A guest with live `protocolVersion` 1 health but no flow relay fails readiness with a fixed message telling the user to recreate the appliance. Runtime data is not deleted, and no Incus stream is opened to that guest.

### 3. Guest bridge

`bridge.py` replaces its raw handler with a flow handler on port 8443. It keeps the existing listener supervision, peer check, 128-slot bound and fatal-exit behavior. Health waits for the relay listener and reports `flow_relay_version: 1`.

Each flow connection runs three activities:

| Activity | Reads | Does |
|---|---|---|
| vsock reader (the handler thread) | vsock, always | Validates frames. Appends DATA to a bounded deque, applies CREDIT and records END. |
| Incus writer | the bounded deque | Writes to the Incus socket, then queues CREDIT. Shuts down Incus writing after the buffer drains following END. |
| Incus reader | the Incus socket | Waits for send credit, sends DATA, and sends END on EOF. |

Shared rules:
- Frame writes to vsock are serialized by a lock.
- Errors and protocol violations shut down the vsock and Incus sockets. Each thread exits on shutdown.
- The bridge never parses Incus bytes.

`Integration/scripts/sync-guest-payload.py` regenerates `EmbeddedGuestPayload.swift`, which changes the payload revision for new appliances. Existing appliances keep reporting health without the field, so the host refuses them as described above.

### 4. Verification

**Swift (socket pairs and a test peer that speaks the protocol):**
- Transparent binary data and half-close in both directions.
- Large transfers both ways with a window-respecting peer.
- With the client not reading, the relay keeps draining the guest descriptor up to W and grants no credit. Credit resumes as the client reads.
- Protocol violations abort only that relay.
- Cancellation works.
- An interop test runs the real `bridge.py` flow handler in a `python3` subprocess over a socket pair against a Unix server fixture.

**Python unit tests:** the bridge handler against an in-process framing peer: window enforcement, credit coalescing, END and half-close, abort on violation, and health advertisement.

**Hardware (opt-in, isolated state):** `relay-stress.py` adds the stalled-reader scenario that reproduced the failure. One pipelined export is left unread for at least 10 seconds while new connections, an existing keep-alive connection, runtime status and health probes must each complete within 1 second. Afterwards the export must drain completely. This is recorded separately from unit test success.

## Risks / Trade-offs

- **Python throughput:** per-frame Python overhead lowers peak throughput compared with raw pumping. Hardware acceptance records the throughput. A blocking `sendall` on vsock is acceptable because the host always drains it.
- **Existing appliances stop working with this Macus** until they are recreated, and recreating an appliance deletes its Incus data. This is accepted to keep one relay socket and implementation, and to leave no appliance on the stalling relay. The failure is explicit and preserves runtime data.
- **Strict protocol enforcement** means a buggy peer aborts its connection rather than corrupting a stream. That is preferred to silent data loss.
