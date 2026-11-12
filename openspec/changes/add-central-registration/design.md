# Design

## Context

Split out of `add-elixir-server` on 2026-10-13. That change now delivers a standalone Macus: one authenticated gateway serving `/runtime`, native Incus (via the `:opsmaru_incus` gateway) and `/mcp` (shared `:opsmaru_incus` Incus operations plus Macus runtime tools), with no durable tasks and no central dependency. The section below is the registration design as previously approved, kept unchanged for later revision.

Central Opsmaru (`upmaru/opsmaru`) is the multi-target service. It operates registered Incus targets with the same `:opsmaru_incus` operations Macus exposes locally.

## Goals / Non-Goals

**Goals:** explicit, reversible registration of one Macus installation; central operation of its Incus under combined central and local limits; no effect on standalone use.

**Non-Goals:** automatic registration, a third service or inbound port opened by Macus, central identity as local owner authority, or Macus becoming a multi-target controller.

## Decisions

### 1. Transport (open; decide when this change is revised)

Macus's gateway already serves the native Incus API over HTTPS with certificate trust. A reachable Mac (LAN, VPN, tailnet) can therefore be registered as an ordinary direct-HTTPS Incus target: central receives a client certificate trusted by the Macus gateway, limited to approved projects, and uses the same `:opsmaru_incus` HTTPS path it uses for clusters. No connector is needed. A Mac behind NAT needs the outbound connector below. Prefer direct HTTPS first; the connector protocol is only needed for the NAT case.

### 2. Enrollment and outbound connection (carried from add-elixir-server)

`macus connect [url]` enrolls only the selected Macus state/installation. First use requires an explicit canonical HTTPS Opsmaru base URL; subsequent use may omit it to resume the saved registration. Reject malformed URLs, userinfo, query/fragment secrets, untrusted TLS identity and unapproved redirects before credential/state changes. Repeating the same URL and active target/device registration is idempotent. A different service requires explicit disconnect before enrollment; never silently transfer keys, owner grants or pending tasks to it.

The Swift executable performs argument/output/deadline handling and invokes owner-authenticated Macus connection administration; the Elixir server uses shared Opsmaru/OAuth primitives for enrollment and connection work. Explicit connect may validate and activate/recover only the installed matching Elixir job through existing launchd identity/state checks. It must not fetch software, activate Swift/VZ, boot/provision an appliance, change shares, enroll a native Incus CLI remote or open an inbound port. Local connection configuration sits below `<state-dir>/server/connection/` with 0700 directory/0600 private files and safe ownership/ancestry. The same two service labels are retained; no connector daemon/job is installed.

Read trusted central protected-resource/enrollment metadata and perform the pre-registered public CLI Device Authorization Grant with the external provider. Display the verification URI/user code and open the system browser only for this explicit command; user code display is deliberate enrollment UI, while device/API tokens and secrets stay out of logs/normal output. The Elixir server bounds polling, denial, expiry and one overall monotonic connect deadline using the designated TamaOAuth primitives. Keycloak is the first acceptance profile; missing library/provider support is resolved upstream or reported as unsupported, with no password collection or insecure TLS/auth fallback. Initial central registration requires the user's target-enrollment scope and policy, never just a successful provider login.

Generate the installation's device certificate/private key locally, prove possession against central's one-use challenge and explicitly approve the target's project/operation limits. Retain the private key here; central receives its public certificate/fingerprint only. Persist pending enrollment identity/challenge receipt safely before completion so a lost response can recover the same committed target/generation without duplicating registration. On denial/cancellation, disable any incomplete connector activation and report pending remote outcome truthfully without changing workloads; never adopt an unverified target identity. User API/refresh tokens are transient setup material and are not retained for reconnect.

After verified enrollment, atomically persist the canonical central URL/trust, target/generation, private device credential reference and maximum approved capability/project policy, then enable shared outbound TLS/WebSocket workers inside Macus's existing Elixir server. A saved active registration reconnects automatically on server restart with device trust; it never needs a stored user password or OAuth refresh token. The local HTTPS listener stays loopback unless separately configured, with no firewall/NAT changes. Connector heartbeat reports transport reachability separately from guest readiness; an absent/stopped guest can be registered for explicitly permitted runtime actions without automatically starting it.

Macus verifies central service identity, session/generation, negotiated operation descriptor and locally approved permissions before every delegated dispatch. Central supplies a verified external principal/owner context over the authenticated session; it is namespaced by central service and subject and cannot become the local owner or access local standalone tasks. The descriptor routes native Incus calls through the same incus.sock client and Macus runtime calls through the same Swift adapter, preserving stopped-state/share prerequisites, force/confirmation flags and bounded budgets. No unrestricted host command, target URL, remote module loading, key/trust administration or path override is accepted.

Central keeps its user task in SQL; Macus commits the linked dispatch ID/input digest and execution receipt in its existing shared journal before acknowledgement. Repeated dispatch reconciles that receipt, not another runner or local user task. Persist native operation IDs and observed runtime outcomes; possible acceptance with no durable outcome remains uncertain. Status/result/cancel/stream messages are versioned, correlated and bounded; lost replies/reconnect do not replay mutations. Per-capability native binary/control/half-close evidence is mandatory before advertising connector stream support.

`macus connection status [--json]` is passive. It reports configured/enrolled/transport-connected/backend-ready state, central URL, target/generation, sanitized last contact/error and revocation-pending status, without credentials. Missing registration succeeds with an explicitly disconnected state and creates no files or services. Central outage marks connection unavailable while local runtime/native Incus/MCP and normal `macus start` remain usable; it cannot force-start or stop the VM.

`macus disconnect` first durably disables local reconnect, closes its outbound session/streams and blocks new central dispatch. It then attempts central device revocation within a bound. If central is unavailable, report local disconnection plus remote-revocation-pending instead of claiming remote revocation; preserve the pending identity/receipt needed for later explicit reconciliation. Repeating disconnect is idempotent. Accepted backend work, local gateway trust, native CLI remotes, VM disks/workloads, local tasks and linked receipts remain intact. Re-enrollment after confirmed revocation requires a new approved generation and never reassigns old accepted work. Central device revocation similarly closes remote delivery within the shared 30-second maximum; local gateway revocation keeps its existing 5-second bound.

The owner can narrow or disable enrolled capabilities independently of central grants. Unknown/incompatible operation versions fail explicitly; connector failure is isolated from the public gateway and Swift runtime. Packaging is passive and starts no connection; `macus start` may resume an already enrolled connector asynchronously but never enrolls one or waits for central readiness as a local-success prerequisite.

Alternative: forwarding all central calls through a local owner-admin HTTP token would erase external caller/target restrictions. The enrolled connector carries constrained operation context and uses the existing shared runner/adapters instead.

## Risks / Trade-offs

- Connector outage/re-enrollment repeats a mutation -> durable dispatch receipts, target generation fencing and uncertainty before any retry.
- Central identity becomes local owner authority -> separate delegated owner namespace, approved project/operation limits and local schema/lifecycle checks.
- Offline disconnect is reported as globally revoked -> immediate durable local disable plus explicit pending central revocation and retained reconciliation identity.

## Migration Plan

Revise this change when central registration is scheduled: settle the transport decision, the durable task dependency and the central contracts, then implement on its own feature branch after `add-elixir-server`.
