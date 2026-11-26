# Tasks

## 1. Prerequisites and qualification spike

- [ ] 1.1 Get an `opsmaru-containers` release that packages `Opsmaru.Containers.Transport.ExecBridge` with the helper source, the split raw entry (`Raw.open/3`, `Raw.run/4`), the optional same-listener `Docker.CowboyHandler` with a `fallback` handler, and request and exchange telemetry. The code is merged to the library's `develop` (change `add-cowboy-gateway-embedding`, upmaru/opsmaru-containers#6) and not yet released. Record the released version and Hex checksum here. Macus depends only on the released package.
- [ ] 1.2 Spike on isolated state, with explicit opt-in, against a disposable engine. Mount the Docker route set on a scratch build of the gateway listener and qualify each item below. Record the observed requests and results. If half-close fails, return this change to planning (design decision 8). Run it after the library records its measurement of the pinned CLI's TLS half-close (its task 2.5). If the shared listener shows a route collision or Cowboy constraint, switch to the decision 1 fallback in the design before task 3.
  - Go `close_notify` half-close over Erlang `:ssl` TLS 1.3, in both directions: `docker exec -i CONTAINER sh -c 'cat; echo done'` with redirected stdin must print `done` (upstream evidence predicts it will not)
  - closing an active raw relay on certificate revocation, from outside the library-owned relay process
  - the pinned CLI's `Upgrade` headers on attach and exec start
  - BuildKit `/grpc` and `/session` with `h2c` through Cowboy `switch_protocol` and takeover
  - Go's acceptance of the gateway certificate as `ca` for `127.0.0.1`

## 2. Engine image and catalog

- [ ] 2.1 Add the engine image build to the appliance image pipeline: Debian 13 arm64, Docker Engine 29.10.0 and the bridge helper from the library release. Record the Incus fingerprint, Docker version, helper digest, source revision and attestation. Verify with the pipeline's image verification. No catalog entry is written until a measured image exists.
- [ ] 2.2 Add the engine catalog entry and its loader to the server. Verify that an absent, malformed or unmeasured entry yields `unavailable`, and that no other image is substituted.

## 3. Server

- [ ] 3.1 Add `opsmaru_containers` to `server/mix.exs`. Extend the canonical Hex-only dependency check in `Integration/scripts/check-server.sh` to it, and verify that the lockfile records the Hex checksum.
- [ ] 3.2 Add certificate scopes to gateway trust, treating existing records as `incus`, and Docker-scoped single-use enrollment. Verify trust tests for the migration, scope refusal in both directions, enrollment replay and revocation closing a Docker stream.
- [ ] 3.3 Add `Macus.Docker` host callbacks (context from the verified peer certificate and the configured target, authorize by scope, and the share bind map). Verify tests for sources inside, outside and escaping shares, relative sources and read-only shares.
- [ ] 3.4 Add engine lifecycle: project creation with the specified features, `Nested.ensure/3` serialized per target, `docker.json`, and the `/docker/engine` owner route. Verify tests with a scripted Incus backend for first create, repeat, uncertain outcome reconciliation, an outdated fingerprint and a missing catalog entry.
- [ ] 3.5 Add the readiness cache with single-flight refresh and Docker-shaped 503s. Add invalidation on Macus lifecycle changes and on dial or pre-commit engine failures. Verify tests for expiry, concurrent waiters, a stopped engine with an expired snapshot, an engine stopped while the snapshot is fresh (one 503, no replay, no further dials until refresh), and a runtime that is not ready.
- [ ] 3.6 Add Docker dispatch to the gateway: mount `Macus.Gateway.DockerHandler` as the fallback of `Opsmaru.Incus.Gateway.CowboyHandler`. It resolves the verified certificate's trust record per request and delegates to `Docker.CowboyHandler` with that record as `host_peer` and `Plug.Cowboy.Handler` as its fallback. Mount `Docker.Plug` on the dispatched router paths with the same record in `conn.private[:opsmaru_containers_peer]`, and record Docker requests in the gateway access log from the library's telemetry. Verify route tests for every dispatched and non-dispatched path, detached exec, a raw route without `Upgrade`, and identical identity on the Plug and raw paths. Verify that Incus routes are unchanged (existing conformance suite), and run the raw relay tests against a scripted engine with TLS half-close.
- [ ] 3.7 Put Docker processes under their own supervisor. Verify that repeated crashes and a bad `docker.json` leave Incus, runtime and MCP tests passing.

## 4. Client

- [ ] 4.1 Add Docker CLI discovery and Homebrew installation, reusing the Incus client rules, plus the Compose and Buildx plugin links. Verify fixture-process tests for present, missing with Homebrew, missing without Homebrew, an explicit `--docker-cli` with missing plugins (no Homebrew run, plugins reported), and an existing plugin left untouched.
- [ ] 4.2 Add Docker key generation, enrollment, and context create, reuse, update and conflict handling through standard `docker context` commands under `DOCKER_CONFIG`. Verify command-sequence tests, including that `config.json` is never written and staged keys are removed.
- [ ] 4.3 Add `macus docker setup|status`, the `start --docker` stage with its flags and persisted enablement, and the Docker checks in `doctor`, with human and JSON output. Verify CLI tests for success, a stopped runtime, a failed Docker stage after Incus setup, Docker not enabled, and the environment override warning.

## 5. Documentation and verification

- [ ] 5.1 Write `docs/docker.md` covering scope, shares, the lack of port forwarding, pinned versions and the open upload stall. Update `README.md`, `docs/cli.md`, `docs/server.md` and `docs/api.md`.
- [ ] 5.2 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`.
- [ ] 5.3 With explicit opt-in on isolated state, isolated `DOCKER_CONFIG` and `INCUS_CONF`, and the pinned CLI, Compose and Buildx, run hardware acceptance through the gateway. Cover version, pull, run, attached exec with stdin EOF, followed logs, BuildKit build, Compose up and down, a bind inside a share, refusal outside a share, certificate revocation, and engine survival across a runtime restart. Leave unchecked until it passes on hardware.
- [ ] 5.4 Run hardware measurement of concurrent Docker and Incus streams: a paused large download, a BuildKit build and an Incus exec running together. Record the latency of independent requests and any head-of-line delay. Leave unchecked until it is measured on hardware.
- [ ] 5.5 Run hardware upload trials through the gateway: 8 MiB paced and unpaced, and 24 MiB, each to a fresh destination, recording every result including partial files. Leave unchecked until recorded on hardware.
- [ ] 5.6 Report the hardware results to `opsmaru-containers` as its consumer acceptance (its task 4.5). Leave unchecked until it is recorded there.
