# Design

## Context

**Boot path today.** Fresh provisioning runs `bootstrap.sh` from cloud-init `runcmd`. It writes `/etc/conf.d/incusd`, adds `tama-storage`, `incusd` and `tama-bridge` to the default runlevel, then starts storage, `rc-service incusd start`, `incusd waitready --timeout 120`, preseed, `tama-storage.sh ready` and `tama-bridge`. Every later boot is plain OpenRC: `tama-storage`, `incusd`, then `tama-bridge`, whose `start_pre` runs `incusd waitready --timeout 120` and `tama-storage.sh ready`. `tama-bridge` itself runs under `supervise-daemon` with `respawn_max=5`, but a failed `start_pre` is never retried.

**Alpine's `incusd` service (aports 3.24-stable).** `command=/usr/sbin/incusd`, `command_args=$INCUSD_OPTIONS`, `command_background=true`, a pidfile under `/run/incus`, `retry` from `INCUSD_STOP_TIMEOUT`. `stop()` runs `incusd shutdown` (or `--force` when `INCUSD_FORCE_STOP=yes`). No `output_log`/`error_log`, no supervisor. Its `conf.d` sets only `INCUSD_OPTIONS=" --group incus"`, with `--logfile /var/log/incus/incusd.log` and `--syslog` commented out. OpenRC sources `/etc/conf.d/incusd` before the init script, and its `start-stop-daemon` wrapper passes `--stdout "$output_log"` and `--stderr "$error_log"` together with `--background`.

**What the host sees.** `RuntimeService` boots the VM and polls `driver.health()` every 500 ms until the start deadline (`readinessTimeoutSeconds`, 1800 s for `macus start`). It reads current-boot `MACUS_OBSERVATION v1` lines from `serial.log` (`/dev/hvc0`) only to set the progress phase and to detect the expected kernel reboot.

**Observed failure.** 3 of 27 boots of an isolated acceptance state showed `incusd [ crashed ]` in the bootcmd `rc-status` dump. No incusd output survived. A force stop and fresh start recovered it within about 40 s twice; once it needed a second retry. `docs/zfs-qualification.md` also records an Incus startup crash under memory overcommit, which retries do not fix.

## Goals / Non-Goals

**Goals:**
- Keep incusd's log and stderr in the guest, and put a bounded tail of them on the serial console whenever incusd is found crashed at boot.
- Recover a transient boot crash inside the guest, within a fixed bound per boot.
- When recovery is exhausted, say so on the console with a stable code, and have `macus start` fail within seconds with that code instead of waiting for the deadline.
- Catch other boot stalls with a bounded no-progress guard.
- At most one automatic host-level restart per start operation for an Incus crash.

**Non-Goals:**
- Diagnosing or fixing the incusd crash itself.
- Supervising incusd after boot. A crash while the runtime is ready is still reported by the existing health refresh as `failed`.
- Updating the payload of existing appliances. cloud-init `write_files` runs once per instance; this change reaches fresh appliances.
- Any change to Incus, its stop semantics, storage, preseed, the transport or control routes.

## Decisions

### 1. Evidence: incusd log and stderr files, tail on crash

`bootstrap.sh` writes:

```sh
INCUSD_OPTIONS="--group incus --logfile /var/log/incus/incusd.log"
INCUSD_STOP_TIMEOUT=45
rc_need="tama-storage"
output_log="/var/log/incus/incusd.err"
error_log="/var/log/incus/incusd.err"
```

`--logfile` keeps incusd's structured log. Go runtime panics and fatal errors bypass the logger and go to stderr, so `error_log` is required to capture them; stdout shares the file as `tama-bridge` already does. Both files are appended across boots. incusd logs warnings and errors by default, so growth is small; rotation is left out.

When the guard (decision 2) finds incusd crashed or stopped, it writes a block to the serial console and to `/var/log/tama-incus-guard.log`:

```
TAMA_INCUSD_CRASHED state=crashed restart=1/2
incusd| --- /var/log/incus/incusd.err (last crash, first 30 lines) ---
incusd| SIGABRT: abort
incusd| ...
incusd| --- /var/log/incus/incusd.log (last 40 lines) ---
incusd| ...
incusd| --- /var/log/incus/incusd.err (last 40 lines) ---
incusd| ...
TAMA_INCUSD_EVIDENCE_END
```

