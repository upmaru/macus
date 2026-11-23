# Spec Delta

## ADDED Requirements

### Requirement: Explicit central connect

`macus connect [url]` SHALL enroll this installation and enable its outbound connector. First use SHALL require a valid trusted HTTPS service URL; later use SHALL resume the saved registration idempotently. Enrollment SHALL require authorized external-provider browser authentication and device key proof. Switching service MUST NOT overwrite an active registration implicitly.

#### Scenario: First connect

- **WHEN** the owner connects to an approved central URL and completes enrollment
- **THEN** the selected installation stores its private device identity and verified target/generation and enables the connector in the existing Elixir server

#### Scenario: Different central service

- **WHEN** connect names a different service while an active registration exists
- **THEN** it reports an explicit disconnect/enrollment conflict and preserves the existing identity, receipts and pending work

### Requirement: Connect side effects and failure bounds

Connect SHALL enforce safe state, installed service identity, trusted metadata and one bounded enrollment deadline. It may explicitly recover only the matching Elixir job. It MUST NOT provision/start the VM, change host shares/native remotes, open inbound ports or persist user OAuth credentials. Failure SHALL preserve workloads and report uncertain registration outcomes.

#### Scenario: Guest absent during enrollment

- **WHEN** connect enrolls a Mac whose guest is absent or stopped
- **THEN** the target can be registered with truthful readiness without acquiring an appliance, booting VZ or changing shares

#### Scenario: Lost enrollment response

- **WHEN** central commits enrollment but the client loses its response
- **THEN** reconnect recovers the same key-bound enrollment receipt without creating another device grant or target

### Requirement: Passive connection status

`macus connection status` SHALL report saved enrollment, transport connectivity and backend readiness separately, with JSON support and sanitized errors. It MUST NOT create files, issue credentials, enroll, activate services or disclose secrets.

#### Scenario: No registration

- **WHEN** connection status inspects an unregistered installation
- **THEN** it reports disconnected without mutating state or starting the server

### Requirement: Safe disconnect

`macus disconnect` SHALL durably disable reconnect and new central dispatch before closing sessions and attempting central revocation. It SHALL be idempotent and report remote-revocation-pending when confirmation is unavailable. Local access, workloads, credentials unrelated to central and execution receipts SHALL remain intact.

#### Scenario: Central unavailable during disconnect

- **WHEN** disconnect cannot reach central
- **THEN** local remote access is disabled immediately and pending revocation is reported without claiming global revocation or deleting VM/task state
