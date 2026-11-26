# Spec Delta

## Purpose

Lets unmodified Docker clients use Macus through its authenticated gateway, with a nested Docker engine that Incus hosts, without a second VM runtime and without changing Incus behaviour.

## ADDED Requirements

### Requirement: Docker routes on the gateway

The server SHALL serve the Docker Engine API on its authenticated HTTPS gateway listener, using the gateway's address, port and TLS identity. It SHALL dispatch to the Docker relay exactly `GET` and `HEAD` `/_ping`, any method on paths beginning `/v<digits>.<digits>/`, and `POST /grpc` and `POST /session` carrying `Upgrade: h2c`. Dispatch SHALL run before the unknown-path fallback. It MUST NOT change the handling of `/`, `/1.0`, `/runtime`, `/mcp` or any other path. The relay SHALL use `opsmaru_containers` and reach Incus only through the server's `opsmaru_incus` connection. Docker paths MUST NOT be prefixed or rewritten.

#### Scenario: Unmodified Docker client

- **WHEN** a Docker context with host `tcp://127.0.0.1:8443`, the gateway certificate as `ca`, and an enrolled Docker-scoped certificate and key runs `docker version`
- **THEN** the client negotiates through `/_ping`, sends versioned requests, and reports the engine's server version through the gateway

#### Scenario: Incus routes unchanged

- **WHEN** Docker is enabled and a standard Incus client uses the same gateway
- **THEN** discovery, REST and WebSocket requests on `/` and `/1.0` behave exactly as before

#### Scenario: Unversioned Docker path

- **WHEN** a client requests `/containers/json` without a version
- **THEN** the gateway returns its bounded unknown-path failure and no request reaches the engine

### Requirement: Docker credential scope

Docker routes SHALL require an enrolled gateway client certificate whose trust record includes the `docker` scope. Native Incus routes SHALL require the `incus` scope, and existing enrollments SHALL be treated as `incus`. A certificate without the required scope SHALL be refused before dispatch or upgrade. Docker routes SHALL refuse with a Docker-shaped 403. Runtime and MCP routes SHALL keep their bearer credentials. Docker certificates SHALL be enrolled through single-use enrollment with proof of the private key. Revoking a Docker certificate SHALL close its active Docker streams within the gateway's revocation interval.

#### Scenario: Incus certificate on a Docker route

- **WHEN** a client presents an enrolled Incus certificate without the `docker` scope to `/v1.57/containers/json`
- **THEN** the request is refused with a Docker-shaped 403 before the engine is dialed

#### Scenario: Docker certificate on an Incus route

- **WHEN** a client presents a Docker-scoped certificate to `/1.0/instances`
- **THEN** the request is refused before any guest stream opens

#### Scenario: Revoked during a stream

- **WHEN** the owner revokes a Docker certificate while `docker logs -f` is streaming through it
- **THEN** new requests with that certificate fail and the stream closes within the revocation interval

### Requirement: Nested engine lifecycle

The server SHALL ensure one Docker engine per state in Incus project `macus-docker` as instance `engine`, using `Opsmaru.Containers.Nested.ensure/3`. The project SHALL use the default project's images, profiles and networks, and keep its own storage volumes. The engine image SHALL be the prebuilt image pinned by Incus fingerprint in the package catalog, and it SHALL set `boot.autostart`. Lifecycle calls SHALL be serialized for each target. An uncertain create or start outcome SHALL be reconciled by observation and MUST NOT be replayed. Without a measured catalog entry the server SHALL report Docker as unavailable and MUST NOT substitute another image. Macus MUST NOT install packages inside the engine, delete the engine project, or replace the engine automatically when the catalog changes.

#### Scenario: First setup

- **WHEN** the owner route ensures the engine on a ready runtime with no `macus-docker` project
- **THEN** the project and engine are created from the pinned fingerprint, the engine runs dockerd, and the observed API range is returned

#### Scenario: Repeated ensure

- **WHEN** ensure runs again for an engine that is already running and owned
- **THEN** nothing is recreated and the same target and range are returned

#### Scenario: Outdated engine image

- **WHEN** the package catalog pins a different engine fingerprint from the one recorded for the running engine
- **THEN** status reports the engine image as outdated and the engine is left unchanged

### Requirement: Engine readiness

Admission SHALL use a `Docker.Capabilities` snapshot for the engine target with a monotonic expiry of at most 10 seconds. When the snapshot is absent or expired, a single refresh per target SHALL observe readiness within a bounded deadline. Concurrent requests SHALL wait on that refresh. A missing, stopped or unready engine, or a runtime that is not ready, SHALL produce a Docker-shaped 503 naming the state. No request SHALL reach the backend without a fresh snapshot. A Macus engine lifecycle change SHALL clear the snapshot for that target. A transport dial failure, or an engine failure before any response byte reaches the client, SHALL invalidate the snapshot and trigger the single refresh. That request SHALL then receive a Docker-shaped 503 naming the observed state, and MUST NOT be replayed.

