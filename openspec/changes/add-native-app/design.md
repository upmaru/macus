# Design

## Context

See [proposal.md](proposal.md). Today's client is the `macus` CLI. It reads `STATE/server/endpoint.json` and `local-cli.token` (`GatewayEndpoint.discover`), pins the server's leaf certificate over TLS 1.3 (`HTTPSGatewayClient`) and calls `/runtime` with a bearer credential. Native Incus `/1.0` is a different door: `Macus.Proxy.Host` admits a caller only by a client certificate in gateway trust. `macus client setup` enrolls the `incus` CLI's certificate with a single-use token bound to that certificate's fingerprint (`TrustTokenStore.issueBound`).

The server is Phoenix 1.8 on Cowboy. `Macus.Application` already supervises `{Phoenix.PubSub, name: Macus.PubSub}` and the endpoint is configured with it, but nothing publishes or subscribes and no socket is mounted. Every public request enters one Cowboy TLS listener; `Opsmaru.Incus.Gateway.CowboyHandler` serves native raw upgrades and hands everything else to `MacusWeb.Endpoint`. `Macus.Auth.Streams` closes streams of a revoked bearer credential within 5 seconds. `Macus.Runtime.Client` makes passive requests to Swift's `runtime.sock`, whose routes are request/response only.

`add-gateway-access-log` adds `STATE/logs/gateway-access.log`, one JSON line per finished exchange with schema version `v`, rotated by size, and a Swift reader for `macus server logs`.

## Goals / Non-Goals

**Goals:** one window that shows runtime state, instances, the processes and agents inside an instance, a terminal into an instance and the gateway access log; updates pushed by the server, never polled by the client; built with the project's toolchains; no effect on a headless install.

**Non-Goals:**

- Managing workloads (create, start, stop, delete, configure, snapshot, file transfer). These stay with standard Incus clients.
- Runtime lifecycle from the app (`start`, stop, restart, reset, upgrade, gateway configuration, token administration).
- Client-to-server commands on the live channel. It is a feed.
- Remote Macus hosts for the app. The channel is reachable wherever the gateway is; the app serves the state directories of the logged-in user on this Mac.
- A menu bar item, notifications, launch at login.
- App Store distribution, sandboxing, Developer ID signing, notarization, a Homebrew cask.
- iOS, iPadOS or any other platform.

## Decisions

### 1. SwiftUI, in this SwiftPM package

| Option | Verdict |
| --- | --- |
| **SwiftUI app as SwiftPM targets in this package** | Chosen. Reuses `GatewayEndpoint`, the pinning code, trust stores and the log reader directly; one toolchain, one `check.sh`, strict Swift 6 concurrency throughout. |
| Xcode project in or beside the repository | Rejected. Adds a second build system the canonical checks do not cover. SwiftPM cannot produce a bundle, but a short script can (decision 10). |
| Web UI served by Phoenix (LiveView) | Rejected. Adds HTML, session auth and assets to the gateway; cannot read the log when the server is stopped; is not what was asked for. The live channel in decision 3 would serve one later. |
| Tauri/Electron | Rejected. A second runtime and none of the Swift reuse. |
| Terminal UI in `macus` | Rejected. Grows the executable that is meant to stay small. |

Targets:

- `MacusAppCore` (library): discovery, channel client, native transport, exec, log tailing, and `@Observable` view models. Depends on `Macus`. No SwiftUI or AppKit, so it is unit-testable.
- `MacusApp` (executable): SwiftUI scenes and views, plus the SwiftTerm view. Depends on `MacusAppCore`.

`Macus` and `MacusCommand` gain no dependency on either. VZ code stays in `Sources/Macus/Virtualization` and the app never calls it.

### 2. Client of the public gateway only

The app uses what the CLI uses: `endpoint.json`, the pinned certificate, TLS 1.3, no system trust, proxies, cookies or redirects. It does not open `runtime.sock` or `incus.sock`, and does not run `macus` or `incus` as a subprocess. A missing endpoint is shown as "Macus is not set up here; run `macus start`", not repaired.

