# Tasks

## 1. Guest payload

- [ ] 1.1 Add `guest_contract`, payload revision, appliance identity and `storage` (backend, pool GUID, layout, phase) to bridge health; verify with bridge fixture tests for ZFS, ext4 and an unready pool.
- [ ] 1.2 Add adoption to `storage.sh` (`/etc/tama-storage/adopt`, import by GUID without force, GUID, vdev, layout, database and pending-marker checks, `storage_adoption_refused`); verify with storage classification tests for success, GUID mismatch, wrong vdev, foreign layout, missing database, pending and started markers, an existing root identity with a stale record, and a fresh root without a record.
- [ ] 1.3 Make `bootstrap.sh` complete on an adopted pool without preseed or `mark-ready`; verify with bootstrap shell tests.
- [ ] 1.4 Render the adoption record only in upgrade seeds (`SeedPreparation`, `prepare-appliance.py`), regenerate `EmbeddedGuestPayload.swift`; verify `sync-guest-payload.py --check` and seed tests, including that a creation seed never carries the record.

## 2. Host records and start

- [ ] 2.1 Add `storage-identity.json` and the journal fields (`guestContract`, `incusVersion`, `lastReadyPackage`), written at each ready and corrected from health; verify store tests for first write, unchanged rewrite, refusal to replace a different GUID and a journal without the fields.
- [ ] 2.2 Add the start preflight (recorded incompatible: refuse before job activation) and the graceful stop for a guest that proves incompatible after boot; verify coordinator and runtime tests for each case, including a graceful stop timeout.
- [ ] 2.3 Report "upgrade available" from start and status for a compatible older root; verify human and JSON output tests.

## 3. Upgrade operation

- [ ] 3.1 Add root staging without runtime creation to `GuestImageManager`, and backup, journal and identity paths to `RuntimePaths`/`StateStore`; verify with store tests.
- [ ] 3.2 Implement preflight, classes and the Incus direction check, with `--dry-run`; verify runtime tests for same, newer, unknown and older Incus, ext4, missing identity, the `serial.log` identity fallback and insufficient space.
- [ ] 3.3 Implement the journaled swap, boot, verification and commit with the fixture driver; verify the success path and that `efi.bin` is recreated.
- [ ] 3.4 Implement automatic rollback and daemon-start resolution of `upgrade.pending`; verify tests that interrupt after each journal step, an unreadable journal, a failed boot and a failed verification, each ending in the previous disks and configuration.
- [ ] 3.5 Implement the `clonefile(2)` data copy with the full-copy fallback and space check; verify on a clone-capable and a non-clone fixture path.
- [ ] 3.6 Implement the inventory read and comparison through the relay; verify preserved, missing-name, added-name and unreachable-guest cases.
- [ ] 3.7 Implement explicit rollback and the discard confirmation; verify reversible and migrating backups.

## 4. API, client and server

- [ ] 4.1 Add `POST /runtime/upgrade` and the backup routes to the runtime API and the server's runtime route list, with the existing authorization; verify route and conformance tests.
- [ ] 4.2 Add `runtime upgrade`, `--dry-run`, `--rollback`, `runtime backups` and `prune` to the client with human and JSON output; verify CLI tests.

## 5. Documentation and verification

- [ ] 5.1 Update `Packaging/homebrew/README.md`, formula caveats, `docs/cli.md`, `docs/api.md`, `docs/development.md` and `README.md`.
- [ ] 5.2 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`.
- [ ] 5.3 With explicit opt-in on isolated state, hardware acceptance for a reversible upgrade with a kept workload marker, then explicit rollback. Leave unchecked until it passes on hardware.
- [ ] 5.4 Hardware acceptance for a migrating upgrade between two appliances with different Incus packages, with the data clone and rollback. Leave unchecked until it passes on hardware, or record that no second qualified appliance exists yet.
- [ ] 5.5 Hardware acceptance for a failed upgrade (forced adoption refusal) ending in the previous state booting on the earlier package. Leave unchecked until it passes on hardware.
- [ ] 5.6 Hardware acceptance on an isolated copy of a pre-relay state (the 2026-11-04 shape), using the `serial.log` identity path. Never run against the retained original. Leave unchecked until it passes on hardware.
