# Spec Delta

## ADDED Requirements

### Requirement: Runtime upgrade commands

The client SHALL provide `runtime upgrade` with `--dry-run` and `--rollback [ID]`, and `runtime backups` with `prune ID`, using the control API. Upgrade SHALL activate the runtime service without booting when it is not running, SHALL acquire and verify the installed package's appliance and prepare the upgrade seed only in a private staging directory of the state, and SHALL hand the staged files to the daemon. A dry run MUST NOT download, stage or stop anything. Upgrade SHALL print the upgrade class, what will be copied and that every workload will be restarted before the runtime is stopped. A rollback that restores a data disk copy SHALL require `--discard-data-since-upgrade` and SHALL name the time of that copy. Prune SHALL require confirmation and SHALL remove only the named backup. These commands MUST NOT run a package manager, change the installed package or implement workload operations.

#### Scenario: Upgrade summary

- **WHEN** macus runtime upgrade is run
- **THEN** the class, copies and restart notice are shown before the stop, and the result reports the new appliance, the verification outcome and the backup ID

#### Scenario: Upgrade with the runtime service not running

- **WHEN** macus runtime upgrade is run after start refused an incompatible state
- **THEN** the runtime service is activated without booting and the upgrade proceeds through the control API

#### Scenario: Listing backups

- **WHEN** macus runtime backups is run
- **THEN** each backup is listed with its ID, time, class, source appliance, Incus package, size and whether it can currently be restored

#### Scenario: Prune without confirmation

- **WHEN** runtime backups prune is run without confirmation
- **THEN** no backup is removed
