# Design

## Context

See [proposal.md](proposal.md). Today's client is the `macus` CLI. It reads `STATE/server/endpoint.json` and `local-cli.token` (`GatewayEndpoint.discover`), pins the server's leaf certificate over TLS 1.3 (`HTTPSGatewayClient`) and calls `/runtime` with a bearer credential. Native Incus `/1.0` is a different door: `Macus.Proxy.Host` admits a caller only by a client certificate in gateway trust. `macus client setup` enrolls the `incus` CLI's certificate with a single-use token bound to that certificate's fingerprint (`TrustTokenStore.issueBound`).

`add-gateway-access-log` adds `STATE/logs/gateway-access.log`, one JSON line per finished exchange with schema version `v`, rotated by size, and a Swift reader for `macus server logs`.

## Goals / Non-Goals

**Goals:** one window that shows runtime state, instances, the processes and agents inside an instance, a terminal into an instance and the gateway access log; built with the project's toolchain; no new server surface; no effect on a headless install.

**Non-Goals:**

- Managing workloads (create, start, stop, delete, configure, snapshot, file transfer). These stay with standard Incus clients.
- Runtime lifecycle from the app (`start`, stop, restart, reset, upgrade, gateway configuration, token administration).
- Remote Macus hosts. The app serves the state directories of the logged-in user on this Mac.
- A menu bar item, notifications, launch at login.
- App Store distribution, sandboxing, Developer ID signing, notarization, a Homebrew cask.
- iOS, iPadOS or any other platform.

## Decisions

### 1. SwiftUI, in this SwiftPM package

| Option | Verdict |
| --- | --- |
| **SwiftUI app as SwiftPM targets in this package** | Chosen. Reuses `GatewayEndpoint`, the pinned transport, trust stores and the log reader directly; one toolchain, one `check.sh`, strict Swift 6 concurrency throughout. |
| Xcode project in or beside the repository | Rejected. Adds a second build system and project file the canonical checks do not cover. SwiftPM cannot produce a bundle, but a short script can (decision 8). |
| Web UI served by Phoenix (LiveView) | Rejected. Adds routes, session auth and assets to the gateway, which is the security boundary; cannot read the log when the server is stopped; is not what was asked for. |
| Tauri/Electron | Rejected. A second runtime and none of the Swift reuse. |
| Terminal UI in `macus` | Rejected. Grows the executable that is meant to stay small and still cannot show the three things together well. |

Targets:

- `MacusAppCore` (library): discovery, runtime client, Incus client, events, exec, process parsing, log tailing, and `@Observable` view models. Depends on `Macus`. No SwiftUI or AppKit, so it is unit-testable.
- `MacusApp` (executable): SwiftUI scenes and views, plus the SwiftTerm view. Depends on `MacusAppCore`.

`Macus` and `MacusCommand` gain no dependency on either. VZ code stays in `Sources/Macus/Virtualization` and the app never calls it.

### 2. Client of the public gateway only

The app uses exactly what the CLI uses: `endpoint.json`, the pinned certificate, TLS 1.3, no system trust, proxies, cookies or redirects. It does not open `runtime.sock` or `incus.sock`, and does not run `macus` or `incus` as a subprocess. A missing endpoint is shown as "Macus is not set up here; run `macus start`", not repaired.

The existing `HTTPSGatewayClient` accepts only `/runtime` paths and has no client certificate. `MacusAppCore` adds a sibling transport for native paths that presents the app identity and supports streaming bodies and WebSockets (`URLSessionWebSocketTask`), with the same pinning delegate. The pinning code is shared, not copied.

### 3. The app's own identity, enrolled once with consent

The app needs a certificate in gateway trust to read `/1.0`.

- **Rejected: reuse the `incus` CLI's key** from `INCUS_CONF`. The log could not tell the app from the CLI, revoking one would revoke both, and the app would read another program's private key.
- **Rejected: a bearer scope that admits native reads.** It changes the gateway's authentication model for one client.
- **Chosen: a dedicated identity.** On first use the app generates a P-256 key and a self-signed certificate named `Macus.app`. When the owner clicks *Connect to workloads*, it issues a bound enrollment token through `TrustTokenStore.issueBound` (owner-local file administration, as `macus client setup` does) and redeems it with the native enrollment request. An unredeemed token is revoked. Nothing is enrolled before the click; until then the app shows runtime state and the access log only.

The key and certificate are stored as 0600 files in a 0700 directory, `~/Library/Application Support/Macus/app-identity/`, one identity for all state directories. The Keychain was considered and deferred: with ad-hoc signing each rebuild is a different code identity and would prompt or lose access. It becomes the right store when Developer ID signing exists.

If the certificate is later removed from trust, native requests fail with 403 and open streams close. The app returns to the *Connect* state and does not re-enroll itself.

### 4. State directory selection

The default state directory is used unless the app is launched with `--state-dir DIR` or the owner picks another in Settings. One window shows one state. All ownership checks the CLI applies to the state and `server` directories apply unchanged, because the same functions are called.

### 5. Views

A `NavigationSplitView` with three sidebar entries.

**Overview.** `GET /runtime/status`, polled every 5 s while the window is visible. Three distinct conditions: server not reachable, server up with runtime absent/stopped/booting/failed (with the failure reason), runtime ready (state, uptime, Incus version, CPUs, memory, disk, endpoint URL). No controls.

