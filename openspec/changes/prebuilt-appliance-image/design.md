# Design

## Context

**Fresh provisioning today:**
- `macus start` downloads the official Alpine 3.24.2 aarch64 cloud-init metal archive named by `Integration/catalog/alpine-3.24.2.json` and `ApplianceCatalogEntry.current`. It verifies the archive SHA-512 and raw-disk SHA-256, extracts the single `disk.raw` member and stages it as `root.raw`. `GuestImageManager` grows the writable root to at least 12 GiB.
- A NoCloud seed (`SeedPreparation.swift`) writes the embedded guest payload (`bootstrap.sh`, `storage.sh`, `bridge.py`, OpenRC scripts) with cloud-init `write_files` and runs `bootstrap.sh` once.
- `bootstrap.sh` waits for IPv4 DHCP, bootstraps CA certificates over HTTP with APK signatures, then installs Incus, QEMU, lxcfs and related packages (`incus>=7.0.1`), and the exact pair `linux-lts=6.18.60-r0 zfs=2.4.4-r0 zfs-libs=2.4.4-r0 zfs-lts=6.18.60-r0 zfs-openrc=2.4.4-r0` from the live v3.24 repositories. It records the kernel in `/etc/tama-zfs-qualified-kernel`, emits `TAMA_ZFS_KERNEL_REBOOT_REQUIRED`, and powers off. The daemon spends its single reboot allowance and boots again into the new kernel. Storage initialization and Incus preseed follow.

**Why that breaks:** Alpine stable branches carry only the newest revision of each package. When `linux-lts` moves, the pinned revision disappears and every fresh start fails with `TAMA_ZFS_QUALIFIED_REVISION_UNAVAILABLE`. This happened on 2026-11-01 (6.18.55 → 6.18.60) and again by 2026-11-08 (6.18.62). Existing appliances are not affected, because they finished provisioning.

**Constraints:**
- The ZFS module must match the booted kernel, and kernel/ZFS combinations require recorded hardware qualification (`linux-appliance` "Default storage qualification" and "ZFS acceptance evidence").
- Runtime acquisition must not need host Python, GnuPG or repository files ("Bounded private appliance preparation").
- Releases, tags and packages are published only with user authorization. CI success is never hardware acceptance.
- GitHub-hosted macOS runners are virtual machines and are not expected to run Virtualization.framework guests, so CI cannot boot the appliance.

## Goals / Non-Goals

**Goals:**
- Fresh provisioning never depends on Alpine still serving a particular package revision.
- Every package in a fresh appliance, including Incus, is fixed by a reviewed lock and recorded in a manifest.
- A new kernel/ZFS combination reaches users only through an explicit build, hardware qualification, human publication and catalog change.
- Fresh first boot needs no package downloads and no kernel-transition reboot.

**Non-Goals:**
- Changing or upgrading existing appliances or their root images.
- Booting or qualifying images in CI.
- Bit-for-bit reproducible images. The published digest, not reproducibility, is the trust root.
- Changing storage layout, ZFS policy, transport, the Incus API or runtime control routes.
- Automatic image updates or a fallback to live package installation.

## Decisions

### 1. Build on a Linux arm64 runner by installing into the image, not booting it

The workflow runs on a GitHub-hosted `ubuntu-24.04-arm` runner. The repository is public, so these runners are available without self-hosting. Installing into the image needs only native arm64 execution, loop devices and `chroot`, which are available there.

Build steps:
1. Download the Alpine archive, `.sha512` and `.asc` named in the build inputs, and the signing key. Verify the signature against the pinned fingerprint `F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22` and the recorded digests with `Integration/scripts/verify-appliance.py`.
2. Extract `disk.raw`, extend it to the build size and grow the root partition and filesystem.
3. Attach it as a loop device with partitions, mount the root and boot/EFI partitions, and bind-mount `/dev`, `/proc` and `/sys` for package triggers. Provide a temporary `resolv.conf`.
4. In a `chroot`, configure `https://dl-cdn.alpinelinux.org/alpine/v3.24/{main,community}` only, run `apk update`, remove `/boot/dtbs-lts` (the existing workaround for EFI partition space), and install every package in the lock at its exact version. APK signature verification stays enabled, using the image's own Alpine keys.
5. Let package triggers (`mkinitfs` and the boot configuration update) run inside the chroot.
6. Write the image record and kernel record (Decision 4), clean the image (Decision 4), unmount, detach and compress.

