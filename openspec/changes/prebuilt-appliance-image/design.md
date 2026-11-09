# Design

## Context

**Fresh provisioning today:**
- `macus start` downloads the official Alpine 3.24.2 aarch64 cloud-init metal archive named by `Integration/catalog/alpine-3.24.2.json` and `ApplianceCatalogEntry.current`. It verifies the archive SHA-512 and raw-disk SHA-256, extracts the single `disk.raw` member and stages it as `root.raw`. `GuestImageManager` grows the writable root to at least 12 GiB.
- A NoCloud seed (`SeedPreparation.swift`) writes the embedded guest payload (`bootstrap.sh`, `storage.sh`, `bridge.py`, OpenRC scripts) with cloud-init `write_files` and runs `bootstrap.sh` once.
- `bootstrap.sh` waits for IPv4 DHCP, bootstraps CA certificates over HTTP with APK signatures, then installs Incus, QEMU, lxcfs and related packages (`incus>=7.0.1`), and the exact pair `linux-lts=6.18.60-r0 zfs=2.4.4-r0 zfs-libs=2.4.4-r0 zfs-lts=6.18.60-r0 zfs-openrc=2.4.4-r0` from the live v3.24 repositories. It records the kernel in `/etc/tama-zfs-qualified-kernel`, emits `TAMA_ZFS_KERNEL_REBOOT_REQUIRED`, and powers off. The daemon spends its single reboot allowance and boots again into the new kernel. Storage initialization and Incus preseed follow.

**Why that breaks:** Alpine stable branches carry only the newest revision of each package. When `linux-lts` moves, the pinned revision disappears and every fresh start fails with `TAMA_ZFS_QUALIFIED_REVISION_UNAVAILABLE`. This happened on 2026-11-01 (6.18.55 → 6.18.60) and again by 2026-11-08 (6.18.62). Existing appliances are not affected, because they finished provisioning.

**Image source:** upmaru/macus-appliance builds the images (change `add-appliance-image-build`). Each image is the signature-verified Alpine 3.24.2 cloud image with one channel's exact locked package set installed, one kernel flavor, and a format 1 image record. Builds create draft releases tagged with the appliance ID, for example `alpine-3.24.2-lts-1`. That repository's `docs/image-contract.md` defines:
- `/etc/macus-appliance-image`: LF-terminated `key=value` lines `format`, `appliance_id`, `channel`, `alpine_branch`, `lock_sha256`, `manifest_sha256`, `kernel_release`, in that order.
- Installed manifest: `apk info -v` output sorted with `LC_ALL=C`, each line LF-terminated; `manifest_sha256` is its SHA-256.
- `/etc/tama-zfs-qualified-kernel`: the kernel release plus LF, equal to `uname -r` when that kernel boots.
- Release assets: `<id>.raw.tar.gz` (single-member `disk.raw` gzip tar), `SHA512SUMS`, `SHA256SUMS`, `<id>.manifest`, `<id>.build.json` and a provenance attestation.

**Kernel flavors on v3.24 (aarch64 package indexes, 2026-11-09):**

| Flavor | Repository | Kernel | ZFS module | Shared userland |
|---|---|---|---|---|
| `lts` | `main` | `linux-lts` 6.18.62-r0 | `zfs-lts` 6.18.62-r0 | `zfs` 2.4.4-r0, `incus` 7.0.1-r2, `qemu-system-aarch64` 11.0.3-r0 |
| `stable` | `community` | `linux-stable` 7.1.5-r0 | `zfs-stable` 7.1.5-r1 | same |

**Constraints:**
- The ZFS module must match the booted kernel, and kernel/ZFS combinations require recorded hardware qualification (`linux-appliance` "Default storage qualification" and "ZFS acceptance evidence").
- Runtime acquisition must not need host Python, GnuPG or repository files ("Bounded private appliance preparation").
- Releases, tags and packages are published only with user authorization. CI success is never hardware acceptance.

## Goals / Non-Goals

**Goals:**
- Fresh provisioning never depends on Alpine still serving a particular package revision.
- A new kernel/ZFS combination reaches users only through hardware qualification, human publication in upmaru/macus-appliance and a Macus catalog change.
- Fresh first boot needs no package downloads and no kernel-transition reboot.
- Users can choose a newer `stable` kernel for a fresh appliance under the same qualification and adoption rules as `lts`.

**Non-Goals:**
- Building images, maintaining package locks or publishing image releases. upmaru/macus-appliance owns those.
- Changing or upgrading existing appliances or their root images, or switching an existing appliance between channels in place.
- Booting or qualifying images in CI.
- Changing storage layout, ZFS policy, transport, the Incus API or runtime control routes.
- Automatic image updates, a fallback to live package installation, or Alpine edge.

## Decisions

### 1. Catalog and trust

The catalog moves to `schema_version` 2 and holds at most one adopted image per channel, each under its own appliance ID.

| Field | Meaning |
|---|---|
| `id` | Appliance ID, equal to the upmaru/macus-appliance release tag |
| `channel` | `lts` or `stable` |
| `archive_url` | `https://github.com/upmaru/macus-appliance/releases/download/<id>/<id>.raw.tar.gz` |
| `archive_sha512`, `archive_bytes`, `member_name`, `raw_bytes`, `raw_sha256` | Verified by acquisition exactly as today |
| `image_format` | Image record format; Macus supports `1` |
| `manifest_sha256` | From the image record; passed to the guest in the seed |
| `kernel_release` | From the image record; passed to the guest in the seed |
| `qualified_packages` | Exact kernel, ZFS and Incus versions, for display and checks |
| `upstream`, `build` | Alpine archive and signer, and the image build's commit, run and attestation, copied from `<id>.build.json` for reference |
| `guest_payload_revision` | Unchanged meaning |

