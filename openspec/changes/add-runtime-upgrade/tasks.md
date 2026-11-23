# Tasks

## 1. Guest payload

- [x] 1.1 Add `guest_contract`, payload revision, appliance identity, `incus_package` (full APK version with release suffix) and `storage` (backend, pool GUID, layout, phase) to bridge health; verify with bridge fixture tests for ZFS, ext4 and an unready pool.
- [x] 1.2 Add adoption to `storage.sh` (`/etc/tama-storage/adopt`, import by GUID without force, GUID, vdev, layout, database and pending-marker checks, `storage_adoption_refused`, then the `import_owned_pool` per-boot steps); verify with storage classification tests for success (including vdev expansion, `backend_file zfs` and `TAMA_STORAGE_ZFS_READY`), GUID mismatch, wrong vdev, foreign layout, missing database, pending and started markers, an existing root identity with a stale record, and a fresh root without a record.
- [x] 1.3 Make `bootstrap.sh` complete on an adopted pool without preseed or `mark-ready`; verify with bootstrap shell tests.
- [x] 1.4 Make `verify-appliance-image.sh` refuse a root that has `/etc/hostid`; verify with an image verification test.
- [x] 1.5 Render the adoption record only in upgrade seeds (`SeedPreparation`, `prepare-appliance.py`), regenerate `EmbeddedGuestPayload.swift`; verify `sync-guest-payload.py --check` and seed tests, including that a creation seed never carries the record.

## 2. Host records and start

- [x] 2.1 Add the daemon-owned `runtime/storage-identity.json` and `runtime/guest-record.json` (`guestContract`, `payloadRevision`, `applianceID`, `incusPackage`, `incusPackageSource`, `lastReadyPackage`), written at each ready and corrected from health; verify store tests for first write, unchanged rewrite, refusal to replace a different GUID, a missing record, a guest that reports only `server_version` (package stays unknown) and the catalog fallback for a known prebuilt entry and an unknown entry.
- [x] 2.2 Add the start preflight in `RuntimeService` before boot (recorded incompatible: refuse with `conflict`, runtime service stays active) and the graceful stop for a guest that proves incompatible after boot; change the legacy bridge message to name `macus runtime upgrade`; verify coordinator and runtime tests for each case, including a graceful stop timeout and `restart`.
- [x] 2.3 Report "upgrade available" from start and status for a compatible older root or payload; verify human and JSON output tests.

## 3. Upgrade operation

- [x] 3.1 Add backup, intent, staging, storage identity and guest record paths to `RuntimePaths`/`StateStore`, and root growth for a staged root to `GuestImageManager`; verify with store tests.
- [x] 3.2 Implement the read-only plan (current check by catalog ID and payload revision, classes, Incus direction, identity resolution, space); verify runtime tests for same, newer, unknown and older Incus packages, a higher and a lower release suffix on the same upstream version, an unparseable version, the same catalog ID with an older payload, ext4, missing identity, the `serial.log` identity fallback and insufficient space.
- [x] 3.3 Implement client staging (acquisition and upgrade seed into `STATE/upgrade-<id>/`) and daemon verification of the staged root digest and adoption record; verify that the shared appliance cache seed is never modified and that a mismatched staged root or identity is refused before the stop.
- [x] 3.4 Implement the journaled swap with recorded file identities, boot under the upgrade operation with the relay closed to clients, verification and commit with the fixture driver; verify the success path, that `efi.bin` is recreated and that the relay is refused to clients until commit.
- [x] 3.5 Implement automatic rollback and daemon-start resolution of `upgrade.pending`; verify tests that interrupt after each journal step and in the middle of the swap renames, after a passed verification before commit, an unreadable journal, a failed boot and a failed verification, each ending in the previous disks and configuration.
- [x] 3.6 Implement the `clonefile(2)` data copy with the full-copy fallback and space check; verify on a clone-capable and a non-clone fixture path.
- [ ] 3.7 Implement the inventory read and comparison through an internal relay stream; verify preserved, missing-name, added-name and unreachable-guest cases.
- [ ] 3.8 Implement explicit rollback with the pairing rules and the discard confirmation; verify root-only rollback, a backup with an unknown root package and its own data copy, rollback across multiple upgrades (reversible A to B, migrating B to C, then rollback to A restores the B to C data copy), refusal when the matching data copy was pruned, and the prune warning for a dependent backup.

## 4. API, client and server

- [ ] 4.1 Add `POST /runtime/upgrade/plan`, `POST /runtime/upgrade` and the backup routes to the runtime API and the server's runtime route list, with the existing authorization; verify route and conformance tests.
- [ ] 4.2 Add `runtime upgrade` (activating the runtime service without booting), `--dry-run`, `--rollback`, `runtime backups` and `prune` to the client with human and JSON output; verify CLI tests, including upgrade after a refused start and a dry run that downloads nothing.

## 5. Documentation and verification

- [ ] 5.1 Update `Packaging/homebrew/README.md`, formula caveats, `docs/cli.md`, `docs/api.md`, `docs/development.md` and `README.md`, and record the 2026-11-23 pre-relay observation in `docs/acceptance.md`.
- [ ] 5.2 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`.
- [ ] 5.3 With explicit opt-in on isolated state, hardware acceptance for a reversible upgrade with a kept workload marker, then explicit rollback. Leave unchecked until it passes on hardware.
- [ ] 5.4 Hardware acceptance for a migrating upgrade between two appliances with different Incus packages, with the data clone and rollback. Leave unchecked until it passes on hardware, or record that no second qualified appliance exists yet.
- [ ] 5.5 Hardware acceptance for a failed upgrade (forced adoption refusal) ending in the previous state booting on the earlier package. Leave unchecked until it passes on hardware.
- [ ] 5.6 Hardware acceptance for a failed upgrade in which the new root is force-stopped with the pool imported, ending in the earlier root importing the pool without force. Leave unchecked until it passes on hardware.
- [ ] 5.7 Hardware acceptance on an isolated copy of a pre-relay state (the 2026-11-04 shape), using the `serial.log` identity path, followed by rollback with the discard confirmation. Never run against the retained original. Leave unchecked until it passes on hardware.
