# Spec Delta

## ADDED Requirements

### Requirement: Gateway access log command

The client SHALL provide `server logs`, which prints recent gateway access records of the selected state, newest last, with `--lines N` to choose how many, `--follow` to keep printing new records across rotation until interrupted, and `--json` to print the stored records unchanged, one per line. The command SHALL read the owner-private log files directly after validating their ownership, and MUST NOT contact the server or runtime, start or stop any service, issue credentials or modify state. It MUST NOT implement workload operations.

#### Scenario: Recent records

- **WHEN** macus server logs is run after clients used the gateway
- **THEN** each recent exchange is shown with its time, caller, method and path, status, outcome, duration and bytes

#### Scenario: Server stopped

- **WHEN** macus server logs is run while the server is not running
- **THEN** the recorded exchanges are still shown and no service is started

#### Scenario: No records yet

- **WHEN** no access log exists for the selected state
- **THEN** the command prints no records and exits successfully

#### Scenario: Unsafe log directory

- **WHEN** the log directory is not owned by the user or is writable by others
- **THEN** the command fails with `invalid_configuration` and prints no records

#### Scenario: Following across rotation

- **WHEN** the log rotates while macus server logs --follow is running
- **THEN** records written after the rotation are printed without duplicates
