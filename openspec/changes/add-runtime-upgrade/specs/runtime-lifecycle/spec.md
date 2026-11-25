# Spec Delta

## ADDED Requirements

### Requirement: Explicit runtime upgrade

The runtime SHALL provide an explicit upgrade that replaces the root disk with the installed package's pinned appliance and boots it against the existing data disk. The client SHALL acquire the appliance and prepare the upgrade seed in a private staging directory of the state, and the daemon that owns the state SHALL verify them and perform the upgrade as a serialized mutation. Upgrade SHALL complete every check that can fail without changing state before stopping the runtime, SHALL stop the runtime gracefully and MUST NOT force-stop a runtime that was ready. Until the upgrade commits, the runtime MUST NOT serve the Incus API to the server or clients and SHALL report the upgrade operation. Upgrade MUST NOT start, stop, create, modify or delete Incus workloads, and MUST NOT read or write Incus datasets or its database directly. Legacy ext4 states and states without a recorded or recoverable pool identity SHALL be refused unchanged.

#### Scenario: Upgrade of a ready runtime

- **WHEN** upgrade is requested for a ready ZFS runtime whose root differs from the installed appliance
- **THEN** the runtime stops gracefully, boots the new root against the same data disk and reports ready with the same pool identity

#### Scenario: Incus held until commit

- **WHEN** the new root reports guest readiness and verification has not finished
- **THEN** the runtime is not ready, the Incus API is not served to clients and progress reports the upgrade operation

#### Scenario: Nothing to upgrade

- **WHEN** the state's catalog ID and recorded payload revision both match the installed package
- **THEN** upgrade reports that it is current and changes nothing

#### Scenario: Same appliance, older payload

- **WHEN** the state's catalog ID matches the installed appliance but its recorded payload revision is older or unknown
- **THEN** upgrade proceeds and replaces the root and seed

#### Scenario: Graceful stop times out

- **WHEN** the runtime does not stop within the shutdown timeout
- **THEN** upgrade fails before any disk is moved and the guest is left running

#### Scenario: Legacy storage

- **WHEN** upgrade is requested for an ext4 state
- **THEN** it is refused and the state is unchanged

#### Scenario: Dry run

- **WHEN** upgrade is requested as a dry run
- **THEN** the class of upgrade, the copies it would make and the space required are reported, and nothing is downloaded, staged, stopped or changed

### Requirement: Upgrade classes and Incus direction

Upgrade SHALL compare the target appliance's full Incus package version, including its package release suffix, with the state's recorded Incus package. The recorded package SHALL be the full installed version last reported by a ready guest of the state or, when none was reported, the pinned Incus package of the state's catalog entry when the installed package knows that entry and it is a prebuilt appliance verified against its package manifest at first boot. The Incus server version alone MUST NOT be used, and a state with neither source SHALL be treated as unknown. When the two are exactly equal, the data disk SHALL NOT be copied. When the target is newer or the earlier version is unknown, the data disk SHALL be copied before the new root first boots. When the target is older, or the direction cannot be determined, upgrade MUST be refused. The class and its consequences SHALL be stated before the runtime is stopped.

#### Scenario: Same Incus package

- **WHEN** only guest scripts, kernel or other packages differ
- **THEN** the data disk is not copied and the previous root is kept

#### Scenario: Newer Incus package

- **WHEN** the target appliance carries a newer Incus package
- **THEN** a copy of the data disk exists before the new root boots

#### Scenario: Newer package release only

- **WHEN** the target carries the same Incus upstream version with a higher package release suffix
- **THEN** the upgrade is migrating and the data disk is copied

#### Scenario: Older package release only

- **WHEN** the target carries the same Incus upstream version with a lower package release suffix
- **THEN** upgrade is refused

#### Scenario: Server version only

- **WHEN** the state's guest reported only an Incus server version without a package release and its catalog entry is unknown to the installed package
- **THEN** the earlier version is unknown and the data disk is copied

#### Scenario: Known prebuilt catalog entry

- **WHEN** no guest of the state reported an Incus package and the state's catalog ID is a prebuilt appliance the installed package knows
- **THEN** that entry's pinned Incus package is the recorded package

#### Scenario: Unknown earlier version

- **WHEN** the state has no recorded Incus package version
- **THEN** the upgrade is treated as migrating and the data disk is copied

#### Scenario: Older Incus package

- **WHEN** the installed package's appliance carries an older Incus than the state last ran
- **THEN** upgrade is refused and names the package or backup that matches the state

### Requirement: Upgrade safety copies and rollback

Upgrade SHALL keep the previous root disk, firmware store, seed and configuration, and any data disk copy, in a private backup inside the state directory. It SHALL record durable intent, including the identity of every file it will move, before moving any disk. If the new root does not reach verified readiness, or the operation is interrupted before it commits at any step, the runtime SHALL be restored to its previous disks and configuration before any other mutation is accepted, and the failure SHALL be reported with its code. An unreadable intent record MUST preserve all files and require explicit recovery. Backups MUST NOT be removed automatically, including by runtime reset. An explicit rollback SHALL restore a named backup. Each backup SHALL record the Incus package of its root, which may be unknown, its pool identity, and whether it holds a data disk copy and when that copy was taken; a backup's own data disk copy is at its root's package and pool. Rollback MUST NOT boot a restored root against a data disk at a different Incus package or holding a different pool. It SHALL restore the root alone only when the root's package is known and equals the current data's recorded package and its pool equals the current pool; otherwise it SHALL restore the backup's own data disk copy, or, when the backup has none and its root's package is known, the earliest later backup's data disk copy recorded at that package and pool, and SHALL be refused unchanged when neither exists. Restoring a data disk copy SHALL require a separate confirmation that data written since that copy was taken is discarded.

