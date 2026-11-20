# Homebrew candidates

The shared tap is [upmaru/homebrew-tap](https://github.com/upmaru/homebrew-tap). Its scaffold is ready; `brew install upmaru/tap/macus` becomes available after verified candidate assets and a completed formula are published. The source formula template here is canonical for both local generation and shared export.

Candidates are development packages, ad-hoc signed with `com.apple.security.virtualization`, without Developer ID signing or notarization. Runtime support is Apple Silicon and macOS 15+. Bottle coverage is the actual verified ARM64 macOS tag; the deployment target alone does not prove bottle compatibility. Source builds require Xcode 27 / Swift 6.4. Packaging requires Python 3.11+ and Homebrew 7 with formula trust support.

## Local generation and package acceptance

Start from a clean committed feature branch with the mise-pinned Elixir/Erlang installed and the opsmaru_incus cassette for the locked version downloaded and attestation-checked (see [development](../../docs/development.md#macus-command)). Use an ignored fresh output directory:

```sh
python3 Packaging/homebrew/candidate.py prepare --output .integration/homebrew-candidate \
  --cassette /absolute/opsmaru_incus-VERSION.tama-cassette
python3 Packaging/homebrew/candidate.py build --opt-in --candidate .integration/homebrew-candidate
brew uninstall upmaru/macus-local/macus
python3 Packaging/homebrew/candidate.py install --opt-in --candidate .integration/homebrew-candidate
```

The build creates a local Git tap, trusts only its generated formula, builds through Homebrew, checks the installed signature/entitlement, generates Homebrew bottle JSON and runs style/audit. The middle uninstall removes the source-built test keg before anything has started a service. Installation then uses `--force-bottle` and requires a receipt showing a poured bottle from the expected tap; source fallback is not bottle evidence.

These opt-in mutations refuse an existing Macus package, another `macus` on PATH or an unrelated local tap. Use a dedicated package environment: runtime isolation or a new account does not isolate machine-wide Homebrew. Candidate data, logs and partial installs are retained on failure for explicit recovery. No package command starts launchd or a VM. Generated artifacts must not be committed.

`prepare` also assembles the Macus server release from the same commit with `Packaging/install-local.sh` (the pinned Elixir/OTP, statically linked OpenSSL, the cassette given) and archives it as `macus-server-<version>.tar.gz`. It refuses a release whose `macus-build.json` names another Macus version or revision, or another `opsmaru_incus` version or checksum than `server/mix.lock` locks at that commit. The formula installs that archive as its `server-release` resource at `libexec/macus`, beside `bin/macus`. Homebrew's own Elixir and Erlang are not used: they would link Homebrew's OpenSSL and wxWidgets and differ from the pinned versions. So neither the bottle nor a source build needs Elixir or Erlang; a source build needs only Swift. The formula embeds `MacusVersion` (from `server/mix.exs`) and `MacusSourceRevision` (the commit) in the executable and stops unless the release records the same identity and the locked `opsmaru_incus`.

`candidate.json` (schema 2) records commit, development version, Macus package version, measured digests of the source and server release archives, the release's `opsmaru_incus` (version, Hex checksum and cassette SHA-256), `tama_dex`, `exqlite` and ERTS, platform, toolchain and signing mode. The library is recorded by its own version and checksum and never compared with the Macus commit. After the source build and after pouring, the installed package is checked:
- the entitlement and signature, the identity embedded in `bin/macus`, the release's `macus-build.json` (same identity, the recorded `opsmaru_incus`, read-only) and its launcher, run through `opt/macus`;
- the full payload: exactly the recorded ERTS, the locked `opsmaru_incus`, `tama_dex` and `exqlite`, only the pinned cassette at its SHA-256, and distribution off;
- `libexec/macus` against the candidate's server release archive, entry by entry. Homebrew may prune empty directories and points bundled dylib install names at `opt/macus` (it does so for exqlite's NIF), signing them again ad hoc. Such a file must keep the archived code, data, linked libraries and symbols; any other difference is refused;
- every Mach-O file in the keg links only `/usr/lib` and `/System/Library`, and the receipt records no runtime dependencies, so no host Erlang, Elixir or OpenSSL is needed;
- `opt/macus/bin/macus`, `opt/macus/libexec/macus/bin/macus` and the linked `bin/macus` resolve into the installed keg; these are the stable paths `macus start` records in its two jobs;
- installation is passive: no Homebrew service in the keg, no new `com.upmaru.macus*` or `homebrew.mxcl.macus*` LaunchAgent or launchd job, unchanged runtime and Incus client state, and no process left running from the keg.

Each install path keeps its own report (schema 3): `source-build-acceptance.json` for the source build (`built_as_bottle`, not poured) and `package-acceptance.json` for the poured bottle. Neither replaces the other. Rerun package checks with `python3 Packaging/homebrew/candidate.py verify --candidate /absolute/candidate`; it writes a separate `package-verify-<time>.json` without a passivity result. Dirty inputs, symlink outputs, reused directories, placeholder hashes and changed artifacts are refused.

## Explicit hardware acceptance

Use the installed binary and existing opt-in runner with fresh short state and a report outside the runtime/install directories:

```sh
export MACUS_BREW_TEST_ROOT="$(mktemp -d /private/tmp/macus-brew.XXXXXX)"
export MACUS_BREW_TEST_PREFIX="$(brew --prefix upmaru/macus-local/macus)"
python3 Integration/scripts/start-acceptance.py --opt-in --hardware \
  --state-dir "$MACUS_BREW_TEST_ROOT/state" --prefix "$MACUS_BREW_TEST_PREFIX" \
  --macus "$MACUS_BREW_TEST_PREFIX/bin/macus" --remote macus-brew-test \
  --report "$MACUS_BREW_TEST_ROOT/start.json"
```

The runner records its isolated `INCUS_CONF`; retain that configuration for standard Incus connectivity/workload persistence checks. Never target ordinary runtime or client state. Failures retain disks and logs. The binary embeds its verified Alpine catalog and guest payload and does not need the checkout.

## Upgrade, rollback and removal

`macus start` owns exactly two per-user jobs for a state, and every package change stops and unloads the same two. Nothing else is registered, so nothing else needs unloading.

| State | Swift runtime job | Macus server job | Plists |
| --- | --- | --- | --- |
| Default (`~/.tama/incus-mac`) | `com.upmaru.macus` | `com.upmaru.macus.server` | `~/Library/LaunchAgents/<label>.plist` |
| Any other state | `com.upmaru.macus.<hash>` | `com.upmaru.macus.server.<hash>` | `STATE/launchd/<label>.plist` |

`<hash>` is the same on both labels. `macus start --json` reports both as `service_label` and `server_label`.

### Stop and unload

1. Stop the runtime through the server while both jobs still run, and confirm it is stopped. `runtime stop` shuts the guest down cleanly; it does not unload launchd.
2. Unload the server job, then the Swift runtime job (the reverse of start). Unloading the Swift job alone would leave the server answering without a runtime; unloading the server alone would leave the VM's daemon behind.
3. Wait until `launchctl print` reports neither label.

```sh
macus --state-dir /absolute/selected/state runtime stop
macus --state-dir /absolute/selected/state runtime status
launchctl bootout "gui/$(id -u)/SERVER_LABEL"
launchctl bootout "gui/$(id -u)/RUNTIME_LABEL"
launchctl print "gui/$(id -u)/SERVER_LABEL"   # must fail: not loaded
launchctl print "gui/$(id -u)/RUNTIME_LABEL"  # must fail: not loaded
```

Replace the state and labels with the exact owned registration. Never boot out or remove a label outside this pair, and never a legacy `com.kritama.*` job as part of a package change.

### Upgrade

After stop and unload, remove only the server job's plist, change the package, then start again:

```sh
rm "$HOME/Library/LaunchAgents/com.upmaru.macus.server.plist"   # isolated: STATE/launchd/SERVER_LABEL.plist
brew upgrade upmaru/tap/macus
macus --state-dir /absolute/selected/state start
```

The server plist records the package's source revision (`MACUS_EXPECTED_REVISION`), so after a package change `start` refuses the old one as a conflict instead of replacing it. Start writes a new one for the installed revision. The Swift job's plist names the stable `opt/macus/bin/macus` and stays valid across versions; start bootstraps it again unchanged. An older plist that names a versioned keg path is a conflict: after stop and unload, remove that owned plist too. Registration replacement is never implicit.

### Rollback

Rollback is the same sequence with a retained, verified earlier bottle in place of `brew upgrade`: stop and unload both jobs, remove the server plist, install the earlier bottle (for a candidate, `candidate.py install --opt-in --candidate /absolute/earlier/candidate` after uninstalling the current one), then `macus start`. Rollback changes only the package. It never replaces or downgrades guest disks, server credentials or the Incus client configuration.

### Removal

After stop and unload, remove both owned plists, then the package:

```sh
rm "$HOME/Library/LaunchAgents/com.upmaru.macus.server.plist" "$HOME/Library/LaunchAgents/com.upmaru.macus.plist"
brew uninstall upmaru/tap/macus
```

A default plist left in LaunchAgents would try to start a missing executable at the next login. Uninstalling removes only the keg.

### What every transition keeps

Upgrade, rollback and removal keep the selected state, which lives outside the keg:

- runtime disks and settings: `STATE/runtime/root.raw`, `data.raw`, `efi.bin` and `STATE/config.json`, with every guest workload;
- server credentials and trust: `STATE/server/gateway.crt` and `gateway.key` (clients keep their pinned certificate), `gateway.json`, `bearer-tokens.json`, `local-cli.token`, `trusted-certificates.json` and the enrollment token records;
- the standard Incus client configuration and its `macus` remote.

A reinstall followed by `macus start` serves the same gateway identity and the same credentials. To discard them, remove those files deliberately; no package command does it.

## Shared export and CI

The PR/manually dispatched candidate workflow installs the pinned Elixir/Erlang, downloads the locked opsmaru_incus cassette and checks its `.sha256` and attestation (until task 9.7 moves that into the release build), serializes package jobs, builds and pours a local bottle, retains artifacts (including the separate source-build and poured-bottle reports) and cleans up only its candidate-owned package and tap. Cleanup verifies the installed receipt/version and tap origin. Local failed partial installs remain for inspection; explicit package cleanup uses `candidate.py cleanup --opt-in --candidate /absolute/candidate`. Neither mode deletes runtime or Incus data. It does not publish releases, modify the shared tap or boot a VM. With publication authorization, upload the exact source, server release and single-hyphen URL bottle filenames recorded in `candidate.json` as immutable development assets. Do not replace existing candidate assets.

After those HTTPS assets exist, prepare a tap feature PR using:

```sh
python3 Packaging/homebrew/candidate.py export --candidate /absolute/candidate \
  --source-url https://github.com/upmaru/macus/releases/download/CANDIDATE_VERSION/SOURCE_ARCHIVE \
  --release-url https://github.com/upmaru/macus/releases/download/CANDIDATE_VERSION/SERVER_RELEASE_ARCHIVE \
  --bottle-root https://github.com/upmaru/macus/releases/download/CANDIDATE_VERSION \
  --destination /absolute/homebrew-tap/Formula/macus.rb
```

Replace uppercase examples with actual generated names. Export checks remote bytes against measured hashes, requires version-specific HTTPS URLs and refuses an existing destination. Macus code PRs target `develop`; tap formula PRs target `main`. Development acceptance is not a stable production release or authorization to finish Git Flow branches.

For repeatable hardware phases, run `Integration/scripts/homebrew-acceptance.py --opt-in --hardware --candidate /absolute/candidate --root /private/tmp/SHORT_FRESH_ROOT --phase start`. It creates isolated state/client configuration and checks first/repeated startup plus a standard Incus workload marker. Run `--phase stop` before changing the package: it stops the runtime, unloads the server job and then the runtime job, waits until neither is loaded, removes only the owned server plist (and with `--transition removal` the runtime plist too) and records what must be retained: disk identities, keyed digests of the server credentials and the Incus client configuration, and the gateway certificate fingerprint. The report holds no secret or unkeyed digest of one. Then run `--phase resume` with a different poured candidate. Resume rejects the same version or a missing stop/unload record, and after start requires the retained data unchanged and a server plist re-registered for the new revision. After a removal stop and `brew uninstall`, `--phase removed` verifies that neither job is loaded, no owned plist remains and the retained data is unchanged. `retry-start` explicitly retries a retained owned failed fixture without resetting it. The report stays under the test root.
