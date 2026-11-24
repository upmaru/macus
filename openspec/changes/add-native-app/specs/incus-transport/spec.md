# Spec Delta

## ADDED Requirements

### Requirement: Runtime state stream

The private control endpoint SHALL provide a streaming read that sends the full runtime status when a reader connects and again on every runtime state transition, so that the server does not sample status. The stream SHALL exist only on the owner-only Unix transport and MUST NOT be exposed as a public route. The number of concurrent readers SHALL be bounded, and a disconnected reader SHALL be released.

#### Scenario: Transition

- **WHEN** the runtime moves from booting to ready while a reader is connected
- **THEN** the reader receives the ready status

#### Scenario: Reader limit

- **WHEN** a reader connects while the maximum number of readers is connected
- **THEN** it is refused with a bounded failure and existing readers continue
