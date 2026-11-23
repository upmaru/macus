# Spec Delta

## MODIFIED Requirements

### Requirement: Upgrade boundary

The appliance manifest and state layout SHALL be versioned. Unsupported schema/protocol versions MUST be rejected. The root disk SHALL hold no state that a newly provisioned root cannot regenerate or receive from the host, so that it can be replaced. Root-image replacement SHALL happen only through the explicit runtime upgrade, which keeps the previous root and, when Incus will migrate its database, a copy of the data disk. Boot, start and provisioning MUST NOT replace a root image.

#### Scenario: Unknown manifest

- **WHEN** the manifest schema is newer than supported
- **THEN** creation returns a clear incompatibility error

#### Scenario: Start with an older root

- **WHEN** start selects a state whose root image differs from the installed package's appliance
- **THEN** the root image is not replaced

#### Scenario: New root after upgrade

- **WHEN** the explicit upgrade boots a newly staged root against an existing data disk
- **THEN** the same pool, Incus database and workloads are served and the previous root is retained unchanged

### Requirement: Storage ownership boundary

Appliance metadata SHALL persist outside the storage subtree controlled by Incus. Incus SHALL exclusively manage the workload subtree it receives. Appliance boot or recovery MUST NOT manage Incus workload datasets, volumes, snapshots or clones directly. Storage reuse MUST verify attached-device and pool identity rather than trusting a pool name alone. The host SHALL keep a record of the owned pool's identity beside the runtime disks, taken from a ready guest, so that ownership survives replacement of the root disk.

#### Scenario: Incus removes a workload

- **WHEN** the standard Incus client deletes an instance or volume from the default pool
- **THEN** appliance metadata and storage identity remain available across restart

#### Scenario: Pool name collision

- **WHEN** a discovered pool shares the expected name but has a different identity or backing device
- **THEN** it is not adopted, wiped or forcibly imported and readiness is withheld

#### Scenario: Identity recorded at readiness

- **WHEN** a ready guest reports an initialized ZFS pool identity
- **THEN** the host records it beside the runtime disks and does not replace a record that names a different pool

## ADDED Requirements

### Requirement: Pool adoption by a replacement root

A root disk without a storage identity SHALL import an existing pool only when the upgrade seed names that pool's identity and layout. Adoption SHALL import by the named identity from the attached data disk without forcing, and MUST verify the pool identity, the exact backing device, the recognized layout marker, an initialized Incus database and the absence of pending or interrupted initialization before recording ownership. Any failed check MUST leave the pool exported and unchanged, withhold readiness and emit a failure observation. A seed for a new runtime MUST NOT carry an adoption record, and a root without one SHALL keep refusing an existing pool. Adoption MUST NOT run Incus preseed.

#### Scenario: Adoption succeeds

- **WHEN** a replacement root boots with an adoption record naming the pool on the attached data disk and that pool has the recognized layout and an Incus database
- **THEN** the root records ownership, Incus starts on the existing database without preseed, and readiness is reported

#### Scenario: Identity mismatch

- **WHEN** the adoption record names an identity that the attached data disk does not hold
- **THEN** nothing is imported or modified and the guest reports an adoption failure

#### Scenario: Uninitialized pool

- **WHEN** the named pool has no Incus database or still has a pending initialization marker
- **THEN** adoption is refused and the pool is preserved

#### Scenario: Fresh root without a record

- **WHEN** a root without identity and without an adoption record finds a ZFS member on the data disk
- **THEN** it refuses the disk as foreign and preserves it

### Requirement: Guest identity reporting

Guest health SHALL report the guest contract version, the payload revision, the appliance identity, the full installed Incus package version including its package release suffix and, for ZFS, the storage identity and phase. The guest contract version SHALL change only when a host can no longer serve an older guest.

#### Scenario: Ready guest

- **WHEN** the host reads health from a ready guest provisioned with this payload
- **THEN** the response includes the contract version, payload revision, appliance identity, the Incus package version with its release suffix and the pool identity in its ready phase
