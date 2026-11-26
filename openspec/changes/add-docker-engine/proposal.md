# Proposal

## Why

Many developer tools only speak the Docker Engine API: `docker`, `docker compose`, `docker buildx`, and libraries that read `DOCKER_HOST` or a Docker context. Macus users who want those tools today need a second VM runtime beside Macus, which is what Macus exists to avoid.

`opsmaru_containers` 0.1.0 (Hex, 2026-11-26) now provides the missing piece as a pure library: a Docker Engine API relay to a nested dockerd running in an Incus system container, reached only through `opsmaru_incus`. On the pinned stack (opsmaru_incus 0.2.10, Incus 7.0.1, Docker Engine 29.10.0) it passed Docker CLI 29.10.0, Compose 5.8.0 and Buildx 0.39.1 acceptance: pull, run, attached exec, followed logs, BuildKit build, Compose up and down. The library leaves the listener, verified identity, engine image, transport, bind path mapping and readiness publication to the host. Its last open task is Macus consumer acceptance. Macus already locks opsmaru_incus 0.2.10, the gateway release that fixed the premature idle close of quiet streams.

## What Changes

- **Docker on an owner-private Unix socket.** When Docker is enabled, the Macus server serves the Docker Engine API on `STATE/server/docker.sock` (mode 0600, in the owner-only `STATE/server` directory), with the same Cowboy stack as the gateway. The `docker` CLI connects with `unix://`. The socket serves only Docker, and the TLS gateway serves no Docker route, because Docker cannot run over TLS under OTP `:ssl` (see "Spike outcome" below).
- **Access is the owner's account.** File permissions limit the socket to the macOS account that owns the state. There is no Docker certificate to enroll or revoke, Docker access grants no Incus, runtime or MCP access, and gateway credentials grant no Docker access. Docker is local only in this change.
- **One nested engine.** The server ensures one engine instance in a dedicated Incus project through `Opsmaru.Containers.Nested.ensure/3`, from a pinned prebuilt engine image (Debian 13 arm64, Docker Engine 29.10.0 and the exec bridge helper), and publishes its readiness to admission. Incus starts the engine automatically when the guest boots.
- **A packaged exec transport.** The server dials dockerd through Incus exec with the bridge helper that passed the library's exec qualification. The dialer and helper are moved into `opsmaru_containers` as packaged, released code before Macus depends on them. Macus does not keep its own copy.
- **Bind mounts under explicit shares only.** `docker run -v` sources are mapped only when they fall inside an explicitly configured Macus share. The share is attached to the engine at the same absolute path. Any other source is refused with a Docker-shaped error that names the share requirement. Nothing new is shared implicitly.
- **Opt-in client setup.** `macus docker setup`, and `macus start --docker` (which persists the choice for later starts), ensure the engine and open its socket, reuse or install the Docker CLI, and create a Docker context named `macus` with standard `docker context` commands. Setup succeeds only when `docker --context macus version` reaches the engine. The default context changes only with `--docker-set-default`. `DOCKER_CONFIG` isolates the client configuration, as `INCUS_CONF` does for Incus.
- **Doctor and status** report engine state, the negotiated API range, the socket, the Docker context, and environment overrides (`DOCKER_HOST`, `DOCKER_CONTEXT`) that would bypass it.

## Capabilities

### New Capabilities

- `docker-engine`: the Docker socket and its access boundary, nested engine lifecycle and readiness, exec transport, raw streams and half-close, bind path policy, failure isolation and acceptance.

### Modified Capabilities

- `startup-bootstrap`: optional Docker setup during `macus start`, with the same conflict, isolation and success rules as Incus client setup.
- `client-cli`: `macus docker setup` and `macus docker status`, plus Docker checks in `doctor`.

## Impact

- **Upstream prerequisite:** an `opsmaru_containers` release that packages the exec bridge dialer and the helper source, and adds a same-listener Cowboy handler for Docker raw upgrades (see design decision 4). It is released as `opsmaru_containers` 0.2.0 (Hex, 2026-11-26). BuildKit also needs a later release that forwards repeated request headers separately (upmaru/opsmaru-containers#10, not yet released). Macus does not vendor acceptance scripts.
- **Spike outcome:** the task 1.2 spike (2026-11-27) failed the half-close gate over the TLS gateway: attached `docker run`, `docker exec` and `docker attach` lost engine output after the client's write EOF while the CLI exited 0, because OTP `:ssl` stops a connection on the peer's `close_notify`. A re-spike over an owner-private Unix socket passed the gate, and BuildKit passed once repeated headers were split (design decisions 1, 2 and 8). The design now uses the socket. Passing the spike is not hardware acceptance (task 5.3).
- **Server:** `server/mix.exs` (add `opsmaru_containers`), the Docker socket listener and its Docker-only router, a `Macus.Docker` host module (context, authorize, bind mapping), engine lifecycle and readiness cache, and the `/docker/engine` owner route. Gateway routes and trust do not change.
- **Appliance image pipeline:** a new pinned engine image artifact with a recorded Incus fingerprint, Docker and helper versions, and attestation, beside the existing appliance catalog.
- **Swift client:** `macus docker setup|status`, a Docker stage in `StartupCoordinator`, Docker checks in `doctor`, and Docker CLI discovery and Homebrew installation that reuse the Incus client rules.
- **Documentation:** `README.md`, `docs/cli.md`, `docs/server.md`, `docs/api.md`, `docs/development.md`, and a new `docs/docker.md` covering the socket, local-only access, shares, ports and pinned versions.
- **Not changed:** gateway routes, trust and behaviour, the Swift sockets and vsock relay, workload operations, and the explicit-share rule. Docker published ports are not forwarded to macOS in this change.
- **Acceptance:** opt-in hardware acceptance through the Docker socket on isolated state, recorded apart from unit test success. It also serves as `opsmaru_containers` task 4.5, the consumer acceptance.
