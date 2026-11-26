# Spec Delta

## ADDED Requirements

### Requirement: Docker client setup

`macus docker setup` SHALL read the runtime status and SHALL refuse when the runtime is not ready, without booting it. It SHALL then:

- ensure the engine through the server's owner route
- reuse `docker` from `PATH` or `--docker-cli`, or install the official Homebrew `docker` formula only when Docker is missing and Homebrew exists
- generate an owner-private Docker key pair and enroll its certificate with the `docker` scope
- create or update a Docker context, using only standard `docker context` commands, under `DOCKER_CONFIG` when set

The default context name SHALL be `macus`. A context with the same endpoint and an enrolled certificate SHALL be reused. A context with the same endpoint and a certificate that is not enrolled SHALL have its TLS material replaced. A context with a different endpoint SHALL fail with conflict and MUST NOT be modified. The default context SHALL change only with `--docker-set-default`. Setup MUST NOT edit `config.json`.

When Compose or Buildx is missing, Homebrew exists and no explicit `--docker-cli` was given, setup SHALL install the official formula and link the plugin into `$DOCKER_CONFIG/cli-plugins`, only where no plugin of that name exists. With an explicit `--docker-cli`, setup MUST NOT run Homebrew for the CLI or its plugins; it SHALL report missing plugins without failing. Staged key material SHALL be removed once the context holds it. Setup SHALL verify by running `docker --context NAME version` against the engine. `macus docker status` SHALL report:

- engine state and image currency
- the negotiated API range
- the context and its endpoint
- the CLI, Compose and Buildx versions, and any drift from the qualified pins

#### Scenario: Ready runtime setup

- **WHEN** `macus docker setup` runs on a ready runtime with Docker installed
- **THEN** a `macus` context is created and `docker --context macus version` reports the engine

#### Scenario: Conflicting context

- **WHEN** a `macus` Docker context already points to another endpoint
- **THEN** setup fails with conflict, preserves that context, and suggests `--docker-context`

#### Scenario: Isolated Docker configuration

- **WHEN** setup runs with `DOCKER_CONFIG` set to a test directory and an explicit `--docker-cli`
- **THEN** only that directory is changed, Homebrew is not run even when Compose or Buildx is missing, and any missing plugin is reported

#### Scenario: Stopped runtime

- **WHEN** `macus docker setup` runs while the runtime is stopped
- **THEN** it fails without booting the runtime or changing Docker configuration

### Requirement: Docker diagnostics

`doctor` SHALL remain read-only. When Docker is enabled for the state, it SHALL report engine state, readiness, image currency and context reachability. It SHALL warn when `DOCKER_HOST` or `DOCKER_CONTEXT` is set to something other than the Macus context. When Docker is not enabled, doctor SHALL report Docker as not set up, without failing.

#### Scenario: Environment override

- **WHEN** doctor runs with `DOCKER_HOST` set to another daemon
- **THEN** it warns that Docker commands bypass the Macus context and names the variable
