# Proposal

## Why

Everything Macus knows is reachable only from a terminal. An owner who wants to see what is running, who is using the gateway and what the agents inside an instance are doing must combine `macus runtime status`, `incus list`, `incus exec … ps` and, once `add-gateway-access-log` lands, `macus server logs --follow`. None of these stays on screen, and none shows the three together.

The data is already available to a same-user client:

- `/runtime` gives runtime state through the pinned HTTPS gateway.
- Native `/1.0` gives instances, their state, events and exec, to any certificate in gateway trust.
- `STATE/logs/gateway-access.log` (from `add-gateway-access-log`) is an owner-private file with a versioned line schema.

A native macOS application can present these without adding a server route, a daemon or a workload operation.

This change reverses a standing rule. `AGENTS.md` says never to introduce GUI requirements and `openspec/config.yaml` says "No … GUI". The rule's purpose is kept: the runtime, the services and installation stay headless and never depend on an application. What changes is that an optional client application may exist.

## What Changes

- **An optional `Macus.app`.** A SwiftUI application for macOS 15+, built from this SwiftPM package as a separate product. It is a client only: it never links Virtualization.framework, never owns the VM or a launchd job, and quitting it changes nothing.
- **It connects the way the CLI does.** It discovers `STATE/server/endpoint.json`, pins the published certificate and uses the local CLI credential for `/runtime`. It opens neither private Unix socket and runs neither `macus` nor `incus`.
- **It has its own gateway identity.** Native `/1.0` requests need a trusted client certificate. The app generates its own key and certificate and enrolls it through the existing single-use bound enrollment token, after the owner confirms once. Its requests then appear in the access log under its own fingerprint, and the owner can revoke it without affecting the `incus` CLI.
- **Runtime overview.** State, uptime, Incus version, resources, endpoint and failure reason, with the server-down and runtime-stopped cases shown distinctly.
- **Instances.** Containers and VMs across projects with type, status, image, addresses and resource use, kept current from the native events stream.
- **Inside an instance.** A process list read through native exec, with known agent programs grouped and shown first with their working directory, age and resource use; and an interactive terminal over the native exec WebSocket.
- **Access log.** A live, filterable table over the access log files, readable while the server is stopped.
- **Read-only in this change.** The app does not start, stop, create, delete or configure instances, and does not start, stop, reset or upgrade the runtime. The terminal is the one place the owner can act, and what they do there is their own Incus exec session.
- **Project rules updated.** `AGENTS.md`, `openspec/config.yaml` and `service-delivery` state the new boundary: headless runtime and installation, optional client application.

## Capabilities

### New Capabilities

- `native-app`: the optional macOS application, its connection and identity, its views and its read-only boundary.

### Modified Capabilities

- `service-delivery`: the package gains an optional application product; the `macus` executable and headless installation are unchanged.

## Impact

- **Depends on** `add-elixir-server` (gateway, trust, enrollment; implemented, unarchived) and `add-gateway-access-log` (the log and its Swift reader). The access log view cannot be implemented before the latter; the other views can.
- **Swift package:** two new targets. `MacusAppCore` (models, gateway and Incus clients, log tailing; no SwiftUI) and `MacusApp` (SwiftUI executable). One new dependency, SwiftTerm, used only by `MacusApp`. The `Macus` library exposes what the app reuses (`GatewayEndpoint`, pinned transport, trust token issuance, the access log reader) as public API; `Macus` and `macus` gain no UI code or dependency.
- **Packaging:** a script assembles and ad-hoc signs `Macus.app` from the SwiftPM build. The Homebrew formula is unchanged and does not install the app. A cask, Developer ID signing and notarization remain future scope.
- **Server and guest:** not changed. No new route, scope or guest payload.
- **Documentation:** `docs/app.md`, `docs/architecture.md`, `README.md`, `AGENTS.md`, `openspec/config.yaml`.
- **Acceptance:** `MacusAppCore` is unit-tested against fixtures. The application itself is accepted by an opt-in hardware run on isolated state, recorded apart from unit test success.
