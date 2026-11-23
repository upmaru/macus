# Proposal

## Why

On 3 of 27 boots of an isolated hardware acceptance state (2026-11-21 19:00 UTC, and 2026-11-22 15:42 and 15:57 UTC), OpenRC reported `incusd [ crashed ]` shortly after boot. Nothing recorded why, nothing restarted it, and `macus start` waited the full 1800 s start deadline with a silent guest console:

- Alpine's `incusd` init script backgrounds the daemon with a pidfile only. It sets no supervisor, no respawn and no log (`--logfile` and `--syslog` are commented out in its `conf.d`), so incusd's log and its stderr, where Go panics go, are discarded.
- `tama-bridge` needs incusd. Its `start_pre` (`incusd waitready --timeout 120`, then `tama-storage.sh ready`) fails once and OpenRC never retries it, so the host vsock bridge never answers.
- `RuntimeService` parses `MACUS_OBSERVATION v1` lines only for the phase and the kernel-reboot signal. It never fails on `stage=failed`, and normal boots emit no observations at all.

A manual `macus runtime stop --force` then `macus start` recovered in 38-39 s on 2 of 3 occasions. The third needed a second retry. The crash is transient, so a bounded retry recovers it, but the user currently has to notice the hang, wait or interrupt, and know the recovery command.

## What Changes

- **Evidence:** the guest writes incusd's log to `/var/log/incus/incusd.log` and its stdout/stderr to `/var/log/incus/incusd.err` through the `/etc/conf.d/incusd` that bootstrap writes. When incusd is found crashed, the guest copies a bounded tail of both files to the serial console, which is the only guest output the host can read.
- **Bounded guest recovery:** a new tama-owned guard (`tama-incus-guard.sh`) starts or waits for incusd, detects a crashed daemon, and restarts it at most 2 times per boot. Bootstrap and `tama-bridge` `start_pre` both use it. Alpine's `incusd` init script and its stop semantics stay unchanged; no supervisor is added.
- **Fail fast:** when guard recovery is exhausted, the guest emits `MACUS_OBSERVATION v1 stage=failed code=incus_crashed` on every boot, not only bootstrap. The runtime readiness loop fails on any current-boot `stage=failed` observation with its code and a message saying disks and Incus data were kept. A no-progress guard also fails start when the guest has reached storage or Incus startup and then produces neither health nor serial output for 5 minutes.
- **Storage stop after a crash:** a crashed incusd leaves its tmpfs mounts and children (such as `dnsmasq`) under `/var/lib/incus`, so the pool cannot be exported at shutdown. When the first export fails and incusd's daemon is gone, `tama-storage` stops those leftovers, unmounts the tmpfs mounts and retries. It never touches datasets or a running incusd. Found and verified in hardware acceptance.
- **Bounded host recovery:** for `incus_crashed` only, start shuts the guest down (graceful first, forced after a bound) and boots it once more within the same start deadline. At most one such restart happens per start operation.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `linux-appliance`: Incus crash evidence on the guest and serial console, and bounded guest-side Incus restart at boot with a failure observation when exhausted.
- `runtime-lifecycle`: fail-fast readiness on guest failure observations and on stalled boots, and one bounded host restart for an Incus crash.

## Impact

- `Integration/guest/bootstrap.sh` (`conf.d/incusd`, guard use), `Integration/guest/storage.sh` (release after a failed export), `Integration/guest/tama-bridge.initd` (`start_pre`), new `Integration/guest/incus-guard.sh`, `Integration/scripts/sync-guest-payload.py`, `Integration/scripts/prepare-appliance.py`, `Integration/qualification/prepare-zfs.py`, `Sources/Macus/Bootstrap/SeedPreparation.swift` and the regenerated `EmbeddedGuestPayload.swift`. The payload revision changes, so the seed is regenerated for fresh appliances.
- `Sources/Macus/Application/RuntimeService.swift` readiness loop, `GuestObservation.swift` and the progress phase text.
- Existing appliances keep the guest payload they were provisioned with, because cloud-init `write_files` runs once per instance. They gain the host-side fail-fast on any failure observation they already emit, but not the guest guard, crash evidence or the `incus_crashed` observation, and so not the no-progress guard either, which arms on a storage or Incus observation.
- No change to Incus, its API, the transport, the storage layout or runtime control routes. Hardware acceptance (a forced incusd crash on a fresh isolated state) stays opt-in and is recorded apart from unit test success.