### 3. Server push over Phoenix Channels, not client polling

The first draft of this design had the app poll `/runtime/status` every 5 s, refresh resource figures every 10 s and run a process-listing exec every 5 s per open view. That makes every client pay for every refresh, multiplies with clients, and shows changes late. It is replaced.

| Option | Verdict |
| --- | --- |
| **Phoenix Channels on a `/live` socket, fed by `Macus.PubSub`** | Chosen. Both ship with Phoenix and PubSub is already supervised. One socket multiplexes topics, with join authorization, heartbeat and presence of subscribers built in. Each source is observed once and fanned out. |
| Server-Sent Events under `/runtime/events` | Rejected. One connection per topic, no join-time authorization per topic, and Incus data would sit under a runtime path. |
| The app holding its own native `/1.0/events` WebSocket | Rejected as the main path. It covers instance lifecycle only; runtime state and processes would still be polled, and every client repeats the subscription. |
| Client polling | Rejected, above. |

**Socket.** `socket "/live", MacusWeb.LiveSocket, websocket: [connect_info: [:peer_data, :auth_token], …], longpoll: false` in `MacusWeb.Endpoint`, before the router. The WebSocket path is `/live/websocket`. Long polling is disabled: it would be polling by another name. Frame size, idle timeout and the number of sockets are bounded (64 KiB client frames, 60 s without heartbeat, 32 sockets).

**Topics.**

| Topic | Join reply | Pushes | Source |
| --- | --- | --- | --- |
| `runtime` | current status | `status` on every state transition | Swift runtime state stream (decision 5) |
| `instances` | all instances, all projects | `upsert`, `remove` | one Incus events subscription held by the server |
| `instance:PROJECT:NAME` | latest process and resource snapshot, or why none | `snapshot`, `unavailable` | one streaming exec per watched instance (decision 7) |
| `access` | the most recent 200 records | `records` (a batch) | the access log's telemetry handler (decision 9) |

Payloads are versioned with `v`, like the access log. Uptime is not pushed: the status carries the start time and the client counts.

**Observers.** `Macus.Live` holds one observer process per source under a `DynamicSupervisor`. An observer starts when its topic gets its first subscriber and stops a short grace period (5 s) after its last, so nothing is watched when nobody is looking and a quick rejoin does not restart the source. Observers broadcast on `Macus.PubSub`; channels only forward. An observer that crashes is restarted with backoff and its topic receives `unavailable` with a reason, never silence presented as current.

**Read-only.** Channels implement `join` and reject every other client event. Nothing on the socket can reach a mutation.

**Not in the access log.** `/live` is not a native Incus exchange and is not recorded there, like `/runtime` and `/mcp`.

**Client.** `MacusAppCore` implements the Phoenix Channels V2 JSON protocol on `URLSessionWebSocketTask` with the pinning delegate: join, reply matching, the protocol heartbeat, rejoin with capped backoff. It is about one file; a third-party client library is not justified and would have to meet strict Swift 6 concurrency.

**Reconnecting without a timer.** When the socket cannot connect because the server is down, the app watches `STATE/server/endpoint.json` with a file-system event source and connects when the server publishes it. Backoff applies only to a server that is published but refusing.

### 4. Channel authorization reuses the gateway's two rules

The gateway already has two rules: runtime requests need a scoped bearer credential; native Incus needs a trusted client certificate. The socket applies both, per topic, and adds nothing.

- **Connect** accepts a bearer credential, a trusted client certificate, or both. The bearer token travels in the WebSocket subprotocol header through Phoenix's `auth_token` option, never in the URL. The certificate is the TLS peer certificate from `peer_data`. A connection with neither valid is refused before any topic exists.
- **`runtime`** requires a bearer credential with `runtime.read`.
- **`instances`** and **`instance:*`** require a certificate in gateway trust. A bearer credential alone does not open them, exactly as it does not open `/1.0`.
- **`access`** requires the owner-local credential: the bearer credential whose principal is `macus-local-cli`, which `macus start` writes to the 0600 `STATE/server/local-cli.token`. Access records name every caller and every path, and today only the owner of the state directory can read them. Whoever can read that token can read the log file, so this rule opens the records to nobody new. A trusted certificate or any other bearer credential, including one with `runtime.read`, is refused: a remote client must not learn what other callers do.
- **Revocation.** The socket registers its bearer credential with `Macus.Auth.Streams` and its certificate with the proxy's trust revocation, so removing either closes the socket within the existing documented bound.

