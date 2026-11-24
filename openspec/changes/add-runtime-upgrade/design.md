# Design

## Context

**State layout.** `STATE/runtime/` holds `root.raw`, `data.raw`, `efi.bin` and `seed.iso`; `STATE/config.json` names the appliance manifest and seed; `STATE/bootstrap-journal.json` records the catalog ID and payload revision the state was created with. `root.raw` holds Alpine, the kernel, Incus, QEMU and the guest scripts. `data.raw` holds the ZFS pool `tama-data`: `tama-data/metadata` is mounted at `/var/lib/incus` (Incus database, certificates, images) and `tama-data/workloads` is the Incus storage source.

**What lives only on the root disk.** The guest has no SSH and no interactive access. Reading `bootstrap.sh` and `storage.sh`, the root disk holds one piece of state that a fresh root cannot regenerate: `/etc/tama-storage/{pool-guid,layout,phase}`. Everything else (subuid ranges, `conf.d/incusd`, sysctl, OpenRC runlevels, the bootstrap-complete marker) is rewritten by bootstrap. Guest logs under `/var/log` are lost with the root and are diagnostic only.

**Why a new root is refused today.** `start_storage` imports a pool only when an identity file exists on the root. With none, a ZFS data disk reaches `refuse "foreign ZFS member has no owned identity"`.

**Host and guest never run mixed while live.** The VM runs inside the daemon process. Replacing the package restarts the daemon and therefore the guest, so a new host binary never meets an already-running old guest. It only ever boots one.

**Client and daemon split.** `macus start` runs `StartupCoordinator` in the client: it downloads and verifies the appliance (`ApplianceAcquisition`), prepares the seed (`SeedPreparation`, which runs `prepare-appliance.py`), writes `bootstrap-journal.json` under `bootstrap.lock`, activates the runtime and server jobs, and only then asks the daemon to boot (`POST /runtime/start`). The daemon never boots on its own when its job is activated. It owns the disks, the VM and the mutation gate. The Incus relay is served to the server and clients whenever `RuntimeService.state` is `ready`.

**Existing versions.** `ApplianceCatalogEntry.qualifiedPackages["incus"]` pins the appliance's Incus package with its Alpine release suffix (`7.0.1-r2`). For a prebuilt appliance this is exact: the seed carries `/etc/macus-appliance-expected`, and `verify-appliance-image.sh` refuses first boot unless the installed package manifest matches its digest. `GuestHealth.incusVersion` is Incus's `server_version` (`7.0.1`), without the suffix, so the two cannot be compared. `EmbeddedGuestPayload.revision` identifies the payload, which reaches the guest through the seed, not the image, so two states on the same catalog ID can carry different guest scripts. Start currently learns of an incompatible guest only after booting it (`health.servesFlowRelay`), and leaves it running.

**Host identity.** Neither the appliance image nor the seed sets `/etc/hostid`. ZFS refuses to import, without force, a pool left imported by a system with a different host identity. Today every boot of a state uses the same root, so the forced stop in the `incus_crashed` recovery path is followed by a successful import. Two different roots against one pool have not been exercised.

**Observed legacy shape.** On 2026-11-23 a state created on 2026-11-04 by an earlier package booted on the current one and stopped with `unavailable`, because its guest bridge predates the flow-controlled relay. That state is ZFS. `serial.log` is append-only and never truncated by the host, and the seed's `bootcmd` copies `/var/log/tama-storage.log` to the console on every boot, so each boot of that state wrote a `TAMA_STORAGE_ZFS_READY <guid>` line. Its bridge answers health but not the flow relay, so the current host cannot query its Incus API. The observation is recorded in `docs/acceptance.md`.

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

**Record.** `STATE/runtime/storage-identity.json` holds `schema_version`, `backend` (`zfs`), `pool_guid`, `layout` (`zfs-v1`) and `source` (`health` or `serial`). It sits beside the disks so it moves with them. The daemon is its only writer. Mode 0600, written atomically.

**How the host learns it.**
1. Guest health reports `storage: {backend, pool_guid, layout, phase}` from this payload onward. The daemon writes the record whenever a ready guest reports a ZFS identity in phase `ready`, and refuses to overwrite a record with a different GUID.
2. For a guest that predates this (no `storage` in health), the upgrade plan reads the last `TAMA_STORAGE_ZFS_READY <guid>` line in `serial.log`. If there is none, upgrade is refused with that reason; nothing is guessed.

