# Design

## Context

See [proposal.md](proposal.md) for motivation and scope. **Revision 2026-10-13:** the Incus client moved to the pure `:opsmaru_incus` library in `upmaru/opsmaru-incus`, together with the native gateway mechanics and shared Incus tools; `:opsmaru` is now the central service only and Macus no longer depends on it. Durable MCP tasks are deferred and central registration moved to `add-central-registration`. Earlier context below is kept for history. The original baseline was `develop` at `0c3eec77b020a174f66e691579d5ceba601cd158`. The current `feature/elixir-server` checkout has a Phoenix/Cowboy scaffold, boundary stubs, pinned Incus reference fixtures and the fixture-only transport trial, with seven original tasks completed. This revision preserves that evidence and assigns the first library/client milestone to Opsmaru's [add-embedded-incus-foundation](https://github.com/upmaru/opsmaru-incus/blob/develop/openspec/changes/add-embedded-incus-foundation/design.md) and later MCP/task/connector implementation to [add-compute-substrate](https://github.com/upmaru/opsmaru/blob/develop/openspec/changes/add-compute-substrate/design.md). Opsmaru now has a published Phoenix scaffold and central/connector planning; no implemented immutable compute/connector dependency is available yet. The seven original Macus tasks record local scaffold/reference/transport evidence; this plan publication does not include the still-uncommitted server implementation.

Observed integration points:

- `Sources/Macus/API/APIServer.swift` owns two private listeners. `runtime.sock` routes HTTP/JSON through `RuntimeRoutes`; `incus.sock` opens a guest stream and relays bytes. Swift remains the direct Apple VZ owner.
- `Sources/Macus/Bootstrap/StartupCoordinator.swift` activates one Swift job, calls private `/v1/runtime/*` routes and configures a `unix:` remote. It already has a serialized bootstrap, one total deadline, explicit cancellation and safe runtime preservation.
- `Sources/Macus/Bootstrap/LaunchAgent.swift` validates launchctl's actual executable and arguments, distinguishes stopped jobs, and isolates nondefault state directories. Its service identity and conflict protections must extend to the second job rather than be replaced.
- `Packaging/install-local.sh` and `Packaging/homebrew/Formula/macus.rb.in` currently install only Swift. `Packaging/homebrew/candidate.py` supplies real revision/checksum/bottle evidence and passive package checks. The active `add-homebrew-tap` change must be reconciled during implementation, not marked complete by this proposal.
- The maintained TamaMCP checkout inspected at `/Users/zacksiri/Development/_kritama/tama-mcp`, revision `33ead37c798a33059dbaf62ddbdb3c10d984671b`, declares package version 0.1.1. Its transport is a framework-neutral Plug supporting the 2026-07-28 protocol, tools, durable task contracts and bounded SSE subscriptions. It does not provide a web server, persistence, stdio, resources, prompts or old-protocol compatibility. Its authorization, validator cache, task store and execution handoff are application-owned adapters.

Main specs still describe direct Unix client access; root context/docs were updated during the initial scaffold work for the public gateway. The private Swift endpoints remain Unix-only. Implementation must now reconcile those context/docs with shared Opsmaru ownership and apply the existing-capability deltas. This revision updates this change's planning artifacts and root planning context, not active scaffold/source code or another change.

## Goals / Non-Goals

**Goals:**

- Make the installed Phoenix server the normal connection boundary for local CLI, standard Incus clients and MCP clients.
- Keep the VM, Incus workloads and client operations independent of the language used for the public server.
- Support operator-configured remote HTTPS with explicit identity and scope enforcement before privileged backend access.
- Consume the shared `:opsmaru_incus` client, gateway mechanics and Incus operations with upstream method evidence and independent Macus bridge/identity acceptance; keep one public endpoint.
- Reuse existing startup safety, budgets and machine-output contracts across the two-service installation.
- Operate fully standalone; central registration is the later `add-central-registration` change.

**Non-Goals:**

- Moving VZ objects, disks or workload state into BEAM; invoking another host VM runtime; adding a GUI or cross-platform packaging requirement.
- Durable MCP tasks (deferred) and central registration (later change).
- A duplicate shared client or proxy implementation, separate Opsmaru endpoint/job, Linux packaging inside Macus, environment/workspace/skill workflows, multi-host scheduling, Docker/Compose translation or automatic guest/network migration.
- An Incus namespace patch, `/incus` compatibility aliases, a Go/Rust sidecar, Burrito or a host Erlang prerequisite for prebuilt installs.
- Local OAuth/OIDC issuer, provider account/consent UI or federation server, and MCP features absent from the pinned library.
- Finishing Git Flow branches, publishing packages or accepting hardware behavior as part of planning.