Observers read Incus through the server's own client on `incus.sock`, as `/mcp` execution does. That is why authorization is checked at join, before a subscriber can cause any backend access.

### 5. Runtime state stream from Swift

The server needs to be told about state changes, or it would poll `runtime.sock` on the app's behalf. The daemon gains `GET /v1/runtime/events`: a chunked response of newline-delimited JSON on the private socket, one object with the full status on connect and one on every transition of `RuntimeState`. The `RuntimeService` actor already owns every transition, so it yields to registered continuations where it assigns state. The stream is bounded to 8 concurrent readers and sends a comment line every 30 s so a dead peer is detected.

`Macus.Runtime.Client` gains a streaming read used only by the `runtime` observer. The route is private: it is not added to the public `/runtime` API.

### 6. The app's own identity, enrolled once with consent

The app needs a certificate in gateway trust for the Incus topics and the terminal.

- **Rejected: reuse the `incus` CLI's key** from `INCUS_CONF`. Revoking one would revoke both, and the app would read another program's private key.
- **Rejected: a bearer scope that admits Incus observation.** It changes the gateway's authentication model for one client.
- **Chosen: a dedicated identity.** On first use the app generates a P-256 key and a self-signed certificate named `Macus.app`. When the owner clicks *Connect to workloads*, it issues a bound enrollment token through `TrustTokenStore.issueBound` (owner-local file administration, as `macus client setup` does) and redeems it with the native enrollment request. An unredeemed token is revoked. Nothing is enrolled before the click; until then the app joins `runtime` with the local CLI credential and shows the access log.

The key and certificate are stored as 0600 files in a 0700 directory, `~/Library/Application Support/Macus/app-identity/`, one identity for all state directories. The Keychain was considered and deferred: with ad-hoc signing each rebuild is a different code identity and would prompt or lose access.

If the certificate is later removed from trust, the socket closes. The app returns to the *Connect* state and does not re-enroll itself.

### 7. Looking inside an instance

**Processes without repeated exec.** Neither Incus nor Linux offers a subscription to a process table, so something must sample it. The sampling happens once, inside the instance, not per client and not per request: the `instance:*` observer starts **one** non-interactive exec of a fixed POSIX `sh` script that loops, every 2 s reading `/proc/[0-9]*/{stat,status,cmdline}`, `readlink`ing `cwd`, reading the instance's CPU and memory counters, and writing one length-prefixed snapshot to stdout. The observer parses each snapshot and broadcasts it only when it differs from the last. When the last subscriber leaves, the observer closes the exec and the loop ends with it.

- Reading `/proc` directly avoids depending on `ps`, whose flags differ between procps and BusyBox.
- The script is a constant. Nothing a client sends is interpolated into it; the project and instance names from the topic are validated against the instance list and passed as API path segments only.
- Bounds: 1 MiB per snapshot, 8 watched instances at once, 4,096 processes per snapshot (further ones counted, not listed).
- Unavailable cases are pushed as `unavailable` with a reason: instance not running, no `sh` in the image, a VM without the Incus agent, exec ended.

**Agents.** "Agent" here means (confirmed by the owner, 2026-11-23) a process whose executable or first argument matches a list of known agent programs. The default list is `claude`, `codex`, `gemini`, `opencode`, `aider`, `amp`, `goose`, and is editable in the app's Settings. Matching is done in the app, so the server stays a neutral feed. Matching processes are grouped at the top with PID, command, working directory, age, CPU time and resident memory; their child processes are nested under them. This is observation only: nothing can signal a process.