The GUID is a selector, not proof. The guest performs the checks below, so a wrong or forged value causes a refusal, never an adoption of other data.

**Delivery.** The upgrade seed writes `/etc/tama-storage/adopt` with `pool_guid=` and `layout=` lines. Fresh-install seeds never contain it. Cloud-init's `write_files` also writes `tama-storage.sh` and its init script, and `bootstrap.sh` registers and starts that service afterwards, so `adopt` always exists before storage first starts on a new root.

**Guest adoption (`storage.sh`).** With `adopt` present and no `pool-guid`, `phase` or `layout` on the root, `start_storage` (before the "foreign ZFS member" branch):
1. loads ZFS and imports with `zpool import -N -d <attached vdev> <guid>`, never by name and never with `-f`;
2. requires the imported pool's GUID to equal the delivered one and `exact_vdev` to hold;
3. mounts `tama-data/metadata` and requires `.tama-storage-layout` to equal the delivered layout, an Incus `database` to exist, and `.tama-preseed-pending` and `.tama-preseed-started` to be absent;
4. writes `pool-guid`, `layout` and `phase=ready` on the root, in that order, then removes `adopt`;
5. continues through `import_owned_pool` with the identity it just wrote, so the pool gets the same per-boot steps as an owned pool: vdev expansion, the metadata mountpoint and dataset checks, `backend_file zfs` and `TAMA_STORAGE_ZFS_READY`.

Any failed check in steps 1 to 3 exports the pool and refuses with `stage=failed code=storage_adoption_refused`, before anything is written to the root. A root that already has an identity ignores `adopt`. The existing "foreign ZFS member" refusal stays for every boot without `adopt`.

**Bootstrap on an adopted pool.** No preseed marker exists, so `incus admin init` is not run. `mark-ready` is skipped because the phase is already `ready`; `ready_storage` then applies its normal per-boot checks (driver `zfs`, source `tama-data/workloads`, default profile pool).

**Host identity of the appliance.** Every root built from a qualified appliance has the same ZFS host identity: no `/etc/hostid`. `verify-appliance-image.sh` refuses first boot when the file exists. A pool that one root left imported after a forced stop can therefore be imported by another root without force, which automatic rollback relies on (decision 5). This is a property of new roots only; an old root's identity cannot be inspected by the host, so hardware acceptance covers a forced stop of a new root followed by rollback onto the earlier one.

### 3. Compatibility is recorded and decided before boot

- **Guest contract.** The payload carries an integer `guest_contract`, raised only when the host can no longer serve an older guest. The first value covers the flow relay. Health reports it together with the payload revision, the appliance ID and `incus_package`: the full installed version of the `incus` package as APK reports it, including the release suffix.
- **Guest record.** `STATE/runtime/guest-record.json` is written only by the daemon, atomically and mode 0600, at each ready: `guestContract`, `payloadRevision`, `applianceID`, `incusPackage`, `incusPackageSource` and `lastReadyPackage` (the macus package that observed it). It lives beside the disks so a backup carries it, and it is separate from `bootstrap-journal.json`, which the client writes under `bootstrap.lock`. A state without the file, or without a field, is "unknown" for that field.
- **Incus package sources.** In order: the `incus_package` reported by a ready guest (`health`); otherwise, when the state's catalog ID is an entry the installed package knows and that entry is a prebuilt appliance verified against its package manifest at first boot, that entry's `qualifiedPackages["incus"]` (`catalog`). `server_version` is never used. Nothing else is guessed: a state with neither source has an unknown Incus package.
- **Start preflight in the daemon.** The check runs in `RuntimeService` before `driver.start`, so it covers `macus start`, `restart` and any API caller. `macus start` therefore still activates the runtime and server jobs, which leaves the daemon reachable for `macus runtime upgrade`, but nothing is booted:
  - recorded contract below the host's minimum: refuse with `conflict`, naming `macus runtime upgrade`;
  - contract unknown: boot and probe as today. If health shows an incompatible guest, start requests a graceful stop, waits within the shutdown timeout, and fails with `unavailable` naming `macus runtime upgrade`. It does not force-stop; if the graceful stop times out, the message says the guest is still running and names `runtime stop --force`. The probed guest is recorded first (a guest without the flow relay as contract 0), so the next start refuses it before boot;
  - compatible but older payload or appliance: start proceeds and reports that an upgrade is available.
