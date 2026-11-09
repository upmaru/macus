# Spec Delta

## MODIFIED Requirements

### Requirement: Appliance provisioning

Provisioning SHALL be idempotent and use a pinned, maintained Alpine Linux ARM64 base and OpenRC service management. Packages SHALL be signature-verified APKs from main/community repositories on the same stable release branch, installed when upmaru/macus-appliance builds the appliance image, at the exact versions of a reviewed lock. The image SHALL contain Incus with its LXC, OCI and ARM64 VM dependencies, and compatible ZFS userspace and boot-kernel modules for exactly one kernel channel: `lts` (`linux-lts`/`zfs-lts`) or `stable` (`linux-stable`/`zfs-stable`), both from that branch. The guest helper SHALL be delivered by the seed. First boot MUST NOT install, upgrade, remove or substitute packages; it SHALL verify the installed packages and booted kernel against the qualified manifest. Provisioning MUST NOT mix edge repositories, bypass package signature verification or include development/desktop/orchestration software.

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

- **WHEN** first boot finds an installed package set, appliance ID, channel or booted kernel that differs from the qualified manifest carried by the seed
- **THEN** it reports an image mismatch before storage initialization, leaves a blank data disk unformatted and withholds readiness

### Requirement: Trusted image acquisition

Automated acquisition SHALL select the fixed compatible ARM64 Macus appliance image for the appliance's kernel channel from trusted metadata shipped with Macus and download it from a published upmaru/macus-appliance release asset. Archive and extracted-disk digests SHALL be verified before runtime creation. Metadata SHALL record the upstream Alpine archive and signer, the image build commit, workflow run and provenance attestation, the image record format, and the expected installed-manifest digest and kernel release. A checksum downloaded beside an image MUST NOT establish trust on its own; unsupported catalog versions or integrity failures SHALL stop creation.

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

### Requirement: Appliance kernel channels

Macus SHALL offer an `lts` kernel channel and a `stable` kernel channel, each served by its own qualified appliance image from the same Alpine stable release branch. `lts` SHALL be the default. The host SHALL choose a channel only when provisioning a fresh appliance and SHALL persist it with the runtime state. Appliances provisioned before prebuilt images SHALL count as `lts`. A request for a different channel on an existing appliance MUST fail without changing its disks or state. A channel without a published, qualified catalog entry MUST NOT be offered and MUST NOT fall back to another channel. Each channel's image SHALL be qualified separately, and a new kernel series SHALL be qualified for EFI boot, virtio storage and networking, vsock, configured VirtioFS and, where supported, nested KVM before its image is published.

#### Scenario: Default channel

- **WHEN** a fresh appliance is provisioned without a channel choice
- **THEN** it uses the catalogued `lts` image

#### Scenario: Newer kernel chosen

- **WHEN** a fresh appliance is provisioned with the `stable` channel and the catalog has a qualified `stable` image
- **THEN** it boots that image with the `linux-stable` kernel and matching `zfs-stable` module, and later starts keep the `stable` channel

#### Scenario: Channel change on an existing appliance

- **WHEN** a start requests a channel other than the one an existing appliance was provisioned with
- **THEN** it fails with a conflict and leaves the appliance's disks and state unchanged

#### Scenario: Channel without a qualified image

- **WHEN** the `stable` channel is requested but the shipped catalog has no published, qualified `stable` image
- **THEN** provisioning fails before any download and does not substitute the `lts` image

### Requirement: Appliance image qualification and adoption

Macus SHALL consume prebuilt appliance images built and released by upmaru/macus-appliance and MUST NOT build images or publish their releases. The shipped catalog SHALL reference only published upmaru/macus-appliance release assets whose exact image has recorded opt-in hardware qualification on isolated state, including ZFS acceptance evidence for its kernel and package versions, and SHALL hold at most one image per channel. Qualifying an unpublished draft image SHALL use a test-only mechanism that still verifies digests and is unavailable in release builds. Macus SHALL accept only image record formats it supports and SHALL reject any other before storage initialization.

#### Scenario: Draft image qualified

- **WHEN** acceptance tooling boots a draft image through the test-only path on isolated state
- **THEN** it verifies the draft's digests, records first-boot, storage, ZFS and relay evidence for that exact image, and changes no shipped catalog

#### Scenario: Qualified image adopted

- **WHEN** hardware qualification of a draft image is recorded and a human publishes its upmaru/macus-appliance release
- **THEN** that channel's catalog entry can move to the published ID, release URL, digests and expected record values through a normal reviewed change

#### Scenario: Qualification fails

- **WHEN** a draft image fails boot, storage or ZFS qualification
- **THEN** it is not adopted, the catalog keeps its previous image for that channel, and the failure is recorded

#### Scenario: Unsupported image format

- **WHEN** first boot finds an image record format Macus does not support
- **THEN** it reports an image mismatch before storage initialization and withholds readiness

#### Scenario: Superseded image

- **WHEN** a newer image is adopted for a channel
- **THEN** Macus versions released earlier keep provisioning the image they pin
