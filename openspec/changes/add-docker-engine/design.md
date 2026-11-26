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

**Macus today.** The server runs one Cowboy TLS 1.3 listener (default `127.0.0.1:8443`). Its certificate is ECDSA P-384 for `localhost`, `127.0.0.1` and `::1` (`Macus.Gateway.Certificate`). It serves `/runtime`, native `/1.0` and `/mcp`. Native Incus requires an enrolled TLS client certificate, and runtime and MCP require scoped bearer credentials. Incus upgrades are relayed by opsmaru_incus's Cowboy handler: it completes the upstream handshake, then casts `{:switch_protocol, headers, RawTunnel, relay}`, and `RawTunnel.takeover/7` receives the client socket and buffered bytes. The server reaches Incus through `Opsmaru.Incus.Connection.unix!` on the Swift `incus.sock`, which the flow-controlled vsock relay carries. Shares are explicit VirtioFS directories (tag `tama-shares`), read-only by default. Workload service forwarding is documented future scope.

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
- Docker on a Unix socket, `DOCKER_HOST` path prefixes, or a second TCP port. See decision 1 for the fallback.
- A command that removes the engine. Its project stays an ordinary Incus project that the user can inspect or delete with `incus`.
- Any workload operation that Incus provides, or a Docker-to-Incus translation layer.

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
- **Rejected: a Unix socket.** It is local-only and would give Docker a second authentication model outside gateway trust. The library's `Raw.relay/4` takes any `Transport.Stream`, so a TLS frontend needs no Unix socket.
- **Fallback: a second TLS port on the same server, identity and trust.** Use it only if the qualification spike (task 1.2) finds a real collision or a Cowboy constraint on the shared listener. It would serve Docker at the root path space with no other change to this design.
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

The library will gain a narrow Cowboy adapter, `Opsmaru.Containers.Docker.CowboyHandler`. It is compiled only when `:cowboy_req` is loaded; `cowboy` is already an optional dependency. It is modelled on opsmaru_incus's handler:

- It opens no listener.
- It takes only Docker raw upgrades on the dispatched paths.
- It sends everything else to its own `fallback`.
- It rests on a split relay entry. `Raw.open/4` admits the request, dials, completes the upstream handshake, and returns either `{:upgrade, status_headers, backend, tail}` or `{:http, status, headers, body}`. `Raw.run/4` relays both streams from `takeover/7`, using a frontend stream over the Cowboy transport that includes Cowboy's buffered bytes.

The listener chain becomes:

1. `Opsmaru.Incus.Gateway.CowboyHandler`
2. its fallback, `Opsmaru.Containers.Docker.CowboyHandler`
3. that handler's fallback, `Plug.Cowboy.Handler`

Ordinary Docker HTTP reaches `Docker.Plug` through the router's dispatched paths.

- **Why in the library, not Macus:** the takeover glue (buffer handoff, response ordering, close semantics) is the subtle part. Central Opsmaru also hosts on Cowboy. opsmaru_incus set the precedent of shipping the same-listener handler with the relay.
- **Not a full gateway module:** opsmaru_incus's `Gateway` also carries admission, policy, identity, leases and exchange telemetry for Incus. opsmaru_containers already has its own equivalents (`Admission`, `Host`, `Context`, `Plug`, `Raw`, `RawTunnel`). TLS, the listener, trust and enrollment stay in the Macus gateway. The library needs only this handler, plus telemetry events that the gateway access log can consume.

