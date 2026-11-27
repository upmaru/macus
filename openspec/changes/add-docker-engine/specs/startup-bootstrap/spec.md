# Spec Delta

## ADDED Requirements

### Requirement: Optional Docker stage

`macus start --docker` SHALL record Docker as enabled for the state. Later starts SHALL run the Docker stage while it remains enabled. The stage SHALL run after Incus client setup succeeds and SHALL perform the same steps as `macus docker setup`. Start SHALL honor `DOCKER_CONFIG`, `--docker-cli`, `--docker-context` and `--docker-set-default`. Success SHALL require the Docker context to reach the engine. Without Docker enabled, start MUST NOT contact Homebrew for Docker, create the engine, enroll a Docker certificate or touch Docker client configuration. A Docker stage failure SHALL identify the failed step, report that the runtime and Incus client remain ready, and leave existing Docker contexts, certificates and engine data in place.

#### Scenario: Start with Docker

- **WHEN** `macus start --docker` runs on a supported host with the engine catalog entry present
- **THEN** start completes with a ready runtime, a working Incus remote and a Docker context whose `docker version` reaches the engine

#### Scenario: Docker stage fails

- **WHEN** Incus setup succeeds but the Docker CLI cannot be found or installed
- **THEN** start exits unsuccessfully, names the Docker step, and reports that the runtime and Incus remote are ready

#### Scenario: Docker not enabled

- **WHEN** `macus start` runs for a state that never enabled Docker
- **THEN** no Docker engine, certificate, context or Homebrew installation is created