**Terminal.** An interactive exec over the native `/1.0` WebSockets with a PTY, opened by the app with its own certificate and rendered by SwiftTerm, with window-resize control messages. This is not on the live channel: it is an Incus stream and stays native. The command is the instance's login shell (`su -l` for the selected user, default root, falling back to `sh`). It opens only when the owner clicks *Open shell*, closes with its view, and is limited to four concurrent sessions. It is recorded in the access log under the app's certificate.

### 8. Views

A `NavigationSplitView` with three sidebar entries.

- **Overview.** The `runtime` topic. Three distinct conditions: server not reachable, server up with runtime absent/stopped/booting/failed (with the failure reason), runtime ready (state, uptime, Incus version, CPUs, memory, disk, endpoint URL). No controls.
- **Instances.** The `instances` topic. Columns: name, project, type (container/VM), status, image. Addresses and resource use change without a lifecycle event, so they are shown in the instance detail, from its live snapshot, not in the list.
- **Instance detail.** *Summary*, *Processes* (joins `instance:PROJECT:NAME` while visible, leaves when hidden), *Terminal*.
- **Access log.** Decision 9.

One state directory per window: the default, or `--state-dir DIR`, or the one picked in Settings. The CLI's ownership checks apply unchanged because the same functions are called.

### 9. Access log: a topic for live records, the files for history

**Record identity.** To merge a pushed record with the same record read from a file, each record needs an identity. Every record carries `"id": "BOOT-SEQ"`, directly after `v`: `BOOT` is 64 random bits chosen when `Macus.Proxy.AccessLog` starts, as 16 lowercase hex digits, and `SEQ` is a decimal counter from 1. The key is added by `add-gateway-access-log` itself (its task 2.7), at this change's request, and keeps that log's schema version at 1. `SEQ` is taken when the exchange's stop event is handled, before the decision to drop, so within one boot a gap marks a record that was not written, whether dropped under overload or lost to a formatting error. Concurrent exchanges can reach the file slightly out of `SEQ` order, so a reader orders by `id` within a boot and does not rely on file order.

**Publishing.** Where the telemetry handler formats a line (`AccessLog.line/5`), it also broadcasts the same map, with exactly the documented keys and nothing else, on `Macus.PubSub`. A broadcast is a message send: it does not wait for a subscriber or for the disk, so the access log's rule that recording never holds up an exchange is kept. A small server process keeps the last 200 records in memory for the join reply and coalesces pushes into batches of at most 200 records or 100 ms, so a burst of requests is one frame, not hundreds. A subscriber whose outbound queue passes a bound is disconnected and can rejoin; it never slows the handler.

The topic carries exactly the records the handler formats. A record the handler drops is neither written nor pushed; subscribers see it as a `SEQ` gap and as `dropped_before` on the next record, the same as a reader of the file. The handler's drop branch returns before formatting, and building a record there only to push it would add work at the moment the server is overloaded.

**The app.** The files remain necessary: they hold history and they work when the server is stopped, which a channel cannot. So the view has two inputs and one table keyed by `id`:

- On open it loads history from the files.
- While joined to `access`, new rows come from the topic, and the join reply's 200 records close the gap between the file read and the join. Duplicates are dropped by `id`, and rows of one boot are ordered by `SEQ`.
- While not joined (server stopped, or the socket is down), it follows the files with a file-system event source. Neither path is polling.
- A record with no `id` (written before this change) can only come from a file and is keyed by its position.

For the files it uses the reader `add-gateway-access-log` adds for `macus server logs` (ownership validation, archives oldest first, follow across rotation). That reader, `GatewayAccessLog` in `Sources/Macus/Client`, is internal to the `Macus` module; this change makes the part the app needs public (task 1.3).

- Loads the most recent 5,000 records and follows new ones. The oldest rows are discarded past 50,000.
- Columns: time, caller, method, path, status, outcome, duration, bytes in/out. Caller is a short fingerprint, replaced by a name when it is the app's own or matches a gateway trust entry.
- Filters: text over path, caller, outcome, protocol. A `dropped_before` marker is its own row.
- A record with a higher `v` than the app knows is shown from the keys it understands; a malformed line is skipped and counted.
- A missing file is an explained empty table. An unsafe directory is an error and nothing is read.

