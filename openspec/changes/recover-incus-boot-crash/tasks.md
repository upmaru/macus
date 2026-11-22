# Tasks

## 1. Guest evidence and recovery

- [x] 1.1 Write `--logfile /var/log/incus/incusd.log` and `output_log`/`error_log` `/var/log/incus/incusd.err` into the `/etc/conf.d/incusd` that `bootstrap.sh` writes, and create `/var/log/incus`; verify with a bootstrap shell test that reads the written `conf.d`.
- [x] 1.2 Add `Integration/guest/incus-guard.sh` (`ensure [readiness command...]`) with the per-boot restart limit, evidence tail, recovery marker and `incus_crashed`/`incus_not_ready` observations from the design; verify with shell fixture tests for a ready daemon, a single crash recovered, a persistent crash exhausted, a count shared across invocations, a not-ready timeout without restart, a readiness-command failure while running, a crash detected by the readiness command, and prefixing of copied lines.
- [x] 1.3 Use the guard in `bootstrap.sh` and `tama-bridge` `start_pre`; deliver it as `/usr/local/libexec/tama-incus-guard.sh` through `SeedPreparation`, `prepare-appliance.py` and `prepare-zfs.py`; add it to `sync-guest-payload.py` and `check.sh`; regenerate `EmbeddedGuestPayload.swift`; verify `sync-guest-payload.py --check`, seed tests and the bootstrap tests.

## 2. Host fail-fast and recovery

- [x] 2.1 Fail the readiness loop on a current-boot `stage=failed` observation with its code and a disks-kept message, including one seen while draining a stopped guest; verify runtime tests for a failure code, a stale marker from before start and a failure seen at guest exit.
- [x] 2.2 Add the no-progress guard (armed by `storage`, `incus` or `ready`, 300 s default, shortened in tests); verify that it trips after a silent stall, stays disarmed without observations, and is reset by serial growth.
- [x] 2.3 Add one graceful-then-forced restart per start operation for `incus_crashed`, with the `incus_recovery` phase and progress text; verify recovery to ready, failure after a second crash, no restart for other codes and force fallback when graceful shutdown hangs.

## 3. Documentation and verification

- [x] 3.1 Document the guest log files, console evidence, failure codes and recovery bounds in `docs/development.md` and `docs/api.md` where boot failures and progress phases are described.
- [x] 3.2 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`.
- [x] 3.3 With explicit opt-in and a fresh isolated state, run the hardware acceptance in the design (normal boot logs, forced single crash recovered, forced persistent crash failing fast after one host restart). Leave this unchecked until it passes on hardware. Passed 2026-11-22 on `/tmp/macus-icr1` (`docs/testing/incus-crash-recovery-acceptance.json`); later guard revisions were copied into the guest by sha256, and the unexported pool after a crash remains an open finding.