## Decisions

### 1. Macus gateway uses the shared `:opsmaru_incus` library

Keep the headless `:macus` Phoenix/Cowboy application in `server/`. It owns the public listener, gateway credentials and trust, host policy, the private Swift runtime adapter, Macus runtime operations and the `search`/`execute` MCP tools. Depend on the released Hex package `{:opsmaru_incus, "~> 0.1.0"}` (published 2026-11-12). `server/mix.lock` records the exact version and checksum. Hex is the library's only distribution route, so do not pin Git revisions or sibling paths.

`:opsmaru_incus` is a pure library with no application callback: depending on it starts no endpoint, listener or process. Macus uses three parts of it: the `Opsmaru.Incus` client over `incus.sock`, the `Opsmaru.Incus.Gateway` relay mounted on the Macus endpoint with Macus host policy (`Opsmaru.Incus.Gateway.Host`), and the shared `Opsmaru.Incus.Operations` descriptors/runner reached through the Macus `search`/`execute` MCP tools. Macus does not depend on the `:opsmaru` central service.

```text
server/lib/macus/
  application.ex       gateway supervision + library configuration
  runtime/             private Swift API client and Macus runtime operations
  host/                Macus capability/path adapter
  proxy/               gateway mount and Macus host policy/trust mediation
  auth/                gateway trust, bearer verification and administration
  mcp/                 operation catalogue, search/execute tools, operations host
server/lib/macus_web/  one public Phoenix endpoint

opsmaru_incus dependency (Hex)
  Opsmaru.Incus             portable client over configured incus.sock
  Opsmaru.Incus.Gateway     native HTTP/WebSocket/raw-upgrade relay mechanics
  Opsmaru.Incus.Operations  shared operation descriptors and synchronous run/3

tama-dex (Tama.Dex, separate library, not yet released)
  one SQLite index; cassette namespaces opsmaru_incus (imported) and macus (local)
  tool definitions and search/execute handlers; started under the Macus supervisor
```

Resolve compatible locked Phoenix/Cowboy/TamaMCP dependencies against the library's ranged requirements. The library's isolated consumer fixture uses Macus's exact Phoenix/Plug.Cowboy/Cowboy/Mint/TamaMCP set. Adding it to `server/mix.lock` adds only `opsmaru_incus`, `mint_web_socket` and `yamerl`. CI, source installs and packaging resolve from Hex without a sibling checkout.

Retain the Cowboy2 adapter established by the successful native SFTP/NBD fixture trial. The initial Bandit choice failed the native upgrade requirement; the documented Cowboy switch-protocol design and response-header guard remain unchanged.

Alternative: implementing the client, proxy or Incus operations in Macus duplicates what central Opsmaru also needs. The shared library holds them; Macus implements host integration.

### 2. One public server, existing private bridges

```text
Swift CLI / standard Incus clients / MCP clients
                     |
                   HTTPS
                     |
               Phoenix / Cowboy
                /      |      \
         /runtime    /1.0*     /mcp
             |          |       |
        runtime client  |   typed runtime/Incus clients
             |          |       |
        runtime.sock    incus.sock
             |              |
        Swift VM actor  Swift duplex relay
             |              |
            VZ           virtio/vsock
                            |
                     guest helper / Incus
```

Public routing:

| Public route | Handling |
| --- | --- |
| `/runtime` and `/runtime/*` | Allowlisted control methods mapped to `/v1/runtime` and its private routes |
| `/`, `/1.0`, `/1.0/*` | Native Incus discovery/API, identity/trust mediation, HTTP bodies and upgrade streams |
| `/mcp` | Maintained TamaMCP transport with exactly two tools, `search` and `execute`, over the combined `:opsmaru_incus` and Macus runtime operation catalogue; host auth and the library operations host |

The `:opsmaru_incus` library runs inside this BEAM without its own endpoint, listener or process. Shared Incus operations use its client configured against incus.sock; Macus runtime operations use runtime.sock. Macus's local endpoint still serves one configured local target; central Opsmaru's separate MCP/REST endpoint can select multiple registered targets. Local Macus never accepts arbitrary independent target addresses.

Public runtime inspection has no version in the path. Keep private Swift routes and snake_case models/version fields; preserve method, conflict and budget behavior. Public status projects connection metadata to `server_endpoint`/`incus_endpoint` and separate server/runtime readiness, omitting internal socket paths and secrets. This is an explicit public response change, not an undocumented alteration of private Swift status.