### 10. Building and delivering

`swift build -c release --product MacusApp` produces a plain executable. `Packaging/app/build-app.sh` assembles `Macus.app` (executable, `Info.plist` with bundle identifier `com.upmaru.macus.app` and `LSMinimumSystemVersion` 15.0, icon), then ad-hoc signs it. No entitlements are needed: the app is not sandboxed (it must read the state directory) and uses no VZ.

The Homebrew formula keeps installing only `macus` and the server release. Installing or removing the app never touches state, launchd jobs or gateway trust; removing its trust entry is done by the owner with a standard Incus client (`incus config trust remove`), which the gateway serves from its own trust store.

The live channel ships with the server release whether or not anyone builds the app.

### 11. Concurrency and testing

- **Server:** `Phoenix.ChannelTest` for connect and join authorization (each credential combination against each topic, including `access` refused to every credential but the owner-local one), rejection of client events, payload shapes, revocation closing the socket, observers starting on first join and stopping after the last, the snapshot parser, and every bound. Observers take their source as a behaviour so tests feed them fixtures.
- **Swift daemon:** the events route emits on each transition, enforces its reader bound and releases a reader that disconnects.
- **App:** view models are `@MainActor @Observable`; clients are actors or `Sendable` structs behind protocols. `MacusAppCore` tests cover discovery failures, enrollment, the channel protocol (join, reply, heartbeat, rejoin), reduction of `upsert`/`remove`/`snapshot` pushes, agent matching, exec framing and log tailing across rotation. A test asserts the app schedules no repeating timer for data.

`Integration/scripts/check.sh` and `check-server.sh` cover the new code. There are no UI snapshot tests in this change.

## Risks / Trade-offs

- **A new public route.** `/live` is new surface on the security boundary. Mitigation: no new credential type or scope; authorization per topic by the two existing rules; read-only channels; bounded sockets and frames; the same revocation bound.
- **The Phoenix socket behind the shared Cowboy handler is unproven here.** Non-native requests reach `MacusWeb.Endpoint` as a plug, and Phoenix upgrades through the plug adapter, but this path has only carried HTTP so far. Mitigation: task 2.1 proves the upgrade through the real listener before anything is built on it.
- **Server-side observation acts with the server's Incus access.** A subscriber causes an exec in an instance. Mitigation: only a trusted certificate can join those topics, which already permits exec; the script is fixed; watched instances are bounded.
- **Process observation is still sampling.** It is one loop per watched instance instead of one request per client per interval, and it stops with the last subscriber, but a 2 s loop runs in the instance while someone is watching.
- **The sampling exec is not in the gateway access log**, because it does not pass through the gateway. Mitigation: the server logs when an instance observer starts and stops, and for which certificate.
- **Two inputs to one table.** The access view merges a topic and files. Mitigation: one key (`id`), one rule (first seen wins), and tests for join during a burst, rejoin after a gap and rotation.
- **Coupling to an unarchived change.** The `id` key and the Swift reader belong to `add-gateway-access-log`. Mitigation: the key is implemented there; task 2.9 confirms it is merged before the topic is built.
- **SwiftTerm is a new dependency.** Pinned exactly, linked only into `MacusApp`.
- **Ad-hoc signing.** Gatekeeper will not open a copied build without the owner's override. Documented; the supported path in this change is building locally.
- **Rule reversal invites scope growth.** The `native-app` spec states the read-only boundary as a requirement, so a workload or lifecycle control needs its own change.

## Open Questions

- **Remote readers of `access`.** The topic is owner-local. Letting a remote operator follow access records would need a new bearer scope and its own review.
- **Runtime start/stop in the app.** Left out. `start` activates launchd jobs and may bootstrap; it deserves its own change with its own confirmation rules.
- **Menu bar status item.** Cheap once the `runtime` topic exists; left out to keep the first version to one window.
- **Other subscribers.** `macus runtime status --watch` and a central connector could use the same topics. Not in this change.
