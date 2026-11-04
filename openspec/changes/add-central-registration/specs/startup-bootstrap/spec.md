# Spec Delta

## ADDED Requirements

### Requirement: Central-independent local startup

Local startup SHALL not require central enrollment, external user login or central availability. An already enrolled connector SHALL reconnect independently after server activation, without extending local readiness requirements or provisioning a registration. Connector failures MUST NOT restart or stop a healthy VM.

#### Scenario: Start while central offline

- **WHEN** an enrolled installation starts locally while central is unreachable
- **THEN** normal local startup can succeed and connection status reports central unavailability separately
