# Tasks

## 1. Build inputs and lock

- [ ] 1.1 Add versioned build inputs: upstream Alpine archive name, URL, SHA-512, raw SHA-256 and pinned signer fingerprint (reusing the current catalog values), the top-level package list mirroring today's `bootstrap.sh` install set with Incus pinned exactly, and the target raw size; verify they are parsed by the build and checked in tests.
- [ ] 1.2 Add the full sorted `name=version` package lock and a lock-refresh script that resolves the current v3.24 main/community repositories for the top-level list and rewrites the lock for human review; verify the script never runs in CI automatically and its output format with fixture APKINDEX data.

## 2. Image build workflow

- [ ] 2.1 Write the build script: verify the upstream archive with `verify-appliance.py`, extend and repartition `disk.raw`, loop-mount root and boot partitions, install the locked packages in a chroot with signature verification, run package triggers, and confirm the Alpine cloud image's bootloader mechanism; verify locally on Linux arm64 or in the workflow.
- [ ] 2.2 Add static image checks: installed manifest equals the lock, the ZFS module exists for the installed kernel release, the initramfs exists, the boot configuration selects the installed kernel, `/etc/tama-zfs-qualified-kernel` and `/etc/macus-appliance-image` are correct, and hygiene (no machine ID, host keys, cloud-init instance state, APK cache, logs or credentials); verify each check fails on a deliberately broken fixture.
- [ ] 2.3 Package the image as a single-member `disk.raw` gzip tar under 2 GiB, and produce `SHA512SUMS`, `SHA256SUMS`, the installed manifest and a build report JSON; verify the archive passes the existing `TarArchive` extraction rules.
- [ ] 2.4 Add `.github/workflows/appliance-image.yml` on `ubuntu-24.04-arm`, `workflow_dispatch` only, minimal permissions, SHA-pinned actions and `actions/attest-build-provenance`; it creates a draft release tagged `appliance/<id>` with the artifacts and never publishes, edits the catalog or opens a pull request; verify the workflow lints and a dry run with release creation disabled succeeds.

## 3. Guest bootstrap and seed

- [ ] 3.1 Replace the CA bootstrap, package installation and kernel-transition paths in `Integration/guest/bootstrap.sh` with offline verification of the appliance ID, installed-manifest digest and booted kernel; on mismatch emit `stage=failed code=image_mismatch` and `TAMA_APPLIANCE_IMAGE_MISMATCH` before storage initialization; verify with shell fixture tests for match, package drift, wrong ID and wrong kernel, including that no `apk` command runs.
- [ ] 3.2 Pass the expected appliance ID and manifest digest from the catalog into the NoCloud seed; regenerate `EmbeddedGuestPayload.swift` and the catalog `guest_payload_revision`; verify `sync-guest-payload.py --check` and seed preparation tests.
- [ ] 3.3 Emit `stage=image` observations, and update host progress, the CLI and `docs/cli.md` so fresh starts no longer announce an expected kernel reboot; keep unknown-observation handling and existing reboot-allowance compatibility; verify progress renderer and observation parser tests.

## 4. Macus catalog and acquisition

- [ ] 4.1 Move the catalog to schema version 2 with a new appliance ID, release asset URL, digests, `upstream`, `build`, `package_manifest_sha256` and exact `qualified_packages`, in both `Integration/catalog/*.json` and `ApplianceCatalogEntry`; keep acquisition's digest, size and extraction checks unchanged; verify catalog decoding, acquisition and cache-validation tests.
- [ ] 4.2 Extend `check-catalog.py` to keep the JSON and Swift entries in sync, require an `upmaru/macus` release URL and reject placeholder digests; verify with passing and failing fixtures.
- [ ] 4.3 Add a test-only way for acceptance tooling to use an unpublished image (for example a catalog override or pre-populated isolated cache) that still verifies digests and is unavailable in release builds; verify a release build rejects it.

## 5. Documentation

- [ ] 5.1 Document the image build, lock refresh, draft release, qualification, publication and retention flow, and the requalification procedure, in `docs/development.md` and `docs/zfs-qualification.md`; update `docs/architecture.md` and `docs/acceptance.md` for prebuilt provisioning and state that existing appliances are unchanged.

## 6. Verification and adoption

- [ ] 6.1 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`.
- [ ] 6.2 With user authorization, dispatch the workflow to produce a draft image for the current `linux-lts`/`zfs-lts` pair; record the run, digests and manifest. CI success is not hardware evidence.
- [ ] 6.3 With explicit opt-in and isolated state, boot the draft image through the test-only path and record first-boot, storage, ZFS and relay acceptance per `docs/zfs-qualification.md`, confirming no package downloads and no kernel-transition reboot; leave this unchecked until it passes on hardware.
- [ ] 6.4 After a human publishes the qualified release, point the shipped catalog at it and verify a fresh isolated `macus start` downloads and verifies the published asset. Do not publish the release, tag a Macus release or merge without user authorization.
