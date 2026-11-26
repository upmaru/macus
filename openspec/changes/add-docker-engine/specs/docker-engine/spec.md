# Spec Delta

## Purpose

Lets unmodified Docker clients on the Mac use Macus through an owner-private Unix socket, with a nested Docker engine that Incus hosts, without a second VM runtime and without changing Incus behaviour.

## ADDED Requirements

### Requirement: Docker socket

When Docker is enabled for the state, the server SHALL serve the Docker Engine API on a Unix socket at `STATE/server/docker.sock`, over plain HTTP/1.1. The socket SHALL serve only the Docker relay, with Docker paths neither prefixed nor rewritten, and MUST NOT serve Incus, runtime, MCP or other server routes. The relay SHALL use `opsmaru_containers` and reach Incus only through the server's `opsmaru_incus` connection. The TLS gateway MUST NOT serve Docker routes, and its handling of every path SHALL be unchanged. When the socket path exceeds 103 bytes, the server SHALL refuse to enable Docker with an error naming the limit and the path, and MUST NOT place the socket elsewhere. When Docker is not enabled, the socket SHALL NOT exist.

#### Scenario: Unmodified Docker client

- **WHEN** a Docker context with host `unix://STATE/server/docker.sock` runs `docker version`
- **THEN** the client negotiates through `/_ping`, sends versioned requests, and reports the engine's server version

#### Scenario: Incus routes unchanged

- **WHEN** Docker is enabled and a standard Incus client uses the gateway
- **THEN** discovery, REST and WebSocket requests on `/` and `/1.0` behave exactly as before

#### Scenario: Docker path on the gateway

- **WHEN** a client requests `/v1.57/containers/json` on the TLS gateway with an enrolled Incus certificate
- **THEN** the gateway returns its unknown-path failure and no request reaches the engine

#### Scenario: Server route on the socket

- **WHEN** a client sends `GET /1.0` or `GET /runtime/status` to the Docker socket
- **THEN** no Incus, runtime or MCP handler runs and no guest stream opens

#### Scenario: Socket path too long

- **WHEN** Docker is enabled for a state directory whose `server/docker.sock` path is longer than 103 bytes
- **THEN** enabling fails with an error naming the limit and the path, and no socket is created

### Requirement: Docker access boundary

Before binding the Docker socket, the server SHALL verify that `STATE/server` is a directory owned by the server's account with mode 0700. It SHALL set the socket to mode 0600. An existing file at the socket path SHALL be removed only when it is a socket owned by the server's account. Any other file type, a symlink, or another owner SHALL be refused, and the socket SHALL NOT be opened. Every connection on the socket SHALL be treated as the state's owner, and host policy SHALL see that one principal on ordinary HTTP and raw streams alike. Docker access MUST NOT grant Incus, runtime or MCP access, and gateway certificates and bearer credentials MUST NOT grant Docker access. Docker setup MUST NOT enroll a gateway certificate or change gateway trust.

#### Scenario: Socket permissions

- **WHEN** the server opens the Docker socket
- **THEN** the socket has mode 0600 inside an owner-only `STATE/server` directory

#### Scenario: Unsafe file at the socket path

- **WHEN** a regular file or a symlink exists at `STATE/server/docker.sock` as the server opens the socket
- **THEN** the file is left in place, the socket is not opened, and Docker status reports the path as unsafe

#### Scenario: Setup leaves gateway trust alone

- **WHEN** `macus docker setup` succeeds
- **THEN** no gateway client certificate or enrollment token has been added

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

Attach, attached exec, BuildKit `h2c` and WebSocket upgrades SHALL be relayed only after the engine's upstream handshake succeeds. The client SHALL receive the engine's upgrade response headers. A raw-stream request without an `Upgrade` header SHALL be refused with a Docker-shaped 400 before admission or dial, except a detached exec start, which SHALL be served as ordinary HTTP. A repeated request header SHALL reach the engine as separate values. A write shutdown from the client SHALL deliver write EOF to the engine while output continues to reach the client. Engine EOF SHALL shut down only the client's read side.

#### Scenario: Stdin EOF

- **WHEN** `docker exec -i CONTAINER sh -c 'cat; echo done'` reads a file from stdin through the socket
- **THEN** the full input reaches the container, `done` is printed after input ends, and the command exits 0

#### Scenario: Attached run without stdin

- **WHEN** `docker run --rm IMAGE sh -c 'echo hello'` runs through the socket
- **THEN** `hello` is printed and the command exits 0

#### Scenario: Detached exec

- **WHEN** `docker exec -d CONTAINER touch /tmp/x` runs through the socket
- **THEN** the exec start is served as ordinary HTTP without an upgrade and the command runs

#### Scenario: Raw stream without an upgrade

- **WHEN** a client sends `POST /v1.57/containers/ID/attach` without an `Upgrade` header
- **THEN** it receives a Docker-shaped 400 and no exec operation is created

#### Scenario: BuildKit session

- **WHEN** `docker buildx build` uses the Docker driver through the socket
- **THEN** `/grpc` and `/session` upgrade with `h2c`, each `X-Docker-Expose-Session-Grpc-Method` value reaches the engine as its own header, and the build completes

### Requirement: Docker failure isolation

The Docker socket listener, engine lifecycle and readiness SHALL run under their own supervision. Their failures, a missing catalog entry, an unusable socket path, or invalid Docker state SHALL produce only Docker-shaped failures or a missing socket, and MUST NOT make the gateway or its Incus, runtime or MCP routes unavailable.

#### Scenario: Docker supervisor crash

- **WHEN** the Docker readiness process crashes repeatedly
- **THEN** Incus, runtime and MCP requests keep succeeding and Docker requests fail with Docker-shaped errors

### Requirement: Docker acceptance

Unit, protocol and fixture tests SHALL run without a VM and MUST NOT be reported as engine acceptance. Hardware acceptance SHALL require explicit opt-in, an isolated state directory, an isolated `DOCKER_CONFIG` and `INCUS_CONF`, and the library's pinned Docker CLI, Compose and Buildx versions. It SHALL cover these, through the installed server's Docker socket:

- version
- pull
- run
- attached exec with stdin EOF
- attached run without stdin
- followed logs
- BuildKit build
- Compose up and down
- a bind mount inside a share
- refusal outside a share
- the socket's mode and owner-only directory, and no Docker route on the gateway
- engine survival across a runtime restart
- concurrent Docker and Incus streams

Upload trials SHALL use fresh destinations, and every partial result SHALL be recorded.

#### Scenario: No false completion

- **WHEN** unit tests pass but the hardware run has not been performed
- **THEN** the Docker acceptance tasks remain unchecked and the change is not treated as complete
