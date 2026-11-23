# Spec Delta

## ADDED Requirements

### Requirement: Runtime upgrade commands

The client SHALL provide `runtime upgrade` with `--dry-run` and `--rollback [ID]`, and `runtime backups` with `prune ID`, using the control API. Upgrade SHALL print the upgrade class, what will be copied and that every workload will be restarted before the runtime is stopped. Rollback of a backup that includes a data disk copy SHALL require `--discard-data-since-upgrade`. Prune SHALL require confirmation and SHALL remove only the named backup. These commands MUST NOT run a package manager, change the installed package or implement workload operations.

#### Scenario: Upgrade summary

- **WHEN** macus runtime upgrade is run
- **THEN** the class, copies and restart notice are shown before the stop, and the result reports the new appliance, the verification outcome and the backup ID

#### Scenario: Listing backups

- **WHEN** macus runtime backups is run
- **THEN** each backup is listed with its ID, time, class, source appliance and size

#### Scenario: Prune without confirmation

- **WHEN** runtime backups prune is run without confirmation
- **THEN** no backup is removed
