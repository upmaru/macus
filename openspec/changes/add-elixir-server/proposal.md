# Proposal

## Why

Macus needs an authenticated public gateway for its Swift runtime, canonical Incus access and agent tools. The first milestone is a standalone Macus. It uses the pure `:opsmaru_incus` library (`upmaru/opsmaru-incus`) for the Incus client, native gateway mechanics and shared Incus MCP tools, the same definitions central Opsmaru uses, without depending on the `:opsmaru` central service. Registering a Mac with central Opsmaru is a later change (`add-central-registration`).

## What Changes

- Keep one headless Phoenix/Cowboy Mix project in `server/`, OTP application `:macus` with `Macus`/`MacusWeb` namespaces, as Macus's public gateway.
- Depend on the pure `:opsmaru_incus` library. It has no application callback, so it starts no endpoint, listener or process inside the Macus BEAM; no other service is installed.
- Expose authenticated HTTPS for local and explicitly configured LAN/remote access. Retain gateway-owned certificate trust for standard Incus clients and scoped bearer credentials for `/runtime` and `/mcp` before private backend access.
- Expose `/runtime/*` mapped to Swift's private `/v1/runtime/*`; preserve `/` and native `/1.0/*` paths, HTTP/streaming/native upgrades and gateway identity mediation without `/incus` aliases or an upstream client patch.
- **BREAKING**: make the Macus gateway the normal connection boundary for Swift CLI and standard Incus clients. Keep `runtime.sock` and `incus.sock` internal and preserve existing remote conflict rules.
- Consume the pinned portable `Opsmaru.Incus` client over the existing `incus.sock` bridge, and mount the shared `Opsmaru.Incus.Gateway` relay with Macus host policy. Client and gateway implementation/provenance belong to opsmaru-incus; Macus verifies its backend, identity and trust integration without a duplicate client or proxy.
- Compose the shared `:opsmaru_incus` Incus tools with Macus-owned Swift runtime tools at one `/mcp` endpoint using maintained TamaMCP contracts. Supply Macus's verified principal/scopes and local connection through the library's host binding. Tools are synchronous and return native operation identity; durable MCP tasks are deferred.
- Install the Swift executable and matching bundled-ERTS Macus release containing the pinned `:opsmaru_incus` dependency as one package. Installation is passive; `macus start` activates the same two independently supervised Swift/Elixir jobs.
- Central registration (`macus connect`/`connection status`/`disconnect`, outbound connector, delegated execution) moved to the later `add-central-registration` change.
- Preserve canonical checks and explicit isolated package/hardware/remote acceptance. Completed scaffold, pinned-reference foundation and Cowboy transport-trial evidence remain valid historical work; new integration tasks remain unchecked.

## Capabilities

### New Capabilities

- `server-gateway`: authenticated Macus HTTPS routes, transparent native Incus transport through the shared gateway component and listener-free shared library use.
- `incus-client`: Macus consumption and verification of the canonical shared `:opsmaru_incus` client through its private bridge.
- `mcp-service`: one composed shared/host tool catalogue, Macus authorization and synchronous, truthful tool results.

### Modified Capabilities

- `incus-transport`: retain native private relays and control API while supplying the same bridge to shared compute code.
- `client-cli`: route normal requests through the gateway and retain private administration/setup/output safety.
- `startup-bootstrap`: activate/verify the same two services with the shared library within the original startup budget.
- `service-delivery`: package the pinned `:opsmaru_incus` dependency inside Macus's matching release with provenance and no third service.

## Impact

- Dependencies are in `upmaru/opsmaru-incus`: `add-embedded-incus-foundation` (client; task 3.9 open), `add-embeddable-incus-gateway` (relay mechanics) and `add-incus-operations` (shared Incus tools). Macus's local gateway, runtime and client integration can start from the client alone; proxy and MCP tasks wait for the corresponding library revisions.
- Macus changes remain concentrated in `server/` gateway/identity/runtime/host composition, Swift client/startup integration and existing source/Homebrew delivery. VZ stays in `Sources/Macus/Virtualization`.
- A real immutable `:opsmaru_incus` revision or released version plus lockfile is required before production builds. Editable sibling paths are development-only; startup never downloads a replacement dependency. Build metadata records the distinct opsmaru-incus revision alongside matched Macus Swift/server identity.
- Durable MCP tasks and central registration are out of scope for this milestone. Environment images, skill bundles, workspace provisioning, service previews, Docker/Compose shims, scheduling and multi-host orchestration remain later changes. No code migration, service activation, publication or branch merge is included in planning.
