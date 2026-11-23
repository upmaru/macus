# Design

## Context

**State layout.** `STATE/runtime/` holds `root.raw`, `data.raw`, `efi.bin` and `seed.iso`; `STATE/config.json` names the appliance manifest and seed; `STATE/bootstrap-journal.json` records the catalog ID and payload revision the state was created with. `root.raw` holds Alpine, the kernel, Incus, QEMU and the guest scripts. `data.raw` holds the ZFS pool `tama-data`: `tama-data/metadata` is mounted at `/var/lib/incus` (Incus database, certificates, images) and `tama-data/workloads` is the Incus storage source.

**What lives only on the root disk.** The guest has no SSH and no interactive access. Reading `bootstrap.sh` and `storage.sh`, the root disk holds one piece of state that a fresh root cannot regenerate: `/etc/tama-storage/{pool-guid,layout,phase}`. Everything else (subuid ranges, `conf.d/incusd`, sysctl, OpenRC runlevels, the bootstrap-complete marker) is rewritten by bootstrap. Guest logs under `/var/log` are lost with the root and are diagnostic only.

**Why a new root is refused today.** `start_storage` imports a pool only when an identity file exists on the root. With none, a ZFS data disk reaches `refuse "foreign ZFS member has no owned identity"`.

**Host and guest never run mixed while live.** The VM runs inside the daemon process. Replacing the package restarts the daemon and therefore the guest, so a new host binary never meets an already-running old guest. It only ever boots one.

**Existing versions.** `ApplianceCatalogEntry.qualifiedPackages["incus"]` pins the appliance's Incus package with its Alpine release suffix (`7.0.1-r2`). `GuestHealth.incusVersion` is Incus's `server_version` (`7.0.1`), without the suffix, so the two cannot be compared. `EmbeddedGuestPayload.revision` identifies the payload. Start currently learns of an incompatible guest only after booting it (`health.servesFlowRelay`), and leaves it running.

**Observed legacy shape.** The 2026-11-04 state is ZFS, and its `serial.log` contains a `TAMA_STORAGE_ZFS_READY <guid>` line, because the seed's `bootcmd` copies `/var/log/tama-storage.log` to the console. Its bridge answers health but not the flow relay, so the current host cannot query its Incus API.

## Goals / Non-Goals

**Goals:**
- A user who upgrades the package can bring an existing ZFS state, including a pre-relay one, onto the installed package's appliance with one explicit command and keep every workload.
- Any failure leaves the state as it was before the command, bootable by the package that created it.
- `start` never ends with a booted guest it cannot serve.
- One guest-side upgrade mechanism, exercising the same boot path as a fresh install.

**Non-Goals:**
- Automatic upgrade during `start` or `brew upgrade`. `start` still never replaces a root image.
- An in-guest payload updater, or patching scripts on an existing root.
- Keeping earlier guest bridge protocols alive in the host.
- Converting or upgrading legacy ext4/`dir` states.
- Downgrading Incus, or any direct handling of Incus datasets, volumes or its database.
- Running `zpool upgrade` or changing the storage layout.

## Decisions

### 1. Replace the root disk; do not update it in place

Every guest-side change (scripts, kernel, ZFS, Incus) is delivered by staging a fresh `root.raw` from the installed package's pinned catalog entry and booting it with a new seed.

- **Why:** existing guests have no updater, so an in-place path cannot reach the guests that most need it. A fresh root runs the provisioning path that fresh installs already exercise, and the old root stays intact as the undo.
- **Rejected: payload sync at boot.** It needs new guest code that old guests lack, a second mechanism for image changes, and a compatibility matrix between payload revisions and images.
- **Rejected: re-running cloud-init by changing the instance ID.** It could rewrite scripts on an existing root, but it cannot change the kernel or Incus, it re-runs every per-instance module, and the current `bootstrap.sh` would fail image verification on a root built by live package installation.
- **Rejected: a host compatibility window for older bridge protocols.** The host never meets a live old guest (see Context), so the window would only postpone the same upgrade while adding a permanent second protocol to maintain.