The root discovery response preserves Incus discovery semantics. No prefix aliases, native client modifications or alternative WebSocket framing are required. Public clients never bypass server failure by silently falling back to Swift sockets. Same-user backend socket access is still technically possible; this architecture is a published client boundary, not a claim that filesystem ownership isolates mutually trusted processes of the same macOS account.

### 3. HTTPS and gateway-owned authentication

The user confirmed LAN/remote support and certificate plus bearer authentication. Bind loopback by default, using a configurable port with 8443 as the ordinary initial default. Enable LAN access only with explicit bind/advertised URL configuration and a suitable certificate. Accept custom certificates for externally advertised identities. Do not open router ports, alter firewall policy or automatically bind `0.0.0.0`/`::`.

Store gateway configuration, endpoint metadata, keys, certificate trust, token records and MCP task state beneath `<state-dir>/server/`, outside the package and outside Swift-owned `runtime/` disks. Use 0700 directories and 0600 files, validate ownership and ancestry, and publish endpoint/build identity atomically. Isolated acceptance selects a separate port/address and separate credentials; it cannot replace default endpoint metadata.

TLS supports both client-certificate Incus requests and bearer-authenticated runtime/MCP requests on the same HTTPS service. A presented peer certificate is not trusted merely because it was supplied. Validate certificate possession and enrolled fingerprint/policy for Incus requests; validate scoped bearer credentials for runtime/MCP requests. Require TLS 1.3 for native-client compatibility. Anonymous discovery is narrowly bounded and synthetic; it does not contact privileged guest APIs or expose guest state. All other routing and upgrades authorize before backend connection.

Provide owner-local CLI administration under `macus server`: endpoint configuration, certificate enrollment/revocation and bearer issuance/revocation. These commands manipulate validated private gateway state, not VM disks or guest shell commands. Normal help/status/doctor does not create that state. `macus start` can prepare its own local server identity/CLI credential once, without printing credentials. Extra client token material is returned only by an explicit issuance action through a private destination.

Local Swift clients verify the gateway's recorded certificate and use their owner-private runtime token. MCP tokens carry distinct read/write/exec/delete scopes. Store bearer verifiers rather than plaintext bearer values where possible; the local CLI's actual token remains in its separate private credential file. Rotation/revocation invalidates new requests and active streams. A documented default revocation recheck bound of 5 seconds applies to long-lived connections; certificate expiry and token expiry are also enforced.

**Why the gateway owns trust:** requests relayed through the guest Unix socket have privileged local access. Guest TLS trust cannot secure a public listener that terminates TLS on macOS. The gateway must authorize every incoming HTTP request and upgrade independently of guest trust.

Native discovery and the `/1.0` server response therefore present the gateway certificate/auth identity and configured public addresses. Gateway `/1.0/certificates` trust operations and enrollment tokens are handled against gateway trust state, using standard Incus wire shapes so remote registration and `incus config trust` work. Token enrollment is the narrowly authorized exception to existing-certificate authentication: only a valid expiring single-use gateway enrollment token can authorize the presented new certificate, and it never opens a guest stream. Authenticated workload requests remain native Incus.

Project-restricted certificate metadata must either be enforced at the gateway with verified native restrictions or rejected explicitly; never claim restrictions that the privileged Unix backend will ignore. The initial certificate policy grants enrolled owner-admin clients full native access. Narrower workload permissions are provided by named MCP tool scopes until restricted-certificate semantics have complete acceptance evidence.

HTTP hop-by-hop headers are handled by the proxy. Identity/trust mediation is a documented allowlist, not a general JSON rewrite engine. Do not expose guest-NAT addresses as usable gateway remotes. Migration and server-address negotiation must select publicly reachable authorized endpoints and be acceptance-tested; no migration may bypass gateway policy merely because the guest advertises another address.

Alternatives: unauthenticated loopback does not satisfy the selected remote scope; forwarding guest trust unchanged would bypass authentication over the private socket. The standalone local certificate/bearer contract needs no external identity provider. Explicit central enrollment uses that service's configured external provider, without changing local gateway trust or introducing a Macus issuer.

### 4. Preserve native streaming and isolate each connection

`Macus.Proxy` mounts the shared `Opsmaru.Incus.Gateway` relay (`add-embeddable-incus-gateway`) and supplies Macus host policy; native routes reach `incus.sock` through it. Ordinary JSON requests, streaming images/files/backups, WebSocket exec/console/events and non-WebSocket native upgrade channels need distinct framing paths. Relay upgrades using native bytes/frames and backpressure, not Phoenix Channels. Do not buffer full uploads or terminal sessions.

