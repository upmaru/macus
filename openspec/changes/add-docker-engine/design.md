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

**`teals`.** A planned Elixir TLS 1.3 server on rustls (`upmaru/teals`) whose peer `close_notify` ends only the read side. It is designed and not built. Its parts are prototyped: half-close against a Go client, a verifier that accepts the pinned `incus` and Docker CLIs' self-signed certificates, and certificates reaching `:cowboy_req.cert/1` through a stream handler. In the `teals` change's gate (2026-11-27), Docker CLI 29.8.2 received all output written after its stdin EOF over a prototype transport with a Cowboy raw takeover and a scripted engine, accepted a self-signed `CA:FALSE` server certificate as its CA, and offered no ALPN. The pinned CLI, a real engine, BuildKit and the gateway's own certificates are not covered by it.

**Direction (2026-11-27).** Docker is served on the gateway, on `teals`, as the first design intended. It waits for `teals`: no interim Unix socket is built (decisions 1, 8 and 11).

**Macus today.** The server runs one Cowboy TLS 1.3 listener (default `127.0.0.1:8443`), which other machines can also use after enrolling with a token. Its certificate is ECDSA P-384 for `localhost`, `127.0.0.1` and `::1` (`Macus.Gateway.Certificate`). It serves `/runtime`, native `/1.0` and `/mcp`. Native Incus requires an enrolled TLS client certificate, and runtime and MCP require scoped bearer credentials. Incus upgrades are relayed by opsmaru_incus's Cowboy handler: it completes the upstream handshake, then casts `{:switch_protocol, headers, RawTunnel, relay}`, and `RawTunnel.takeover/7` receives the client socket and buffered bytes. The server reaches Incus through `Opsmaru.Incus.Connection.unix!` on the Swift `incus.sock`, which the flow-controlled vsock relay carries. Shares are explicit VirtioFS directories (tag `tama-shares`), read-only by default. Workload service forwarding is documented future scope.

## Goals / Non-Goals

**Goals:**

- Unmodified `docker`, `docker compose` and `docker buildx` (Docker driver) work against Macus at the library's pinned versions, through the same authenticated gateway as Incus.
- Docker access is a separately revocable credential. It never widens Incus, runtime or MCP access.
- Docker is opt-in. Enabling it never changes Incus behaviour, and a Docker failure never makes the Incus gateway unavailable.
- Setup follows the Incus client model: standard client commands, no hand-written client configuration, conflicts refused, isolation through environment variables.

**Non-Goals:**

- Forwarding Docker published ports (`-p`) to macOS. This stays in the existing future scope for transparent service exposure.
- A native OCI engine on Incus application containers, a shared image store with Incus, Swarm, plugins, or rootless and multi-tenant isolation between Docker clients.
- Installing dockerd inside a running instance, or building an engine image on the user's machine.
- Docker on a Unix socket, `DOCKER_HOST` path prefixes, or a second TCP port. See decision 1.
- A command that removes the engine. Its project stays an ordinary Incus project that the user can inspect or delete with `incus`.
- Any workload operation that Incus provides, or a Docker-to-Incus translation layer.
- Implementing TLS in Macus. `teals` is designed and released on its own.

## Decisions

### 1. Serve Docker on the existing gateway listener, at Docker's own paths

The Docker CLI connects to `tcp://127.0.0.1:8443` with a context that holds `ca` (the gateway certificate), `cert` and `key`. The gateway dispatches to the Docker relay exactly these requests:

- `GET` and `HEAD` `/_ping`
- any method on `/v<digits>.<digits>/…`
- `POST /grpc` and `POST /session` with `Upgrade: h2c`

Dispatch runs before the unknown-path fallback. All other paths keep their current behaviour.