### 2. The host carries the storage identity

**Record.** `STATE/runtime/storage-identity.json` holds `schema_version`, `backend` (`zfs`), `pool_guid`, `layout` (`zfs-v1`) and `source` (`health` or `serial`). It sits beside the disks so it moves with them. Mode 0600, written atomically.

**How the host learns it.**
1. Guest health reports `storage: {backend, pool_guid, layout, phase}` from this payload onward. The host writes the record whenever a ready guest reports a ZFS identity in phase `ready`, and refuses to overwrite a record with a different GUID.
2. For a guest that predates this (no `storage` in health), upgrade reads the last `TAMA_STORAGE_ZFS_READY <guid>` line in `serial.log`. If there is none, upgrade is refused with that reason; nothing is guessed.

The GUID is a selector, not proof. The guest performs the checks below, so a wrong or forged value causes a refusal, never an adoption of other data.

**Delivery.** The upgrade seed writes `/etc/tama-storage/adopt` with `pool_guid=` and `layout=` lines. Fresh-install seeds never contain it.

**Guest adoption (`storage.sh`).** With `adopt` present and no `pool-guid`, `phase` or `layout` on the root, `start_storage`:
1. loads ZFS and imports with `zpool import -N -d <attached vdev> <guid>`, never by name and never with `-f`;
2. requires the imported pool's GUID to equal the delivered one and `exact_vdev` to hold;
3. mounts `tama-data/metadata` and requires `.tama-storage-layout` to equal the delivered layout, an Incus `database` to exist, and `.tama-preseed-pending` and `.tama-preseed-started` to be absent;
4. writes `pool-guid`, `layout` and `phase=ready` on the root, in that order, then removes `adopt`.

Any failed check exports the pool and refuses with `stage=failed code=storage_adoption_refused`. A root that already has an identity ignores `adopt`. The existing "foreign ZFS member" refusal stays for every boot without `adopt`.

**Bootstrap on an adopted pool.** No preseed marker exists, so `incus admin init` is not run. `mark-ready` is skipped because the phase is already `ready`; `ready_storage` then applies its normal per-boot checks (driver `zfs`, source `tama-data/workloads`, default profile pool).

### 3. Compatibility is recorded and decided before boot

- **Guest contract.** The payload carries an integer `guest_contract`, raised only when the host can no longer serve an older guest. The first value covers the flow relay. Health reports it together with the payload revision, the appliance ID and `incus_package`: the full installed version of the `incus` package as APK reports it, including the release suffix.
- **Journal.** `bootstrap-journal.json` gains `guestContract`, `incusPackage` (the last `incus_package` reported by a ready guest) and `lastReadyPackage`. `server_version` is never used for this: a guest that reports only `server_version` leaves `incusPackage` unknown. They are updated at each ready, not only at creation. A journal without them is "unknown".
- **Start preflight.** Before job activation:
  - recorded contract below the host's minimum: refuse with `conflict`, naming `macus runtime upgrade`. Nothing is booted;
  - contract unknown: boot and probe as today. If health shows an incompatible guest, start requests a graceful stop, waits within the shutdown timeout, and fails with `unavailable` naming `macus runtime upgrade`. It does not force-stop; if the graceful stop times out, the message says the guest is still running and names `runtime stop --force`;
  - compatible but older payload or appliance: start proceeds and reports that an upgrade is available.
- **Verify, do not trust.** After every ready, the host compares reported payload revision, appliance ID and contract with the journal and corrects the journal. A restored backup therefore cannot leave a stale record.

### 4. Two classes of upgrade

| Class | Condition | `data.raw` | Undo |
| --- | --- | --- | --- |
| Reversible | Target Incus package equals the journal's `incusPackage` exactly | Not copied | Swap the old root back |
| Migrating | Target Incus package is newer, or the recorded one is unknown | Cloned before the first boot of the new root | Restore the clone and the old root |
| Refused | Target Incus package is older than the recorded one, or the direction cannot be determined | Untouched | Not applicable |

