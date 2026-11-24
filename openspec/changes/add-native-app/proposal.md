# Proposal

## Why

Everything Macus knows is reachable only from a terminal. An owner who wants to see what is running, who is using the gateway and what the agents inside an instance are doing must combine `macus runtime status`, `incus list`, `incus exec … ps` and, once `add-gateway-access-log` lands, `macus server logs --follow`. None of these stays on screen, and none shows the three together.

Two things are missing:

- **A place to look.** A native macOS application can present runtime state, instances, the processes inside them and the access log in one window.
- **A way to be told.** The server answers questions; it does not announce changes. A client that wants current state must ask repeatedly. The server is a Phoenix application with `Macus.PubSub` already supervised and unused. Phoenix Channels over that PubSub give every observer the same real-time feed, with the server watching each source once however many clients are connected.

This change reverses a standing rule. `AGENTS.md` says never to introduce GUI requirements and `openspec/config.yaml` says "No … GUI". The rule's purpose is kept: the runtime, the services and installation stay headless and never depend on an application. What changes is that an optional client application may exist.

## What Changes

- **A live channel on the gateway.** The server mounts one Phoenix Channels socket at `/live`. Topics carry runtime state, the instance list and one instance's processes and resource use. Each source is observed once by the server and published on `Macus.PubSub`; observation runs only while a topic has subscribers. The channel is read-only: it accepts no client event that changes anything.
- **The channel uses the gateway's existing credentials.** The `runtime` topic needs a bearer credential with `runtime.read`, as `/runtime` does. Topics that carry Incus data need a client certificate in gateway trust, as native `/1.0` does. Revocation closes the socket within the existing bound. No new scope or credential type.
- **The Swift daemon announces state changes.** A private streaming route on `runtime.sock` emits runtime state transitions, so the server does not sample status.
- **An optional `Macus.app`.** A SwiftUI application for macOS 15+, built from this SwiftPM package as a separate product. It is a client only: it never links Virtualization.framework, never owns the VM or a launchd job, and quitting it changes nothing.
- **The app does not poll.** Overview, instance list and process views are driven by channel pushes. It reconnects when the server publishes its endpoint, not on a timer.
- **It has its own gateway identity.** The app generates its own key and certificate and enrolls it through the existing single-use bound enrollment token, after the owner confirms once. The owner can revoke it without affecting the `incus` CLI.
- **Inside an instance.** A live process list with known agent programs grouped first, with their working directory, age and resource use; and an interactive terminal over the native exec WebSocket.
- **Access log.** A live, filterable table over the access log files, readable while the server is stopped.
- **Read-only in this change.** The app does not start, stop, create, delete or configure instances, and does not start, stop, reset or upgrade the runtime. The terminal is the one place the owner can act, and what they do there is their own Incus exec session.
- **Project rules updated.** `AGENTS.md`, `openspec/config.yaml` and `service-delivery` state the new boundary: headless runtime and installation, optional client application.

## Capabilities

### New Capabilities

- `native-app`: the optional macOS application, its connection and identity, its views and its read-only boundary.

### Modified Capabilities

- `server-gateway` (introduced by the unarchived `add-elixir-server` change): adds the live channel, its authorization and its bounds. `/live` joins `/runtime`, `/1.0` and `/mcp` as a public route.
- `incus-transport`: adds the private runtime state stream.
- `service-delivery`: the package gains an optional application product; the `macus` executable and headless installation are unchanged.

## Impact

- **Depends on** `add-elixir-server` (gateway, trust, enrollment; implemented, unarchived) and `add-gateway-access-log` (the log and its Swift reader). The access log view cannot be implemented before the latter; everything else can.
- **Server:** `MacusWeb.LiveSocket` and channels for `runtime`, `instances` and `instance:*`; `Macus.Live` observers (runtime stream reader, Incus events subscriber, per-instance process stream) under a supervisor that starts them on first subscriber and stops them after the last; registration with the stream revocation watchers. No new dependency: Phoenix Channels and PubSub ship with Phoenix.
- **Swift daemon:** `GET /v1/runtime/events` on `runtime.sock`, and `Macus.Runtime.Client` support for reading it.
- **Swift package:** two new targets. `MacusAppCore` (models, channel client, native transport, log tailing; no SwiftUI) and `MacusApp` (SwiftUI executable). One new dependency, SwiftTerm, used only by `MacusApp`. The `Macus` library exposes what the app reuses as public API; `Macus` and `macus` gain no UI code or dependency.
- **Packaging:** a script assembles and ad-hoc signs `Macus.app` from the SwiftPM build. The Homebrew formula is unchanged and does not install the app. A cask, Developer ID signing and notarization remain future scope.
- **Guest:** not changed.
- **Documentation:** `docs/app.md`, `docs/api.md` (the live channel and its topics), `docs/server.md`, `docs/architecture.md`, `README.md`, `AGENTS.md`, `openspec/config.yaml`.
- **Acceptance:** the server channels and `MacusAppCore` are unit-tested against fixtures. The application and the live channel on real hardware are accepted by an opt-in run on isolated state, recorded apart from unit test success.
