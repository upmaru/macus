# Spec Delta

## ADDED Requirements

### Requirement: Connected operation bridge reuse

Enrolled central operations SHALL reuse the existing native Incus relay and private Swift runtime adapter after delegated authorization. The connector MUST NOT add another guest helper, expose private socket paths publicly or bypass native stream/lifecycle limits.

#### Scenario: Central workload inspection

- **WHEN** a permitted central operation inspects this Macus target
- **THEN** the same configured incus.sock client is used and no new host-to-guest transport is created
