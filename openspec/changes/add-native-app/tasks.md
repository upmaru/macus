# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Hardware acceptance is opt-in, uses only isolated state directories and is recorded apart from unit test success.

## 1. Project rules and package

- [ ] 1.1 Update `AGENTS.md` and `openspec/config.yaml`: the runtime, services and installation stay headless and never require an application; an optional client application is allowed; cross-platform requirements stay excluded. Verify strict OpenSpec validation passes.
- [ ] 1.2 Add the `MacusAppCore` library and `MacusApp` executable targets and the exactly pinned SwiftTerm dependency (linked only into `MacusApp`). Verify `swift build` of `macus` links no SwiftUI, AppKit or SwiftTerm symbol, and extend `Integration/scripts/check.sh` to build and test the new targets with warnings as errors and swift-format.
- [ ] 1.3 Make public in `Macus` what the app reuses: endpoint discovery, the pinning delegate, bound trust token issuance and revocation, gateway trust lookup. Verify existing tests pass unchanged.

## 2. Connection and identity

- [ ] 2.1 Add state selection (default, `--state-dir`, Settings) and endpoint discovery in `MacusAppCore`. Verify missing state, missing endpoint, unsafe ownership and a malformed endpoint each produce their distinct condition and create nothing.
- [ ] 2.2 Add the native transport: pinned TLS 1.3 with the app's client certificate, streaming responses and WebSockets. Verify a certificate mismatch sends no credential and no request body.
- [ ] 2.3 Add the app identity: P-256 key and self-signed certificate as 0600 files in a 0700 directory, created once. Verify modes, reuse across launches and refusal of an identity directory that is not owner-private.
- [ ] 2.4 Add explicit enrollment: bound token, native enrollment request, revocation of an unredeemed token. Verify nothing is enrolled before the owner action, enrollment is idempotent when already trusted, and a 403 after revocation returns the app to the unconnected state without re-enrolling.

## 3. Overview and instances

- [ ] 3.1 Add the runtime status model and Overview view. Verify server unreachable, runtime absent, stopped, booting, failed and ready are each presented distinctly and that stale state is not shown as current.
- [ ] 3.2 Add the instance list model over `/1.0/instances` with recursion and all projects. Verify containers and VMs, multiple projects, an empty list and a runtime that is not ready.
- [ ] 3.3 Add the events stream with per-instance refetch, polling fallback and capped backoff. Verify the list updates on lifecycle events, survives a dropped stream and stops all requests when the window closes.
- [ ] 3.4 Add the Instances and instance Summary views.

## 4. Inside an instance

- [ ] 4.1 Add the fixed `/proc` script, the non-interactive exec client and the record parser with the 1 MiB and 10 s bounds. Verify parsing of procps and BusyBox shaped input, kernel threads, truncated and malformed output, and that the script is a constant with no interpolation.
- [ ] 4.2 Add agent matching with the default list and the Settings editor, and the process tree. Verify matching by executable and by first argument, nesting of children and an empty match.
- [ ] 4.3 Add the Processes view, refreshing only while visible. Verify no exec is started after the view closes and that a stopped instance, a missing `sh` and a VM without the agent are each explained.
- [ ] 4.4 Add the interactive exec client (PTY, control channel, resize) and the SwiftTerm view, with explicit open, close on view removal and the four-session limit. Verify framing against the recorded exec fixture, the limit, and that closing the view ends the operation.

## 5. Access log

- [ ] 5.1 After `add-gateway-access-log` is implemented, confirm its reader is public API of `Macus` (ownership validation, archives oldest first, follow across rotation); if it is CLI-private, move it there in that change.
- [ ] 5.2 Add the log model: initial 5,000 records, follow, 50,000-row bound, filters, caller naming from gateway trust, `dropped_before` rows, tolerance of a newer `v` and of malformed lines. Verify each, including no duplicate or lost record across a rotation.
- [ ] 5.3 Add the Access Log view. Verify a missing file shows an explained empty table and an unsafe directory shows an error and no records.

## 6. Packaging and documentation

- [ ] 6.1 Add `Packaging/app/build-app.sh` and `Info.plist` producing an ad-hoc signed `Macus.app`. Verify the bundle launches from a clean build and that the Homebrew candidate is byte-for-byte unaffected.
- [ ] 6.2 Write `docs/app.md` (what it shows, the connection and identity, how to revoke it, what it never does, building it, the Gatekeeper note) and update `docs/architecture.md` and `README.md`.
- [ ] 6.3 Run `Integration/scripts/check.sh` and `openspec validate --all --strict --no-interactive`.

## 7. Hardware acceptance (opt-in)

- [ ] 7.1 On an isolated state directory with its own `INCUS_CONF`, run `macus start`, launch a container and a VM, start a listed agent program in the container, then open the app with that state. Record: the overview, connection by explicit action, both instances listed and updating when one is stopped with `incus`, the agent shown with its working directory, a shell session with resize, the app's own requests in the access log under its certificate, removal of its certificate with `incus config trust remove` returning the app to unconnected, and that quitting the app leaves the runtime and instances running. Preserve Incus data on failure.
- [ ] 7.2 On the same state with the server stopped, record that the access log is still shown and the overview reports the server as not running.