- **Verify, do not trust.** After every ready, the daemon compares the reported payload revision, appliance ID, contract and Incus package with the guest record and corrects the record. A restored backup therefore cannot leave a stale record.

### 4. Two classes of upgrade

| Class | Condition | `data.raw` | Undo |
| --- | --- | --- | --- |
| Reversible | Target Incus package equals the recorded `incusPackage` exactly | Not copied | Swap the old root back |
| Migrating | Target Incus package is newer, or the recorded one is unknown | Cloned before the first boot of the new root | Restore the clone and the old root |
| Refused | Target Incus package is older than the recorded one, or the direction cannot be determined | Untouched | Not applicable |

Both sides are full package versions with the release suffix: the catalog's `qualifiedPackages["incus"]` and the recorded `incusPackage`. Equality is exact string equality. Direction compares the dotted upstream version numerically and then the `-rN` release number; a version outside that form has no determinable direction and is refused. Any difference, including the release suffix alone, counts as migrating or refused, never reversible: a package release may still alter the database. Kernel and ZFS changes alone are reversible, because the pool's feature flags are never upgraded.

**Nothing to upgrade.** A state is current only when its catalog ID equals the installed entry's and its recorded payload revision equals `EmbeddedGuestPayload.revision`. A matching catalog ID with an older or unknown payload revision is still upgraded, because the guest scripts come from the seed.

The command prints the class and what will be copied before it stops the runtime. `--dry-run` prints the same and changes nothing.

### 5. The upgrade operation

The work is split the way `start` already splits it: the client downloads and prepares, the daemon owns the disks.

1. **Plan (daemon, read-only).** `POST /runtime/upgrade/plan` evaluates the installed catalog entry, which the daemon shares with the client because both are the same executable, against the state: require a ZFS state, resolve the storage identity (decision 2), determine whether the state is current, the class and Incus direction (decision 4), and the free space needed (decision 6). It returns these and the pool identity, and writes nothing. `--dry-run` stops here. `macus runtime upgrade` first activates the runtime job the same way `start` does, without booting, so the plan works when start was refused.
2. **Stage (client).** The client acquires and verifies the target appliance with the existing catalog acquisition, then prepares the upgrade seed with the planned pool identity into a new private `STATE/upgrade-<id>/`, never into the shared `appliance-cache/<catalog-id>/`. A later fresh creation therefore never sees an adoption record.
3. **Execute (daemon).** `POST /runtime/upgrade` names the staging ID. Under the mutation gate the daemon re-runs the plan, requires the same class and identity, verifies the staged root's digest against the installed catalog entry and the seed's adoption record against the identity, and then:
   1. **Inventory.** If the guest is ready, read the inventory (decision 7).
   2. **Stop.** Graceful stop only, within the configured shutdown timeout. A timeout aborts the upgrade with the guest left running and nothing moved.
   3. **Journal.** Write `STATE/upgrade.pending` (atomic, fsynced) with the backup ID, the class, the step reached, the old and new catalog IDs, and the file identity (device and inode) of the old `root.raw`, `efi.bin`, `seed.iso` and `data.raw` and of the staged root and seed. Each later step updates the step reached before acting.
   4. **Safety copy.** Create `STATE/backups/<id>/`. For a migrating upgrade, clone `data.raw` into it with `clonefile(2)`.
   5. **Prepare the root.** Grow the staged root as `GuestImageManager.create` does.
   6. **Swap.** Rename `root.raw`, `efi.bin` and `seed.iso` from `runtime/` into the backup, with `config.json`, `bootstrap-journal.json` and `guest-record.json` copied beside them. Rename the staged root and seed into `runtime/`. `efi.bin` is not carried over; the first boot creates a new variable store, as on a fresh install. Save the new `config.json`, which names the installed catalog's manifest in `appliance-cache`.
   7. **Boot and verify.** Boot with the normal readiness loop under the operation `upgrade`. Reaching guest readiness does not make the runtime `ready`: until commit the relay is not served to the server or clients, and progress reports the upgrade operation. Require ready health, a reported `pool_guid` equal to the record, and the inventory comparison where one was taken, read through an internal relay stream.
   8. **Commit.** Update the guest record from health, write `backups/<id>/backup.json` (decision 6), remove `upgrade.pending` and `upgrade-<id>/`, and only then mark the runtime `ready`.

