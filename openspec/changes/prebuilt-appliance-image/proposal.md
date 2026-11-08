# Proposal

## Why

Fresh appliances install their kernel, ZFS and Incus packages live from Alpine's v3.24 repositories on first boot. The bootstrap pins the kernel/ZFS pair exactly and refuses to substitute. Alpine keeps only the newest package revision on a stable branch, so every upstream kernel update breaks `macus start` for every new user until Macus requalifies and ships a new pin:

- On 2026-11-01 Alpine replaced `linux-lts`/`zfs-lts` 6.18.55-r0 with 6.18.60-r0. Fresh starts failed with `TAMA_ZFS_QUALIFIED_REVISION_UNAVAILABLE` until the pin moved (`docs/zfs-qualification.md`, 2026-11-04).
- By 2026-11-08 the repository served `zfs-lts` 6.18.62-r0, and an isolated first boot failed the same way: `Alpine v3.24 no longer provides linux-lts=6.18.60-r0 zfs=2.4.4-r0; refusing to substitute`.

The pin is correct; the ZFS module must match the booted kernel, and the combination must be qualified. The defect is that the qualified packages are fetched at first boot from a source that deletes them. Incus and its dependencies also float (`incus>=7.0.1`), so two fresh appliances can differ.

## What Changes

- **Prebuilt appliance image:** a manually dispatched GitHub Actions workflow builds a Macus appliance image on a GitHub-hosted Linux arm64 runner. It starts from the signature-verified Alpine 3.24.2 cloud image and installs an exact, locked package set (kernel, ZFS, Incus, QEMU and the rest of today's first-boot packages) into the image's root filesystem without booting it.
- **Static verification in CI:** the workflow checks the installed package set against the lock, the kernel/ZFS module and initramfs match, the boot entry, and image hygiene (no machine ID, host keys, cloud-init instance state, package cache or build secrets). CI cannot boot the image and does not claim to.
- **Draft release publication:** the workflow attaches the compressed image, its digests, the installed package manifest and a build provenance attestation to a **draft** GitHub release. Only a human publishes it, after hardware qualification.
- **Pinned by digest:** the Macus catalog points at the published release asset under a new appliance ID and pins its archive and raw-disk digests. The digest in the shipped catalog is the trust root. The catalog records the upstream Alpine signature verification and the build provenance.
- **No package installation on first boot:** the guest bootstrap verifies the installed packages offline against the qualified manifest and fails on any difference. It no longer contacts package repositories or performs a kernel-transition reboot. First boot keeps storage initialization, Incus preseed and service setup.
- **Requalification becomes planned:** moving to a newer kernel means updating the lock, building a new draft image, qualifying it on hardware, publishing it and moving the catalog. Published images stay downloadable after Alpine drops their packages.
- **BREAKING (provisioning only):** fresh appliances use a new appliance ID and image source. Existing appliances, their disks and their root images are untouched.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `linux-appliance`: appliance provisioning from a prebuilt image, trusted image acquisition from Macus releases, boot observations without a package or kernel-transition stage, plus new requirements for the image build and the qualification gate before a catalog points at an image.

## Impact

- New `.github/workflows/appliance-image.yml` and build scripts and inputs under `Integration/appliance-image/` (or similar), including the package lock.
- `Integration/guest/bootstrap.sh` (package install, CA bootstrap and kernel-transition paths replaced by offline verification) and the regenerated `EmbeddedGuestPayload.swift`.
- `Integration/catalog/*.json`, `Sources/Macus/Bootstrap/ApplianceCatalog.swift`, `ApplianceAcquisition.swift` and `Integration/scripts/check-catalog.py` for the new source and provenance fields.
- Startup progress: the expected kernel reboot no longer occurs for fresh appliances. The reboot-allowance mechanism may remain for compatibility, but fresh provisioning must not depend on it.
- Documentation: development, acceptance, ZFS qualification and CLI progress docs.
- No change to the Incus API, transport, storage layout, runtime control routes or existing appliances. Hardware acceptance stays opt-in and separate from CI success.