Both sides are full package versions with the release suffix: the catalog's `qualifiedPackages["incus"]` and the journal's `incusPackage`. Equality is exact string equality. Direction compares the dotted upstream version numerically and then the `-rN` release number; a version outside that form has no determinable direction and is refused. Any difference, including the release suffix alone, counts as migrating or refused, never reversible: a package release may still alter the database. Kernel and ZFS changes alone are reversible, because the pool's feature flags are never upgraded.

The command prints the class and what will be copied before it stops the runtime. `--dry-run` prints the same and changes nothing.

### 5. The upgrade operation

Owned by the daemon under `RuntimeService`'s mutation gate, exposed as `POST /runtime/upgrade`, so the process that holds the state lock and the disks performs it.

1. **Preflight (no changes).** Require a ZFS state, a storage identity (decision 2), a target that differs from the current root, an acceptable Incus direction and enough free space (decision 6). Acquire and verify the target image through the existing catalog acquisition. If the guest is ready and reachable, read the inventory (decision 7).
2. **Stop.** Graceful stop only, within the configured shutdown timeout. A timeout aborts the upgrade with the guest left running.
3. **Journal.** Write `STATE/upgrade.pending` (atomic, fsynced) with a new backup ID, the class, the step reached and the old and new catalog IDs.
4. **Safety copy.** Create `STATE/backups/<id>/`. For a migrating upgrade, clone `data.raw` into it with `clonefile(2)`.
5. **Stage.** Build `STATE/upgrade-<id>/` with the new `root.raw` (digest verified, grown as `GuestImageManager.create` does) and the adoption seed.
6. **Swap.** Rename `root.raw`, `efi.bin` and `seed.iso` from `runtime/` into the backup, with the old `config.json` and `bootstrap-journal.json` copied beside them. Rename the staged root and seed into `runtime/`. `efi.bin` is not carried over; the first boot creates a new variable store, as on a fresh install. Save the new `config.json`.
7. **Boot and verify.** Start with the normal readiness loop. Require ready health, a reported `pool_guid` equal to the record, and the inventory comparison where one was taken.
8. **Commit.** Update the journal fields, write `backups/<id>/backup.json` (time, class, old and new catalog IDs, the root's Incus package, the data copy's Incus package when one exists, package that made it), remove `upgrade.pending`.

Renames are within one directory tree, so each step is idempotent and needs no copy.

**Failure and interruption.** A failure after step 3 rolls back automatically: stop the guest (graceful, then forced, since the new root has no user state and the pool is restored or unmigrated), move the new root aside into `backups/<id>/failed/` for diagnosis, rename the old trio back, restore `config.json` and the journal, and for a migrating upgrade replace `data.raw` with the clone. The command then fails, naming the failure code and saying the previous state was restored. On daemon start, a present `upgrade.pending` is resolved the same way before any other mutation: a journal at or before the swap rolls back, and `start` is refused until resolution succeeds. A journal that cannot be parsed preserves everything and requires explicit recovery, like an invalid reset intent.

**Explicit rollback.** `macus runtime upgrade --rollback [ID]` restores the latest (or named) backup with the same steps. Each backup records the Incus package its root carries and, for a data copy, the Incus package the data was at when copied. A root is restored only together with data at its own Incus package:

- if the journal's current `incusPackage` equals the backup root's package, only the root is restored and `data.raw` stays;
- otherwise rollback also restores a data copy recorded at that package, taken from the named backup or, when that backup has none, from the earliest later backup that has one. This requires `--discard-data-since-upgrade`, because everything written to `data.raw` since that copy is lost, and the command names the copy's time;
- if no such copy exists (it was pruned, or the current package is unknown), rollback is refused and nothing changes.