Each copied line is cut to 400 bytes and prefixed with `incusd| `, so no copied log line can parse as a `MACUS_OBSERVATION` or the legacy reboot marker. A Go crash dump is hundreds of lines long, and its reason and crashing goroutine come first, so a tail alone loses them (seen in hardware acceptance). The guard therefore also copies the first 30 lines from the last line that starts a crash (`panic: `, `fatal error: `, `SIG…: `, `unexpected fault address`). incusd writes its log to stderr as well as `--logfile`, so `incusd.err` repeats the regular log. The console is `/dev/hvc0`, written directly rather than through stdout, because the guard runs both under cloud-init (stdout is teed to hvc0) and under OpenRC (stdout goes to the OpenRC console). If the console is not writable, the guard writes to stderr instead.

### 2. Guest recovery: a tama-owned guard, not `supervise-daemon`

**Rejected: `supervisor=supervise-daemon` in `conf.d/incusd`.** Alpine's `stop()` is `incusd shutdown`. That makes incusd exit on its own while its supervisor still runs, and `supervise-daemon` would respawn it. A clean `rc-service incusd stop` (and the shutdown path) would race a respawn. It would also supervise incusd for the whole runtime, not just at boot, and `respawn_max` counts within a period rather than giving a per-boot bound. Overriding `stop()` to fix this would mean replacing Alpine's init script.

**Chosen: `/usr/local/libexec/tama-incus-guard.sh ensure [readiness command...]`.** Bootstrap calls `ensure` in place of `rc-service incusd start` plus `waitready`. `tama-bridge` `start_pre` calls `ensure /usr/local/libexec/tama-storage.sh ready` in place of `waitready` plus `ready`. The guard:

1. Emits `MACUS_OBSERVATION v1 stage=incus`, so normal boots report the phase too.
2. If an earlier invocation this boot already gave up (`/run/tama-incus-guard/failed`), emits the failure observation again and exits 1.
3. Reads `rc-service incusd status`. OpenRC exits 0 for started, 32 for crashed (started, but the recorded daemon is gone), 3 for stopped, 4 or 8 while stopping or starting, and 16 for inactive.
4. Stopped or inactive before the guard has launched anything: `rc-service incusd start` once, without counting it as a restart.
5. Started: polls `incusd waitready --timeout 5`. When ready, runs the readiness command if one was given and exits with success. If the readiness command fails, it checks the status again. A crashed or stopped incusd is a crash (step 6). A running incusd means the readiness command failed on its own, and the guard returns that failure as before.
6. Crashed, or stopped after a launch: writes the evidence block. If the per-boot restart count (`/run/tama-incus-guard/restarts`) has reached the limit, zaps a crashed incusd, marks `failed`, emits `MACUS_OBSERVATION v1 stage=failed code=incus_crashed` and exits 1. The zap matters for shutdown. OpenRC runs Alpine's `stop()` on a crashed service, `incusd shutdown` fails, and OpenRC then refuses to stop `tama-storage` (seen in hardware acceptance). Otherwise it increments the count, emits `stage=incus state=restarting`, runs `rc-service incusd zap` (when crashed) and `rc-service incusd start`, waits 1 s and loops.
7. Started but still not ready after 120 s: writes the evidence block, emits `stage=failed code=incus_not_ready` and exits 1. A live but slow incusd may be running database or storage work, so the guard does not restart it, which matches today's single `waitready --timeout 120`.

On success after any restart, the guard writes `TAMA_INCUSD_RECOVERED restarts=N`, so a recovered boot still leaves evidence.

`zap` then `start` restarts only incusd. It does not run Alpine's `stop()`, which would call `incusd shutdown` against a dead daemon, and it does not touch dependents. The limit is 2 restarts (3 launches in total) per boot, counted in `/run`, which is tmpfs. Bootstrap and `tama-bridge` share that count, and every boot starts again from zero. Worst case the guard spends 3 × 120 s before reporting failure, and in that time it writes console output on each attempt. Tunables (`TAMA_INCUS_MAX_RESTARTS`, `TAMA_INCUS_READY_TIMEOUT`, `TAMA_CONSOLE`, `TAMA_BOOT_ROOT`) exist for the shell tests. The shipped payload uses the defaults.

### 3. Fail fast on the host

The readiness loop now handles observations as follows:

- **Failure observation.** Any current-boot `stage=failed` observation ends the wait at once, with `RuntimeError(.unavailable, …)`. The message names the code, says disks and Incus data were kept, and gives the recovery commands (`macus runtime stop --force`, then `macus start`). The VM is left running, consistent with the existing timeout path. This also covers the codes bootstrap already emits (`storage_refused`, `image_mismatch`, `initialization_interrupted`, …), all of which end bootstrap with exit 1 today and so can never become ready. A failure observation seen while draining a stopped guest is reported in place of the generic unexpected-exit error.
- **No-progress guard.** Once the current attempt has observed `storage`, `incus` or `ready`, the loop tracks the serial log size. If neither health nor any serial growth arrives for 300 s, start fails with `timeout`, naming the last phase and saying disks and data were kept. The guard does not arm before storage, so package installation and image verification on legacy first boots are unaffected. A guard that runs out of restarts emits output on every attempt, so the guard alone cannot trip it. The limit is an internal `RuntimeService` parameter so tests can shorten it.

Existing appliances never emit `stage=incus` on normal boots, so for them the no-progress guard does not arm and their behaviour is unchanged.

### 4. Host recovery: one restart per start operation, in `RuntimeService`

For `code=incus_crashed` only, the readiness loop restarts the guest once before failing:

1. Sets the progress phase to `incus_recovery`.
2. Calls `driver.requestStop()` (ACPI, so OpenRC stops services and `tama-storage` exports or unmounts the data disk) and waits up to `min(shutdownTimeoutSeconds, 60)` s, bounded by the start deadline. It force-stops only if the guest is still running after that. If `requestStop` throws, it force-stops.
3. Moves the serial offset to the current end, starts the VM again and resumes the readiness loop with the no-progress guard disarmed.

A second `incus_crashed` in the same operation fails with a message saying one automatic restart was already tried. Other failure codes never restart, because a storage refusal or interrupted preseed must stay preserved for explicit recovery.

**Why `RuntimeService` and not `StartupCoordinator`:** the runtime owns the driver, the serial offsets, the mutation gate and the generation checks that make emergency force stop safe. The expected-kernel-reboot restart already lives there. Doing it in the coordinator would need a stop and start over the control API from outside the mutation gate, and it would not help `macus runtime start` or `restart`.

**Why the count is not persisted like `RebootAllowanceStore`:** the reboot allowance is a once-per-appliance-lifetime contract that must survive daemon restarts. This bound is per start operation. A daemon restart ends that operation, and a new operation is a new user request, so an in-memory flag in `startLocked` gives the bound with nothing on disk to manage, reset or harden. Each start can cost at most two boots plus one bounded shutdown.

## Risks / Trade-offs

- [A deterministic crash (for example memory overcommit) restarts three times per boot and twice per start] → Bounded at 3 launches per boot and 2 boots per start. Each crash leaves evidence, and the final error names the code.
- [Forced stop during host recovery] → Used only after a bounded graceful shutdown fails. incusd is already dead, ZFS is crash-consistent, and nothing is deleted or reset.
- [Log files grow across boots] → incusd's default level is warnings and errors. Panics are rare. Rotation can be added later without a protocol change.
- [Copied log tails reach `serial.log`] → `serial.log` is already private (0600) in the owned state directory. Lines are bounded, prefixed and never parsed as observations. Incus logs do not contain client credentials.
- [OpenRC status exit codes] → The guard treats only 0 as running and only 32 or 3 as crashed or stopped, and waits on the transitional codes. Hardware acceptance confirms the crashed code on Alpine 3.24.
- [The pool is not exported after an incusd crash] → Hardware acceptance showed that, even with incusd zapped, `zpool export` finds `/var/lib/incus` busy, probably from mounts or child processes the dead incusd left behind. The data is kept and the next boot imports the pool. Cleaning up after a dead incusd is left to a storage change.
- [Existing appliances do not receive the guard] → Stated in the proposal. Their recovery stays manual, and the host still fails fast on the failure observations they already emit.

## Hardware acceptance

Explicit, opt-in, on a fresh isolated state directory, recorded apart from unit test success:

1. Fresh `macus start` on a new isolated state: boot reaches ready, and `/var/log/incus/incusd.log` and `incusd.err` exist.
2. Forced single crash on a normal boot (for example a one-shot `kill -SEGV` of incusd from a test-only hook before `tama-bridge` starts): the console shows `TAMA_INCUSD_CRASHED` with log tails and `TAMA_INCUSD_RECOVERED restarts=1`, and start becomes ready without user action.
3. Forced persistent crash (every launch killed): the console shows 3 evidence blocks and `stage=failed code=incus_crashed`. The host restarts the guest once (`incus_recovery`), sees the failure again, and `macus start` fails within minutes with the code and the disks-kept message. A later `macus runtime stop --force` then `macus start`, with the hook removed, reaches ready with workloads intact.