All renames stay within the state directory, so none copies data. Each step is resolvable from the journal: the recorded file identities say, for every path, whether it holds an old file, a new one or nothing, so recovery can finish or undo any partly done rename.

Implementation choices:
- The backup ID is a UTC time, which sorts, followed by random hex. The daemon chooses it under the mutation gate: the staging ID when it still sorts after every backup, otherwise a new ID that does, because a rollback finished while the client staged may have made a newer backup and an unnamed rollback restores the latest. A failed journal write withdraws any journal it installed, and the staged root is removed with it; only a journal that cannot be withdrawn keeps the staging, for the start-time rollback.
- The daemon checks the staged seed by requiring the ISO to contain, byte for byte, the user data this package renders for the planned pool. The ISO stores that file uncompressed and contiguous.
- Until commit, the upgrade owns the mutation gate and force stop is refused, so only the readiness timeout or daemon death ends it. Daemon death is resolved from the journal.
- Rollback moves new files into `backups/<id>/failed/` and deletes nothing, except an unneeded copy of a data disk the new root never booted against. A rolled-back backup has no `backup.json`.

**Failure and interruption.** Any failure after step 3 rolls back automatically: stop the guest (graceful, then forced; the host identity property in decision 2 lets the old root import a pool the new root left imported), move the new root and seed aside into `backups/<id>/failed/` for diagnosis, rename the old trio back, restore `config.json`, the journal and the guest record, and for a migrating upgrade replace `data.raw` with the clone, moving the migrated disk into `failed/`. The command then fails, naming the failure code and saying the previous state was restored. On daemon start, a present `upgrade.pending` is rolled back the same way before any other mutation is accepted, whatever step it reached, including a verified upgrade that had not yet committed; `start` is refused until that succeeds. Workload writes made before commit are discarded with a migrating rollback; the runtime never served clients in that window, so only autostarted instances can have written. A journal that cannot be parsed preserves everything and requires explicit recovery, like an invalid reset intent.

**Explicit rollback.** `macus runtime upgrade --rollback [ID]` restores the latest (or named) backup with the same steps. A root must never boot against data at a different Incus package, nor against a pool other than the one it owns. Each backup records its root's Incus package (which may be unknown), its pool GUID and, when it has one, a data copy, which is by construction at that same package: it was taken after that root last stopped. For the selected backup:

1. if its root's package is known and equals the guest record's current `incusPackage`, and its pool equals the current pool identity, only the root, firmware store, seed and configuration are restored, and `data.raw` stays;
2. otherwise, if the backup has its own data copy, that copy is restored with the root, whatever the package, even when it is unknown;
3. otherwise, if its root's package is known, the data copy of the earliest later backup recorded at that same known package and pool is restored with the root;
4. otherwise rollback is refused and nothing changes.

Cases 2 and 3 require `--discard-data-since-upgrade`, because everything written to `data.raw` since that copy is lost, and the command names the copy's time: when it was taken, after the root stopped, not when the upgrade committed.

Examples:
- First upgrade of a pre-relay state: the Incus package is unknown, so the upgrade is migrating and its backup holds the old root and a data copy. Rollback uses case 2.
- A to B reversible (root only, package known because equality was required), then B to C migrating (root and data copied at B's package, which equals A's). Rolling back to A uses case 3 with the B to C backup's data copy, never A's root over C's migrated database.

After rollback the state matches the earlier package; with the current package installed, `start` will again report that an upgrade is required or available.