- **Why this set is enough:** the pinned clients call unversioned `/_ping` only to negotiate a version, and send every later API call to a versioned path. Buildx's Docker driver and the CLI's build session dial `/grpc` and `/session` directly. None of these collide with `/1.0`, `/runtime`, `/mcp` or Incus discovery at `/`.
- **Why the same listener:** one endpoint, one TLS identity, one remote configuration and one credential lifecycle, as the user expects from Incus. The gateway already authenticates before any privileged backend access, closes revoked streams and takes over raw upgrades under Cowboy.
- **Rejected: a path prefix (`tcp://127.0.0.1:8443/docker`).** The Docker client prefixes its base path onto API calls, but `Client.DialHijack` sends `/grpc` and `/session` without it ([moby `client/hijack.go`](https://github.com/moby/moby/blob/master/client/hijack.go)), so BuildKit would escape the prefix. `Docker.Plug` also admits on `conn.request_path`, so a prefix would need a library change as well.
- **Needs `teals`:** under OTP `:ssl` this listener cannot carry Docker (decision 8). Docker routes are mounted only while the gateway runs on `teals` (decision 11).
- **Rejected: an owner-private Unix socket.** A re-spike showed it passes the half-close gate, and it was this change's design for a time. It is local-only and gives Docker a second authentication model outside gateway trust, so with `teals` removing the TLS blocker it is not built, not even as an interim.
- **Fallback: a second TLS port on the same server, identity and trust.** The task 1.2 spike found no collision or Cowboy constraint on the shared listener, so it is used only if one appears later. It would serve Docker at the root path space with no other change to this design.
- **Cost:** unversioned Docker API paths other than `/_ping` (for example a hand-written `curl /containers/json`) get the gateway's bounded unknown-path failure. Supported tools use versioned paths.

### 2. Docker access is a certificate scope

Gateway trust records a scope set for each enrolled client certificate. Existing Incus enrollments are recorded with `incus`. The Docker certificate is enrolled with `docker` only.

- Docker routes require an enrolled certificate with `docker`.
- Native Incus routes require `incus`.
- Runtime and MCP keep bearer credentials.

A certificate without the required scope is refused before dispatch, with a Docker-shaped 403 on Docker routes and the existing native refusal on Incus routes.

The Swift client generates the Docker key pair (ECDSA P-384, owner-private) and enrolls the public certificate through the gateway's single-use enrollment with proof of the private key, using the local owner credential to mint the token. It then passes the files to `docker context create`. The client deletes its staged copies once Docker holds them.

- **Why:** a Docker credential grants control of the engine, not the guest's Incus. Keeping the scopes apart lets the owner revoke either one alone and attributes access-log lines correctly. An Incus certificate gains nothing from also being a Docker credential, because Incus can already exec into the engine.
- **Revocation:** Docker streams are gateway streams, so revoking the certificate closes active Docker streams within the existing revocation interval.

### 3. One engine per state, in a dedicated project

- **Target:** project `macus-docker`, instance `engine`. The server creates the project once with `features.images=false`, `features.profiles=false`, `features.storage.volumes=true` and `features.networks=false`, so it uses the default project's images, profiles and networks while keeping Docker volumes apart. The engine does not appear in `incus list` for the default project.
- **Spec:** `Nested.Spec` names the pinned engine image by Incus fingerprint. It sets `boot.autostart=true` and attaches one disk device per configured share (decision 6). The image comes from a catalog entry pinned in the package, beside the appliance catalog. Incus verifies the fingerprint on download, so the server never accepts an unpinned image.
- **Image:** Debian 13 arm64 with Docker Engine 29.10.0, containerd and BuildKit as shipped by that Docker release, plus the exec bridge helper at a fixed path. The catalog records the Incus fingerprint, Docker version, helper digest, source revision and attestation. The appliance image pipeline builds it. There is no fake checksum: until a measured image exists, the catalog entry is absent and Docker setup reports `unavailable`.
- **Lifecycle:** `ensure/3` runs only from the owner route `POST /docker/engine` (called by `docker setup`, or by start when Docker is enabled), serialized for each target through one server process. An uncertain create or start outcome is reconciled by reading the instance, never replayed. A changed catalog fingerprint is reported as `engine image outdated` and not applied automatically. Engine replacement is future work.
- **Persistence:** `STATE/server/docker.json` (owner-private, written atomically) records `enabled`, project, instance and the catalog ID last ensured. Start reads it to decide whether to run the Docker stage. Docker images, containers and volumes live inside the engine instance on the Incus pool, so they survive restarts and runtime upgrades like any other workload.

### 4. Raw handoff under Cowboy

`Docker.Raw.relay/4` admits the request, opens the backend, completes the upstream handshake and then writes the response to the frontend itself. Under Cowboy, `switch_protocol` sends the `101` before `takeover/7` runs, so calling `relay/4` after takeover would produce two responses. Calling it before takeover is impossible, because the handler does not own the socket.

The gateway already composes Cowboy handlers. Every request enters `Opsmaru.Incus.Gateway.CowboyHandler`. It takes only native SFTP and NBD raw upgrades and passes everything else to its `fallback` handler, which today is `Plug.Cowboy.Handler` running the Phoenix router. A Docker raw upgrade (`Upgrade: tcp` on `/v1.57/…/attach`, `h2c` on `/grpc`) is not a native path, so it would fall through to Plug, which cannot take over the socket.

The library provides a narrow Cowboy adapter, `Opsmaru.Containers.Docker.CowboyHandler`, compiled only when `:cowboy_req` is loaded. It is modelled on opsmaru_incus's handler:

- It opens no listener and starts no process before a request.
- It takes a request only when the path, with any `/vX.Y` prefix stripped, matches a pinned route whose takeover is a Docker stream, an `h2c` upgrade or a WebSocket. Everything else, including ordinary Docker HTTP and detached exec start (`POST /exec/{id}/start` without `Upgrade`), goes to its required `fallback` with the body unread.
- A matched raw route without an `Upgrade` header, or sent over HTTP/2, gets a Docker-shaped 400 with no admission or dial. Cowboy cannot write Docker's hijacked `200`, and `switch_protocol` exists only on HTTP/1.1.
- It rests on a split relay entry. In one unlinked, monitored relay process, `Raw.open/3` runs host policy and admission, dials, completes the upstream handshake, and returns `{:upgrade, response, backend, tail}` or `{:http, status, headers, body}`. The handler casts `switch_protocol` with the engine's headers, and the relay calls `Raw.run/4` after `takeover/7` hands it the socket and Cowboy's buffered bytes. Cowboy writes `101 Switching Protocols` where dockerd writes `101 UPGRADED`; the headers are identical, and clients check only the status code.
- If the handler dies before the cast, or takeover misses `:handoff_timeout`, the relay closes the backend and nothing is retried.

The listener chain becomes:

1. `Opsmaru.Incus.Gateway.CowboyHandler`
2. its fallback, `Opsmaru.Containers.Docker.CowboyHandler`
3. that handler's fallback, `Plug.Cowboy.Handler`

Ordinary Docker HTTP reaches `Docker.Plug` through the router's dispatched paths.

**Per-connection identity.** The handler passes its `:host_peer` option to the host callbacks as `request.host_peer`. That option comes from the handler configuration, while the client certificate belongs to the connection. Macus therefore mounts a thin wrapper, `Macus.Gateway.DockerHandler`, in position 2. For each request it reads the presented certificate, whose key the TLS handshake proved, with `:cowboy_req.cert/1`, resolves its trust record, and calls `Docker.CowboyHandler.init/2` with `host_peer` set to that record. It delegates `upgrade` and `terminate` the same way the Incus handler delegates to its fallback. On the Plug path the router puts the same record in `conn.private[:opsmaru_containers_peer]`, so `Macus.Docker.context/1` and `authorize/2` see identical identity on both paths. A request without a resolvable Docker-scoped record never reaches `Docker.CowboyHandler`.

**Repeated headers.** The handler must forward a repeated request header as separate values. Cowboy joins them with `, `, and BuildKit's session request needs each `X-Docker-Expose-Session-Grpc-Method` value on its own. The spike found the library forwarded the joined value. The fix is upmaru/opsmaru-containers#10, and Macus depends on the release that contains it (task 1.3).

- **Why in the library, not Macus:** the takeover glue (buffer handoff, response ordering, close semantics) is the subtle part. Central Opsmaru also hosts on Cowboy. opsmaru_incus set the precedent of shipping the same-listener handler with the relay.
- **Not a full gateway module:** opsmaru_incus's `Gateway` also carries admission, policy, identity, leases and exchange telemetry for Incus. opsmaru_containers already has its own equivalents (`Admission`, `Host`, `Context`, `Plug`, `Raw`, `RawTunnel`). TLS, the listener, trust and enrollment stay in the Macus gateway. The library needs only this handler, plus telemetry events that the gateway access log can consume.

- Requests that need a raw stream but carry no `Upgrade` header (Docker's legacy raw `200` attach) get the library's Docker-shaped 400. The pinned CLI sends `Upgrade: tcp` for attach and attached exec start. The task 1.2 spike saw both taken over with `101`, so `Upgrade` is present; it did not log the header values.
- **Rejected: a separate Ranch listener with its own HTTP/1.1 parser.** That is a second public HTTP implementation, outside the gateway's existing bounds and access log.

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

### 8. Half-close comes from `teals`

Docker clients half-close hijacked streams. `docker exec -i … < file` and `docker cp` depend on the client's write EOF reaching dockerd while output keeps flowing back. The pinned CLI also half-closes as soon as a stream is hijacked when there is no stdin, so ordinary `docker run` and `docker exec` depend on it too. The frontend must treat the client's write EOF as read EOF while keeping its own write side open, and must shut down only its write side on backend EOF.

**OTP `:ssl` fails this (task 1.2).** It stops the connection on a peer `close_notify` (`ssl_gen_statem` handles the alert as `{stop, {shutdown, peer_close}}`), and the code is the same on OTP master (ssl 11.7.9). A TCP FIN beneath TLS ends the connection as `transport_closed`. Through a scratch gateway, the pinned CLI lost all engine output after its write EOF: `docker exec -i` with redirected stdin, `docker exec` without `-i`, and `docker run` with and without `-i`. Each returned 0 bytes to the client and ended `caller_closed`, while the CLI exited 0. The same commands run on the engine directly worked.

**The relay path itself works** when the transport half-closes: the same handler chain over a Unix socket delivered every output byte after the client's write EOF, with and without stdin.

**`teals` is expected to pass, and that is a gate.** It reports the peer's `close_notify` as read EOF and keeps writing. Before any server work, the pinned CLI must receive all output after its stdin EOF over a `teals` prototype under Cowboy's raw takeover (task 1.4, which is also the first gate in the `teals` change). If it does not, this change returns to planning and Docker stays unavailable. The `teals` gate passed with CLI 29.8.2 and a scripted engine, which does not close task 1.4.

### 9. Client setup mirrors Incus client setup

`macus docker setup` runs these steps in order, and `macus start --docker` runs them as its last stage:

1. Read the runtime status. Refuse when the runtime is not ready, and never boot it. Refuse when the gateway does not run on `teals`, naming the setting (decision 11).
2. `POST /docker/engine`.
3. Find `docker` (on `PATH` or `--docker-cli`). Install the official Homebrew `docker` formula only when it is missing and Homebrew exists.
4. Enroll the Docker certificate.
5. Create or reuse the context.
6. Verify with `docker --context NAME version --format '{{.Server.APIVersion}}'`.

- **Context rules:** the default name is `macus` (`--docker-context NAME`). An existing context with the same endpoint and a still-enrolled certificate is reused. With the same endpoint and a non-enrolled certificate, the TLS material is replaced with `docker context update`. A different endpoint is a conflict, and the existing context is preserved. `docker context use` runs only with `--docker-set-default`. `DOCKER_CONFIG` selects the configuration directory, and macus never edits `config.json`.
- **Compose and Buildx:** setup reports whether the CLI finds `compose` and `buildx`. When either is missing, Homebrew exists and no explicit `--docker-cli` was given, setup installs the `docker-compose` or `docker-buildx` formula and links its plugin binary into `$DOCKER_CONFIG/cli-plugins`, only when no plugin of that name exists there. A link is plugin installation, not configuration. An existing plugin is never replaced. An explicit `--docker-cli` marks an isolated or caller-managed client, as `--incus` does for Incus: setup then never runs Homebrew for the CLI or its plugins, and only reports missing plugins.
- **Versions:** the gateway does not refuse other CLI versions. Admission negotiates within the engine's API range. Status and doctor report the CLI, Compose and Buildx versions and say when they differ from the qualified pins. Acceptance covers only the pinned versions.
- **Environment:** doctor warns when `DOCKER_HOST` or `DOCKER_CONTEXT` is set to something other than the Macus context, because either one bypasses it.

### 10. Failure isolation

The Docker dispatch, engine lifecycle and readiness refresh run under their own supervisor. A crash, a missing catalog entry, a bad `docker.json` or an engine failure produces Docker-shaped failures only. Incus, runtime and MCP routes are unaffected. When Docker is disabled, the dispatch returns a Docker-shaped `503` (`docker not set up`) to an authenticated Docker-scoped caller, and the unknown-path failure to anyone else.

### 11. The gateway moves to `teals`

The gateway stays one Ranch listener on the same port, certificate files, trust store, ALPN `http/1.1` and TLS 1.3. On `teals` it is `Teals.Ranch` with `cowboy_clear` and the `teals` stream handler, in client mode `verify: :request`, which accepts any certificate or none and leaves trust to the gateway, as the `verify_fun` does today. `:cowboy_req.cert/1` and `Plug.Conn.get_peer_data/1` keep returning the certificate.

- **Selected by configuration.** A `transport` setting in `server/gateway.json`, `ssl` or `teals`, is read at server start. It starts as `ssl`. Docker requires `teals`.
- **Incus behaviour is preserved.** WebSockets still end when the client sends `close_notify`, because the stream handler turns half-close off for them. Native SFTP and NBD tunnels gain half-close only with an `opsmaru_incus` release whose raw relay reads the transport's message tags, treats read EOF as one direction, and no longer cuts the open direction at its fixed drain deadline while traffic flows.
- **Libraries first.** `teals`, that `opsmaru_incus` release, and an `opsmaru_containers` release whose `Transport.CowboyStream` handles `teals` messages are released before Macus depends on them. The library changes also work on `ssl`.
- **Revocation** keeps its 5 s bound for every kind of stream, so `teals`'s `close_timeout` is set inside it.
- **Before switching**, the default identity, any operator certificate and enrolled client certificates are checked with `teals`, because its verifier library may reject certificates OTP accepts (task 1.5).
- **Rollback** is setting `ssl` and restarting. Trust, certificates and configuration are unchanged. Docker is then unavailable until `teals` is selected again.

## Risks / Trade-offs

- **[Intermittent stdin write stall]** → It is open in the library. Large uploads can fail with `502` and leave partial destinations. Acceptance records every upload trial with fresh destinations, and `docs/docker.md` states the limitation until the library closes it.
- **[Shared listener load]** → Long BuildKit and log streams share the gateway listener's acceptor pool and connection limits with Incus. Acceptance runs Docker streams concurrently with Incus exec, and records connection limits and latency.
- **[Library API dependency]** → Decisions 4 and 5 need `opsmaru_containers` 0.2.0, which is released. BuildKit also needs the repeated-header fix (upmaru/opsmaru-containers#10), which is not released yet. Macus takes that release rather than carrying a fork (task 1.3).
- **[Dependency on an unbuilt library]** → Docker waits for `teals`, so it has no date. The first gate (task 1.4) runs on a prototype before the library is built out.
- **[New TLS stack under all gateway traffic]** → Incus, runtime, MCP and Docker move off OTP `:ssl` together. The `ssl` setting stays for rollback, and the gateway conformance suite runs on both.
- **[Native code]** → A fault in `teals`'s native code stops the whole server, not one connection.
- **[Revoking raw streams]** → After takeover, a raw relay runs in a library-owned process that holds the connection. The task 1.2 spike found that killing the Cowboy request process did not end it. Macus needs a handle from `opsmaru_containers` before task 3.2.
- **[CLI version drift]** → Homebrew's `docker` formula moves faster than the pins. Negotiation keeps it working within the API range, and status reports the drift. Acceptance remains pin-specific.
- **[No port forwarding]** → `-p` publishes inside the engine only. Documentation says so prominently, and service exposure stays future scope.

## Migration / Rollback

1. Pass the gates (tasks 1.4 and 1.5) and take the library releases (tasks 1.3 and 1.6).
2. Ship the server with the `transport` setting at `ssl`. Nothing changes for existing states.
3. Select `teals`, and accept Incus, runtime and MCP behaviour on it before Docker (task 5.3).
4. Enable Docker. It is opt-in and has no effect on states that do not enable it.

Disabling Docker means removing the context with `docker context rm` and revoking the certificate. The engine project stays as Incus data and is never deleted by Macus. Removing the `docker.json` record turns the start stage off. Setting `transport` back to `ssl` removes the Docker routes. Downgrading the package leaves the project as an ordinary Incus project.

## Open Questions

- When does `transport` default to `teals` for new and existing states?