Use Cowboy custom dispatch handlers on the same HTTPS listener for native Incus upgrades and streaming, with Phoenix/Plug handling runtime and MCP routes. Authorize the presented identity before opening any backend socket. Native SFTP/NBD handlers validate the backend's HTTP 101 response before requesting Cowboy's documented `switch_protocol` handoff; the connection process then relays opaque bytes without implementing either guest protocol. Transfer backend socket ownership before the request worker exits and retain already-read bytes from both handshakes. Bound active reads, writes, shutdown/drain intervals and connection counts. Preserve applicable half-close and cleanup semantics. HTTP/2 cannot perform these HTTP/1.1 Upgrade handshakes; clients use their native HTTP/1.1 path.

First prove the adapter choice using isolated TLS-to-Unix fixtures: binary duplex traffic, coalesced handshake bytes, credential rejection before backend access, backend denial, disconnect cleanup and ordinary Phoenix requests on the same listener. This evidence selects the adapter; it does not complete the native proxy/client port or establish hardware acceptance. Do not fork Cowboy or modify the Incus client to make the trial pass.

Retain Cowboy's `invalid_response_headers: :error_terminate` guard explicitly. The selected Cowboy release includes the documented server-side mitigation for Cowlib CVE-2026-43966; verify rejection of CR/LF-bearing upgrade response headers. Native protocol names are allowlisted and application code must not feed unchecked input into structured-field header encoders. A successful fixture does not establish that the transitive Cowlib release itself is fixed.

Dispatch Incus and MCP routes before global `Plug.Parsers`. The TamaMCP Plug owns bounded MCP body validation, and `Opsmaru.Incus.Gateway.Plug` refuses requests whose body a parser has already consumed. Runtime control retains its own documented bounds and private single-request behavior. All paths must preserve queries (including project, target and operation secrets), ETags, binary data and relevant connection teardown. Transport secrets in upgrade URLs are redacted from logs.

Use independent supervised connection workers with bounded queues/buffers and stream quotas. A worker can wait for socket readiness without serializing all requests through one GenServer. Control/status and authentication stay responsive under idle or slow streams. Backend failure closes affected streams and leaves Swift/Incus data intact. No generic retry of mutating requests after an ambiguous disconnect.

Alternatives: routing every operation through typed models would narrow the native API and require updates for each new endpoint. A JSON-only reverse proxy would break exec, events and uploads. The raw proxy and typed client serve different entry points and share transport infrastructure where appropriate.

### 5. Consume and independently verify the shared Incus client

The add-embedded-incus-foundation change in `upmaru/opsmaru-incus` is the first implementation prerequisite for this section. It needs no central server, OIDC, registry, connector, MCP catalogue or durable task runner. Macus may proceed with its local gateway/runtime/native proxy and this client integration once that library revision is verified. Section 6 depends on `add-incus-operations` and must not gate first library/client acceptance.

opsmaru-incus owns the portable `Opsmaru.Incus` implementation, pinned upstream source inventory, notices, differential fixtures and full client coverage. Macus supplies its private relay connection through the library's configured backend contract. Gateway native proxying remains separate from this typed client path; shared tools and Macus integration code use the same client implementation.

The existing Macus inventory and differential fixtures remain recorded as completed reference-foundation work. Reusable inputs were transferred to the shared library with provenance; retain Macus-specific relay/gateway consumer fixtures. Any temporary `Macus.Incus` compatibility module can only delegate to the dependency, never duplicate request codecs, retries or protocol behavior.

The full required client surface remains discovery/models/extensions; native project/member targeting; instances/snapshots; images; profiles/access; networks/clusters; storage; files/backups/native upgrades; operations/events; exec/console; and migration/copy. Required method/type evidence is checked at the pinned dependency revision. A missing library entry blocks a complete client claim rather than being filled by a second Macus implementation or disguised by raw-proxy success.

Macus acceptance proves its configured bridge, verified identity/owner context, deadlines, error propagation and native stream integration. opsmaru-incus fixture/coverage results are linked separately; real Macus guest evidence remains mandatory for hardware acceptance. Updates to the dependency/upstream reference require an inventory diff and affected consumer reruns.

Alternative: implementing a few Macus-only REST calls would both duplicate the shared backend and fail the original complete-port contract. The shared library preserves that contract; this change verifies and consumes it.

### 6. Search and execute operations at one MCP endpoint

**Revision 2026-11-12:** `:opsmaru_incus` 0.1.0 ships operation descriptors and `Opsmaru.Incus.Operations.run/3` but no MCP binding (its optional TamaMCP tool modules were removed on 2026-11-04). Macus therefore does not register one MCP tool per operation. `/mcp` advertises exactly two tools, `search` and `execute`, backed by the separate tama-dex library (module namespace `Tama.Dex`, kritama/tama-dex). The user confirmed the three tama-dex defaults below on 2026-11-12.

