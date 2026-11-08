# Spec Delta

## MODIFIED Requirements

### Requirement: Appliance provisioning

Provisioning SHALL be idempotent and use a pinned, maintained Alpine Linux ARM64 base and OpenRC service management. Packages SHALL be signature-verified APKs from main/community repositories on the same stable release branch, installed when the Macus appliance image is built, at the exact versions of a reviewed lock. The image SHALL contain Incus with its LXC, OCI and ARM64 VM dependencies, and compatible ZFS userspace and boot-kernel modules. The guest helper SHALL be delivered by the seed. First boot MUST NOT install, upgrade, remove or substitute packages; it SHALL verify the installed packages and booted kernel against the qualified manifest. Provisioning MUST NOT mix edge repositories, bypass package signature verification or include development/desktop/orchestration software.

#### Scenario: Repeated provisioning

- **WHEN** a previously initialized data disk is booted again
- **THEN** storage and profiles remain intact and initialization does not reset workloads

#### Scenario: Alpine service ordering

- **WHEN** OpenRC starts services on first boot or a subsequent boot
- **THEN** cgroup/kernel prerequisites and persistent storage are ready before Incus starts, and helper health reports readiness only after the Incus API responds and the selected storage layout is validated

#### Scenario: Alpine kernel support

- **WHEN** the selected appliance image is validated on a supported Mac
- **THEN** EFI, virtio storage/networking, vsock, configured VirtioFS, and container kernel prerequisites work, ZFS modules load for the booted kernel on a fresh ZFS appliance, and nested VM capability additionally requires usable guest KVM and ARM64 VM dependencies

#### Scenario: Upstream supersedes qualified packages

- **WHEN** the Alpine stable branch no longer serves the kernel, ZFS or Incus revisions in the catalogued image
- **THEN** a fresh appliance still provisions from that image without contacting package repositories

#### Scenario: Installed packages differ from the manifest

- **WHEN** first boot finds an installed package set, appliance ID or booted kernel that differs from the qualified manifest carried by the seed
- **THEN** it reports an image mismatch before storage initialization, leaves a blank data disk unformatted and withholds readiness

### Requirement: Trusted image acquisition

Automated acquisition SHALL select a fixed compatible ARM64 Macus appliance image from trusted metadata shipped with Macus and download it from a published Macus release asset. Archive and extracted-disk digests SHALL be verified before publication or runtime creation. Metadata SHALL record the upstream Alpine signature verification of the base image against a pinned signer, the build commit and workflow run, the build provenance attestation and the installed package manifest digest. A checksum downloaded beside an image MUST NOT establish trust on its own; unsupported catalog versions or integrity failures SHALL stop creation.

#### Scenario: Authentic pinned archive

- **WHEN** the catalogued archive is downloaded
- **THEN** it is accepted only if its exact archive and raw-disk digests match the shipped trusted entry, with upstream signer and build provenance recorded in that entry

#### Scenario: Tampered archive or cache

- **WHEN** an archive or previously cached raw image differs from its trusted digest
- **THEN** it is rejected before seed/runtime creation and no existing runtime data is modified

### Requirement: Boot-scoped provisioning observations

Guest provisioning SHALL expose versioned stage observations scoped to the current boot. Observations SHALL distinguish image verification, storage initialization, and Incus initialization. They MUST NOT contain secrets or serve as readiness evidence. Unknown observations SHALL be ignored safely. Fresh provisioning from a catalogued image MUST NOT require a kernel-transition reboot. The host SHALL keep honoring the explicit expected-kernel-reboot signal scoped to the current boot from appliances provisioned before prebuilt images.

#### Scenario: Prebuilt first boot

- **WHEN** a fresh appliance boots the catalogued image with its seed
- **THEN** it verifies the image and proceeds to storage and Incus initialization in the same boot, without an expected-reboot observation

#### Scenario: Kernel transition

- **WHEN** an appliance provisioned before prebuilt images emits the expected-reboot observation in the current boot before shutting down
- **THEN** the host treats that shutdown as the expected kernel transition and leaves durable continuation registered, while fresh appliances never emit it

#### Scenario: Provisioning failure

- **WHEN** the image does not match the qualified manifest or storage initialization refuses existing data
- **THEN** progress identifies the failure and preserves diagnostics without installing or substituting packages, formatting data, or advertising readiness

## ADDED Requirements

### Requirement: Appliance image build

Macus SHALL build appliance images with a manually dispatched GitHub Actions workflow on a GitHub-hosted Linux arm64 runner, starting from the upstream Alpine archive verified against the pinned signer and recorded digests. The build SHALL install the exact locked package set into the image without booting it, run package triggers so the installed kernel, its ZFS module and initramfs match, and record the kernel release, appliance ID and installed package manifest digest in the image. The build SHALL fail when the installed packages differ from the lock, a locked version is unavailable, the ZFS module does not match the installed kernel, or the boot configuration does not select the installed kernel. Images MUST NOT contain a machine ID, SSH host keys, cloud-init instance state, package caches, build logs or workflow credentials. CI success MUST NOT be reported as boot, ZFS or hardware evidence.

#### Scenario: Locked build

- **WHEN** the workflow runs while the repository still serves every locked version
- **THEN** the image contains exactly the locked packages, its manifest digest and kernel record match, and static checks pass

#### Scenario: Repository drift

- **WHEN** a locked version is unavailable or the resolved package set differs from the lock
- **THEN** the build fails without producing or attaching an image

#### Scenario: Image hygiene

- **WHEN** the image is prepared for compression
- **THEN** it has no machine ID, host keys, cloud-init instance state, package caches, logs or credentials, so the seed runs as a first boot

### Requirement: Appliance image release and qualification

The image build SHALL attach the compressed image, its archive and raw-disk digests, the installed package manifest and a build provenance attestation to a draft GitHub release for a new appliance ID. Workflows and agents MUST NOT publish that release or change the shipped catalog. A human SHALL publish it only after recorded opt-in hardware qualification on isolated state, including ZFS acceptance evidence for its kernel and package versions. The shipped catalog SHALL reference only published, qualified images. A published image referenced by any released Macus version MUST remain available and MUST NOT be replaced in place; a changed image requires a new appliance ID. Qualifying an unpublished image SHALL use a test-only mechanism that still verifies digests and is unavailable in release builds.

#### Scenario: Draft image

- **WHEN** the build workflow completes
- **THEN** the release remains a draft and the shipped catalog is unchanged

#### Scenario: Qualified image adopted

- **WHEN** hardware qualification of a draft image is recorded and a human publishes the release
- **THEN** the catalog can move to the new appliance ID, release URL, digests and provenance through a normal reviewed change

#### Scenario: Qualification fails

- **WHEN** the draft image fails boot, storage or ZFS qualification
- **THEN** it is not published, the catalog keeps its previous image, and the failure is recorded

#### Scenario: Superseded image

- **WHEN** a newer image is adopted
- **THEN** older published images stay downloadable for the Macus versions that pin them
