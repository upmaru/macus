# Design

## Context

See [proposal.md](proposal.md). Every public request enters one Cowboy TLS listener (`Macus.Gateway.listener/1`). `Opsmaru.Incus.Gateway.CowboyHandler` switches native raw upgrades itself and hands everything else to `MacusWeb.Endpoint`, where `MacusWeb.Router` mounts `Opsmaru.Incus.Gateway.Plug` at `/` and `/1.0`. `Macus.Proxy.Host` authorizes by the peer's client certificate against gateway trust, or admits a server peer by an operation or image secret.

The shared library's `add-gateway-exchange-telemetry` change emits `[:opsmaru_incus, :gateway, :exchange, :start | :stop]`. The stop event is emitted exactly once from a per-exchange observer process, after the exchange has really ended, and carries: `protocol`, `method`, `path`, `project`, `target`, `all_projects`, `operation`, `peer_address`, `peer_port`, `peer_fingerprint`, `admitted_as`, `status`, `outcome`, `reason`, and the measurements `duration`, `request_bytes`, `response_bytes`.

The server release runs under launchd with stdout and stderr in `STATE/logs/server.{out,err}.log`, which launchd never rotates. `STATE/logs` is created 0700 by the Swift component when it writes the job plist; a foreground `macus serve` may run without it.

## Goals / Non-Goals

**Goals:** a complete, secret-free, bounded record of native gateway exchanges that the owner can read with one command; no effect on relayed traffic.

**Non-Goals:** recording `/runtime` and `/mcp` requests; a remote or HTTP way to read the log; shipping logs anywhere; tamper evidence or guaranteed delivery (this is an access log, not an audit trail); rotating `server.out.log`; per-frame records; configuration of the format.

## Decisions

### 1. Consume the library's events

`Macus.Proxy.AccessLog` attaches one handler to the stop event when the server starts serving. The alternatives were rejected:

- **Logging in `Macus.Proxy.Host.authorize/2`** sees every request and its certificate but not the status, duration, bytes or end of a stream, and nothing refused before authorization.
- **`Plug.Telemetry` on the endpoint** misses raw upgrades and stream ends, and has no gateway outcome.

The handler rescues every error and counts it. `:telemetry` detaches a handler that raises, which would stop the log silently, so a failure inside the handler must never escape.

### 2. An OTP logger file handler writes the file

The handler turns the event into a report and logs it with the domain `[:macus, :access]`. A dedicated `:logger_std_h` handler, added at startup, filters for that domain and writes the file. This gives, without a custom writer process:

- size rotation (`max_no_bytes`, `max_no_files`), with archives beside the file;
- overload protection: the handler drops, then flushes, as its queue grows (its synchronous mode is disabled, see below);
- `file_check`, so a file removed by the owner is reopened.

A filter on the default handler drops the same domain, so access lines are not repeated in `server.out.log`.

Because the stop event comes from the library's observer process, nothing but that observer could ever wait on the logger handler, and it does not wait either: `sync_mode_qlen` equals `drop_mode_qlen`, which turns the handler's synchronous mode off, so no relay, request process, admission slot or observer waits for the disk.

`logger_std_h` drops in its callers without reporting the count through any public interface, so the telemetry handler does its own admission ahead of it: before logging a line it reads the handler process's message queue length, and at 500 pending lines (below the handler's own drop threshold of 1000) it drops the record, counts it and emits `[:macus, :access_log, :dropped]`. The next written line after a drop carries `"dropped_before": N`. A record the handler itself drops beyond that point, or a write error it reports, is not counted; the queue check makes that unlikely.

### 3. Location, ownership and bounds

- **Path:** `STATE/logs/gateway-access.log`, beside the launchd logs the documentation already names.
- **Directory:** at startup the server requires `STATE/logs` to be an owner-private directory (`Macus.PrivatePath.private_dir/2`) and creates it 0700 only when absent, as it does for `STATE/server`. An unsafe directory disables the access log with one error line and does not stop the gateway: failing to log must not take the gateway down.
- **File mode:** `server/rel/env.sh.eex` sets `umask 077`, so the file and its rotated archives are created 0600. The 0700 directory is the boundary either way.
- **Bounds:** 10 MiB per file, 5 archives, so at most about 60 MiB. Both are constants in this change.

