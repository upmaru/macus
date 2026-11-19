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

`candidate.json` (schema 2) records commit, development version, Macus package version, measured digests of the source and server release archives, the release's `opsmaru_incus` (version, Hex checksum and cassette SHA-256), `tama_dex`, `exqlite` and ERTS, platform, toolchain and signing mode. The library is recorded by its own version and checksum and never compared with the Macus commit. After the source build and after pouring, the installed pair is checked: the entitlement and signature, the identity embedded in `bin/macus`, the release's `macus-build.json` (same identity, the recorded `opsmaru_incus`) and its launcher. `package-acceptance.json` records the installed keg and poured receipt. Rerun package checks with `python3 Packaging/homebrew/candidate.py verify --candidate /absolute/candidate`. Dirty inputs, symlink outputs, reused directories, placeholder hashes and changed artifacts are refused.

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

## Upgrade and removal

Stop the runtime, confirm it is stopped, then unload its owned service before package changes. `runtime stop` does not unload launchd. Get the label/plist from startup and the selected state: default `com.upmaru.macus`, isolated `com.upmaru.macus.<state-hash>`.

```sh
macus --state-dir /absolute/selected/state runtime stop
macus --state-dir /absolute/selected/state runtime status
launchctl bootout "gui/$(id -u)/OWNED_SERVICE_LABEL"
brew upgrade upmaru/tap/macus
macus --state-dir /absolute/selected/state start
```

Replace the example state and label with the exact owned registration. New Homebrew registrations use validated `opt/macus/bin/macus`; after stop/unload the opt link can advance without leaving a removed keg path. An old versioned-keg plist remains a conflict: explicitly remove only its owned plist after stop/unload, then start again. Registration replacement is never implicit.

Before uninstall, use the same stop/status/bootout sequence, remove only the owned plist, then `brew uninstall upmaru/tap/macus` (or the local test formula). Retain runtime disks and Incus configuration. Rollback reinstalls a retained verified prior bottle after stop/unload; it does not replace or downgrade guest disks.

## Shared export and CI

The PR/manually dispatched candidate workflow installs the pinned Elixir/Erlang, downloads the locked opsmaru_incus cassette and checks its `.sha256` and attestation (until task 9.7 moves that into the release build), serializes package jobs, builds and pours a local bottle, retains artifacts and cleans up only its candidate-owned package and tap. Cleanup verifies the installed receipt/version and tap origin. Local failed partial installs remain for inspection; explicit package cleanup uses `candidate.py cleanup --opt-in --candidate /absolute/candidate`. Neither mode deletes runtime or Incus data. It does not publish releases, modify the shared tap or boot a VM. With publication authorization, upload the exact source, server release and single-hyphen URL bottle filenames recorded in `candidate.json` as immutable development assets. Do not replace existing candidate assets.

After those HTTPS assets exist, prepare a tap feature PR using:

```sh
python3 Packaging/homebrew/candidate.py export --candidate /absolute/candidate \
  --source-url https://github.com/upmaru/macus/releases/download/CANDIDATE_VERSION/SOURCE_ARCHIVE \
  --release-url https://github.com/upmaru/macus/releases/download/CANDIDATE_VERSION/SERVER_RELEASE_ARCHIVE \
  --bottle-root https://github.com/upmaru/macus/releases/download/CANDIDATE_VERSION \
  --destination /absolute/homebrew-tap/Formula/macus.rb
```

Replace uppercase examples with actual generated names. Export checks remote bytes against measured hashes, requires version-specific HTTPS URLs and refuses an existing destination. Macus code PRs target `develop`; tap formula PRs target `main`. Development acceptance is not a stable production release or authorization to finish Git Flow branches.

For repeatable hardware phases, run `Integration/scripts/homebrew-acceptance.py --opt-in --hardware --candidate /absolute/candidate --root /private/tmp/SHORT_FRESH_ROOT --phase start`. It creates isolated state/client configuration and checks first/repeated startup plus a standard Incus workload marker. Run `--phase stop` before changing the package, then `--phase resume` with a different poured candidate. Resume rejects the same version or a missing stop/unload record. After stop/unload/uninstall, `--phase removed` verifies retained data. `retry-start` explicitly retries a retained owned failed fixture without resetting it. The report stays under the test root.
