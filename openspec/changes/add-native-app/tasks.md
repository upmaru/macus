# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Hardware acceptance is opt-in, uses only isolated state directories and is recorded apart from unit test success.

## 1. Project rules and package

- [ ] 1.1 Update `AGENTS.md` and `openspec/config.yaml`: the runtime, services and installation stay headless and never require an application; an optional client application is allowed; cross-platform requirements stay excluded; `/live` is a public route. Verify strict OpenSpec validation passes.
- [ ] 1.2 Add the `MacusAppCore` library and `MacusApp` executable targets and the exactly pinned SwiftTerm dependency (linked only into `MacusApp`). Verify `swift build` of `macus` links no SwiftUI, AppKit or SwiftTerm symbol, and extend `Integration/scripts/check.sh` to build and test the new targets with warnings as errors and swift-format.
- [ ] 1.3 Make public in `Macus` what the app reuses: endpoint discovery, the pinning delegate, bound trust token issuance and revocation, gateway trust lookup. Verify existing tests pass unchanged.

## 2. Live channel in the server

- [ ] 2.1 Mount `MacusWeb.LiveSocket` at `/live` with WebSocket only, `peer_data` and `auth_token` connect info and the frame, idle and socket-count bounds. Before building on it, prove through the real Cowboy TLS listener that a Phoenix Channels upgrade completes behind `Opsmaru.Incus.Gateway.CowboyHandler`, that the peer certificate is visible in `peer_data`, and that native raw upgrades and `/1.0` WebSockets are unaffected.
- [ ] 2.2 Implement connect authorization: bearer from `auth_token` only, certificate from the TLS peer, either or both. Verify refusal with neither, refusal of a token in the query string, and registration with the bearer and certificate revocation watchers so that revoking either closes the socket within the bound.
- [ ] 2.3 Add `Macus.Live`: the observer behaviour, the `DynamicSupervisor`, start on first subscriber, stop after the 5 s grace period, restart with backoff, and `unavailable` with a reason on failure. Verify with fixture sources: one observer for many subscribers, stop after the last leaves, no stop on a rejoin within the grace period, and no stale value presented as current after a crash.
- [ ] 2.4 Add the `runtime` channel (requires `runtime.read`) over the runtime observer. Verify join reply, a push per transition, and refusal for a certificate-only connection.
- [ ] 2.5 Add the `instances` channel (requires a trusted certificate) over one Incus events subscription with per-instance refetch. Verify join reply across projects, `upsert` and `remove`, refusal for a bearer-only connection with no Incus request made, and recovery when the events subscription ends.
- [ ] 2.6 Add the `instance:PROJECT:NAME` channel and its observer: validation of the names against the instance list, the fixed looping `/proc` script, the length-prefixed snapshot parser, change detection, and the 1 MiB, 4,096-process and 8-instance bounds. Verify procps and BusyBox shaped input, truncated and malformed snapshots, each unavailable reason, the watch limit, that the exec ends when the observer stops, and that the script is a constant with no interpolation.
- [ ] 2.7 Refuse every client event other than join, leave and heartbeat on all channels. Verify nothing is dispatched.
- [ ] 2.8 Verify under load that a slow or stalled live subscriber does not delay relayed HTTP, WebSocket or raw exchanges, and log observer start and stop with the subscribing certificate.

## 3. Runtime state stream in the Swift daemon

- [ ] 3.1 Add `GET /v1/runtime/events` to the private control API: full status on connect, one line per `RuntimeState` transition, a keep-alive comment every 30 s, at most 8 readers. Verify each transition is emitted once, the reader bound, release of a disconnected reader, and that the route is absent from the public `/runtime` API.
- [ ] 3.2 Add the streaming read to `Macus.Runtime.Client` and the runtime observer. Verify reconnection after the daemon restarts and `unavailable` while `runtime.sock` is absent.

## 4. App connection and identity