Implementation choices for explicit rollback:
- It only renames files. The root, firmware store, seed and, in cases 2 and 3, `data.raw` it replaces go into a new backup with `operation: rollback`, `restored_from` and `data_from`, beside copies of the records. Nothing is deleted, and the rollback can itself be rolled back under the same rules: its root's package is the one the data was at, and its data copy, when it has one, is at that package.
- It leaves the runtime stopped. A ready runtime is stopped gracefully first, and a timeout moves nothing. `start` then boots the restored root normally, or refuses it before boot if its recorded contract is incompatible.
- `STATE/rollback.pending` journals every rename with the file's device and inode before the first one. A failed rename is undone at once; an interrupted rollback is undone at the next daemon start, which restores the replaced records, journals that they are restored, and only then removes the new backup, so a repeated undo never reads a partly removed one. An unreadable journal preserves everything and refuses runtime changes, as for an upgrade.
- The selected backup's directory is kept with whatever remains, such as its own data copy when case 1 left it unused, and lists as `restored`. A data copy restored from another backup is moved, so that backup lists without one. With no ID, rollback selects the latest backup that still holds a root.
- The selected backup's guest record replaces the current one; a backup without one removes the current one, which describes another root.
- Automatic rollback likewise removes a guest record written for the new root when the earlier state had none, moving it into `failed/`.

Implementation choices for the API and client:
- Public routes and scopes: `POST /runtime/upgrade/plan` and `GET /runtime/backups` need `runtime.read`, since neither writes anything. `POST /runtime/upgrade` and `POST /runtime/upgrade/rollback` need `runtime.write`. A rollback with `discard_data_since_upgrade` also needs `runtime.delete` and `"confirm": "discard-data"`, like a forced stop. `POST /runtime/backups/prune` needs `runtime.delete`. Its `"confirm": "prune-backup"` is optional: without it Swift receives `confirm: false`, removes nothing and names the dependent backups, which is how `macus runtime backups prune ID` warns before `--confirm`.
- The server checks every ID against the upgrade ID form before dispatch, and projects the runtime `status` inside an upgrade or rollback result as it does a status object, so the private socket path never leaves the host.
- `macus runtime upgrade` (and `--dry-run` and `--rollback`) activates the jobs through the start coordinator's job handling, under the bootstrap lock, and boots nothing. The lock stays held until the command ends, so a concurrent `macus start` cannot prepare the shared appliance cache while staging reads it. The client stages the appliance this executable ships, never a draft qualification catalog, because the daemon plans against that one. The client refuses a plan whose target appliance or guest payload is not this executable's, current or not: it comes from a runtime service still running from another package.
- A refusal before the upgrade journal is written removes `STATE/upgrade-<id>/`; every client run stages under a new ID. After the journal, rollback owns the staged files as before.
- New upgrade and rollback IDs take the second after the newest backup's when the clock would not sort them after it, so the latest backup is the last one made even within one second.

### 6. Safety copies

- **Location:** `STATE/backups/<id>/`, private (0700), on the same volume as the disks by construction.
- **Clone:** `clonefile(2)` directly, so a volume without clone support fails clearly instead of silently copying. On that failure the upgrade falls back to a full copy only when free space exceeds the allocated size of `data.raw` plus the new root; otherwise it is refused before the stop.
- **Space:** a clone costs nothing at first and diverges as the guest writes. The plan requires free space for a fully allocated new root (12 GiB, or the image size if larger) and reports the worst-case cost of keeping the backup.
- **Record:** `backup.json` holds the time, class, old and new catalog IDs, the root's Incus package and its source (or unknown), whether a data copy exists, and the macus package that made it.
- **Retention:** nothing removes a backup automatically. `macus runtime backups` lists them with size, class, Incus package and whether each can currently be restored under the rollback rules; `macus runtime backups prune ID` removes one after confirmation, and names any other backup that depends on its data copy and would stop being restorable. Runtime reset (`DELETE` with `confirm=true`) does not remove backups and says so.

### 7. Verification through Incus only

Before the stop the relay is closed to clients: new client streams are refused and open ones are ended. When the guest is ready, the daemon then waits until Incus runs no task operation and reads names only, per project, through the existing relay: instances, storage volumes of the default pool, networks and profiles. After the new root is ready it reads them again through an internal relay stream, which is available during the upgrade operation although the relay is closed to clients, and requires every earlier name to be present. New names are allowed. The inventory is stored in the backup directory.