**Instances.** `GET /1.0/instances?recursion=2&all-projects=true` for the initial list, then one `/1.0/events?type=lifecycle,operation&all-projects=true` WebSocket. A lifecycle event refetches the one instance it names. Resource figures refresh every 10 s for visible rows only. If the events stream ends, the app falls back to a 10 s list poll and retries the stream with backoff capped at 60 s. Columns: name, project, type (container/VM), status, image, IPv4, CPU, memory.

**Instance detail.** Tabs: *Summary* (config and state already fetched), *Processes*, *Terminal*.

**Access log.** See decision 7.

### 6. Looking inside an instance

**Processes.** Incus has no process-list endpoint, so the app runs one non-interactive exec (`wait-for-websocket`, no PTY) of a fixed POSIX `sh` script that reads `/proc/[0-9]*/{stat,status,cmdline}` and `readlink`s `cwd`, and prints one NUL-delimited record per process. Reading `/proc` directly avoids depending on `ps`, whose flags differ between procps and BusyBox. The output is limited to 1 MiB and the exec to 10 s. It runs when the tab opens and every 5 s while the tab is visible, never in the background and never for more than one instance at a time. The script is a constant; nothing the user types is interpolated into it.

Unavailable cases are reported, not hidden: instance not running, no `sh` in the image, a VM without the Incus agent.

**Agents.** "Agent" here means (confirmed by the owner, 2026-11-23) a process whose executable or first argument matches a list of known agent programs. The default list is `claude`, `codex`, `gemini`, `opencode`, `aider`, `amp`, `goose`, and is editable in Settings. Matching processes are grouped at the top with PID, command, working directory, age, CPU time and resident memory; their child processes are nested under them. This is observation only: the app cannot signal a process.

**Terminal.** An interactive exec over the native WebSockets with a PTY, rendered by SwiftTerm, with window-resize control messages. The command is the instance's login shell (`su -l` for the selected user, default root, falling back to `sh`). It opens only when the owner opens the tab and clicks *Open shell*, closes with the tab, and is limited to four concurrent sessions so the app cannot exhaust the gateway's stream bound. Interactive exec is an Incus operation relayed unchanged; the app adds a renderer, not behaviour.

Every exec above is recorded in the access log under the app's certificate, like any other caller's.

### 7. Access log view

The app reads the files, not a route: it works when the server is stopped and adds no surface. It uses the reader `add-gateway-access-log` adds for `macus server logs` (ownership validation, archives oldest first, follow across rotation), which that change must expose from the `Macus` library rather than keep private to the CLI. This is the one requirement this change places on the other.

- Loads the most recent 5,000 records and follows new ones with a file-system event source. Memory is bounded: the oldest rows are discarded past 50,000.
- Columns: time, caller, method, path, status, outcome, duration, bytes in/out. Caller is a short fingerprint, replaced by a name when the fingerprint is the app's own or matches a gateway trust entry.
- Filters: text over path, caller, outcome (`ok` / refused / failed), protocol. A `dropped_before` marker is shown as its own row.
- A record with a higher `v` than the app knows is shown from the keys it understands and counted in a footer note; a malformed line is skipped and counted.
- A missing file is an empty table with an explanation, not an error. An unsafe directory is an error and nothing is read.

### 8. Building and delivering

`swift build -c release --product MacusApp` produces a plain executable. `Packaging/app/build-app.sh` assembles `Macus.app` (executable, `Info.plist` with bundle identifier `com.upmaru.macus.app` and `LSMinimumSystemVersion` 15.0, icon), then ad-hoc signs it. No entitlements are needed: the app is not sandboxed (it must read the state directory) and uses no VZ.

The Homebrew formula keeps installing only `macus` and the server release. Installing or removing the app never touches state, launchd jobs or gateway trust; removing its trust entry is done by the owner with a standard Incus client (`incus config trust remove`), which the gateway serves from its own trust store.

### 9. Concurrency and testing

View models are `@MainActor @Observable`; clients are actors or `Sendable` structs behind protocols, so tests substitute fixtures. `MacusAppCore` tests cover: discovery failures, enrollment (token issued, redeemed, revoked on failure), instance list and event reduction, events fallback, the process script's output parser (procps and BusyBox shaped `/proc`, truncated and malformed output, the 1 MiB limit), agent matching, exec framing, and log tailing across rotation. There are no UI snapshot tests in this change.

`Integration/scripts/check.sh` builds both new targets with warnings as errors and runs their tests.

## Risks / Trade-offs

- **An app is a larger attack surface than a CLI.** It holds a trusted certificate while open. Mitigation: read-only requests except exec; enrollment needs an explicit click; the identity is separate and revocable; the same pinning and ownership checks as the CLI.
- **Process inspection is an exec.** It creates an Incus operation every 5 s per open Processes tab and a line in the access log. Mitigation: only while visible, one instance at a time; the interval is a constant to revisit after hardware acceptance.
- **SwiftTerm is a new dependency.** Mitigation: pinned exactly, linked only into `MacusApp`.
- **Ad-hoc signing.** Gatekeeper will not open a copied build without the owner's override. Mitigation: documented; the supported path in this change is building locally.
- **Schema coupling to the access log.** Mitigation: the shared reader and the `v` rule above.
- **Rule reversal invites scope growth.** Mitigation: the `native-app` spec states the read-only boundary as a requirement, so a workload or lifecycle control needs its own change.

## Open Questions

- **Runtime start/stop in the app.** Left out. `start` activates launchd jobs and may bootstrap; it deserves its own change with its own confirmation rules.
- **Menu bar status item.** Cheap to add once the Overview model exists; left out to keep the first version to one window.
- **`/runtime` and `/mcp` requests in the log view.** Follows the same open question in `add-gateway-access-log`.
