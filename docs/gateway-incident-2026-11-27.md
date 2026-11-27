# Gateway incident, native OCI spike, 2026-11-27

Two gateway faults seen during the native OCI qualification spike, on isolated
state `.integration/docker-spike/state` (gateway `127.0.0.1:60542`, scratch
build `feature/docker-engine-spike` at `e5ebbec`, opsmaru_incus 0.2.10, guest
incusd 7.0.1, host `incus` CLI 7.5.1). Evidence: the spike's
`gateway-findings.md` and the access and server logs copied into
`gateway-incident/` at 20:10:52 UTC. Server log times are UTC+7.

Both faults are in opsmaru_incus. Macus makes the first more likely. Neither
depends on the Docker work.

## Fault 1: a slow trust answer becomes `403 unauthorized` or `revoked`

### What happened

From 20:00:26 to 20:01:23 UTC every gateway answer was slow: successful
requests also took 0.5–2 s, against 3–15 ms before and after. In that window
eight requests from the trusted certificate got `403`, reason `unauthorized`,
`admitted_as` empty, after 1005–2310 ms. One `/1.0/events` upgrade got `403
revoked` after 1699 ms. The server log has only the `Sent 403 in …ms` request
lines, no cause. The `t14-18.log` run recorded these as `Error: not
authorized`.

### Cause

opsmaru_incus runs every host callback under `callback_timeout`, 1000 ms by
default. A callback that overruns or fails is treated as a denial:

- `Opsmaru.Incus.Gateway.Policy.authorize/2` (`lib/opsmaru/incus/gateway/policy.ex`,
  the `_ ->` clause after `callback/2`) answers `403 "not authorized"`, reason
  `:unauthorized`, for any result other than `{:ok, grant}` or
  `{:error, :unauthenticated}`. That includes `{:error, :timeout}`, and it
  happens even on anonymous routes such as `GET /1.0`.
- `Policy.recheck/3` gets `min(callback_timeout, recheck_interval / 4)`, also
  1000 ms. Anything except `{:ok, true}` is `403 "Authorization expired or
  revoked"`, reason `:revoked`. This recheck runs once more before every
  admitted request (`authorized/4`) and before each WebSocket or raw relay
  opens.
- `Opsmaru.Incus.Gateway.Lease.loop/7` (`lease.ex`) rechecks every open stream
  every `recheck_interval - 2 × budget - 50` ms (2950 ms in production). If
  one recheck overruns, `invalidate(:revoked, …)` runs: the owner is told
  `{:gateway_stopped, _, :revoked}`, interrupted and killed. So a single slow
  answer ends every open events stream, operation channel and streamed
  response.

The library never logs the overrun, which is why the server log gives no
cause.

Macus's answer is file I/O on the host, never the guest.
`Macus.Proxy.Host.authorize/2` and `valid?/3` call `Macus.Proxy.Trust.lookup/3`
on every request and every recheck. Each call:

1. runs `Macus.PrivatePath.private_dir/2`: an `lstat` of the gateway directory,
   then one `lstat` per ancestor up to `/` (about ten for the spike's state
   directory), plus two `readlink`s for the `/var` and `/tmp` aliases;
2. runs `private_entry/3` (one `lstat`), `File.stat/1` and `File.read/1`;
3. decodes the JSON, validates every entry, and decodes the matching
   certificate twice.

With N open streams that is N lookups every 2.95 s, plus one or two per
request. Each file call takes a dirty I/O scheduler. When the host's
filesystem or the BEAM's I/O is slow, the lookup crosses the 1 s budget. The
trust store sits in the same state directory as the VM's disk image, and the
guest pool was 96% full and writing heavily at the time. The same effect is
already documented in this repository:
`server/test/macus/proxy/native_relay_test.exs` explains that a 100 ms budget
"a loaded CI runner's trust-file read exceeds, ending streams that no test
meant to revoke" (PR #33).

**Not established:** why the host was slow in that window. A trust lookup
reads only host files, and the same requests answered end to end in 3–15 ms
before and after the window, so the gateway host itself was slow, not only
the guest. Host I/O contention from the VM disk
image and dirty-scheduler saturation in the BEAM are both possible. Telling
them apart needs timing around the callback, proposed below.

### Reproduction

`server/test/macus/proxy/gateway_incident_test.exs` drives opsmaru's
`Policy` and `Lease` with Macus's real host policy and trust store. A
pass-through host delays Macus's answer the way a slow filesystem does. These
tests pass on 0.2.10 and pin the defect:

- a trusted certificate whose lookup overruns gets `403`, `:unauthorized`,
  `:not_sent` after the budget;
