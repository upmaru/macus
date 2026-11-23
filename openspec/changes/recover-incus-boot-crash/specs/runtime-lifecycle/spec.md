# Spec Delta

## ADDED Requirements

### Requirement: Fail-fast guest boot failure

Start SHALL fail promptly when the current boot emits a trusted `stage=failed` observation, instead of waiting for the start deadline. The error SHALL name the observed failure code, state that disks and Incus data were kept, and give the recovery steps. Start SHALL also fail when, after the current boot attempt has reached storage or Incus startup, neither live health nor any new serial output arrives within a bounded no-progress interval. Neither path SHALL stop, reset or delete the runtime, and observations from earlier boots MUST NOT trigger either.

#### Scenario: Guest reports a failure code

- **WHEN** the current boot emits `MACUS_OBSERVATION v1 stage=failed code=storage_refused`
- **THEN** start fails within seconds with an unavailable error naming `storage_refused` and saying disks were kept, and the VM is not force-stopped

#### Scenario: Stale failure marker

- **WHEN** `serial.log` holds a failure observation from an earlier boot
- **THEN** a new start ignores it

#### Scenario: Silent stall after storage

- **WHEN** the current boot observed the storage stage and then produces no health and no serial output for the no-progress interval
- **THEN** start fails with a timeout naming the last phase, without waiting for the start deadline

#### Scenario: Guest without observations

- **WHEN** the guest never emits a storage, Incus or ready observation
- **THEN** the no-progress guard stays disarmed and the start deadline applies as before

### Requirement: Bounded host recovery from an Incus crash

When the current boot reports `code=incus_crashed`, start SHALL shut the guest down, gracefully first and forced only after a bounded wait, and boot the same runtime once more within the remaining start deadline. At most one such restart SHALL happen per start operation; the bound is not persisted and no other failure code SHALL trigger it. Explicit force stop SHALL still cancel the operation, and live helper and Incus readiness SHALL still be required.

#### Scenario: Crash recovered by a fresh boot

- **WHEN** the first boot of a start reports `incus_crashed` and the next boot becomes healthy
- **THEN** start reports ready after exactly one automatic restart

#### Scenario: Crash repeats after the host restart

- **WHEN** the boot after the automatic restart also reports `incus_crashed`
- **THEN** start fails with an error saying one automatic restart was already tried and disks were kept, without a further restart

#### Scenario: Non-crash failure

- **WHEN** the guest reports a different failure code
- **THEN** start fails without an automatic restart
