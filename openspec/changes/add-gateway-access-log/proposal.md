# Proposal

## Why

The Macus server keeps no record of the native Incus requests it relays. `STATE/logs/server.out.log` holds whatever the release prints, with no caller, no gateway decision and nothing at all for the requests that never enter the Phoenix endpoint:

- **Raw SFTP/NBD upgrades** are served by `Opsmaru.Incus.Gateway.CowboyHandler` before `MacusWeb.Endpoint` runs.
- **WebSockets** (exec, console, events, migration) appear to end at the upgrade. When they really ended, how much they moved and why (revocation, idle, lifetime) is known only inside the shared relay.
- **Refusals** carry no reason. An owner cannot tell an untrusted certificate from a full gateway or a stopped runtime.

An owner who exposes the gateway beyond loopback needs to answer "who did what through my gateway, and what was refused". Today that cannot be answered.

The shared library change `add-gateway-exchange-telemetry` (upmaru/opsmaru-incus) makes the gateway emit one start/stop event pair per exchange with secret-free metadata. This change turns those events into a bounded, owner-private access log and a command to read it.

## What Changes

- **The server records every native gateway exchange.** One JSON line per finished exchange is appended to `STATE/logs/gateway-access.log`: time, protocol, method, path, project, target, operation, peer, the fingerprint of the presented client certificate, how the request was admitted, status, outcome, reason, duration and bytes each way. Refused requests are recorded too.
- **Secrets are never recorded.** No `authorization` value, query string, operation or image secret, header, body, token or grant is written. The shared library does not emit them; the server writes only named fields.
- **The log is bounded and owner-private.** It rotates by size and keeps a fixed number of archives (10 MiB and 5 by default). The files live in the 0700 `STATE/logs` directory and are created 0600.
- **Logging never holds up a request.** Lines are written by an OTP logger file handler with overload protection, fed from the library's exchange observer, never from a relay. Under overload lines are dropped and the drop is counted; no exchange waits.
- **`macus server logs` reads it.** The command prints recent entries for the selected state, with `--lines`, `--follow` and `--json`. It reads the files directly; it needs no running server and adds no API route.
- **Exchange metrics** (count, duration, bytes by protocol and outcome) are added to `MacusWeb.Telemetry` from the same events.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `server-gateway` (introduced by the unarchived `add-elixir-server` change): adds the access record, its redaction and its bounds.
- `client-cli`: adds `server logs`.

## Impact

- **Dependency:** the `:opsmaru_incus` release that contains `add-gateway-exchange-telemetry`. `server/mix.exs`, `mix.lock` and the bundled cassette pin move to it, and `Macus.Build` records the new version and checksum. This change cannot be implemented before that release is on Hex.
- **Server:** a new `Macus.Proxy.AccessLog` (telemetry handler, JSON formatter and logger handler setup), a child in `Macus.Application` when serving, `MacusWeb.Telemetry` metrics, a filter that keeps access lines out of the default stdout handler, and `umask 077` in `server/rel/env.sh.eex`.
- **Swift:** `MacusCLI` parsing and a reader for `server logs`, with human and JSON presentation.
- **Documentation:** `docs/cli.md` (the command, and the log beside `service.*.log` and `server.*.log`), `server/README.md`, `Packaging/homebrew/README.md` (the log is kept on upgrade and removal like other state).
- **Not changed:** the gateway's admission, trust and relay behaviour, the public route contract, `/runtime` and `/mcp` (their requests are not recorded here), the Swift daemon, the guest and Incus.
- **Acceptance:** unit and server tests cover format, redaction, rotation and overload. Hardware acceptance is opt-in on isolated state and recorded apart from unit test success.
