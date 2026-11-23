# Proposal

## Why

A package upgrade can strand a user's workloads. On 2026-11-23 the default state, created on 2026-11-04 by an earlier package, was started on the current one (`docs/acceptance.md`, "Upgrade from an earlier package"). `start` booted the VM and stopped with `unavailable`, because the guest bridge predates the flow-controlled relay. The only path offered was to move the state aside and start fresh; the workloads stayed on disks that only the earlier package can serve.

Three properties of the current design cause this:

- **The guest payload is written once.** Cloud-init `write_files` runs once per instance and the seed is copied into the state at creation, so no later package can change the guest scripts of an existing appliance.
- **The root image cannot be replaced.** `RuntimeService.update` refuses a different appliance ("Appliance replacement requires a future upgrade protocol"), and `linux-appliance` defers root replacement "until backup and Incus schema compatibility are proven".
- **The pool's ownership record lives on the root disk.** `storage.sh` keeps the pool GUID, layout and phase in `/etc/tama-storage`. A new root has none and refuses the existing pool as "foreign ZFS member has no owned identity", so a root swap would fail even if the host allowed it.

The data layout already permits a safe upgrade: Incus's database and every workload live in the ZFS pool on `data.raw`, and the guest has no interactive access, so `root.raw` holds no user state.

## What Changes

- **The root disk becomes replaceable.** An explicit `macus runtime upgrade` stops the runtime gracefully, sets the old `root.raw`, `efi.bin` and `seed.iso` aside, stages a fresh root from the installed package's pinned appliance with a new seed, and boots it against the existing `data.raw`. This is the fresh-install boot path with an existing pool. There is no in-guest updater.
- **The host carries the pool identity.** The host records the pool GUID and layout beside the disks and delivers them to a new root through the seed. The guest adopts only that pool, on the attached data disk, with the recognized layout and an initialized Incus database; anything else is refused and preserved.
- **Upgrades are classed by reversibility.** When the Incus package is unchanged, `data.raw` is not copied and undo is swapping the old root back. When the Incus package moves forward, or the old version is unknown, `data.raw` is cloned first, because Incus migrates its database forward and cannot go back. Versions are full package versions with the release suffix, reported by the guest. Rollback restores a root only together with data at that root's Incus package. An appliance whose Incus is older than the state's last recorded Incus is refused.
- **Start decides before it boots.** `start` compares the state's recorded guest contract with the installed package before activating jobs or booting. A known-incompatible state is refused with the upgrade command. A guest found incompatible only after boot is stopped gracefully instead of being left running.
- **Failure rolls back.** The operation is journaled. A failed or interrupted upgrade restores the old root, and the data clone when one was taken. Safety copies are kept until the user removes them with `macus runtime backups prune`.
- **Verification is read-only and through Incus.** After the upgrade the host requires Incus readiness, the recorded pool identity and, when the old guest could be reached, an unchanged list of instances, volumes, networks and profiles.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `linux-appliance`: replaceable root disk, host-carried storage identity and pool adoption by a new root; the upgrade boundary is no longer deferred.
- `runtime-lifecycle`: explicit upgrade, safety copies, rollback, post-upgrade verification and the pre-boot compatibility decision.
- `client-cli`: `runtime upgrade` and `runtime backups` commands.
- `service-delivery`: automatic appliance upgrade stays future scope; explicit upgrade is delivered.

## Impact

- **Guest payload:** `Integration/guest/storage.sh` (adoption of a host-named pool), `bridge.py` (health reports the storage identity, payload revision and guest contract), `bootstrap.sh` (fresh root with an initialized pool), the seed (`SeedPreparation.swift`) and the regenerated `EmbeddedGuestPayload.swift`. The payload revision changes.
- **Host:** `RuntimeService` (upgrade and rollback under the mutation gate), `StateStore` and `RuntimePaths` (backups, journal, identity record), `GuestImageManager` (stage a root without creating a runtime), `BootstrapStore` (the journal gains the guest contract and last full Incus package version), `StartupCoordinator` (pre-boot decision), runtime routes, the client and the server's runtime route list.
- **Documentation:** `Packaging/homebrew/README.md` (upgrade and rollback), `docs/cli.md`, `docs/api.md`, `docs/development.md` (replaces "Do not replace root disks in place"), `README.md`.
- **Not changed:** Incus, its API, the transport, the storage layout, workload operations, and `start`'s rule that it never replaces a root image. Legacy ext4/`dir` states are refused by upgrade and keep working as today.
- **Acceptance:** hardware acceptance is opt-in on isolated state and recorded apart from unit test success. It must include the 2026-11-04 pre-relay state shape before the change is treated as complete.
