# Tasks

A task is checked only when its implementation and its specified verification passed. Hardware acceptance is opt-in, uses only isolated state directories and is recorded apart from unit test success.

## 1. Shared library

- [x] 1.1 Wait for the `:opsmaru_incus` release that contains `add-gateway-exchange-telemetry`. Move `server/mix.exs`, `mix.lock` and the bundled cassette to it and verify `Macus.Build` records the new version and checksum and that `Integration/scripts/check-server.sh` passes. Done 2026-11-25 with 0.2.10: `mix.exs` and `mix.lock` moved, the generated pages regenerated, and `Macus.Build` reads the version and checksum from the lock (`gateway_test.exs`, "the recorded library identity is the locked one"). The cassette is not in the repository; packaging takes it from the 0.2.10 release, and the opt-in release smoke with that cassette was not run.
- [x] 1.2 Add a server test that attaches to the library's stop event through the mounted gateway and fails if any key the access record reads is missing from the locked library's metadata. `Macus.Proxy.AccessLog.reads/0` lists the keys; `server/test/macus/proxy/access_log_gateway_test.exs` holds a relayed request's real event to it.

## 2. Access log in the server

- [x] 2.1 Add `Macus.Proxy.AccessLog`: the telemetry handler, the JSON line formatter with the documented key order and the `[:macus, :access]` logger domain. Verify the line for a relayed read, a relayed mutation, a refusal for an untrusted certificate, anonymous discovery, a trust action, an operation-peer and an image-peer admission, a WebSocket and a raw upgrade, and that a handler error is rescued, counted and leaves the handler attached. Verified by driving `:telemetry.execute/3` with the stop metadata planned in `add-gateway-exchange-telemetry` (`server/test/macus/proxy/access_log_test.exs`); through the mounted gateway (`access_log_gateway_test.exs`) the relayed read and mutation, the untrusted-certificate refusal, anonymous discovery, a trust action, a WebSocket and a raw upgrade are verified against the library's real events; operation-peer and image-peer admissions are verified only with the driven event.
- [x] 2.2 Add the `:logger_std_h` handler with size rotation and overload protection, started only when serving, and the filter that keeps the domain out of the default handler. Verify rotation at the size limit, removal of the oldest archive, reopening after the file is deleted, and that `server.out.log` receives no access line.
- [x] 2.3 Require an owner-private `STATE/logs`, creating it 0700 only when absent, and set `umask 077` in `server/rel/env.sh.eex`. Verify 0600 files and archives, that an unsafe or unwritable directory disables the log with one error and the gateway still serves, and that `Macus.Release` and the existing private-path tests still pass with the umask. The 0600 modes are verified in a fresh VM started under `umask 077`; the release template carries the line.
- [x] 2.4 Count drops and write `dropped_before` on the next line. Verify with a stalled log device that relayed HTTP, WebSocket and raw exchanges keep their responses, admission releases and timing bounds, that drops are counted and that the marker appears once writing resumes. Verified through the mounted gateway with the writer suspended (`:sys.suspend/1`): HTTP reads and a refusal, an operation WebSocket and NBD tunnels return their exact bytes within the bound and release their slots, the drops are counted and the next record carries the marker.
- [x] 2.5 Add a redaction test over the server's gateway test suite that fails if the log contains a fixture bearer or enrollment token, `authorization` value, query string, operation or image secret, header, body byte or certificate body, or a key outside the documented set. `Macus.TestSupport.AccessLogAudit` checks the log every `native_relay_test.exs` test wrote (documented keys only, no credential scheme, query string, secret parameter or PEM body), and `access_log_gateway_test.exs` drives exchanges carrying marked credentials, queries, secrets, headers, bodies and frames and fails on any marker. The other gateway suites (`identity_trust`, `enrollment`, `official_client_trust`, `cowboy_upgrade`) do not run the audit.
- [x] 2.6 Add the exchange counter and duration and byte summaries to `MacusWeb.Telemetry`, tagged by protocol, admission kind and outcome only.
- [x] 2.7 Write `id` (`BOOT-SEQ`) on every record, after `v`, for `add-native-app` (its task 2.9). Verify the key order, one boot value and `SEQ` from 1 within a run, uniqueness across a restart, and that the `SEQ` gap after a stalled writer equals `dropped_before`.

## 3. Client command

- [x] 3.1 Parse `server logs` with `--lines`, `--follow` and `--json` in `MacusCLI`, with usage errors for an invalid count, and add it to `--help`.
- [x] 3.2 Implement the reader: ownership validation, reading across archives oldest first, the human rows and unchanged JSON lines. Verify recent records, more lines than the current file holds, a missing file, an unsafe directory, a malformed line (skipped and counted in the human output, passed through under `--json`) and that the command opens no socket and writes nothing.
- [x] 3.3 Implement `--follow` across rotation and interruption. Verify no duplicate or lost record across a rotation and exit status 130 on interrupt.

## 4. Documentation and checks

- [x] 4.1 Document the log (path, fields, schema version, bounds, what is never recorded, that it is not an audit trail) and the command in `docs/cli.md` and `server/README.md`, and that upgrade and removal keep it in `Packaging/homebrew/README.md`.
- [x] 4.2 Run `Integration/scripts/check.sh` and `openspec validate --all --strict --no-interactive`.

## 5. Hardware acceptance (opt-in)

- [ ] 5.1 On an isolated state directory with its own `INCUS_CONF`, run `macus start`, then `incus list`, `incus launch`, `incus exec`, `incus file push` and an SFTP mount through the gateway, and one request from an untrusted certificate. Record that `macus server logs` shows one record per exchange with the expected caller, status, outcome and bytes, that streams are recorded when they end, and that the log contains no secret. Preserve Incus data on failure.
