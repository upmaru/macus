# Design

## Context

**The library.** `opsmaru_containers` 0.1.0 is a pure OTP library (`Opsmaru.Containers.*`, no application callback). The host supplies:

- `Opsmaru.Containers.Host` callbacks: `context/1` (verified identity and target), `authorize/2` (classified request) and `map_bind_source/2`.
- A `Transport` dialer that opens an independent duplex `Transport.Stream` to dockerd for each request.
- A ready `Context` carrying a `Docker.Capabilities` snapshot (target, API range, monotonic expiry).
- The listener: ordinary HTTP goes through `Opsmaru.Containers.Docker.Plug`, and raw streams (attach, attached exec, BuildKit `h2c`, WebSocket) go through `Docker.Raw.relay/4` with a frontend `Transport.Stream`.

`Nested.ensure/3` creates or adopts the engine instance (`security.nesting=true`, marker `user.opsmaru.containers.role=engine`) from an image that already runs dockerd. It returns the observed API range. The library never installs packages, keeps no database and opens no Incus connection of its own.

**What the library does not ship.** The 0.1.0 package contains the `Transport` behaviour but no production dialer. The exec bridge that passed qualification (`scripts/acceptance/exec_socket_bridge.ex` and `exec_socket_bridge.go`) is outside the package `files`. The library also leaves engine image selection, port forwarding and the consumer gate (its task 4.5) to the host.

**Evidence recorded by the library.** These results are recorded in `opsmaru-containers/docs/docker-live-acceptance.md`, using a Macus build's gateway with opsmaru_incus 0.2.10:

- The exec qualification gates passed: half-close in both directions, a 75 s idle events stream, independent requests during a paused 24 MiB download, cleanup after partial setup, and 8 MiB uploads and downloads.
- Six read-only differential cases passed, and the pinned CLI, Compose and Buildx checks passed.

Two issues remain open: an intermittent stdin write stall that can leave a partial upload, and BuildKit teardown reporting `:stream_failed` after a successful build.

