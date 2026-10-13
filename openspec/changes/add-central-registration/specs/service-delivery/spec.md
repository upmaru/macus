# Spec Delta

## ADDED Requirements

### Requirement: Embedded connector delivery and preservation

The existing Macus release SHALL include the pinned shared connector without another daemon/job or database requirement. Installation SHALL not enroll or start it. Upgrades/removal SHALL preserve selected-state device identity, disabled/pending revocation state and receipts; incompatible recovery MUST NOT reset or replay execution.

#### Scenario: Package upgraded after disconnect

- **WHEN** an installation with a disabled connector is upgraded
- **THEN** the connector remains disabled and its receipt/revocation state survives without reconnecting or changing workloads