tama-dex indexes `tama-operations/1` documents into SQLite. A `tama-operations/1` document is an OpenAPI 3.1 profile: one `POST /operations/{operationId}` per operation, plus `x-tama-scopes`, `x-tama-destructive`, `x-tama-confirmation`, `x-tama-bounds` and `x-tama-identity`. Macus keeps one index with two cassettes. A cassette is a namespace: operations are addressed by `(cassette, operation_id)` and IDs need only be unique within a cassette (kritama/tama-dex#1 `d91fe07`). Executors stay keyed by `x-tama-source`.

| Cassette / source | Document | Executor |
| --- | --- | --- |
| `opsmaru_incus` cassette (imported), source `opsmaru_incus` | `Opsmaru.Incus.Operations.openapi/0` in the opsmaru_incus release cassette (planned for 0.2.0) | `Macus.Dex.IncusExecutor`: `Opsmaru.Incus.Operations.run(call.operation_id, input, host: Macus.MCP.IncusHost, caller: call.context.caller, scopes: call.scopes)` |
| `opsmaru_incus` cassette (imported), source `opsmaru_incus_native` | `Opsmaru.Incus.NativeOperations.openapi/0` in the same release cassette; always installed with it | None registered in this milestone. Its operations require `incus.native.*` scopes, which Macus never grants until it registers `Macus.Dex.NativeExecutor` over `Opsmaru.Incus.NativeOperations.run/3` (same `host:`, `call.context.caller` and `call.scopes`). |
| `macus` cassette (local), source `macus` | Macus-built document of `macus_runtime_*` operations | `Macus.Dex.RuntimeExecutor` over the private Swift adapter |

1. **Load at server start.** Macus starts `Tama.Dex.Index` under its own supervisor. At server start it installs the bundled `opsmaru_incus` cassette with `Tama.Dex.import(index, path, sha256: pin, async: true)`. The pin is the SHA-256 recorded in build metadata, and the cassette name comes from its manifest (`as:` is used only on a collision). It loads its own document with `Tama.Dex.load(index, doc, cassette: "macus")`. Both calls use `async: true` and/or `timeout:`. Per-cassette status from `Tama.Dex.cassettes/1` is reported as gateway readiness, separate from VM readiness. `Index.status/1` `:ready` means only that at least one cassette is committed. A slow or failed import never blocks or fails VM startup. A cassette on its first import returns `not_ready` with `dispatched: false` while committed cassettes keep serving. An import replaces its whole cassette atomically, so an upgrade that drops an operation removes it without touching `macus`. Loading into an imported cassette's name, or the reverse, fails with `cassette_conflict`. Startup never downloads a cassette. A bundled file that fails its `sha256:` pin is rejected: nothing is imported, the previous entries stay, and Macus reports that cassette's readiness as failed with repair guidance (reinstall the matching package). It is never silently rebuilt. tama-dex's rebuild mode applies only when no pin is given or the index schema version differs, and Macus always passes a pin.
2. **Index path.** `<state-dir>/server/tama-dex.sqlite3`, mode 0600, under the existing owner-private ancestry checks. It is derived data: deleting it, or a schema-version mismatch, recreates it from the cassette and documents.
3. **Macus owns the tool modules.** The two TamaMCP tool modules on the Macus server take their definitions from `Tama.Dex.MCP.search_tool/0` and `execute_tool/0` (via `raw_input_schema`/`raw_output_schema`). They delegate to `Tama.Dex.MCP.handle_search/3` and `handle_execute/4` with the caller's verified scopes and the per-source executors above. tama-dex does not depend on TamaMCP.
4. **Macus owns the executor adapters.** Each executor is a `Tama.Dex.Executor` behaviour module, `execute(%Tama.Dex.Call{} = call, input) :: {:ok, map} | {:error, map}`, defined in kritama/tama-dex#1 `55e3a59`. The call struct carries `cassette`, `source`, `operation_id`, `scopes`, `context` and `opts`; `handle_execute/4` puts the caller in `context`. Executors are registered as `%{source => module | {module, opts}}`. They pass `call.scopes`, the scopes tama-dex just checked, so each executor re-checks exactly those. A missing entry, or a module without `execute/2`, returns `no_executor` with `dispatched: false`. opsmaru_incus keeps no tama_dex dependency.

| Tool | Behavior |
| --- | --- |
| `search` | Bounded query ranked across all cassettes, with an optional `cassette` filter, filtered to the caller's verified scopes. Each result carries `cassette`, `cassette_version`, operation ID, description, schemas, scopes, confirmation and bounds. |
| `execute` | Takes `{cassette, operation_id, input}`, all required, and returns `{cassette, operation_id, source, result}`. Before dispatch, tama-dex checks the cassette and scope visibility (`not_found` otherwise), the executor, input schema and confirmation presence, then dispatches once and validates the result. Errors carry `dispatched`. `dispatch_failed` and `invalid_output` are `dispatched: true`, keep `x-tama-identity` fields and must be reconciled, never retried. |

The executor still enforces each operation's own rules: `run/3` re-checks scope, confirmation value and host authorization, and the runtime executor enforces Swift preconditions. Access to `execute` therefore does not grant every operation. tama-dex imposes no deadline around an executor. Macus caps its own waits and returns `running` with operation or runtime identity. No per-operation MCP tools, dynamic plugin loader, second MCP service or Macus-owned search engine are introduced.

The Macus runtime document follows the profile:
- A graceful `macus_runtime_stop` is separate from a destructive, confirmed `macus_runtime_force_stop`.
- Runtime deletion takes a string `confirm` token that the executor maps to the private `{"confirm": true}`.
- Stopped-state preconditions are described in text and `x-macus-*` metadata, and the private API enforces them with 409.

Blocking releases: tama-dex, and the opsmaru_incus release that adds `Operations.openapi/0` and its cassette. The Macus document, `Operations.Host` and executors can be built and fixture-tested before then.

| Operation family | Owner / scope / delegation |
| --- | --- |
| Runtime status/config/progress/health/capabilities | Macus; `runtime.read`; Swift runtime adapter |
| Runtime create/start/stop/restart/config replacement | Macus; `runtime.write`; existing lifecycle API |
| Runtime deletion/forced stop | Macus; explicit destructive inputs and runtime permission |
| Incus inspection | opsmaru-incus; `incus.read`; shared client through configured incus.sock |
| Instance/state/image/snapshot mutation | opsmaru-incus; `incus.write`; same shared client |
| Bounded guest exec | opsmaru-incus; `incus.exec`; explicitly selected instance |
| Workload deletion/destructive restore | opsmaru-incus; `incus.delete`; explicit destructive inputs |

Macus's authorization adapter verifies its own bearer credentials and normalizes principal, scopes and expiry. Macus implements `Opsmaru.Incus.Operations.Host`: `binding/2` returns the local `incus.sock` connection and context for an authenticated caller, `authorize/3` applies Macus policy to the validated input, and `image_remote/2`/`allow_restricted?/3` deny by default unless Macus configures approved remotes. Request fields cannot substitute another owner, backend URL, socket or host path. Tool execution waits for host identity readiness; dependency load order cannot bypass gateway policy. Schemas carry no target ID; Macus has one local target. Macus-specific tools retain the stopped-state/configuration and explicit confirmation rules of the Swift runtime.

Register a Macus host adapter for passive Swift/runtime capabilities and directory-share prerequisites. The current Swift configuration update requires a stopped VM; unresolved new shares report that prerequisite rather than causing an implicit restart. This milestone does not provision worktrees, install skills or create environment images.

Operations execute synchronously. Incus mutations return the native operation identity and completed/running/failed/uncertain status after a bounded wait; runtime lifecycle tools report the Swift runtime's progress and readiness the same way. Callers poll later state by executing the operation and runtime status operations. No durable MCP task store, runner, journal or task handles are introduced; possibly accepted mutations are never retried automatically. A durable task layer can be added later around the same tools.

No generic host-shell operation, arbitrary HTTP operation, unsupported MCP resources/stdin transport, external database or clustered scheduler is introduced. Macus's authenticated Incus gateway retains its native API independently of the selected MCP catalogue.

### 7. Combined package, separate processes and startup ownership

Install one matched package at distinct paths:

```text
<prefix>/bin/macus                       Swift executable
<prefix>/libexec/macus/                  complete Elixir release
  bin/macus
  lib/, releases/, erts-*/
```

Both carry matched immutable Macus source revision/package version metadata. The server release also records its distinct pinned `:opsmaru_incus` dependency revision/version and backend-reference provenance; it does not compare two different repositories' commits for equality. Include the library in the existing Macus release. Build the release with bundled ERTS for the supported macOS ARM64 baseline and test that no installed Elixir/Erlang or sibling opsmaru-incus checkout is needed. Source builds document Swift plus pinned Elixir/OTP build prerequisites. The Homebrew bottle includes the complete release; startup does not fetch a separately versioned server payload. The release build obtains the tama-dex cassette in step with the locked library:
1. Read the locked `opsmaru_incus` version from `server/mix.lock`.
2. Download `opsmaru_incus-<version>.tama-cassette` and its `.sha256` from that upmaru/opsmaru-incus GitHub Release.
3. Verify the hash and the provenance attestation (`gh attestation verify --repo upmaru/opsmaru-incus`).
4. Bundle the file and record its SHA-256 in build metadata as the import pin.

Any failure fails the build. There is no hand-maintained second pin. Keep signatures, real hashes and build-platform provenance; development artifacts retain their honest ad-hoc status.

The Swift job keeps `com.upmaru.macus`; the Elixir job uses `com.upmaru.macus.server`. Nondefault states receive matched state-hash suffixes, isolated listeners/logs and no automatic login registration. Launch the Elixir release with `bin/macus start` in the foreground, with release distribution disabled unless explicitly needed; launchd supervises the OS process and OTP supervises internal workers. Elixir shutdown is independent of guest shutdown. Retain stable Homebrew opt paths for both jobs and verify their actual executables, full arguments, selected state and package metadata before reuse/kickstart.

Startup sequence inside the existing bootstrap lock and total budget:

1. Check arguments, host/VZ entitlement, source/package identity, complete installed release, endpoint/TLS configuration, safe state and client prerequisites before downloads.
2. Acquire/verify the appliance only for absent runtimes; preserve all current disk/config/recovery rules.
3. Prepare private gateway state/credentials and activate/reuse the private Swift job and public Elixir job. Service activation is idempotent, rejects conflicts and has one shared remaining deadline.
4. Wait for authenticated gateway availability with matching package/state identity. All normal lifecycle/health/progress requests now go through `/runtime`; launchctl activation and owner-local file administration are bootstrap mechanics, not a second public API.
5. Create/start the guest via the gateway, preserving `remaining_seconds`, expected-reboot behavior, progress and truthful live readiness. The gateway can be available while its guest is not ready.
6. Register the unmodified standard Incus client against the HTTPS server. Explicitly enroll its certificate through owner-approved gateway trust or an expiring single-use bootstrap enrollment token, verify the server certificate, and use standard remote commands. Prove connectivity with `incus list` and native upgrade checks in acceptance.
7. Report both service identities/ownership, public endpoint, live runtime readiness and client connection; retain existing JSON output and interruption semantics. Partial success is not a complete start.

No ordinary CLI request silently bypasses the gateway if it fails. Offline help/capabilities and local gateway administration remain possible. A missing server job is recoverable without restarting a ready VM. Missing/mismatched release files cause repair guidance rather than an unverified startup download.

Alternatives: making Swift supervise BEAM would couple server crashes to VM lifecycle. Running BEAM inside the Linux appliance would remove the selected native host service boundary. A separate user installation/download would undermine the agreed one-package installation contract.

### 8. Verification and integration with existing delivery work

Extend the root canonical check script to run strict Swift checks, Mix formatting/compilation/tests, proxy/auth/composed-MCP conformance fixtures and a release smoke check. Link pinned opsmaru-incus client/gateway/tool evidence independently and test its consumer bindings; do not rerun a Macus-owned duplicate implementation or count library evidence as real guest acceptance. Commit locks and required notices; ignore `server/_build`, `server/deps`, package outputs and `.integration`. Pin tools in mise and use the existing macOS CI boundary; no cross-platform host support is added.

Tests use fake Unix backends and actual TLS/HTTP clients to prove authorization-before-connect, route mapping, ETags/query preservation, body bounds, binary uploads, upgrades, half-close, event overflow, truthful tool results and service identity conflicts without VZ boot. Include standard Incus client interactions against an Incus-shaped fixture endpoint; library tests alone do not establish CLI compatibility.

Installed package checks verify both component revisions, full ERTS payload, passive installation, server startup in an isolated configuration and absence of host toolchain dependency. Real hardware acceptance must separately use the installed package and explicit opt-in, isolated state and `INCUS_CONF`, and prove Linux/Incus boot, actual system-container and OCI-container boot/readiness through the gateway, nested VM boot/readiness where supported or an explicit documented unsupported skip, native HTTP/exec/console/events, MCP inspection/mutations, repeated startup, server-only restart with a retained workload marker, runtime restart persistence, package upgrade/removal and a genuinely separate authenticated LAN/remote client. HTTP/MCP responses and capability reports cannot replace actual workload boot evidence. A loopback test is not remote-client evidence. Failures preserve owned runtime disks, workloads and diagnostics; no reset is used as a recovery shortcut.

The upstream reference and protocol documentation inform the port and native authentication behavior: [Incus client interfaces](https://github.com/lxc/incus/blob/main/client/interfaces.go), [Incus authentication](https://linuxcontainers.org/incus/docs/main/authentication/), [Phoenix headless generator](https://phoenix.hexdocs.pm/Mix.Tasks.Phx.New.html), [Mix release delivery](https://mix.hexdocs.pm/Mix.Tasks.Release.html). Pin exact source/package references for implementation; these moving documentation links are not build inputs.

### 9. Central registration (moved)

Central registration, `macus connect`/`connection status`/`disconnect`, the outbound connector and delegated execution moved to the later `add-central-registration` change on 2026-10-13. This change delivers a standalone Macus with no central dependency.

## Risks / Trade-offs

- Privileged Unix forwarding could defeat remote auth -> authenticate before backend access; enforce gateway trust and narrowly test all identity exceptions.
- Native certificate/address metadata describes the guest rather than the TLS gateway -> explicitly mediate transport identity/trust, preserve workload payloads and validate actual standard-client enrollment and migrations.
- SDK port breadth could be mistaken for raw proxy breadth -> separate coverage manifests and completion gates; do not declare parity from a subset.
- BEAM mailboxes or HTTP middleware can consume unbounded data -> bounded per-stream workers, route-specific body handling and saturation tests.
- Crashes can leave a mutation outcome unknown -> native operation IDs in tool results and explicit uncertainty instead of automatic replay; durable tasks are deferred.
- Two runtime processes and shared package upgrades add lifecycle coordination -> separate jobs, matching revision checks, stable paths and preserve-data rollback.
- Bearer credentials and TLS identity make LAN access a host trust boundary -> explicit configuration, private storage, scopes, revocation/expiry and separate remote-client evidence.
- Existing Homebrew work overlaps packaging requirements -> reconcile its final integrated contract during apply; do not rewrite another change or claim its incomplete acceptance here.

## Migration Plan

1. Integrate the released `:opsmaru_incus` Hex package (0.1.0 delivers the client, gateway and Incus operations) on `feature/elixir-server`. Gateway, runtime, client, the operations host and the Macus runtime document/executor proceed against it. The `search`/`execute` tool modules and index loading wait for tama-dex and the opsmaru_incus release that ships its profile document and cassette. Preserve completed tasks; new dependency/ownership tasks remain unchecked. Pass canonical consumer checks and installed-package evidence before deployment claims.
2. Keep existing VM state and Swift internal APIs. Install a complete matching package passively; do not create credentials or activate services during package installation.
3. Before replacing an existing installed version, stop the runtime explicitly and unload both owned services that exist. Retain disks, logs and gateway credentials. Do not auto-unload foreign or legacy registrations.
4. On explicit `macus start`, initialize gateway state only if absent, activate both verified jobs and connect through the public server. An existing named `unix:` remote remains a conflict: present an explicit owner-controlled transition or select a different remote name. Do not hand-edit or silently overwrite Incus client configuration.
5. Configure and verify remote HTTPS identity/enrollment only when remote exposure is requested. Retain loopback access for the local CLI and use the same authorized server routes for remote clients.
6. On failure, retain state and provide stage-specific guidance. Rollback stops/unloads the owned services and reinstalls the retained prior complete package. It must not downgrade/migrate guest disks or delete credential state. Document that the prior Swift-only package uses explicit legacy socket remotes rather than claiming it supports the new gateway.

## Open Questions

- The exact first deployment's LAN hostname, operator-supplied certificate and advertised address are configuration inputs, not fixed product requirements.
- Resolved 2026-11-12: `:opsmaru_incus` 0.1.0 from Hex, locked in `server/mix.lock`. Its coverage still reports `complete_port=false`, so complete-client claims (task 6.12) stay blocked on later library releases.
- Resolved 2026-11-12 (user confirmed): Macus loads the index at server start, stores it at `<state-dir>/server/tama-dex.sqlite3` and owns the two tool modules; see section 6. Importing the `opsmaru_incus` cassette always installs its `opsmaru_incus_native` source. Still open: whether and when Macus registers `opsmaru_incus_native` → `Macus.Dex.NativeExecutor` over `Opsmaru.Incus.NativeOperations.run/3` (same `host:`, `call.context.caller` and `call.scopes`) and grants `incus.native.*` scopes, which the curated scopes never imply. Until then, Macus never grants `incus.native.*`, so native operations stay hidden and no caller can reach a `no_executor` result. Once registered, the proposed default is to grant those scopes only when explicitly requested at token issuance.
- Cross-machine LAN acceptance requires an owner-supplied isolated remote test client. Until that evidence is available, mark that acceptance task incomplete rather than infer it from loopback success.
