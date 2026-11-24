# Spec Delta

## ADDED Requirements

### Requirement: Live observation channel

The server SHALL expose one Phoenix Channels WebSocket at `/live` on its authenticated gateway, in addition to `/runtime`, native Incus paths and `/mcp`. Its topics SHALL publish runtime status, the instance list across projects, and one instance's processes, addresses and resource use. A join SHALL reply with the current value and later changes SHALL be pushed. Payloads SHALL carry a schema version. Long polling MUST NOT be offered. Requests to `/live` are not native Incus exchanges.

#### Scenario: Runtime transition

- **WHEN** the runtime changes state while a client is joined to the runtime topic
- **THEN** the client is pushed the new status without requesting it

#### Scenario: Instance started

- **WHEN** an instance is started with a standard Incus client while a client is joined to the instances topic
- **THEN** the client is pushed that instance's new state

#### Scenario: Join reply

- **WHEN** a client joins the instances topic
- **THEN** the reply contains every instance in every project

### Requirement: Live channel authorization

A connection to the live channel SHALL require a valid bearer credential, a client certificate in gateway trust, or both, and SHALL be refused otherwise before any topic is joined. The bearer credential MUST NOT be accepted from the request URL. The runtime topic SHALL require a bearer credential with the `runtime.read` scope. Topics that carry Incus data SHALL require a trusted client certificate and MUST NOT be opened by a bearer credential alone. Authorization SHALL be decided at join, before the join can cause backend access. Revoking the credential or certificate SHALL close the connection within the gateway's documented revocation bound.

#### Scenario: Bearer without certificate

- **WHEN** a client with a valid `runtime.read` bearer credential and no trusted certificate joins the instances topic
- **THEN** the join is refused and no Incus request is made

#### Scenario: Unauthenticated connect

- **WHEN** a client presents neither a valid bearer credential nor a trusted certificate
- **THEN** the connection is refused

#### Scenario: Certificate revoked

- **WHEN** the owner removes a certificate from gateway trust while its live connection is open
- **THEN** the connection is closed within the revocation bound and receives no further push

### Requirement: Read-only live channel

The live channel MUST NOT accept any client event that changes runtime, gateway, credential or workload state. Client events other than joining and leaving a topic and the protocol heartbeat SHALL be refused.

#### Scenario: Client event

- **WHEN** a joined client pushes an event to a topic
- **THEN** it is refused and nothing is changed

### Requirement: Shared bounded observation

The server SHALL observe each source once regardless of the number of subscribers, SHALL start observing a source only when its topic has a subscriber and SHALL stop within a bounded grace period after its last subscriber leaves. Instance processes SHALL be read by one fixed command per watched instance, into which no client-supplied text is placed. Connections, client frame size, snapshot size and the number of instances watched at once SHALL be bounded, and observation MUST NOT delay relayed gateway traffic. When a source cannot be observed, its topic SHALL report that it is unavailable and why, and MUST NOT present the last value as current.

#### Scenario: Two subscribers

- **WHEN** two clients join the same instance topic
- **THEN** one command observes that instance and both receive its snapshots

#### Scenario: Last subscriber leaves

- **WHEN** the last client leaves an instance topic and none joins within the grace period
- **THEN** the observing command is ended

#### Scenario: Virtual machine without agent

- **WHEN** a client joins the topic of a virtual machine whose Incus agent is not running
- **THEN** the topic reports that the instance cannot be observed and why

#### Scenario: Watch limit

- **WHEN** a client joins an instance topic while the maximum number of instances is already watched
- **THEN** the join is refused with a stable reason and existing subscriptions continue