Example: A to B is reversible (root only), then B to C is migrating (root and data copied at B's package, which equals A's). Rolling back to A restores A's root and the data copy from the B to C backup, never A's root over C's migrated database. After rollback the state matches the earlier package; with the current package installed, `start` will again report that an upgrade is required.

### 6. Safety copies

- **Location:** `STATE/backups/<id>/`, private (0700), on the same volume as the disks by construction.
- **Clone:** `clonefile(2)` directly, so a volume without clone support fails clearly instead of silently copying. On that failure the upgrade falls back to a full copy only when free space exceeds the allocated size of `data.raw` plus the new root; otherwise it is refused before the stop.
- **Space:** a clone costs nothing at first and diverges as the guest writes. Preflight requires free space for the new root image and reports the worst-case cost of keeping the backup.
- **Retention:** nothing removes a backup automatically. `macus runtime backups` lists them with size, class, Incus package and whether each can currently be restored; `macus runtime backups prune ID` removes one after confirmation, and names any earlier backup that depends on its data copy and would stop being restorable. Runtime reset (`DELETE` with `confirm=true`) does not remove backups and says so.

### 7. Verification through Incus only

Before the stop, when the guest is ready, the host reads names only, per project, through the existing relay: instances, storage volumes of the default pool, networks and profiles. After the new root is ready it reads them again and requires every earlier name to be present. New names are allowed. The inventory is stored in the backup directory.

When the old guest cannot be queried (the pre-relay case), the comparison is skipped and the result says so. Pool identity and Incus readiness are still required, and the post-upgrade inventory is printed for the user to check.

No instance is started, stopped or modified by the upgrade. Instances come back according to Incus's own autostart settings.

### 8. Homebrew and documentation

- `Packaging/homebrew/README.md` gains the upgrade step after `macus start` reports that one is required or available, and rollback covers both package and state.
- Formula caveats name `macus runtime upgrade --dry-run`.
- `docs/development.md` replaces "Do not replace root disks in place to upgrade Incus" with the supported command; replacing disks by hand stays unsupported.

## Risks / Trade-offs

- **Adoption weakens "a new root never imports an unknown pool".** Mitigated by requiring an explicit host command, a host-named GUID, the exact attached vdev, the layout marker and an initialized database. A fresh-install seed can never adopt.
- **GUID from `serial.log` is guest-written text.** It is used only to select which pool to verify, and only for guests that cannot report health identity.
- **The first boot of a new root is slower than a restart,** and guest logs on the old root leave the running system. They stay readable in the backup.
- **A migrating upgrade cannot be undone without losing later writes.** The command states this before stopping and rollback requires an explicit flag.
- **Backups can grow to the size of the data disk.** They are listed with sizes and never pruned silently.
- **A reversible upgrade still restarts every workload.**

## Migration Plan

1. Ship the payload and host changes. Fresh installs get health identity and the storage identity record from first ready.
2. Existing server-era states gain the record at their next ready start, with no upgrade needed.
3. Pre-relay states are upgraded with the `serial.log` identity path.
4. Unit and fixture tests first; then opt-in hardware acceptance on isolated state for each case in the tasks, including a copy of a pre-relay state. The change is not complete, and no release is cut on it, until that acceptance passes.

## Open Questions

- Does a new root boot reliably with a newly created `efi.bin`, given the "invalid boot loader" restart failure recorded in `docs/acceptance.md`?
- Do Incus instances with `boot.autostart` return correctly on a new root when the bridge network (`incusbr0`) is recreated from the database rather than preseed?
- Does every pre-relay state's `serial.log` still contain the `TAMA_STORAGE_ZFS_READY` line, or can log growth or truncation have removed it? If not, a one-time read-only GUID probe from the new root (import refused, GUID printed for the user to confirm) may be needed.
- Should a reversible upgrade later be allowed to run from `start` behind an explicit flag? Deferred until hardware acceptance has passed.