### 4. Line format

One JSON object per line, UTF-8, keys in this order:

```json
{"v":1,"id":"9c1f6a02b47de853-4127","time":"2026-11-23T10:15:02.412Z","protocol":"http","method":"GET","path":"/1.0/instances/web","project":"default","target":null,"all_projects":false,"operation":null,"peer":"192.168.1.20:51422","certificate":"3f9a…","admitted_as":"caller","status":200,"outcome":"ok","reason":null,"duration_ms":12,"request_bytes":0,"response_bytes":1834}
```

- `v` is the schema version. Adding a key keeps it; renaming or removing one increments it.
- `id` is `BOOT-SEQ`, the record's identity, added for `add-native-app`, which merges records pushed live with the same records read from the files. `BOOT` is 64 random bits chosen when the server starts, as 16 lowercase hexadecimal digits; `SEQ` is a decimal counter from 1 for that run. It is taken when the stop event arrives, before the drop decision, so within a run it orders the records and a gap marks one that was not written. Adding the key keeps `v` at 1.
- `time` is when the exchange ended, UTC with milliseconds.
- `peer` is `address:port`, with IPv6 in brackets.
- `certificate` is the library's `peer_fingerprint`: the SHA-256 of the certificate the caller presented, or `null`. With `admitted_as: "caller"` it is the trusted certificate that authorized the request, because `Macus.Proxy.Host` authorizes only by certificate. For a refused request it is merely what was presented.
- `project` is `null` when the caller selected none, which Incus treats as its default; the log does not invent `"default"`.
- Other values are the library's, with atoms as strings.

The server writes only these keys. An unknown metadata key from a newer library is ignored, so a library upgrade cannot add a field to the file unreviewed.

### 5. `macus server logs`

```
macus [--state-dir DIR] server logs [--lines N] [--follow] [--json]
```

- Reads `gateway-access.log` and, when more lines are requested than it holds, its archives, oldest first. Default 50 lines.
- Human output is one row per exchange: time, caller (certificate prefix, or `anonymous`, `operation-peer`, `image-peer`, `refused`), method and path, status, outcome and reason when not `ok`, duration and bytes.
- `--json` prints the stored lines unchanged, one per line, so the output is the file's schema.
- `--follow` keeps printing new lines and follows rotation, until interrupted.
- It validates that the state directory and `logs` are owner-private, as other `server` commands do, and fails with `invalid_configuration` otherwise.
- A missing file prints nothing and exits 0: no exchange has been recorded yet.
- It contacts neither the server nor the runtime, starts nothing and changes nothing.

Reading the file in Swift avoids a new authenticated route and works when the server is stopped, which is when a log is often wanted.

### 6. Metrics

`MacusWeb.Telemetry` gains a counter and duration and byte summaries on the stop event, tagged by `protocol`, `admitted_as` and `outcome` only. `path`, `project` and `certificate` are never metric tags.

## Risks / Trade-offs

- **Lines can be lost.** Overload drops, a handler error or a crash between the exchange and the write lose a line. Mitigation: drops are counted and marked in the file; the documentation calls this an access log, not an audit trail.
- **Paths name workloads.** Instance, image and volume names appear in `path`. Mitigation: the file is owner-private, like the state it describes.
- **Unauthenticated noise.** A gateway exposed on a network records every refused probe. Mitigation: size rotation bounds the cost; refusals are the point of the record.
- **Library coupling.** The record depends on the library's metadata keys. Mitigation: the server writes named keys only and a test fails if an expected key is missing from the locked library's event.
- **`umask 077` is process-wide.** Everything the release creates becomes owner-private. Mitigation: the server writes only under the state directory, where that is already the rule; the existing private-path tests still pass.
- **Rotation during `--follow`.** Mitigation: the reader reopens by path when the file shrinks or its identity changes.

## Open Questions

- Should the bounds or an off switch live in `server/gateway.json`? Not until an owner asks; constants keep the preflight unchanged.
- Should `/runtime` and `/mcp` requests be recorded in the same file with a `surface` key? They carry bearer principals, which need their own redaction review.