- The runtime trust decision is unchanged: Macus accepts an image only if the shipped digests match. Provenance fields are informational and can be checked with `gh attestation verify --repo upmaru/macus-appliance`.
- `check-catalog.py` keeps the JSON and Swift entries in sync, requires the URL to be an upmaru/macus-appliance release asset whose tag equals the ID, requires `image_format` 1, rejects placeholder digests and allows at most one entry per channel.

### 2. First boot verifies instead of installing

New `bootstrap.sh` flow for fresh appliances:
1. Persist the IPv4 DHCP configuration and wait for an IPv4 route, as today. Incus still needs the network for workload images.
2. Read `/etc/macus-appliance-image`. Require `format=1` and the exact key order. Compare `appliance_id`, `channel`, `manifest_sha256` and `kernel_release` with the expected values the seed carries. Recompute the manifest digest with the contract's rule and compare it. Compare `uname -r` with `kernel_release` and `/etc/tama-zfs-qualified-kernel`.
3. On any mismatch emit `MACUS_OBSERVATION v1 stage=failed code=image_mismatch` and a `TAMA_APPLIANCE_IMAGE_MISMATCH` diagnostic, and exit before storage initialization. Never install, upgrade or substitute packages.
4. Continue with today's sysctl, cgroup, module loading, OpenRC, storage and Incus steps unchanged.

The CA bootstrap, `apk update`/`apk add`, `/boot/dtbs-lts` removal and kernel-transition reboot paths are removed from the payload. Keeping live installation as a fallback would reintroduce the original failure, so there is none. Existing appliances keep the bootstrap script they were provisioned with, because cloud-init `write_files` runs once.

Observations: emit `stage=image` for verification instead of `stage=packages`. Host progress and the CLI must stop announcing an expected kernel reboot for fresh appliances. The reboot-allowance mechanism may stay for compatibility, but fresh provisioning must succeed without consuming it.

### 3. Kernel channels

- **Selection:** the host picks a channel only when it provisions a fresh appliance. `lts` is the default. A `stable` choice (for example `macus start --kernel stable`; the exact flag is chosen during implementation) is persisted with the runtime state, so restarts and later `macus start` calls keep it. Asking for a different channel on an existing appliance fails with `conflict` and changes nothing; moving channels means a new state directory. Appliances provisioned before prebuilt images count as `lts`.
- **Availability:** a channel is offered only when the shipped catalog has an entry for it. If `stable` is not catalogued, selecting it fails before any download, rather than falling back to `lts`.
- **Seed:** the seed carries the selected entry's appliance ID, channel, manifest digest and kernel release.
- **Cadence:** `linux-stable` moves across kernel series during a branch's lifetime, while `linux-lts` stays on one series. Published images keep working when Alpine moves on, so this only changes how often `stable` is requalified.

### 4. Qualification and adoption

- **Qualifying a draft:** draft assets are not public. Acceptance tooling downloads them with authenticated `gh release download --repo upmaru/macus-appliance` and supplies them through a test-only mechanism, such as a catalog override accepted only by acceptance tooling or a pre-populated isolated appliance cache. The mechanism still verifies digests and is never available in release builds. Hardware acceptance then records first-boot, storage, ZFS and relay evidence for that exact image on isolated state, following `docs/zfs-qualification.md`, and confirms no package downloads and no kernel-transition reboot.
- **New kernel series:** the first qualification of a channel's kernel series (including the first `stable` image, kernel 7.x) also covers EFI boot, virtio block and network, vsock, configured VirtioFS and, where the host supports it, nested KVM.
- **Per channel:** each channel is qualified and adopted on its own. `lts` adoption does not wait for `stable`.
- **Adoption:** after the evidence is recorded, a human publishes the upmaru/macus-appliance release. A normal Macus feature branch then moves that channel's catalog entry to the published ID, URL and digests. Released Macus versions keep provisioning the images they pin; upmaru/macus-appliance never deletes or replaces published assets.

## Risks / Trade-offs

- **Cross-repository contract:** the image record and manifest rule live in upmaru/macus-appliance and are verified here. Macus supports only `image_format` 1 and rejects any other, and contract changes need coordinated changes in both repositories.
- **Hosting and availability:** fresh installs depend on upmaru/macus-appliance release assets instead of the Alpine CDN. Assets are served from GitHub's CDN, retention forbids deleting or replacing them, and acquisition already enforces size, digest and timeout limits.
- **Image size:** pre-installed packages make the download larger than the 627 MB base archive, but first boot no longer downloads those packages. Archives stay under 2 GiB.
- **Security updates are slower:** fresh appliances get kernel and Incus fixes only when a new image is qualified and adopted. Users can still apply standard Alpine updates themselves.
- **`stable` support level:** `linux-stable` and `zfs-stable` live in `community`, which Alpine supports for a shorter period than `main`, and the kernel series changes more often. `stable` is opt-in, and `lts` stays the default.
- **Newer kernel on Virtualization.framework:** 7.x kernels have no Macus hardware evidence yet. The first `stable` qualification must cover the virtual hardware Macus relies on before that image is published.
- **No fallback:** if a published asset were removed, fresh installs for that Macus version would fail. Retention in upmaru/macus-appliance prevents that.

## Migration

- Existing appliances and state directories are untouched. `macus start` on an existing runtime reuses its disks and never downloads an image. They count as `lts` and are not converted.
- Fresh starts use the new appliance ID, cache directory and image source.
- The first image to adopt is expected to be `lts` with the then-current `linux-lts`/`zfs-lts` pair, for example 6.18.62-r0, after it passes qualification.
- `stable` is adopted separately after its own qualification. Until then the catalog offers only `lts`.
