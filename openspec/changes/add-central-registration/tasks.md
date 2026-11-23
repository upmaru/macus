# Tasks

Later change, split from `add-elixir-server` on 2026-10-13. Waits for the standalone milestone and the central Opsmaru registration contracts; revise before implementing.

## 1. Central enrollment and connector integration

- [ ] 1.1 Add Swift connect [url], connection status [--json] and disconnect commands plus owner-authenticated Elixir administration; verify usage/URL/state validation, saved-URL resume, changed-service conflict, output/deadline behavior and passive unregistered status with no secret output.
- [ ] 1.2 Reuse launchd/package identity preflight to explicitly recover only the matching Elixir job for connect; verify no Swift activation, downloads/appliance/VZ boot, share/native-remote changes or third service on absent/stopped runtime fixtures.
- [ ] 1.3 Integrate trusted central metadata and external-provider Device Authorization Grant through verified shared OAuth primitives; verify Keycloak browser approval, denied/expired/polling timeout and unsupported-provider failure without local issuer/password or persisted user tokens.
- [ ] 1.4 Implement private device generation, one-use key-bound enrollment and durable pending/completed receipt state; verify bad service/key/owner, unsafe paths, replay, lost completion response and idempotent same-registration recovery with no target duplication or private-key upload.
- [ ] 1.5 Enable shared outbound connector workers inside the existing server and configure central TLS/device/generation/local operation limits; verify no dependency endpoint/Repo/inbound port, backoff/restart, stale session fencing and separate connection/backend readiness.
- [ ] 1.6 Integrate delegated owner namespace and allowed operation descriptors with the same runtime/Incus adapters and journal runner; verify project/tool/target/owner/confirmation/stopped-state checks before socket access and inability to inspect local standalone tasks or run arbitrary host commands.
- [ ] 1.7 Integrate central task/dispatch receipt/native operation linkage and bounded control/data streams; verify duplicate/conflicting dispatch, missing acknowledgement, restart, interrupted exec/binary transfer, cancellation intent and uncertain outcomes cause no second mutation or runner.
- [ ] 1.8 Implement durable local disconnect, session closure and bounded central device revocation/reconciliation; verify offline revocation-pending, repeated disconnect, confirmed revoke/new generation and preserved local gateway/workload/receipt markers without automatic retry or VM shutdown.
- [ ] 1.9 Document and fixture-test standalone versus registered CLI/server/package behavior; verify no enrollment at install/start, central outage does not block local startup and disabled connectors remain disabled across upgrade/removal.
- [ ] 1.10 With explicit isolated installed/central/hardware opt-in, prove macus connect, central target discovery/authorized dispatch, receipt recovery and disconnect from a separate central client; retain device/OIDC/network evidence separately from VZ/guest tests and leave unavailable acceptance gates incomplete.
