# Tasks

## 1. Protocol and host relay

- [x] 1.1 Add the flow relay protocol constants and frame codec (DATA/CREDIT/END, 64 KiB maximum payload, 256 KiB window) with an incremental parser; verify valid frames, partial headers/payloads across reads, and rejection of unknown types, bad lengths and zero/oversized credit.
- [x] 1.2 Implement `FlowControlledRelay` with queue-confined nonblocking Dispatch sources, an always-armed guest reader, window/credit enforcement, coalesced credit, END/half-close handling, normal completion, abort and cancellation; verify binary transparency and half-close in both directions, 2 MB bidirectional transfers, stalled-client draining to exactly one window without credit until the client reads, protocol-violation aborts and cancellation using socket pairs and a Swift test peer.
- [x] 1.3 Add optional `GuestHealth.flowRelayVersion`, select port 8445 and the framed relay only for version 1 and keep port 8443/raw relay otherwise; verify health decoding with and without the field, unchanged `protocolVersion` checks, and relay/port selection through the runtime service; the API server dispatches on the returned relay mode.

## 2. Guest bridge and payload

- [x] 2.1 Add the port-8445 flow handler to `bridge.py` with an eager vsock reader, bounded Incus writer, credit-gated Incus reader, serialized frame writes, END/half-close, abort and the shared 128-slot listener supervision; health reports `flow_relay_version: 1` only after both relay listeners start; verify Python unit tests for window enforcement, credit coalescing, half-close, abort on violation, listener failure exit and health advertisement.
- [x] 2.2 Add a Swift interop test that runs the real bridge flow handler in a `python3` subprocess, connected over Unix sockets standing in for vsock and the Incus socket; verify transparent bidirectional transfer, half-close and stalled-client behavior across both implementations.
- [x] 2.3 Regenerate `EmbeddedGuestPayload.swift` and record the new revision in the appliance catalog; verify `sync-guest-payload.py --check` and `check-catalog.py`.

## 3. Documentation and verification

- [x] 3.1 Document the flow relay, port 8445, health field, appliance compatibility (existing appliances keep the raw relay until recreated) and the Virtualization.framework stall evidence in architecture and transport docs.
- [x] 3.2 Extend `Integration/scripts/relay-stress.py` with the opt-in stalled-reader scenario and throughput record; verify it compiles and its non-hardware argument handling in tests.
- [x] 3.3 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`; review the diff for Swift 6 concurrency, bounded buffers, unchanged raw relay and no committed `.integration`/build outputs.
- [ ] 3.4 With explicit opt-in and an isolated state directory, provision an appliance with the new payload and run the stalled-reader and relay stress acceptance; record results separately from unit tests and leave this unchecked until it passes on hardware.

Evidence (2026-11-08, unit and fixture level only): `Integration/scripts/check.sh` passed with 147 Swift tests (13 flow relay unit tests, 2 Swift–Python interop tests) and 80 Python tests, release build and strict formatting; `openspec validate --all --strict` passed 10 items. The stall was reproduced read-only on Macus `64a2ec0` with a sample showing the Virtualization.framework vsock device queue blocked in `writev`; hardware acceptance of the fix (3.4) has not run.