- an upgrade whose admission recheck overruns is refused `403 :revoked`;
- one overrunning recheck revokes an open stream and kills its owner, while
  the certificate stays trusted throughout.

### Proposed fix

In opsmaru_incus (issue A below): treat a host callback that overruns or
crashes as "host unavailable", not as a decision. On admission, return `503`
with a new reason such as `:host_timeout`, kept separate from `:unauthorized`
and `:revoked`. For an open stream, revoke only on an explicit `false` from
`valid?/3`. On an overrun, retry within the documented revocation bound and
fail closed only when no definite answer arrives in time. Log or emit
telemetry for every overrun.

In Macus (needs an OpenSpec change, because `Macus.Proxy.Trust` documents
that it reads the store on every request):

- Keep an in-memory snapshot of the parsed store in the `Trust` process, for
  example in an ETS table that only `Trust` writes. `Trust.update/3` replaces
  the snapshot in the same call that writes the file, so a removed
  certificate is still refused on the next request. A lookup then needs one
  `lstat` of the store file. A change in inode, size, mtime, mode or owner
  reloads it with the full private-path check, so hand edits and unsafe
  stores are still caught.
- Check the ancestors when the gateway starts and when the snapshot reloads,
  not on every lookup.
- Wrap the lookup in `:telemetry.span/3` and log any lookup over 250 ms, so
  the next incident leaves evidence.

Raising `callback_timeout` only moves the threshold, and the recheck budget is
capped at `recheck_interval / 4` (1250 ms) anyway.

## Fault 2: event streams through the gateway die after 30 s of quiet

### What happened

The findings report that event streams stopped carrying `operation` events,
and that `incus launch` and `incus init` hung after `POST /1.0/instances`
until the server was restarted.

The copied evidence does not show operation events being filtered:

- No code path filters events by operation or owner. incusd 7.0.1's
  `events.Server.broadcast` filters only by project, permission, message type
  and location. `Opsmaru.Incus.Gateway.WebSocketRelay` passes `/1.0/events`
  frames through unchanged. Macus has no event code.
- `events-rerun.jsonl` (`incus monitor` through the gateway, 20:11:09–20:12:20)
  carries every operation event until 20:11:40.313. After that no operation
  was created at all: the logging stream has no further `New operation` line,
  and its only later activity is `n-out` stopping on its own at 20:12:00
  (a lifecycle event with no operation) and one `GET /1.0` at 20:12:20. The
  "last operation event at 20:11:40" is simply the end of the test run, not
  the start of a fault.
- `init-debug.log` (20:09:52) and `init-debug2.log` (20:17:04) both end where
  a successful `incus init` ends: the operation wait returned and the client
  read the new instance (`checkNetwork`). For the 20:09:52 run, the access log
  shows the client's events stream closed by the caller 796 ms after it
  opened, and no further requests.

What the evidence does show is a stream that dies after 30 s of silence:

- the monitor exited with `Error: read tcp 127.0.0.1:53656->127.0.0.1:60542:
  i/o timeout` (`events.err`);
- events streams that the caller closed at almost exactly 30 s: 19:11:23
  (30163 ms) and 19:12:04 (30188 ms), each with its exec channels, 20:03:19
  (30233 ms, 496 bytes), and the 19:49:10 monitor (160 s, closed about 34 s
  after its last event).

### Cause

