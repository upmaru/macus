# Proposal

## Why

Fresh appliances install their kernel, ZFS and Incus packages live from Alpine's v3.24 repositories on first boot. The bootstrap pins the kernel/ZFS pair exactly and refuses to substitute. Alpine keeps only the newest package revision on a stable branch, so every upstream kernel update breaks `macus start` for every new user until Macus requalifies and ships a new pin:

- On 2026-11-01 Alpine replaced `linux-lts`/`zfs-lts` 6.18.55-r0 with 6.18.60-r0. Fresh starts failed with `TAMA_ZFS_QUALIFIED_REVISION_UNAVAILABLE` until the pin moved (`docs/zfs-qualification.md`, 2026-11-04).
- By 2026-11-08 the repository served `zfs-lts` 6.18.62-r0, and an isolated first boot failed the same way: `Alpine v3.24 no longer provides linux-lts=6.18.60-r0 zfs=2.4.4-r0; refusing to substitute`.

The pin is correct; the ZFS module must match the booted kernel, and the combination must be qualified. The defect is that the qualified packages are fetched at first boot from a source that deletes them. Incus and its dependencies also float (`incus>=7.0.1`), so two fresh appliances can differ.

## What Changes

- **Prebuilt images from upmaru/macus-appliance:** a separate repository builds locked appliance images and attaches them to draft releases (upmaru/macus-appliance, change `add-appliance-image-build`). It owns the package locks, the build workflow, static checks, the image record format and release retention. This change is the Macus side: it consumes those images and never builds them.
- **Two kernel channels:** `lts` (`linux-lts`/`zfs-lts` from v3.24 `main`, 6.18.62 on 2026-11-09) stays the default. `stable` (`linux-stable`/`zfs-stable` from v3.24 `community`, 7.1.5 on 2026-11-09) is opt-in for a newer kernel, with the same ZFS 2.4.4, Incus 7.0.1 and QEMU 11.0.3 userland. A fresh appliance picks its channel once at first provisioning; existing appliances keep theirs. Alpine edge is not used.
- **Pinned by digest:** the Macus catalog holds at most one adopted image per channel, each a published release asset of upmaru/macus-appliance under its own appliance ID, pinned by archive and raw-disk digests. The digest in the shipped catalog stays the trust root.
- **No package installation on first boot:** the guest bootstrap verifies the image record (format 1), the installed-manifest digest and the booted kernel against the values the seed carries, and fails on any difference. It no longer contacts package repositories or performs a kernel-transition reboot. First boot keeps storage initialization, Incus preseed and service setup.
- **Qualification stays in Macus:** each draft image is booted on hardware through a test-only path before anyone publishes it, and each channel is qualified separately. The first `stable` run also covers what a new kernel series can break on Virtualization.framework.
- **BREAKING (provisioning only):** fresh appliances use a new appliance ID and image source. Existing appliances, their disks and their root images are untouched.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `linux-appliance`: appliance provisioning from a prebuilt image, trusted acquisition from upmaru/macus-appliance releases, `lts` and `stable` kernel channels selected at first provisioning, boot observations without a package or kernel-transition stage, and a qualification gate before the catalog points at an image.

## Impact

- `Integration/guest/bootstrap.sh` (package install, CA bootstrap and kernel-transition paths replaced by offline verification) and the regenerated `EmbeddedGuestPayload.swift`.
- `Integration/catalog/*.json`, `Sources/Macus/Bootstrap/ApplianceCatalog.swift`, `ApplianceAcquisition.swift`, `SeedPreparation.swift` and `Integration/scripts/check-catalog.py` for the new source, channel and expected record values.
- Channel selection: `macus start` and the daemon's provisioning path take an optional channel for a fresh state directory, persist it with the runtime state and reject a different channel for an existing appliance; `docs/cli.md` documents it.
- Startup progress: the expected kernel reboot no longer occurs for fresh appliances. The reboot-allowance mechanism may remain for compatibility, but fresh provisioning must not depend on it.
- Acceptance tooling: a test-only way to boot an unpublished draft image with digest checks.
- Documentation: development, acceptance, ZFS qualification and CLI progress docs.
- No change to the Incus API, transport, storage layout, runtime control routes or existing appliances. Hardware acceptance stays opt-in and separate from CI success.