*Alternative considered:* booting the image under QEMU on the runner. Rejected because it adds a second hypervisor whose behavior is not Virtualization.framework, and is slower. The image's first real boot is checked during hardware qualification instead.

*Alternative considered:* `alpine-make-vm-image` creating a disk from scratch. Rejected for now because starting from the signed official cloud image keeps its known EFI, cloud-init and partition layout, which hardware acceptance has already covered. An implementation may still borrow its techniques.

*Open point:* the Alpine cloud metal image's exact bootloader mechanism must be confirmed during implementation. The build must prove that the boot configuration selects the installed `linux-lts` kernel and initramfs, and fail otherwise.

### 2. A full package lock

`Integration/appliance-image/packages.lock` (path indicative) lists every package that must be present in the final image as `name=version`, covering the base image's packages and the additions. It is the complete `apk info -v` closure, sorted.

- The top-level package list mirrors today's `bootstrap.sh` install set, with Incus pinned exactly instead of `>=7.0.1`.
- After installation the build compares the sorted `apk info -v` output to the lock and fails on any difference: missing, extra or different version.
- A lock-refresh script resolves the current repository for the top-level list and rewrites the lock. A human reviews the diff. Refreshing the lock is the start of requalification, never an automatic CI step.
- The build fails if the repository no longer serves a locked version. That failure is expected once Alpine moves on, and it does not affect already published images.

### 3. Artifact format and size

- Keep today's archive format: a gzip tar with one regular member `disk.raw`. `ApplianceAcquisition` and `TarArchive` then keep working, and no new host decompressor is needed.
- The raw size is fixed by the build (expected to be a few GiB, measured during implementation) and recorded in the catalog as `raw_bytes`. The compressed archive must stay below GitHub's 2 GiB release asset limit and is recorded as `archive_bytes`.
- Runtime root growth to 12 GiB stays in `GuestImageManager`. The implementation must confirm the filesystem still grows into it at first boot, as it does today.

### 4. Image contents and hygiene

**Baked into the image:**
- Every locked package, including the kernel, initramfs and ZFS module.
- `/etc/tama-zfs-qualified-kernel` with the installed kernel release.
- `/etc/macus-appliance-image`: appliance ID, lock SHA-256, installed-manifest SHA-256 and kernel release. It contains no secrets and no build host paths.
- The HTTPS v3.24 repositories file, as today.

**Stays in the seed, not the image:** the guest helper payload (`bootstrap.sh`, `storage.sh`, `bridge.py`, OpenRC scripts), the ZFS ARC cap and Incus preseed. Helper fixes then ship with Macus without a new image, and an image's qualification is not invalidated by helper changes. The seed's `guest_payload_revision` stays independent of the image digest.

**Removed before compression:** `/etc/machine-id` contents, SSH host keys, cloud-init instance state (`cloud-init clean --logs` equivalent, so the NoCloud seed runs as a first boot), APK caches, `/var/log` contents, shell history, the temporary `resolv.conf` and any workflow token or path. Free blocks are zeroed so the archive compresses well.

### 5. First boot verifies instead of installing

New `bootstrap.sh` flow for fresh appliances:
1. Persist the IPv4 DHCP configuration and wait for an IPv4 route, as today. Incus still needs the network for workload images.
2. Read `/etc/macus-appliance-image`. Compute the SHA-256 of the sorted `apk info -v` output and compare it, and the appliance ID, with the expected values the seed carries from the catalog. Compare `uname -r` with `/etc/tama-zfs-qualified-kernel`.
3. On any mismatch emit `MACUS_OBSERVATION v1 stage=failed code=image_mismatch` and a `TAMA_APPLIANCE_IMAGE_MISMATCH` diagnostic, and exit before storage initialization. Never install, upgrade or substitute packages.
4. Continue with today's sysctl, cgroup, module loading, OpenRC, storage and Incus steps unchanged.

The CA bootstrap, `apk update`/`apk add` and kernel-transition reboot paths are removed from the payload. Keeping live installation as a fallback would reintroduce the original failure, so there is none. Existing appliances keep the bootstrap script they were provisioned with, because cloud-init `write_files` runs once.

