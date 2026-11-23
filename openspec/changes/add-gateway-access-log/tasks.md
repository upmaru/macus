# Tasks

Planning only. All tasks remain unchecked until implementation and their specified verification pass. Hardware acceptance is opt-in, uses only isolated state directories and is recorded apart from unit test success.

## 1. Shared library

- [ ] 1.1 Wait for the `:opsmaru_incus` release that contains `add-gateway-exchange-telemetry`. Move `server/mix.exs`, `mix.lock` and the bundled cassette to it and verify `Macus.Build` records the new version and checksum and that `Integration/scripts/check-server.sh` passes.
- [ ] 1.2 Add a server test that attaches to the library's stop event through the mounted gateway and fails if any key the access record reads is missing from the locked library's metadata.

## 2. Access log in the server

- [ ] 2.1 Add `Macus.Proxy.AccessLog`: the telemetry handler, the JSON line formatter with the documented key order and the `[:macus, :access]` logger domain. Verify the line for a relayed read, a relayed mutation, a refusal for an untrusted certificate, anonymous discovery, a trust action, an operation-peer and an image-peer admission, a WebSocket and a raw upgrade, and that a handler error is rescued, counted and leaves the handler attached.
- [ ] 2.2 Add the `:logger_std_h` handler with size rotation and overload protection, started only when serving, and the filter that keeps the domain out of the default handler. Verify rotation at the size limit, removal of the oldest archive, reopening after the file is deleted, and that `server.out.log` receives no access line.
- [ ] 2.3 Require an owner-private `STATE/logs`, creating it 0700 only when absent, and set `umask 077` in `server/rel/env.sh.eex`. Verify 0600 files and archives, that an unsafe or unwritable directory disables the log with one error and the gateway still serves, and that `Macus.Release` and the existing private-path tests still pass with the umask.
- [ ] 2.4 Count drops and write `dropped_before` on the next line. Verify with a stalled log device that relayed HTTP, WebSocket and raw exchanges keep their responses, admission releases and timing bounds, that drops are counted and that the marker appears once writing resumes.
- [ ] 2.5 Add a redaction test over the server's gateway test suite that fails if the log contains a fixture bearer or enrollment token, `authorization` value, query string, operation or image secret, header, body byte or certificate body, or a key outside the documented set.
- [ ] 2.6 Add the exchange counter and duration and byte summaries to `MacusWeb.Telemetry`, tagged by protocol, admission kind and outcome only.

## 3. Client command

- [ ] 3.1 Parse `server logs` with `--lines`, `--follow` and `--json` in `MacusCLI`, with usage errors for an invalid count, and add it to `--help`.
- [ ] 3.2 Implement the reader: ownership validation, reading across archives oldest first, the human rows and unchanged JSON lines. Verify recent records, more lines than the current file holds, a missing file, an unsafe directory, a malformed line (skipped and counted in the human output, passed through under `--json`) and that the command opens no socket and writes nothing.
- [ ] 3.3 Implement `--follow` across rotation and interruption. Verify no duplicate or lost record across a rotation and exit status 130 on interrupt.

## 4. Documentation and checks

- [ ] 4.1 Document the log (path, fields, schema version, bounds, what is never recorded, that it is not an audit trail) and the command in `docs/cli.md` and `server/README.md`, and that upgrade and removal keep it in `Packaging/homebrew/README.md`.
- [ ] 4.2 Run `Integration/scripts/check.sh` and `openspec validate --all --strict --no-interactive`.

## 5. Hardware acceptance (opt-in)

- [ ] 5.1 On an isolated state directory with its own `INCUS_CONF`, run `macus start`, then `incus list`, `incus launch`, `incus exec`, `incus file push` and an SFTP mount through the gateway, and one request from an untrusted certificate. Record that `macus server logs` shows one record per exchange with the expected caller, status, outcome and bytes, that streams are recorded when they end, and that the log contains no secret. Preserve Incus data on failure.
