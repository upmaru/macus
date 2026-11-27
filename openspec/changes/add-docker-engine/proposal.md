# Proposal

## Why

Many developer tools only speak the Docker Engine API: `docker`, `docker compose`, `docker buildx`, and libraries that read `DOCKER_HOST` or a Docker context. Macus users who want those tools today need a second VM runtime beside Macus, which is what Macus exists to avoid.

`opsmaru_containers` 0.1.0 (Hex, 2026-11-26) now provides the missing piece as a pure library: a Docker Engine API relay to a nested dockerd running in an Incus system container, reached only through `opsmaru_incus`. On the pinned stack (opsmaru_incus 0.2.10, Incus 7.0.1, Docker Engine 29.10.0) it passed Docker CLI 29.10.0, Compose 5.8.0 and Buildx 0.39.1 acceptance: pull, run, attached exec, followed logs, BuildKit build, Compose up and down. The library leaves the listener, verified identity, engine image, transport, bind path mapping and readiness publication to the host. Its last open task is Macus consumer acceptance. Macus already locks opsmaru_incus 0.2.10, the gateway release that fixed the premature idle close of quiet streams.

## What Changes

- **Docker on the existing gateway.** The Macus server serves the Docker Engine API on its authenticated HTTPS gateway, on the same address and TLS identity as Incus, at Docker's own paths: `/_ping`, versioned `/v<major>.<minor>/*`, and BuildKit's `/grpc` and `/session`. None of these overlap `/1.0`, `/runtime` or `/mcp`. The `docker` CLI connects with `tcp://<gateway>` and TLS client certificates, as `incus` does.
- **A Docker-scoped client certificate.** Docker clients authenticate with an enrolled gateway client certificate that carries a `docker` scope. The scope grants Docker routes only, and Incus client certificates do not grant Docker access. Enrollment, revocation and stream closure reuse the gateway credential lifecycle.
- **The gateway moves to `teals`.** OTP `:ssl` cannot keep writing after a client's `close_notify`, which Docker needs. The gateway gains a `transport` setting, `ssl` or `teals`, with the same port, certificates, trust and clients. Docker is served only on `teals`.
- **One nested engine.** The server ensures one engine instance in a dedicated Incus project through `Opsmaru.Containers.Nested.ensure/3`, from a pinned prebuilt engine image (Debian 13 arm64, Docker Engine 29.10.0 and the exec bridge helper), and publishes its readiness to admission. Incus starts the engine automatically when the guest boots.
- **A packaged exec transport.** The server dials dockerd through Incus exec with the bridge helper that passed the library's exec qualification. The dialer and helper are moved into `opsmaru_containers` as packaged, released code before Macus depends on them. Macus does not keep its own copy.
- **Bind mounts under explicit shares only.** `docker run -v` sources are mapped only when they fall inside an explicitly configured Macus share. The share is attached to the engine at the same absolute path. Any other source is refused with a Docker-shaped error that names the share requirement. Nothing new is shared implicitly.
- **Opt-in client setup.** `macus docker setup`, and `macus start --docker` (which persists the choice for later starts), ensure the engine, enroll the Docker certificate, reuse or install the Docker CLI, and create a Docker context named `macus` with standard `docker context` commands. Setup succeeds only when `docker --context macus version` reaches the engine. The default context changes only with `--docker-set-default`. `DOCKER_CONFIG` isolates the client configuration, as `INCUS_CONF` does for Incus.
- **Doctor and status** report engine state, the negotiated API range, the Docker context, and environment overrides (`DOCKER_HOST`, `DOCKER_CONTEXT`) that would bypass it.

## Capabilities

### New Capabilities

- `docker-engine`: the Docker route set on the gateway, Docker credential scope, the gateway transport setting, nested engine lifecycle and readiness, exec transport, raw streams and half-close, bind path policy, failure isolation and acceptance.

### Modified Capabilities

- `startup-bootstrap`: optional Docker setup during `macus start`, with the same conflict, isolation and success rules as Incus client setup.
- `client-cli`: `macus docker setup` and `macus docker status`, plus Docker checks in `doctor`.

## Impact

- **Upstream prerequisites:** `opsmaru_containers` 0.2.0 (Hex, 2026-11-26) has the packaged exec bridge and the Cowboy handler for raw upgrades. Still needed and not released: the repeated-header fix (upmaru/opsmaru-containers#10); its Cowboy stream handling `teals` messages and a handle to end a relay on revocation; `teals` itself (designed, not built); and an `opsmaru_incus` raw relay that keeps half-close over it. Macus does not vendor acceptance scripts or carry forks.
- **Spike outcome:** the task 1.2 spike (2026-11-27) failed the half-close gate over the OTP TLS gateway: attached `docker run`, `docker exec` and `docker attach` lost engine output after the client's write EOF while the CLI exited 0. A Unix socket passed it and was this change's design for a time. Docker now returns to the gateway on `teals` and waits for it, with no interim socket. A `teals` prototype has since passed with Docker CLI 29.8.2 and a scripted engine; the pinned CLI and the gateway certificate are still to be shown (task 1.4).
- **Server:** `server/mix.exs` (add `opsmaru_containers` and `teals`), the gateway listener and its `transport` setting, the gateway router (Docker route dispatch before unknown paths), certificate scopes in gateway trust and enrollment, a `Macus.Docker` host module (context, authorize, bind mapping), engine lifecycle and readiness cache, and the `/docker/engine` owner route.
- **Appliance image pipeline:** a new pinned engine image artifact with a recorded Incus fingerprint, Docker and helper versions, and attestation, beside the existing appliance catalog.
- **Swift client:** `macus docker setup|status`, a Docker stage in `StartupCoordinator`, Docker checks in `doctor`, and Docker CLI discovery and Homebrew installation that reuse the Incus client rules.
- **Documentation:** `README.md`, `docs/cli.md`, `docs/server.md`, `docs/api.md`, `docs/development.md`, and a new `docs/docker.md` covering scope, shares, ports and pinned versions.
- **Not changed:** Incus routes and behaviour, the Swift sockets and vsock relay, workload operations, and the explicit-share rule. Docker published ports are not forwarded to macOS in this change.
- **Acceptance:** opt-in hardware acceptance on isolated state, recorded apart from unit test success. It also serves as `opsmaru_containers` task 4.5, the consumer acceptance.