When the old guest cannot be queried (the pre-relay case), the comparison is skipped and the result says so. Pool identity and Incus readiness are still required, and the post-upgrade inventory is printed for the user to check.

No instance is started, stopped or modified by the upgrade. Instances come back according to Incus's own autostart settings.

Implementation choices:
- The inventory is read only from a runtime that is `ready`. A stopped runtime is not booted on its old root to take one, so its comparison is skipped and the result says why. A ready guest whose inventory cannot be read refuses the upgrade before the stop, naming stopping the runtime as the way to upgrade without the comparison.
- Volumes are compared as `type/name`, without `image` volumes, which Incus expires on its own schedule. Networks are the managed ones; unmanaged entries are the guest's interfaces.
- After readiness the new root must serve the inventory, compared or not; otherwise verification fails and the upgrade is rolled back. Both inventories are written to the backup as `inventory-before.json` and `inventory-after.json`, and the result returns the current one.
- The internal stream joins one end of a socket pair to the guest with the same flow-controlled relay that serves `incus.sock` clients, and sends one bounded HTTP request per stream.

### 8. Homebrew and documentation

- `Packaging/homebrew/README.md` gains the upgrade step after `macus start` reports that one is required or available, and rollback covers both package and state.
- Formula caveats name `macus runtime upgrade --dry-run`.
- `docs/development.md` replaces "Do not replace root disks in place to upgrade Incus" with the supported command; replacing disks by hand stays unsupported.
- The legacy guest bridge error names `macus runtime upgrade` instead of recreating the appliance.
- `docs/acceptance.md` records the 2026-11-23 pre-relay observation that motivated this change.

## Risks / Trade-offs

- **Adoption weakens "a new root never imports an unknown pool".** Mitigated by requiring an explicit host command, a host-named GUID, the exact attached vdev, the layout marker and an initialized database. A fresh-install seed can never adopt.
- **GUID from `serial.log` is guest-written text.** It is used only to select which pool to verify, and only for guests that cannot report health identity.
- **Rollback depends on host identity.** If a root ever carried a different ZFS host identity, a forced stop during automatic rollback could leave a pool the earlier root cannot import without force. New roots are verified to carry none; the earlier root is covered only by hardware acceptance.
- **The client stages, the daemon executes.** The client removes its staged directory when the request certainly never reached the daemon (no connection, an exhausted budget, a refused credential or a gateway answer marked `not_dispatched`); one can still be left behind if the client is interrupted between staging and execution, or the request may have run. It holds no user data and is removed by the next upgrade or listed for removal.
- **The first boot of a new root is slower than a restart,** and guest logs on the old root leave the running system. They stay readable in the backup.
- **A migrating upgrade cannot be undone without losing later writes.** The command states this before stopping and rollback requires an explicit flag.
- **Backups can grow to the size of the data disk.** They are listed with sizes and never pruned silently.
- **A reversible upgrade still restarts every workload.**

## Migration Plan

1. Ship guest identity reporting, the guest record, the storage identity record and the start preflight first. Fresh installs and existing server-era states gain both records at their next ready start, with no upgrade needed, and the next incompatible change is refused before boot.
2. Ship adoption, the upgrade operation and rollback.
3. Pre-relay states are upgraded with the `serial.log` identity path.
4. Unit and fixture tests first; then opt-in hardware acceptance on isolated state for each case in the tasks, including a copy of a pre-relay state. The change is not complete, and no release is cut on it, until that acceptance passes.

## Open Questions

- Does a new root boot reliably with a newly created `efi.bin`, given the "invalid boot loader" restart failure recorded in `docs/acceptance.md`?
- Do Incus instances with `boot.autostart` return correctly on a new root when the bridge network (`incusbr0`) is recreated from the database rather than preseed?
- Does the qualified Alpine ZFS package ever generate `/etc/hostid` at first boot? Image verification refuses one, and hardware acceptance confirms it.
- A pre-relay state whose `serial.log` was deleted has no identity source and is refused. If that case occurs, a one-time read-only GUID probe from the new root (import refused, GUID printed for the user to confirm) may be needed.
- Should a reversible upgrade later be allowed to run from `start` behind an explicit flag? Deferred until hardware acceptance has passed.
