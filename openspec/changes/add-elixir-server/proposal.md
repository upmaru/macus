# Proposal

## Why

Macus needs an authenticated public gateway for its Swift runtime, canonical Incus access and agent tools. The first milestone is a standalone Macus. It uses the pure `:opsmaru_incus` library (`upmaru/opsmaru-incus`, released on Hex as 0.1.0) for the Incus client, native gateway mechanics and shared Incus operation descriptors, the same definitions central Opsmaru uses, without depending on the `:opsmaru` central service. Registering a Mac with central Opsmaru is a later change (`add-central-registration`).

## What Changes

- Keep one headless Phoenix/Cowboy Mix project in `server/`, OTP application `:macus` with `Macus`/`MacusWeb` namespaces, as Macus's public gateway.
- Depend on the pure `:opsmaru_incus` library from Hex (`~> 0.1.0`, locked in `server/mix.lock`). It has no application callback, so it starts no endpoint, listener or process inside the Macus BEAM; no other service is installed.
- Expose authenticated HTTPS for local and explicitly configured LAN/remote access. Retain gateway-owned certificate trust for standard Incus clients and scoped bearer credentials for `/runtime` and `/mcp` before private backend access.
- Expose `/runtime/*` mapped to Swift's private `/v1/runtime/*`; preserve `/` and native `/1.0/*` paths, HTTP/streaming/native upgrades and gateway identity mediation without `/incus` aliases or an upstream client patch.
- **BREAKING**: make the Macus gateway the normal connection boundary for Swift CLI and standard Incus clients. Keep `runtime.sock` and `incus.sock` internal and preserve existing remote conflict rules.
- Consume the locked portable `Opsmaru.Incus` client over the existing `incus.sock` bridge, and mount the shared `Opsmaru.Incus.Gateway` relay with Macus host policy. Client and gateway implementation/provenance belong to opsmaru-incus; Macus verifies its backend, identity and trust integration without a duplicate client or proxy.
- Expose agents to one `/mcp` endpoint advertising exactly two tools, `search` and `execute`, using maintained TamaMCP contracts. The tools cover one catalogue: the exported shared `:opsmaru_incus` operation descriptors plus Macus-owned Swift runtime operations. The separate tama-dex library (`Tama.Dex`) indexes `tama-operations/1` documents into SQLite at `<state-dir>/server/tama-dex.sqlite3`. Macus loads the bundled, SHA-pinned opsmaru_incus cassette and its own `macus` runtime document at server start, reporting index readiness separately from VM readiness. Macus owns both tool modules, built from `Tama.Dex.MCP`. `execute` dispatches shared operations to `Opsmaru.Incus.Operations.run/3` with Macus's verified principal/scopes and its local connection through the library's operations host contract. Operations are synchronous and return native operation identity; durable MCP tasks are deferred. No per-operation MCP tools are registered.
- Install the Swift executable and matching bundled-ERTS Macus release containing the pinned `:opsmaru_incus` dependency as one package. Installation is passive; `macus start` activates the same two independently supervised Swift/Elixir jobs.
- Central registration (`macus connect`/`connection status`/`disconnect`, outbound connector, delegated execution) moved to the later `add-central-registration` change.
- Preserve canonical checks and explicit isolated package/hardware/remote acceptance. Completed scaffold, pinned-reference foundation and Cowboy transport-trial evidence remain valid historical work; new integration tasks remain unchecked.

## Capabilities

### New Capabilities

- `server-gateway`: authenticated Macus HTTPS routes, transparent native Incus transport through the shared gateway component and listener-free shared library use.
- `incus-client`: Macus consumption and verification of the canonical shared `:opsmaru_incus` client through its private bridge.
- `mcp-service`: a two-tool (`search`/`execute`) surface over one combined shared/host operation catalogue, Macus authorization and synchronous, truthful results.

### Modified Capabilities

- `incus-transport`: retain native private relays and control API while supplying the same bridge to shared compute code.
- `client-cli`: route normal requests through the gateway and retain private administration/setup/output safety.
- `startup-bootstrap`: activate/verify the same two services with the shared library within the original startup budget.
- `service-delivery`: package the pinned `:opsmaru_incus` dependency inside Macus's matching release with provenance and no third service.

## Impact

- `:opsmaru_incus` 0.1.0 on Hex delivers all three library changes (`add-embedded-incus-foundation`, `add-embeddable-incus-gateway`, `add-incus-operations`, all archived upstream). Gateway, runtime, client, proxy and `execute` work can proceed now. The library still reports `complete_port=false`, so a complete-client claim waits for later releases. The `search`/`execute` tool modules and index loading wait for a tama-dex release and the opsmaru_incus release (planned 0.2.0) that adds `Operations.openapi/0` and its cassette.
- Macus changes remain concentrated in `server/` gateway/identity/runtime/host composition, Swift client/startup integration and existing source/Homebrew delivery. VZ stays in `Sources/Macus/Virtualization`.
- Production builds resolve `:opsmaru_incus` from Hex through the committed lockfile; Hex is the library's only distribution route, so no Git revision or sibling path is pinned. Startup never downloads a replacement dependency. Build metadata records the distinct opsmaru-incus version and checksum alongside matched Macus Swift/server identity.
- Durable MCP tasks and central registration are out of scope for this milestone. Environment images, skill bundles, workspace provisioning, service previews, Docker/Compose shims, scheduling and multi-host orchestration remain later changes. No code migration, service activation, publication or branch merge is included in planning.
