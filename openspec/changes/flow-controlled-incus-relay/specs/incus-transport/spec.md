# Spec Delta

## MODIFIED Requirements

### Requirement: Transparent proxy

Incus transport SHALL relay bytes bidirectionally over vsock to the guest Incus Unix socket without rewriting URLs, JSON, headers or WebSocket frames. Streaming and half-close SHALL be supported. The vsock hop SHALL carry each stream in per-connection flow-controlled frames whose payloads reproduce the original byte stream exactly. The runtime SHALL become ready only when live guest health advertises flow relay version 1.

#### Scenario: Streaming exec

- **WHEN** Incus upgrades an exec or event connection to WebSocket
- **THEN** frames and connection lifetime are preserved across the bridge

#### Scenario: Guest without the flow relay

- **WHEN** live guest health omits `flow_relay_version` or reports a version other than 1
- **THEN** the runtime fails readiness with an instruction to recreate the appliance, opens no Incus stream to the guest and deletes no runtime data

### Requirement: Host-only helper

Guest helper SHALL accept only host vsock CID 2 and expose the Incus Unix socket through the flow-controlled relay and a read-only health endpoint on distinct fixed ports. No helper endpoint SHALL accept guest shell commands.

#### Scenario: Guest peer denied

- **WHEN** a nested guest connects to the helper
- **THEN** the connection is rejected before any Incus bytes are relayed

### Requirement: Relay availability

Host relay I/O SHALL use bounded buffers and nonblocking readiness notifications so idle streams cannot exhaust workers needed for control requests or health probes. The flow-controlled relay SHALL keep every guest vsock descriptor drained regardless of client backpressure, bound each direction to a fixed per-connection window, grant credit only after delivery to the local peer, and abort only the offending connection on a protocol violation. Fatal failure of either guest listener SHALL terminate the helper for supervisor restart; transient accept errors SHALL be retried. Guest health SHALL require the Incus relay listener to have started and SHALL advertise the flow relay version.

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
