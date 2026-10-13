# Spec Delta

## Purpose

Lets a registered Macus accept constrained central operations without weakening its standalone gateway.

## ADDED Requirements

### Requirement: Optional outbound central connector

Macus SHALL run an explicitly enrolled connector in its existing Elixir service, with no extra endpoint, inbound port, repository or launchd job. Device and central identities SHALL be verified before dispatch. Central outages MUST NOT prevent standalone local runtime, native Incus or MCP access.

#### Scenario: Central connection unavailable

- **WHEN** the enrolled connector cannot reach central
- **THEN** the gateway reports disconnected status while local services and Swift-owned workloads remain available

### Requirement: Constrained delegated execution

Connected dispatch SHALL match active target/generation, known operation version and approved local scopes/projects. External owner context SHALL remain distinct from local owner authority. Arbitrary commands, destinations, modules and credential administration MUST NOT be accepted through the connector.

#### Scenario: Local permission denied

- **WHEN** central requests an operation outside the installation's approved capabilities
- **THEN** Macus rejects it before private socket or host runtime access even if the central user otherwise has a grant