Observations: emit `stage=image` for verification instead of `stage=packages`. Host progress and the CLI must stop announcing an expected kernel reboot for fresh appliances. The reboot-allowance mechanism may stay for compatibility, but fresh provisioning must succeed without consuming it.

### 6. Catalog and trust

The catalog moves to `schema_version` 2 under a new appliance ID. The ID names the image, for example `alpine-3.24.2-macus-<n>`; the exact scheme is chosen during implementation. Every published image gets a new ID.

| Field | Meaning |
|---|---|
| `archive_url` | `https://github.com/upmaru/macus/releases/download/<tag>/<asset>` |
| `archive_sha512`, `archive_bytes`, `member_name`, `raw_bytes`, `raw_sha256` | Verified by acquisition exactly as today |
| `upstream` | Alpine archive name, SHA-512 and pinned signer fingerprint verified by the build |
| `build` | Repository, commit, workflow run URL and attestation reference |
| `package_manifest_sha256` | SHA-256 of the sorted installed manifest; also passed to the guest in the seed |
| `qualified_packages` | Exact kernel, ZFS and Incus versions, for display and checks |
| `guest_payload_revision` | Unchanged meaning |

- The runtime trust decision is unchanged: Macus accepts the image only if the shipped digests match. Provenance fields are informational and can be checked with `gh attestation verify`.
- `check-catalog.py` keeps the JSON and Swift entries in sync, requires the URL to be under `upmaru/macus` releases, and rejects placeholder digests.

### 7. Release publication and qualification

**Workflow:** `.github/workflows/appliance-image.yml` runs only on `workflow_dispatch`, with inputs for the appliance ID and lock revision. Its permissions are limited to `contents: write`, `id-token: write` and `attestations: write`, and third-party actions are pinned by commit SHA. It creates a **draft** release tagged `appliance/<id>` with:
- the compressed image archive;
- `SHA512SUMS` and `SHA256SUMS` for the archive and raw disk;
- the installed package manifest;
- a build report JSON with upstream verification, lock digest, kernel release, commit and run URL;
- a build provenance attestation from `actions/attest-build-provenance`.

It never publishes the release, edits the catalog or opens a pull request with catalog changes.

**Qualification of a draft image:** draft assets are not public. Qualification therefore downloads them with authenticated `gh release download` and supplies them to an isolated test through a test-only mechanism, such as a catalog override accepted only by acceptance tooling or a pre-populated isolated appliance cache. The mechanism still verifies the digests and is never available in release builds. Hardware acceptance then records boot, storage and ZFS evidence for that image on isolated state, following `docs/zfs-qualification.md`.

**Adoption:** after the evidence is recorded, a human publishes the release. A normal feature branch then moves the catalog to the new ID, URL and digests.

**Retention:** published images referenced by any released Macus are never deleted or replaced. Older Macus versions keep provisioning the image they pin.

## Risks / Trade-offs

- **Boot configuration under chroot:** triggers may behave differently than on a booted system. Mitigation: the build verifies the boot entry and initramfs statically, and hardware qualification boots the exact artifact before publication.
- **Hosting and availability:** fresh installs depend on GitHub release assets instead of the Alpine CDN. Assets are served from GitHub's CDN, and acquisition already enforces size, digest and timeout limits.
- **Image size and build time:** pre-installed packages make the download larger than the 627 MB base archive, but first boot no longer downloads those packages. The archive must stay under 2 GiB.
- **Security updates are slower:** fresh appliances get kernel and Incus fixes only when a new image is qualified. This is the deliberate trade-off for a qualified kernel/ZFS pair. Users can still apply standard Alpine updates themselves.
- **Supply chain:** APK signatures, the exact lock, SHA-pinned actions, minimal workflow permissions and provenance attestations bound what a compromised dependency can change. A human reviews both the lock and the publication.
- **No fallback:** if a published asset were removed, fresh installs for that Macus version would fail. Retention prevents that.

## Migration

- Existing appliances and state directories are untouched. `macus start` on an existing runtime reuses its disks and never downloads an image.
- Fresh starts use the new appliance ID, cache directory and image source.
- The first image to adopt is expected to carry the then-current `linux-lts`/`zfs-lts` pair, for example 6.18.62-r0, after it passes qualification.