#### Scenario: Engine stopped with no fresh snapshot

- **WHEN** the engine instance is stopped, the snapshot is absent or expired, and a client runs `docker ps`
- **THEN** the refresh observes the stopped engine, the client receives a 503 naming it, and no exec operation is created

#### Scenario: Engine stops while the snapshot is fresh

- **WHEN** the engine stops outside Macus less than 10 seconds after a successful refresh, and a client runs `docker ps`
- **THEN** the dial fails before any response is committed, the snapshot is invalidated, the client receives a 503 naming the stopped engine, the request is not replayed, and later requests are refused by admission without dialing until a refresh observes a running engine

### Requirement: Exec transport

The server SHALL dial dockerd with the exec bridge transport packaged in `opsmaru_containers`. The bridge helper SHALL be installed in the engine image. Each Docker client connection SHALL use its own engine stream and Incus exec operation, with no pooling or multiplexing. A client disconnect SHALL end its exec operation. Macus MUST NOT ship a private copy of the library's acceptance scripts.

#### Scenario: Client disconnect

- **WHEN** a client disconnects during a large archive download
- **THEN** the corresponding exec operation reaches a terminal state and no bridge helper remains for it

### Requirement: Bind path policy

The bind source callback SHALL accept only absolute, normalized macOS paths inside a configured Macus share, and SHALL map each to the same path. Each share SHALL be attached to the engine as an Incus disk device at its macOS path, with the share's access mode. Paths outside every share, relative or non-normalized paths, and paths that resolve outside a share SHALL be denied with a Docker-shaped error naming the share requirement. Docker setup MUST NOT create, widen or change a share.

#### Scenario: Source inside a share

- **WHEN** `docker run -v /Users/me/src/app:/app` runs and `/Users/me/src` is a configured share
- **THEN** the container sees the share's files at `/app`

#### Scenario: Source outside every share

- **WHEN** a bind source is `/Users/me/Documents` and no share contains it
- **THEN** the request is refused before reaching the engine and the error names the share requirement

### Requirement: Raw streams and half-close

Attach, attached exec, BuildKit `h2c` and WebSocket upgrades SHALL be relayed only after the engine's upstream handshake succeeds. The client SHALL receive the engine's upgrade response headers. A raw-stream request without an `Upgrade` header SHALL be refused with a Docker-shaped 400. A TLS `close_notify` from the client SHALL deliver write EOF to the engine while output continues to reach the client. Engine EOF SHALL shut down only the client's read side.

#### Scenario: Stdin EOF over TLS

- **WHEN** `docker exec -i CONTAINER sh -c 'cat; echo done'` reads a file from stdin through the gateway
- **THEN** the full input reaches the container, `done` is printed after input ends, and the command exits 0

#### Scenario: BuildKit session

- **WHEN** `docker buildx build` uses the Docker driver through the gateway
- **THEN** `/grpc` and `/session` upgrade with `h2c` and the build completes

### Requirement: Docker failure isolation

Docker dispatch, engine lifecycle and readiness SHALL run under their own supervision. Their failures, a missing catalog entry, or invalid Docker state SHALL produce only Docker-shaped failures, and MUST NOT make Incus, runtime or MCP routes unavailable. When Docker is not set up, an authenticated Docker-scoped caller SHALL receive a Docker-shaped 503, and any other caller SHALL receive the unknown-path failure.

#### Scenario: Docker supervisor crash

- **WHEN** the Docker readiness process crashes repeatedly
- **THEN** Incus, runtime and MCP requests keep succeeding and Docker requests fail with Docker-shaped errors

### Requirement: Docker acceptance

Unit, protocol and fixture tests SHALL run without a VM and MUST NOT be reported as engine acceptance. Hardware acceptance SHALL require explicit opt-in, an isolated state directory, an isolated `DOCKER_CONFIG` and `INCUS_CONF`, and the library's pinned Docker CLI, Compose and Buildx versions. It SHALL cover these, through the gateway:

- version
- pull
- run
- attached exec with stdin EOF
- followed logs
- BuildKit build
- Compose up and down
- a bind mount inside a share
- refusal outside a share
- certificate revocation
- engine survival across a runtime restart
- concurrent Docker and Incus streams

Upload trials SHALL use fresh destinations, and every partial result SHALL be recorded.

#### Scenario: No false completion

- **WHEN** unit tests pass but the hardware run has not been performed
- **THEN** the Docker acceptance tasks remain unchecked and the change is not treated as complete