- Requests that need a raw stream but carry no `Upgrade` header (Docker's legacy raw `200` attach) get a Docker-shaped 400 that names the missing upgrade. The pinned CLI sends `Upgrade: tcp` for attach and exec start. Task 1.2 confirms that against the CLI's actual requests.
- **Rejected: a separate Ranch listener with its own HTTP/1.1 parser.** That is a second public HTTP implementation, outside the gateway's existing bounds and access log.

### 5. Exec transport moves into the library

The qualified bridge becomes a packaged module, `Opsmaru.Containers.Transport.ExecBridge`, in an `opsmaru_containers` release. Its helper source and reproducible build instructions also move into the library. The Macus engine image installs the helper. The dialer receives the server's `Opsmaru.Incus` connection for the target, a bounded `RequestContext`, the helper's path, and Incus stream limits.

- **Why:** central Opsmaru needs the same transport. The library already owns the qualification evidence. Macus's rules keep shared Incus mechanics in libraries, not duplicated in the host.
- **Each Docker client connection is one Incus exec operation** with its own WebSockets, each on its own `incus.sock` connection through the flow-controlled relay. There is no pooling or multiplexing. Acceptance measures whether a stalled stream delays others (task 5.4).

### 6. Bind mounts map through explicit shares

`map_bind_source/2` accepts an absolute, normalized macOS path only when it lies inside a configured share. It returns the same absolute path. The engine instance receives each share as an Incus disk device whose source is the share's guest mount and whose path inside the engine is the share's macOS path. So `docker run -v "$PWD":/app` works unchanged when `$PWD` is inside a share.

- Paths outside every share, symlinks that leave a share, and relative or non-normalized sources are denied. The library returns a Docker-shaped error naming the share requirement.
- A read-only share stays read-only. Writes fail inside the container with the kernel's read-only error. The policy cannot upgrade a share's access.
- Adding or removing a share keeps its existing runtime rules. The next `ensure` brings the engine's disk devices in line.
- Named volumes use the library's existing policy: local-driver bind options and custom drivers are refused.

### 7. Readiness is cached per target and refreshed on demand

The server keeps one `Docker.Capabilities` snapshot per target with a 10 s monotonic expiry. On a Docker request with an absent or expired snapshot, one single-flight refresh calls `Nested.readiness/2` with a bounded deadline. Concurrent requests wait on that refresh, up to their admission deadline.

An unready engine, a guest that is not ready, or a missing engine produces a Docker-shaped `503` with a message naming the state (`engine stopped`, `runtime not ready`, `docker not set up`). Admission never reaches the backend without a fresh snapshot.

A fresh snapshot can still be stale if the engine stops outside Macus (for example `incus stop macus-docker/engine`). Three rules bound that window to one request:

- Macus's own lifecycle calls clear the snapshot.
- A dial failure, or an engine failure before any response byte reaches the client, invalidates the snapshot and triggers the single-flight refresh.
- The failing request gets the Docker-shaped 503 for the state the refresh observes, and is never replayed.

Later requests are refused by admission, without dialing, until a refresh sees a running engine. The relay's existing "honest upstream failure before commitment" behaviour makes this safe: nothing was sent to the client yet.

### 8. TLS half-close is a qualification gate

Docker clients half-close hijacked streams. `docker exec -i … < file` and `docker cp` depend on the client's write EOF reaching dockerd while output keeps flowing back. Over TLS, Go's `tls.Conn.CloseWrite` sends `close_notify`. The server's frontend stream adapter must treat that as read EOF while keeping the write side open, and must shut down only its own write side on backend EOF.

This depends on Erlang `:ssl` behaviour under TLS 1.3, so task 1.2 qualifies it before any other server work. If it cannot be met, decision 1's fallback does not help, because the fallback also uses TLS. The change then returns to planning instead of shipping a Docker endpoint without stdin EOF.

### 9. Client setup mirrors Incus client setup

`macus docker setup` runs these steps in order, and `macus start --docker` runs them as its last stage:

1. Read the runtime status. Refuse when the runtime is not ready, and never boot it.
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

## Risks / Trade-offs

- **[Intermittent stdin write stall]** → It is open in the library. Large uploads can fail with `502` and leave partial destinations. Acceptance records every upload trial with fresh destinations, and `docs/docker.md` states the limitation until the library closes it.
- **[Shared listener load]** → Long BuildKit and log streams share the gateway listener's acceptor pool and connection limits with Incus. Acceptance runs Docker streams concurrently with Incus exec, and records connection limits and latency.
- **[Library API dependency]** → Decisions 4 and 5 need an `opsmaru_containers` release. Macus work after the spike waits for it rather than carrying a fork.
- **[CLI version drift]** → Homebrew's `docker` formula moves faster than the pins. Negotiation keeps it working within the API range, and status reports the drift. Acceptance remains pin-specific.
- **[No port forwarding]** → `-p` publishes inside the engine only. Documentation says so prominently, and service exposure stays future scope.

## Migration / Rollback

Docker is opt-in and has no effect on existing states until it is enabled. Disabling means removing the context with `docker context rm` and revoking the certificate. The engine project stays as Incus data and is never deleted by Macus. Removing the `docker.json` record turns the start stage off. Downgrading the package leaves the project as an ordinary Incus project.