- [ ] 4.1 Add state selection (default, `--state-dir`, Settings) and endpoint discovery in `MacusAppCore`. Verify missing state, missing endpoint, unsafe ownership and a malformed endpoint each produce their distinct condition and create nothing.
- [ ] 4.2 Add the Phoenix Channels V2 client on `URLSessionWebSocketTask` with the pinning delegate: connect with bearer and optional client certificate, join, reply matching, heartbeat, rejoin with capped backoff. Verify against recorded frames, and that a certificate mismatch sends no credential.
- [ ] 4.3 Connect when `endpoint.json` is published, using a file-system event source. Verify no repeating timer is scheduled for data anywhere in `MacusAppCore`.
- [ ] 4.4 Add the app identity: P-256 key and self-signed certificate as 0600 files in a 0700 directory, created once. Verify modes, reuse across launches and refusal of an identity directory that is not owner-private.
- [ ] 4.5 Add explicit enrollment: bound token, native enrollment request, revocation of an unredeemed token. Verify nothing is enrolled before the owner action, enrollment is idempotent when already trusted, and a socket closed by revocation returns the app to the unconnected state without re-enrolling.

## 5. Overview and instances

- [ ] 5.1 Add the runtime model on the `runtime` topic and the Overview view. Verify server unreachable, runtime absent, stopped, booting, failed and ready are each presented distinctly and that state held while disconnected is marked as not current.
- [ ] 5.2 Add the instance list model reducing the join reply, `upsert` and `remove`, and the Instances and instance Summary views. Verify containers and VMs, multiple projects, an empty list, and an unavailable topic.

## 6. Inside an instance

- [ ] 6.1 Add the process model on `instance:PROJECT:NAME`, joined only while the view is visible. Verify join on appear, leave on disappear, and each unavailable reason shown.
- [ ] 6.2 Add agent matching with the default list and the Settings editor, and the process tree. Verify matching by executable and by first argument, nesting of children and an empty match.
- [ ] 6.3 Add the Processes view with addresses and resource use.
- [ ] 6.4 Add the native transport for exec (pinned TLS, the app's certificate, WebSockets), the interactive exec client (PTY, control channel, resize) and the SwiftTerm view, with explicit open, close on view removal and the four-session limit. Verify framing against the recorded exec fixture, the limit, and that closing the view ends the operation.

## 7. Access log

- [ ] 7.1 After `add-gateway-access-log` is implemented, confirm its reader is public API of `Macus` (ownership validation, archives oldest first, follow across rotation); if it is CLI-private, move it there in that change.
- [ ] 7.2 Add the log model: initial 5,000 records, follow, 50,000-row bound, filters, caller naming from gateway trust, `dropped_before` rows, tolerance of a newer `v` and of malformed lines. Verify each, including no duplicate or lost record across a rotation.
- [ ] 7.3 Add the Access Log view. Verify a missing file shows an explained empty table and an unsafe directory shows an error and no records.

## 8. Packaging and documentation

- [ ] 8.1 Add `Packaging/app/build-app.sh` and `Info.plist` producing an ad-hoc signed `Macus.app`. Verify the bundle launches from a clean build and that the Homebrew candidate differs only by the server release's live channel.
- [ ] 8.2 Document the live channel in `docs/api.md` and `docs/server.md` (path, topics, payloads and their version, authorization per topic, bounds, that it is read-only and not in the access log). Write `docs/app.md` and update `docs/architecture.md` and `README.md`.
- [ ] 8.3 Run `Integration/scripts/check.sh` and `openspec validate --all --strict --no-interactive`.

## 9. Hardware acceptance (opt-in)

- [ ] 9.1 On an isolated state directory with its own `INCUS_CONF`, run `macus start`, launch a container and a VM, start a listed agent program in the container, then open the app with that state. Record: the overview, connection by explicit action, both instances listed and updating when one is stopped with `incus`, the agent shown with its working directory and disappearing when it exits, a shell session with resize, removal of its certificate with `incus config trust remove` returning the app to unconnected, and that quitting the app leaves the runtime and instances running. Preserve Incus data on failure.
- [ ] 9.2 On the same state, record that restarting the runtime is shown in the overview as it happens, that the in-instance observer process is gone after the Processes view is closed, and that `incus exec`, an SFTP mount and `incus file push` behave as before while two live subscribers are connected.
- [ ] 9.3 With the server stopped, record that the access log is still shown and the overview reports the server as not running; then start the server and record that the app connects without being restarted.