The Incus 7.5.1 client (`client/incus_events.go`) sets a 30 s read deadline
on the events WebSocket ("The server pings every 10s, so a silent connection
is a dead one") and extends it only on a data frame or a server ping. incusd
7.0.1 pings every listener every 10 s (`internal/server/events/connections.go`).

opsmaru_incus 0.2.10 never lets a ping reach the client:

- `WebSocketRelay.controls/3` (`web_socket_relay.ex`) answers each backend
  `{:ping, payload}` with a local pong and drops the ping;
- `Opsmaru.Incus.Gateway.WebSocket` sets the frontend's Cowboy
  `idle_timeout: :infinity` and never sends a ping of its own. Its moduledoc
  describes ping/pong as "local to each independently negotiated connection".

So any events stream through the gateway that goes 30 s without an event
fails at the client. `incus monitor` exits. An operation of class `websocket`
(exec, console) fails with "Lost connection to the event listener". A task
operation reconnects and falls back to polling (`client/operations.go`
`setupListener`), which is slow but works. The Incus 7.0.1 reference driver
that the fixture tests use has no read deadline, which is why the existing
tests never caught this.

Fault 1 adds to it: during a slow episode every open stream is revoked
(above), so clients lose their listeners together.

**Not established:** an indefinite hang after `POST /1.0/instances`, or
operation events missing while lifecycle events arrive. The access log is
written when an exchange ends, so a stream still open at 20:10:52 is not in
it. The post-restart runs (20:11–20:17) have no copied access log. A rerun
should record `incus monitor --type=operation,lifecycle --format=json`, the
access log, and `incus --debug` with timestamps until the hang. Then a server
`:observer` or `Process.list` snapshot during the hang shows whether any
relay is parked waiting for an `ack`.

### Reproduction

`native_relay_test.exs`, "backend keepalive pings stop at the gateway; a
quiet events stream carries none": the fixture incusd pings its events
listener every 100 ms. Through the production listener the gateway answers
every ping, and the client receives no frame at all in a second. It passes on
0.2.10 and pins the defect.

### Proposed fix

In opsmaru_incus (issue B below): keep the frontend WebSocket alive. Either
forward backend pings to the client and relay the client's pongs back, or
have `Gateway.WebSocket` send its own ping at least every 10 s while the
exchange is open. Count a client pong as caller activity for `idle_timeout`.
Pings are control frames, so neither option changes native payloads. Until
it lands, Macus cannot fix this alone, because the frontend handler belongs
to the library.

## Issue text for opsmaru_incus

### A. Host callback overruns are reported as `unauthorized` and `revoked`

**Version:** 0.2.10

`Policy.authorize/2`, `Policy.recheck/3` and `Lease.loop/7` treat a host
callback that overruns `callback_timeout` (or crashes) the same as a negative
decision:

- an overrun in `authorize/2` returns `403`, reason `:unauthorized`, even on
  anonymous routes;
- an overrun in the admission recheck returns `403`, reason `:revoked`;
- one overrun in an open exchange's lease recheck revokes the exchange and
  kills its owner.

A trusted caller is therefore refused, and every open stream torn down, when
the host is briefly slow. Nothing is logged, and the access log shows a
definite denial. Seen in Macus with a trust lookup (local file reads) on a
loaded host: eight `403 unauthorized` and one `403 revoked` within a minute,
each just over the 1 s budget, while successful requests took 0.5–2 s.

**Expected:**

- An overrun or crash is "host unavailable", not "denied". Admission answers
  `503` (retryable) with its own failure reason, such as `:host_timeout`, and
  telemetry, never `:unauthorized` or `:revoked`.
- An open exchange is revoked only on an explicit `false` from `valid?/3`. An
  overrun is retried within `recheck_interval`, and the exchange fails closed
  only when no definite answer arrives within the bound. The bound stays a
  guarantee.
- The `Failure` reasons and `docs/gateway.md` document the distinction.

**Reproduction:** a host whose `authorize/2` or `valid?/3` sleeps longer than
`callback_timeout` and then returns a positive answer. `Policy.admit/2`
returns `{:error, %Failure{status: 403, reason: :unauthorized}}` or
`%Failure{reason: :revoked}`. A `Lease` dies with `:revoked` after one slow
recheck.

### B. Gateway WebSockets carry no keepalive to the client; Incus ≥ 7.5 clients drop quiet event streams after 30 s

**Version:** 0.2.10

`WebSocketRelay.controls/3` answers backend pings locally and drops them, and
`Gateway.WebSocket` (Cowboy, `idle_timeout: :infinity`) never pings the
client. incusd pings every events listener every 10 s, and since 7.5 the
official client sets a 30 s read deadline on the events WebSocket that only
data frames and server pings extend (`client/incus_events.go`). Through the
gateway, an events stream with no events for 30 s fails at the client:
`incus monitor` exits with `read tcp …: i/o timeout`, and exec or console
operations fail with "Lost connection to the event listener". Seen in Macus
with incus 7.5.1 against incusd 7.0.1: streams the caller closed at
30163–30233 ms, and a monitor that died about 30 s after its last event.

**Expected:** a client connected through the gateway sees at least one ping
every 10 s while the exchange is open. Either forward backend pings (and
relay pongs back), or ping from the frontend on a fixed interval of 10 s or
less. Count client pongs as caller activity for `idle_timeout`. Add a test
with a backend that pings and a client that requires pings.

**Reproduction:** a backend events WebSocket that sends `{:ping, _}`
periodically and no data. The client of the gateway receives no frame. With
the Incus ≥ 7.5 Go client, `GetEvents()` fails after 30 s.

## Other observations

- Docker routes on the shared listener did carry traffic in the faulty boot
  (`/_ping`, `/grpc` and `/session` raw relays from 19:14:51 UTC). Nothing
  links them to either fault, but "no traffic" holds only for the later Unix
  socket listener.
- Several native requests completed with outcome `uncertain`, reason `killed`,
  despite a 2xx status (for example `POST /1.0/instances` at 20:09:52 and
  `DELETE /1.0/instances/n-sd` at 20:02:37). This is unexplained and not
  linked to either fault.
