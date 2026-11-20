# Proposal

## Why

The current isolated source installer cannot prove the experience of a user installing Macus through Homebrew. A tap with prebuilt bottles will let testers exercise installation, first startup, upgrades and removal without a host Swift, Elixir or Erlang toolchain, while keeping development distribution distinct from a production release.

**Reconciliation 2026-11-20** (add-elixir-server task 9.6): the package this change delivers is no longer Swift-only. Since add-elixir-server tasks 9.2–9.5 and 9.7, the formula and candidate carry the Swift `macus` executable **and** the paired bundled-ERTS Macus server release at `libexec/macus`, assembled from the same commit, and installation is passive with `macus start` activating two per-user jobs. The payload contract and provenance are owned by [add-elixir-server design §7](../add-elixir-server/design.md); this change owns the Homebrew delivery surface around it. Its tap-publication, installed-package hardware acceptance and integration-review tasks remain open.

## What Changes

- Add a Macus formula and reproducible ARM64 bottle workflow, with macOS 15+ restrictions, actual checksums and source-commit provenance. The bottle carries both components: the Swift executable and the paired bundled-ERTS server release (pinned shared dependency, SHA-256-pinned opsmaru_incus cassette) as a checksummed resource. Bottle installation needs no host Swift, Elixir or Erlang toolchain; contributors can still build from source with Swift 6.4 only.
- Provide a local Git tap rehearsal before publication, then populate the existing public Upmaru tap repository and prepare an immutable development artifact publication path. Shared identity is `upmaru/tap`, backed by `upmaru/homebrew-tap` (`git@github.com:upmaru/homebrew-tap.git`), created by the user.
- Preserve the virtualization entitlement through bottle creation and installation; verify the installed executable, its embedded identity and the paired release payload. Initial test bottles use clearly documented ad-hoc development signing. Developer ID signing and notarization remain future production work.
- Keep installation passive and `macus start` responsible for the two per-user services (Swift runtime job and server job). Use a verified stable Homebrew executable path for new registrations and document an explicit stop/unload/start sequence for upgrades and removal that covers both owned jobs and the revision-bound server plist.
- Add packaging checks and separately opted-in hardware acceptance using the actual Homebrew-installed binary, isolated runtime state and Incus configuration. Preserve data and diagnostics on failure and uninstall.
- Document the commands for local rehearsal and eventual `brew install upmaru/tap/macus`, plus supported bottle coverage, dependency behavior and distribution limitations.

## Capabilities

### New Capabilities

None; delivery belongs to the existing `service-delivery` capability.

### Modified Capabilities

- `service-delivery`: Homebrew formula/bottle delivery, artifact integrity, local install rehearsal and acceptance; stable service paths across Homebrew upgrades.

## Impact

- `Packaging/homebrew`, packaging automation, README and packaging/development/acceptance documentation.
- `Sources/Macus/Client/MacusStart.swift` and service identity checks where Homebrew's stable opt path and versioned Cellar path differ; relevant Swift regressions.
- `Integration/scripts` and packaging/acceptance fixtures; retain the canonical native checks and strict OpenSpec validation.
- Macus artifact CI and a separate tap repository with formula checks and bottle metadata. No tap repository or release is created by this proposal.
- Testers need Homebrew on a supported Apple Silicon Mac, network access for the existing pinned Alpine appliance and the standard Incus client. The bottle install has no host Swift, Elixir or Erlang requirement. Incus remains optional at package-install time and is installed/configured explicitly by existing startup behavior.
- This change owns the Homebrew delivery surface: formula, candidate generation, local tap rehearsal, tap publication path and installed-package acceptance. The two-component payload itself — the paired bundled-ERTS release, its pinned shared dependency and cassette, and the two service jobs — is owned by `add-elixir-server`; its packaging tasks 9.2–9.5 and 9.7 are complete and this change does not duplicate that contract. No guest image changes, workload API changes, Docker compatibility layer, automatic appliance upgrade or GUI are included.
