# Tasks

## 1. Guest bootstrap and seed

- [ ] 1.1 Replace the CA bootstrap, package installation, `/boot/dtbs-lts` removal and kernel-transition paths in `Integration/guest/bootstrap.sh` with offline verification of the format 1 image record (exact keys and order), appliance ID, channel, recomputed manifest digest and booted kernel, following upmaru/macus-appliance `docs/image-contract.md`; on mismatch emit `stage=failed code=image_mismatch` and `TAMA_APPLIANCE_IMAGE_MISMATCH` before storage initialization; verify with shell fixture tests for a match on both channels, package drift, unknown format, wrong ID, wrong channel and wrong kernel, confirming that the read-only `apk info -v` query is the only APK operation.
- [x] 1.2 Pass the selected catalog entry's appliance ID, channel, manifest digest and kernel release into the NoCloud seed; regenerate `EmbeddedGuestPayload.swift` and the catalog `guest_payload_revision`; verify `sync-guest-payload.py --check` and seed preparation tests.
- [ ] 1.3 Emit `stage=image` observations, and update host progress, the CLI and `docs/cli.md` so fresh starts no longer announce an expected kernel reboot; keep unknown-observation handling and existing reboot-allowance compatibility; verify progress renderer and observation parser tests.

## 2. Catalog, acquisition and channels

- [x] 2.1 Move the catalog to schema version 2 with at most one entry per channel, each with `id`, `channel`, an upmaru/macus-appliance release asset URL, digests, `image_format`, `manifest_sha256`, `kernel_release`, exact `qualified_packages`, `upstream` and `build`, in both `Integration/catalog/*.json` and `ApplianceCatalogEntry`; keep acquisition's digest, size and extraction checks unchanged; verify catalog decoding, acquisition and cache-validation tests.
- [x] 2.2 Extend `check-catalog.py` to keep the JSON and Swift entries in sync, require an upmaru/macus-appliance release URL whose tag equals the ID, require `image_format` 1, allow at most one entry per channel and reject placeholder digests; verify with passing and failing fixtures.
- [ ] 2.3 Add channel selection for fresh provisioning: default `lts`, an optional `stable` choice through `macus start` and the daemon's provisioning path, persisted with the runtime state; a different channel for an existing appliance fails with `conflict` without changes, a channel without a catalogued image fails before any download, and pre-prebuilt appliances count as `lts`; document it in `docs/cli.md`; verify CLI parsing, persistence and conflict tests.
- [x] 2.4 Add a test-only way for acceptance tooling to use an unpublished draft image from upmaru/macus-appliance (for example a catalog override or pre-populated isolated cache) that still verifies digests and is unavailable in release builds; verify a release build rejects it.

## 3. Documentation

- [x] 3.1 Document prebuilt provisioning, channels, the qualification and adoption flow and the requalification procedure in `docs/development.md`, `docs/zfs-qualification.md`, `docs/architecture.md` and `docs/acceptance.md`, linking upmaru/macus-appliance for building and releasing images, and state that existing appliances are unchanged.

## 4. Verification and adoption

- [x] 4.1 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`.
- [x] 4.2 With explicit opt-in and isolated state, boot the first `lts` draft image from upmaru/macus-appliance through the test-only path and record first-boot, storage, ZFS and relay acceptance per `docs/zfs-qualification.md`, confirming no package downloads and no kernel-transition reboot; leave this unchecked until it passes on hardware.
- [ ] 4.3 With explicit opt-in and isolated state, qualify the first `stable` draft image the same way, adding EFI boot, virtio block and network, vsock, configured VirtioFS and, where supported, nested KVM checks for the new kernel series; leave this unchecked until it passes on hardware. `lts` adoption does not wait for it.
- [x] 4.4 After a human publishes a qualified upmaru/macus-appliance release, point that channel's catalog entry at it and verify a fresh isolated `macus start` on that channel downloads and verifies the published asset. Do not publish releases, tag a Macus release or merge without user authorization.
