# Macus server

Headless Phoenix/Cowboy OTP application `:macus`. Swift owns the VM and
private Unix sockets; this application supplies the public gateway.
Macus owns runtime/auth/proxy/host integration. It consumes the pure
`:opsmaru_incus` Hex library (Incus client, gateway relay and operation
descriptors) in this same BEAM, with no listener, process or extra job. `/mcp`
exposes only `search` and `execute` tools; no duplicate fallback client is
implemented here.
See [the development guide](../docs/development.md) and
[the implementation plan](../openspec/changes/add-elixir-server/tasks.md).

From this directory:

```sh
mise exec -- mix deps.get
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
```

The scaffold starts its supervision tree without opening a listener, accessing
backend sockets or creating runtime state. Gateway HTTPS and authentication
are pending implementation; `mix phx.server` does not enable a listener yet.
Explicit calls to `Macus.Runtime` now use the private Swift adapter. Its fixture
tests verify routes, limits, deadlines, concurrency and passive socket safety:

```sh
mise exec -- mix test test/macus/runtime/client_test.exs
```

## Gateway access log

While serving, `Macus.Proxy.AccessLog` records every native gateway exchange
in the owner-private `STATE/logs/gateway-access.log`, one JSON line per
exchange (schema version `v: 1`). It consumes the shared library's
`[:opsmaru_incus, :gateway, :exchange, :stop]` telemetry event, which is
emitted from a per-exchange observer process after the exchange ended; the
handler rescues and counts every error, so it is never detached.

- **Writer:** a dedicated `:logger_std_h` handler accepting only the logger
  domain `[:macus, :access]`, rotating at 10 MiB and keeping 5 archives
  (`gateway-access.log.0` newest to `.4` oldest). A filter on the default
  handler keeps access lines out of `server.out.log`.
- **Never blocking:** the handler's synchronous mode is off. When its queue
  reaches 500 lines, records are dropped, counted
  (`[:macus, :access_log, :dropped]`) and the next written line carries
  `dropped_before`.
- **Private:** `STATE/logs` must be owner-private 0700 (created only when
  absent) and `rel/env.sh.eex` sets `umask 077`, so the file and archives
  are 0600. An unsafe directory disables the log with one error; the
  gateway still serves.
- **Redaction:** only the documented keys are written; tokens,
  `authorization` values, query strings, secrets, headers, bodies and
  frames never are. Unknown library metadata is ignored.
- **Metrics:** `MacusWeb.Telemetry` counts exchanges and summarizes
  duration and bytes, tagged only by `protocol`, `admitted_as` and
  `outcome`.

It is an access log, not an audit trail. `macus server logs` reads it; see
[the CLI reference](../docs/cli.md#gateway-access-log) for the fields.