**Upstream release 0.2.0.** `opsmaru-containers` change `add-cowboy-gateway-embedding` (upmaru/opsmaru-containers#6, released as `opsmaru_containers` 0.2.0 on 2026-11-26) adds what decisions 4 and 5 need: the split raw entry `Raw.open/3` and `Raw.run/4`, `Docker.CowboyHandler`, `Transport.CowboyStream`, the packaged `Transport.ExecBridge` with its helper source under `priv/exec_bridge`, and exchange telemetry. Two of its findings shape this design:

- The packaged `ExecBridge` is covered by scripted-session fixtures only. The live exec qualification used the acceptance copy, so Macus hardware acceptance is the first live run of the packaged dialer.
- Under OTP `:ssl`, once a TLS client sends `close_notify`, later server writes on that connection are not delivered. The library's TLS frontend therefore writes nothing after client EOF, and engine output sent after it is lost (decision 8).

**What the task 1.2 spike found (2026-11-27).** Two runs on isolated state, with a scratch server build and the pinned CLI:

- **Over the TLS gateway, Docker is unusable.** Ordinary attached commands lost all engine output while the CLI exited 0, because the CLI half-closes as soon as a stream is hijacked. The cause is in OTP: on a peer `close_notify`, `ssl_gen_statem` stops the connection (`{shutdown, peer_close}`), also on OTP master (ssl 11.7.9), and a TCP FIN beneath TLS ends it as `transport_closed`. No library or Macus change can keep writing on that connection.
- **Over an owner-private Unix socket, the half-close gate passes.** The same Cowboy handler chain on a `ranch_tcp` listener at `STATE/server/docker.sock` delivered every output byte after the client's write EOF, with and without stdin, including 1 MiB through `sha256sum`.
- **A library defect, separate from TLS.** `Docker.CowboyHandler` forwarded Cowboy's joined value for repeated request headers. BuildKit repeats `X-Docker-Expose-Session-Grpc-Method` once per method, so `docker buildx build` failed with `no local sources enabled` on both transports. With the header split back, the build passed over the socket. The fix is open as upmaru/opsmaru-containers#10 and is not released yet.

**Macus today.** The server runs one Cowboy TLS 1.3 listener (default `127.0.0.1:8443`), which other machines can also use after enrolling with a token. Its certificate is ECDSA P-384 for `localhost`, `127.0.0.1` and `::1` (`Macus.Gateway.Certificate`). It serves `/runtime`, native `/1.0` and `/mcp`. Native Incus requires an enrolled TLS client certificate, and runtime and MCP require scoped bearer credentials. Incus upgrades are relayed by opsmaru_incus's Cowboy handler: it completes the upstream handshake, then casts `{:switch_protocol, headers, RawTunnel, relay}`, and `RawTunnel.takeover/7` receives the client socket and buffered bytes. The server reaches Incus through `Opsmaru.Incus.Connection.unix!` on the Swift `incus.sock`, which the flow-controlled vsock relay carries. Shares are explicit VirtioFS directories (tag `tama-shares`), read-only by default. Workload service forwarding is documented future scope.

## Goals / Non-Goals

**Goals:**

- Unmodified `docker`, `docker compose` and `docker buildx` (Docker driver) work against Macus at the library's pinned versions, through a Unix socket served by the Macus server.
- Docker access is limited to the macOS account that owns the state. It never widens Incus, runtime or MCP access, and a Docker client holds no Incus or gateway credential.
- Docker is opt-in. Enabling it never changes Incus behaviour, and a Docker failure never makes the Incus gateway unavailable.
- Setup follows the Incus client model: standard client commands, no hand-written client configuration, conflicts refused, isolation through environment variables.

**Non-Goals:**

- Forwarding Docker published ports (`-p`) to macOS. This stays in the existing future scope for transparent service exposure.
- A native OCI engine on Incus application containers, a shared image store with Incus, Swarm, plugins, or rootless and multi-tenant isolation between Docker clients.
- Installing dockerd inside a running instance, or building an engine image on the user's machine.
- Docker over TCP or TLS, Docker access from other machines or other local accounts, and `DOCKER_HOST` path prefixes. See decision 1.
- A command that removes the engine. Its project stays an ordinary Incus project that the user can inspect or delete with `incus`.
- Any workload operation that Incus provides, or a Docker-to-Incus translation layer.

## Decisions

### 1. Serve Docker on an owner-private Unix socket

When Docker is enabled for the state, the server opens a second listener: a Unix socket at `STATE/server/docker.sock`. It is a Cowboy `ranch_tcp` listener bound with `ip: {:local, path}` and `port: 0`, speaking plain HTTP/1.1 (`cowboy_clear`). The Docker CLI connects through a context with `host=unix://STATE/server/docker.sock`. The context holds no TLS material.

The socket serves only the Docker relay (decision 4). Docker's paths keep their own meaning, with no prefix or rewrite, and no Incus, runtime, MCP or Phoenix route is mounted there. The TLS gateway serves no Docker route: a Docker path on the gateway gets its existing unknown-path failure.

- **Why a socket:** the gateway cannot carry Docker. Docker clients half-close hijacked streams and expect output to keep flowing back. Under OTP `:ssl`, a peer `close_notify` stops the connection, so engine output after the client's write EOF is lost (decision 8). On a plain stream socket, a write shutdown is only a read EOF for the server, and the library's `Transport.CowboyStream` keeps writing. The spike passed this gate over the socket.
- **Why not TCP without TLS:** any local account can connect to a loopback port, so access would need a new credential protocol over plaintext. A socket file in an owner-only directory gets its access boundary from the filesystem (decision 2).
- **Why not another TLS stack:** `fast_tls` does not expose OpenSSL's zero-return condition, so it cannot report a clean half-close either. A TLS terminator outside the BEAM is another long-running process and listener to supervise, package and secure, and it still needs a second endpoint.
- **Rejected: Docker on the gateway at Docker's paths.** This was the first design, and the task 1.2 spike measured it: attached `docker run`, `docker exec` and `docker attach` returned no output and exited 0 (decision 8).
- **Path limit:** macOS limits a socket path to 103 bytes. `STATE/server/docker.sock` is 8 bytes longer than `STATE/incus.sock`, so a state directory that fits the Incus socket can be too long for Docker. The server then refuses to enable Docker with an error naming the limit and the path. It never places the socket elsewhere.
- **Cost:** Docker is local only. A machine that reaches Incus through the gateway with an enrolled certificate gets no Docker access in this change. A remote Docker path would need TLS half-close support in OTP `:ssl` or a different transport, and is future work.

### 2. Docker access is the socket's file permissions

The server runs as the macOS account that owns the state, under its launchd user agent. Before binding, it checks that `STATE/server` is a directory owned by that account with mode 0700. It binds the socket and sets it to mode 0600. The directory is the access boundary, because no other account can traverse it. The socket's mode is a second layer that also covers the moment between bind and chmod.

- **One principal.** Every connection is the state's owner, so the host callbacks see one fixed principal on both the Plug and raw paths. There is no Docker credential to enroll, rotate or revoke, and Docker setup touches no gateway trust.
- **No widening.** The socket grants Docker routes only. It gives no access to Incus, runtime or MCP routes. Gateway certificates and bearer credentials grant no Docker access, because the gateway serves no Docker route.
- **Stale socket file.** At bind time, an existing socket at the path is removed only when `lstat` reports a socket owned by the account. Any other file type, a symlink, or another owner is refused, and the listener does not start.
- **Disabling.** When Docker is disabled for the state, the server does not open the socket and removes its own socket file. Whether a taken-over raw relay ends when its listener stops is checked in task 3.2. If it does not, Macus asks the library for a cancel handle.
- **Why this is enough:** the account that owns the state can already reach Incus, which can exec into the engine. Docker access gives that account nothing it lacks, and gives other accounts nothing. This is the same model as the Swift daemon's owner-only `incus.sock` and `runtime.sock`.

### 3. One engine per state, in a dedicated project

- **Target:** project `macus-docker`, instance `engine`. The server creates the project once with `features.images=false`, `features.profiles=false`, `features.storage.volumes=true` and `features.networks=false`, so it uses the default project's images, profiles and networks while keeping Docker volumes apart. The engine does not appear in `incus list` for the default project.
- **Spec:** `Nested.Spec` names the pinned engine image by Incus fingerprint. It sets `boot.autostart=true` and attaches one disk device per configured share (decision 6). The image comes from a catalog entry pinned in the package, beside the appliance catalog. Incus verifies the fingerprint on download, so the server never accepts an unpinned image.
- **Image:** Debian 13 arm64 with Docker Engine 29.10.0, containerd and BuildKit as shipped by that Docker release, plus the exec bridge helper at a fixed path. The catalog records the Incus fingerprint, Docker version, helper digest, source revision and attestation. The appliance image pipeline builds it. There is no fake checksum: until a measured image exists, the catalog entry is absent and Docker setup reports `unavailable`.
- **Lifecycle:** `ensure/3` runs only from the owner route `POST /docker/engine` (called by `docker setup`, or by start when Docker is enabled), serialized for each target through one server process. An uncertain create or start outcome is reconciled by reading the instance, never replayed. A changed catalog fingerprint is reported as `engine image outdated` and not applied automatically. Engine replacement is future work.
- **Persistence:** `STATE/server/docker.json` (owner-private, written atomically) records `enabled`, project, instance and the catalog ID last ensured. Start reads it to decide whether to run the Docker stage. Docker images, containers and volumes live inside the engine instance on the Incus pool, so they survive restarts and runtime upgrades like any other workload.

### 4. Raw handoff under Cowboy

`Docker.Raw.relay/4` admits the request, opens the backend, completes the upstream handshake and then writes the response to the frontend itself. Under Cowboy, `switch_protocol` sends the `101` before `takeover/7` runs, so calling `relay/4` after takeover would produce two responses. Calling it before takeover is impossible, because the handler does not own the socket.

A Docker raw upgrade (`Upgrade: tcp` on `/v1.57/…/attach`, `h2c` on `/grpc`) needs a handler that can take over the connection. `Plug.Cowboy.Handler` cannot, so the socket listener does not route raw upgrades through Plug.

The library provides a narrow Cowboy adapter, `Opsmaru.Containers.Docker.CowboyHandler`, compiled only when `:cowboy_req` is loaded. It is modelled on opsmaru_incus's handler:

- It opens no listener and starts no process before a request.
- It takes a request only when the path, with any `/vX.Y` prefix stripped, matches a pinned route whose takeover is a Docker stream, an `h2c` upgrade or a WebSocket. Everything else, including ordinary Docker HTTP and detached exec start (`POST /exec/{id}/start` without `Upgrade`), goes to its required `fallback` with the body unread.
- A matched raw route without an `Upgrade` header, or sent over HTTP/2, gets a Docker-shaped 400 with no admission or dial. Cowboy cannot write Docker's hijacked `200`, and `switch_protocol` exists only on HTTP/1.1.
- It rests on a split relay entry. In one unlinked, monitored relay process, `Raw.open/3` runs host policy and admission, dials, completes the upstream handshake, and returns `{:upgrade, response, backend, tail}` or `{:http, status, headers, body}`. The handler casts `switch_protocol` with the engine's headers, and the relay calls `Raw.run/4` after `takeover/7` hands it the socket and Cowboy's buffered bytes. Cowboy writes `101 Switching Protocols` where dockerd writes `101 UPGRADED`; the headers are identical, and clients check only the status code.
- If the handler dies before the cast, or takeover misses `:handoff_timeout`, the relay closes the backend and nothing is retried.

The socket listener's chain is:

1. `Opsmaru.Containers.Docker.CowboyHandler`, for raw upgrades
2. its fallback, `Plug.Cowboy.Handler` running `Macus.Docker.Router`, a Plug router that mounts only `Docker.Plug`

The Incus gateway's chain does not change.

**Identity.** The handler passes its `:host_peer` option to the host callbacks as `request.host_peer`. Because every connection on the socket is the state's owner (decision 2), that option is a fixed owner principal set in the listener configuration. `Macus.Docker.Router` puts the same principal in `conn.private[:opsmaru_containers_peer]`, so `Macus.Docker.context/1` and `authorize/2` see identical identity on both paths. No per-request wrapper and no certificate lookup are needed.

**Repeated headers.** The handler must forward a repeated request header as separate values. Cowboy joins them with `, `, and BuildKit's session request needs each `X-Docker-Expose-Session-Grpc-Method` value on its own. The spike found the library forwarded the joined value. The fix is upmaru/opsmaru-containers#10, and Macus depends on the release that contains it (task 1.3).

- **Why in the library, not Macus:** the takeover glue (buffer handoff, response ordering, close semantics) is the subtle part. Central Opsmaru also hosts on Cowboy. opsmaru_incus set the precedent of shipping the same-listener handler with the relay.
- **Not a full gateway module:** opsmaru_incus's `Gateway` also carries admission, policy, identity, leases and exchange telemetry for Incus. opsmaru_containers already has its own equivalents (`Admission`, `Host`, `Context`, `Plug`, `Raw`, `RawTunnel`). The listener, its permissions and its bounds stay in Macus. The library needs only this handler, plus telemetry events that the access log can consume.

- Requests that need a raw stream but carry no `Upgrade` header (Docker's legacy raw `200` attach) get the library's Docker-shaped 400. The pinned CLI sends `Upgrade: tcp` for attach and attached exec start. The task 1.2 spike saw both taken over with `101`, so `Upgrade` is present; it did not log the header values.
- **Same HTTP stack as the gateway.** The socket listener is Cowboy with the library's handler, not a second HTTP implementation. It has its own Ranch bounds (acceptors and maximum connections) and Cowboy request limits. Docker requests are recorded in the server's access log from the library's telemetry.

### 5. Exec transport moves into the library

The qualified bridge becomes a packaged module, `Opsmaru.Containers.Transport.ExecBridge`, in an `opsmaru_containers` release. Its helper source and build instructions live in the library under `priv/exec_bridge`. The Macus engine image installs the helper. `Macus.Docker.context/1` returns `dialer: {ExecBridge, options}` with the helper's guest path, dockerd's socket path, per-connection `limits` within the Incus connection's `max_stream_bytes`, and a keepalive interval. It passes no `request_context`: one built inside `context/1` would be owned by that callback's short-lived process, so the relay's stream deadline bounds the stream instead.

- **Why:** central Opsmaru needs the same transport. The library already owns the qualification evidence. Macus's rules keep shared Incus mechanics in libraries, not duplicated in the host.
- **Each Docker client connection is one Incus exec operation** with its own WebSockets, each on its own `incus.sock` connection through the flow-controlled relay. There is no pooling or multiplexing. Acceptance measures whether a stalled stream delays others (task 5.4).
- **Limits fail, never truncate.** A stream that exceeds its input or output limit fails with a Docker-shaped error. Large image pulls, `docker cp` and build contexts must fit the configured limits, and acceptance records the values used.
- **Evidence:** the packaged module has fixture coverage only (Context). Macus hardware acceptance (task 5.3) is its first live run, and it is reported to the library as consumer acceptance.

### 6. Bind mounts map through explicit shares

`map_bind_source/2` accepts an absolute, normalized macOS path only when it lies inside a configured share. It returns the same absolute path. The engine instance receives each share as an Incus disk device whose source is the share's guest mount and whose path inside the engine is the share's macOS path. So `docker run -v "$PWD":/app` works unchanged when `$PWD` is inside a share.

- Paths outside every share, symlinks that leave a share, and relative or non-normalized sources are denied. The library returns a Docker-shaped error naming the share requirement.
- A read-only share stays read-only. Writes fail inside the container with the kernel's read-only error. The policy cannot upgrade a share's access.
- Adding or removing a share keeps its existing runtime rules. The next `ensure` brings the engine's disk devices in line.
- Named volumes use the library's existing policy: local-driver bind options and custom drivers are refused.

### 7. Readiness is cached per target and refreshed on demand

The server keeps one `Docker.Capabilities` snapshot per target with a 10 s monotonic expiry. On a Docker request with an absent or expired snapshot, one single-flight refresh calls `Nested.readiness/2` with a bounded deadline. Concurrent requests wait on that refresh, up to their admission deadline.

An unready engine, a guest that is not ready, or a missing engine produces a Docker-shaped `503` with a message naming the state (`engine stopped`, `runtime not ready`, `engine missing`). Admission never reaches the backend without a fresh snapshot.

A fresh snapshot can still be stale if the engine stops outside Macus (for example `incus stop macus-docker/engine`). Three rules bound that window to one request:

- Macus's own lifecycle calls clear the snapshot.
- A dial failure, or an engine failure before any response byte reaches the client, invalidates the snapshot and triggers the single-flight refresh.
- The failing request gets the Docker-shaped 503 for the state the refresh observes, and is never replayed.

Later requests are refused by admission, without dialing, until a refresh sees a running engine. The relay's existing "honest upstream failure before commitment" behaviour makes this safe: nothing was sent to the client yet.

### 8. Half-close needs a plain stream socket

Docker clients half-close hijacked streams. `docker exec -i … < file` and `docker cp` depend on the client's write EOF reaching dockerd while output keeps flowing back. The pinned CLI also half-closes as soon as a stream is hijacked when there is no stdin, so ordinary `docker run` and `docker exec` depend on it too. The frontend must treat the client's write EOF as read EOF while keeping its own write side open, and must shut down only its write side on backend EOF.

Task 1.2 made this a gate before any other server work.

**TLS fails the gate.** Under OTP `:ssl`, a peer `close_notify` stops the connection (`ssl_gen_statem` handles the alert as `{stop, {shutdown, peer_close}}`), and the code is the same on OTP master (ssl 11.7.9). A TCP FIN beneath TLS ends the connection as `transport_closed`. Through a scratch gateway, the pinned CLI lost all engine output after its write EOF: `docker exec -i` with redirected stdin, `docker exec` without `-i`, and `docker run` with and without `-i`. Each returned 0 bytes to the client and ended `caller_closed`, while the CLI exited 0. The same commands run on the engine directly worked.

**A Unix socket passes it.** Over `ranch_tcp` on `STATE/server/docker.sock`, `Transport.CowboyStream` sets `exit_on_close: false`, so the client's write shutdown arrives as read EOF and writes continue. In the re-spike, `docker exec -i C sh -c 'cat; echo done'` printed `line1`, `line2` and `done` in three runs, with 12 bytes in, 33 out and outcome `ok`. `docker exec` and `docker run`, with and without stdin, printed their output, and 1 MiB of stdin through `sha256sum` matched. `docker attach` to a container started with `-d -i` still ends with `unexpected EOF`, as it does without Macus: Docker keeps that container's stdin open.

**Gate kept.** Hardware acceptance (task 5.3) repeats attached exec with stdin EOF and attached run without stdin through the installed server's socket.

### 9. Client setup mirrors Incus client setup

`macus docker setup` runs these steps in order, and `macus start --docker` runs them as its last stage:

1. Read the runtime status. Refuse when the runtime is not ready, and never boot it.
2. `POST /docker/engine`. The server records Docker as enabled, ensures the engine, opens the socket if it is not open, and returns the socket path.
3. Find `docker` (on `PATH` or `--docker-cli`). Install the official Homebrew `docker` formula only when it is missing and Homebrew exists.
4. Create or reuse the context with `host=unix://` and the returned socket path.
5. Verify with `docker --context NAME version --format '{{.Server.APIVersion}}'`.

- **Context rules:** the default name is `macus` (`--docker-context NAME`). An existing context with the same endpoint is reused. A different endpoint is a conflict, and the existing context is preserved. `docker context use` runs only with `--docker-set-default`. `DOCKER_CONFIG` selects the configuration directory, and macus never edits `config.json`.
- **Compose and Buildx:** setup reports whether the CLI finds `compose` and `buildx`. When either is missing, Homebrew exists and no explicit `--docker-cli` was given, setup installs the `docker-compose` or `docker-buildx` formula and links its plugin binary into `$DOCKER_CONFIG/cli-plugins`, only when no plugin of that name exists there. A link is plugin installation, not configuration. An existing plugin is never replaced. An explicit `--docker-cli` marks an isolated or caller-managed client, as `--incus` does for Incus: setup then never runs Homebrew for the CLI or its plugins, and only reports missing plugins.
- **Versions:** the server does not refuse other CLI versions. Admission negotiates within the engine's API range. Status and doctor report the CLI, Compose and Buildx versions and say when they differ from the qualified pins. Acceptance covers only the pinned versions.
- **Environment:** doctor warns when `DOCKER_HOST` or `DOCKER_CONTEXT` is set to something other than the Macus context, because either one bypasses it.

### 10. Failure isolation

The Docker socket listener, engine lifecycle and readiness refresh run under their own supervisor. A crash, a missing catalog entry, a bad `docker.json`, a socket path that cannot be bound or an engine failure produces Docker-shaped failures or a missing socket only. The gateway, Incus, runtime and MCP routes are unaffected. When Docker is not enabled, the socket does not exist.

## Risks / Trade-offs

- **[Intermittent stdin write stall]** → It is open in the library. Large uploads can fail with `502` and leave partial destinations. Acceptance records every upload trial with fresh destinations, and `docs/docker.md` states the limitation until the library closes it.
- **[Shared Incus transport]** → Docker has its own listener, but every Docker stream is an Incus exec on the server's Incus connection and the vsock relay, beside Incus traffic. Acceptance runs Docker streams concurrently with Incus exec, and records latency and any head-of-line delay (task 5.4).
- **[Library API dependency]** → Decisions 4 and 5 need `opsmaru_containers` 0.2.0, which is released. BuildKit also needs the repeated-header fix (upmaru/opsmaru-containers#10), which is not released yet. Macus takes that release rather than carrying a fork (task 1.3).
- **[TLS half-close]** → Under OTP `:ssl`, Docker cannot run over TLS (decision 8). Docker therefore stays off the gateway and is local only until OTP or a different transport changes that.
- **[Active streams on disable]** → After takeover, a raw relay runs in a library-owned process that holds the connection. The TLS spike found that killing the Cowboy request process did not end it. With one owner principal there is no per-client revocation, but disabling Docker should still end active streams. Task 3.2 checks whether stopping the listener does, and if not, Macus asks the library for a cancel handle.
- **[Socket path length]** → A state directory whose `server/docker.sock` path exceeds 103 bytes cannot serve Docker. Setup fails with an error naming the limit and the path, and suggests a shorter state directory.
- **[CLI version drift]** → Homebrew's `docker` formula moves faster than the pins. Negotiation keeps it working within the API range, and status reports the drift. Acceptance remains pin-specific.
- **[No port forwarding]** → `-p` publishes inside the engine only. Documentation says so prominently, and service exposure stays future scope.

## Migration / Rollback

Docker is opt-in and has no effect on existing states until it is enabled. Until then the server opens no socket and the gateway is its only listener. Disabling means removing the context with `docker context rm` and removing the `docker.json` record, which turns the start stage off and, at the next server start, leaves the socket closed and removed. The engine project stays as Incus data and is never deleted by Macus. Downgrading the package leaves the project as an ordinary Incus project.