#### Scenario: New root fails to become ready

- **WHEN** the new root reports a failure or misses readiness
- **THEN** the previous root and configuration are restored, a migrated data disk is replaced by its copy, and the command fails saying the previous state was restored

#### Scenario: Interrupted upgrade

- **WHEN** the daemon stops after the intent record is written and before the upgrade commits
- **THEN** the next daemon start restores the previous state before accepting start

#### Scenario: Interrupted after verification

- **WHEN** the daemon stops after the new root passed verification and before commit
- **THEN** the next daemon start restores the previous state rather than committing

#### Scenario: Backup retention

- **WHEN** an upgrade commits
- **THEN** its backup remains until the user removes it explicitly

#### Scenario: Rollback of a migrating upgrade

- **WHEN** rollback needs to restore a data disk copy and the discard confirmation is absent
- **THEN** it is refused and nothing changes

#### Scenario: Rollback with an unknown Incus package

- **WHEN** the selected backup's root has an unknown Incus package and the backup holds its own data disk copy
- **THEN** rollback restores that root together with that copy after the discard confirmation

#### Scenario: Rollback across a later migration

- **WHEN** a root-only backup is selected after a later upgrade migrated the Incus database
- **THEN** rollback restores that root together with the later backup's data disk copy recorded at the root's Incus package, after the discard confirmation, and never the root alone

#### Scenario: No matching data copy

- **WHEN** the selected root's Incus package differs from the current data's, the backup has no data disk copy and no later copy at that package remains
- **THEN** rollback is refused and nothing changes

#### Scenario: Backup of another pool

- **WHEN** the selected root's pool differs from the current data disk's pool and no data disk copy of the root's pool remains
- **THEN** rollback is refused and nothing changes, even when the Incus packages are equal

#### Scenario: Root-only rollback

- **WHEN** the selected root's Incus package is known and equals the current data's recorded package
- **THEN** only the root, firmware store, seed and configuration are restored and the data disk is kept

#### Scenario: No space for a copy

- **WHEN** the volume cannot clone the data disk and lacks space for a full copy
- **THEN** upgrade is refused before the runtime is stopped

### Requirement: Post-upgrade verification

Before committing, upgrade SHALL require live Incus readiness and a guest-reported pool identity equal to the recorded one. Before reading the earlier names, upgrade SHALL close the Incus relay to clients, ending open client streams, and SHALL wait until Incus runs no task operation; the relay SHALL stay closed to clients until the upgrade ends. When the previous guest could be queried, upgrade SHALL read the names of instances, default-pool volumes, networks and profiles through the Incus API before the stop and again after readiness, and SHALL fail verification if any earlier name is missing. When the previous guest could not be queried, the result SHALL state that the comparison was skipped.

#### Scenario: Inventory preserved

- **WHEN** every earlier instance, volume, network and profile name is present after the upgrade
- **THEN** the upgrade commits

#### Scenario: Missing workload

- **WHEN** an earlier instance name is absent after the upgrade
- **THEN** verification fails and the previous state is restored

#### Scenario: Unreachable previous guest

- **WHEN** the previous guest could not serve the Incus API to this host
- **THEN** upgrade verifies pool identity and readiness, reports the comparison as skipped, and returns the current inventory

### Requirement: Compatibility decision before boot

The daemon SHALL record, beside the runtime disks, the guest contract version, payload revision, appliance identity and full Incus package version reported at each readiness, and SHALL be the only writer of that record. Before booting, the runtime SHALL compare the recorded contract with the installed package. A state recorded as incompatible MUST be refused with the upgrade command and MUST NOT be booted; start MAY still activate the runtime service so that the upgrade command can reach it. When compatibility is unknown and the booted guest proves incompatible, start SHALL request a graceful stop and fail naming the upgrade command; it MUST NOT leave that guest running after a successful stop and MUST NOT force-stop it. A compatible state with an older root or payload SHALL start and report that an upgrade is available.

#### Scenario: Recorded incompatible state

- **WHEN** start selects a state whose recorded guest contract is below the installed package's minimum
- **THEN** start fails with a conflict naming the upgrade command and the guest is not booted

#### Scenario: Upgrade after a refused start

- **WHEN** start was refused for an incompatible state and the user runs the upgrade command
- **THEN** the upgrade reaches the runtime service without booting the earlier root

#### Scenario: Unknown state proves incompatible

- **WHEN** a state without a recorded contract boots a guest the host cannot serve
- **THEN** start stops the guest gracefully and fails naming the upgrade command, with disks kept

#### Scenario: Older compatible root

- **WHEN** the recorded contract is compatible and the root is older than the installed appliance
- **THEN** start reaches ready and reports that an upgrade is available
