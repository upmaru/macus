# Spec Delta

## MODIFIED Requirements

### Requirement: Transparent proxy

Incus transport SHALL relay bytes bidirectionally over vsock to the guest Incus Unix socket without rewriting URLs, JSON, headers or WebSocket frames. Streaming and half-close SHALL be supported. When live guest health advertises flow relay version 1, the vsock hop SHALL carry the stream in per-connection flow-controlled frames whose payloads reproduce the original byte stream exactly; otherwise the unframed relay SHALL be used.

#### Scenario: Streaming exec

- **WHEN** Incus upgrades an exec or event connection to WebSocket
- **THEN** frames and connection lifetime are preserved across the bridge

#### Scenario: Flow relay selection

- **WHEN** the runtime is ready and guest health reports `flow_relay_version` 1
- **THEN** new Incus connections use the flow-controlled guest port, and appliances whose health omits the field keep the unframed relay

### Requirement: Host-only helper

Guest helper SHALL accept only host vsock CID 2 and expose the Incus Unix socket through an unframed and a flow-controlled relay, plus a read-only health endpoint, on distinct fixed ports. No helper endpoint SHALL accept guest shell commands.

#### Scenario: Guest peer denied

- **WHEN** a nested guest connects to the helper
- **THEN** the connection is rejected before any Incus bytes are relayed

### Requirement: Relay availability

Host relay I/O SHALL use bounded buffers and nonblocking readiness notifications so idle streams cannot exhaust workers needed for control requests or health probes. The flow-controlled relay SHALL keep every guest vsock descriptor drained regardless of client backpressure, bound each direction to a fixed per-connection window, grant credit only after delivery to the local peer, and abort only the offending connection on a protocol violation. Fatal failure of any guest listener SHALL terminate the helper for supervisor restart; transient accept errors SHALL be retried. Guest health SHALL require the Incus relay listeners to have started and SHALL advertise the flow relay only after its listener has started.

#### Scenario: Idle streams

- **WHEN** many Incus streams remain idle or apply backpressure
- **THEN** control requests and health probes still complete, and duplex half-close remains supported

#### Scenario: Stalled reader

- **WHEN** one flow-relayed Incus client stops reading while its response is still streaming
- **THEN** other existing and new Incus connections, control requests and health probes continue to complete, the stalled stream buffers at most one window per direction, and it resumes without loss once read

#### Scenario: Protocol violation

- **WHEN** a peer sends a malformed frame, data beyond its window, or data after end of stream
- **THEN** only that connection is shut down and other relays continue

#### Scenario: Listener failure

- **WHEN** a guest listener fails permanently while another has active clients
- **THEN** the helper exits promptly and cannot continue advertising healthy transport
