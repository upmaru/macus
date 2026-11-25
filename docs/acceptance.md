# Acceptance evidence

Host validation: 2026-10-03 UTC (2026-10-04 Asia/Bangkok). Apple M4 Max, 64 GiB, macOS 27.0.1 and Apple Swift 6.4; minimum deployment target remains macOS 15.

## Native checks and CI

Debug/release builds with warnings-as-errors, 26 Swift Testing tests plus four guest-helper tests, strict Swift formatting, guest shell/Python syntax and strict OpenSpec validation passed locally. Tests cover lifecycle concurrency/cancellation, failure retention, configuration/path/manifest safety, HTTP framing and binary duplex/half-close behavior.

GitHub Actions runs these checks on the macOS ARM64 `xcode-27` runner with pinned checkout/setup-node actions and OpenSpec 1.14.0. [The Alpine implementation workflow run passed](https://github.com/kritama/tama-incus-mac/actions/runs/37146208220). CI does not boot VZ or establish hardware acceptance; final PR-head checks are recorded on GitHub.

## Prebuilt LTS appliance

The [qualification record](zfs-qualification.md#prebuilt-draft-qualification-2026-11-10)
covers local hardware acceptance for the published LTS image and the open Stable
checks. [Published LTS adoption](zfs-qualification.md#published-lts-adoption-2026-11-10)
covers a separate download and first boot through the shipped catalog.

## Original Alpine appliance

The signed native Swift process boots the verified Alpine ARM64 raw image through Apple VZ EFI, provisions signed stable-branch APK packages, starts OpenRC services and exposes Incus through Unix-to-vsock sockets. No SSH or Mac VM CLI is used. The host reports nested virtualization support, and the Linux guest exposes usable KVM.

[Image provenance](testing/alpine-image.json) records the official Alpine 3.24.2 cloud-init metal r0 archive, SHA-512, pinned cloud signing fingerprint and raw SHA-256. Both checksum corruption and a checksum-matching archive with an invalid signature were rejected before extraction. [Resolved package versions](testing/alpine-package-versions.txt) record the acceptance appliance's signed v3.24 main/community packages: Incus LTS 7.0.1-r1, LXC 7.0.0-r0, QEMU 11.0.3-r0 and Linux 6.18.52-lts. No edge repository or unsigned-package exception is used.

Hardware testing corrected several Alpine-specific provisioning gaps: wait for IPv4 DHCP across reboots, start D-Bus and nftables, force an offline ext4 check before resize, load TUN/vsock modules on every boot and install QEMU's split audio/GPU/device modules. Incus startup readiness now waits for its internal startup tasks, beyond a successful `/1.0` response. The selected ARM64 AAVMF firmware lacks the Secure Boot pair; the nested test explicitly sets `security.secureboot=false`, consistent with the v1 boundary.

## Hardware results

Isolated Alpine appliances have passed real standard Incus system-container and OCI boot/exec, outbound networking, outer restart persistence and stopped-state data growth from 8 to 9 GiB. The guest directory-pool capacity grew from 8,350,298,112 to 9,407,197,184 bytes while the container's marker remained intact.

The final freshly provisioned appliance (`alpine-3.24.2-incus-a14`) passed the entire acceptance runner, including read-only write rejection, writable share propagation, cached OCI reuse after both restarts and growth, and nested Debian 13 ARM64 guest-agent `uname -m`. [The hardware report](testing/alpine-hardware-acceptance.json) records command results, capabilities, selected server environment and all 17 successful checks. Successful test workloads/remotes were removed by the runner.

Earlier runs exposed missing OCI cached files after restart while the image metadata remained present. Both `alpine:latest` and `alpine:3.23` reproduced it on fresh fixtures; a later diagnostic image survived reuse. The selected Incus 7.0.1 source contains a background-download cancellation path that can remove cache files; this is a suspected cause of the observed loss. New appliances set `images.auto_update_interval=0` and keep image updates explicit. Cached reuse passed in the complete final fixture under that default. Automatic background image updates remain unverified. A transient native EFI configuration failure also motivated releasing stopped VZ attachments before reopening them; the final immediate restart and growth/start cycle both passed. Failed fixtures and their Incus data are retained in ignored `.integration/`.

## Review and scope

CodeRabbit completed five reviews during this Alpine acceptance work. Its minor DHCP configuration idempotency finding was corrected; four subsequent reviews completed with zero findings. The last review covered the final VZ cleanup and explicit-image-update changes. Earlier native implementation findings were also addressed. Checks affected by the final Swift change were rerun successfully.

All 23 implementation/acceptance tasks in the archived OpenSpec checklist are complete. PR publication, head CI and review-thread resolution are tracked on GitHub. This records the supported initial implementation and acceptance fixture. Production signed/notarized distribution, a published appliance, Homebrew formula, automatic image/root upgrades, forwarding and custom DNS remain outside this initial implementation. No image, runtime disk, downloaded executable or client credential is committed.

The standard native Incus CLI used for acceptance is 7.5.1 from the verified official Homebrew ARM64 bottle, SHA-256 `864f707022778302ef3be6f11746f7aea15e659613c768ed63ab56f349eff2da`.

## PR review verification — 2026-10-04 UTC

The review fixes revalidate cached readiness inside start, replace blocking host relay pumps with bounded nonblocking Dispatch sources, supervise both guest listeners as one process and persist confirmed reset intent across daemon restart. The complete JSON configuration contract is explicit: initializer/template defaults do not imply omitted required fields. Regression tests verify incomplete JSON returns 400, custom values survive decoding, dead/unhealthy guests are not returned as ready, reset interruptions before/after configuration removal recover, invalid intent preserves data, and fatal listener failure exits even with a blocked worker.

The updated signed native process and newly provisioned Alpine appliance `alpine-3.24.2-incus-review-v1` passed [all 17 hardware checks](testing/pr-review-hardware-acceptance.json). The [idle-stream regression](testing/pr-review-relay-stress.json) held 80 real Incus connections open; all 60 control/health/Incus probes succeeded, with a maximum response time under 7 ms on this fixture. Swift regressions also verify 2 MB bidirectional transfers with forced backpressure, half-close and cancellation. These timings describe this local fixture, not a production performance guarantee.

CodeRabbit CLI completed an uncommitted review of the 16 implementation/planning/test files with zero findings. The standalone hardware stress runner was added afterward and separately passed syntax and real-hardware validation. The GitHub PR review remains the record for the published commit. The docstring coverage warning in the original PR review analyzed zero supported files (29 were unsupported); it does not establish Swift documentation coverage. API and recovery contracts are maintained in the project documentation.

## tim client acceptance — 2026-10-04 UTC

This gate is separate from the 17-check runtime acceptance above. Unit success does not establish it.

Canonical `Integration/scripts/check.sh` passed for both executables: warnings-as-errors debug and release builds, 41 Swift tests, strict formatting, guest shell/Python syntax, four guest-helper tests, and an isolated-prefix install. The install placed signed `tama-incus-mac` and `tim` in one prefix, applied the virtualization entitlement only to the daemon, and did not create runtime state or a launch agent. `mise run spec:validate` passed all 6 OpenSpec items.

CodeRabbit CLI 0.8.2 completed an authenticated review of the branch plus untracked client, test, packaging, and OpenSpec files (`review_completed`, 3 minor findings). Two findings were pre-existing and outside this slice: historical absolute paths in the prior runtime report, and guest preseed-marker behavior. They were not rewritten here. The restart-timeout finding conflicts with the validated 650-second lifecycle default; the CLI documents that restart includes shutdown plus boot and that a longer `--timeout` is required when those configured deadlines exceed 650 seconds. No finding required a product-code change.

The actual installed `tim` binary was then run against the existing stopped isolated appliance `<workspace>/.integration/a15`, using the appliance files in `<workspace>/.integration/alpine-a15`. It was not pointed at `~/.tama/incus-mac` or `~/.local`. The standard Incus 7.5.1 CLI created fixtures only. Installed tim proved status/start/doctor, JSON list, running virtual-machine filtering, show metadata plus live state, a `not_found` JSON error, restart, stop, and stopped doctor/list failures that did not boot the guest. Data and root disk sizes stayed 9,663,676,416 and 12,884,901,888 bytes. The guest and daemon were stopped afterward. [The redacted report](testing/tim-client-hardware-acceptance.json) records the checks. Earlier fixture-script mistakes left owned instances in that stopped appliance; they were retained rather than cleaned by another boot. That list/show scope is superseded. The lifecycle results remain historical only.

## tim client setup — 2026-10-04 UTC

`tim list` and `tim show` are not part of this client. Setup acceptance is separate from both the 17-check runtime gate and the historical lifecycle run above.

Swift tests drove fixture `brew` and `incus` processes for installation, prefix discovery, install failure, timeout reaping, remote conflict, idempotent registration, optional default switching and unrelated-remote preservation. No host `brew install` ran. `Integration/scripts/check.sh` and strict OpenSpec validation passed after the revision.

CodeRabbit CLI 0.8.2 completed an authenticated review of the revised uncommitted slice (`review_completed`, 1 minor finding). The finding was that the acceptance script recorded an unchanged default without failing the run; the script now requires `incus remote get-default` to succeed and to differ from the new remote. The observed run had already kept the default at `local`.

A newly installed `tim` in `<workspace>/.integration/tim-setup-prefix`, not the in-use prefix, registered `tama-mac` against the ready `<workspace>/.integration/a15` socket using the cached Incus 7.5.1 CLI and a fresh `INCUS_CONF`. `incus list tama-mac:` exited 0. Setup was idempotent and did not change the default remote. The appliance was not stopped, restarted or reconfigured. [The redacted setup report](testing/tim-client-setup-acceptance.json) records that this was not a lifecycle gate and not an actual Homebrew install.

Before PR publication, direct review corrected subprocess cancellation cleanup, removed EOF waits on pipes inherited by descendants, and made an unreadable default remote fail before registration. Regression tests exercise cancellation/reaping, inherited writers, simultaneous stdout/stderr, output overflow and failed default discovery. Canonical checks passed with 50 Swift tests and 4 guest Python tests, release builds, strict formatting and isolated installation; strict OpenSpec validation passed all 6 items. Installed setup acceptance passed again from a new `<workspace>/.integration/tim-pr-prefix` using a fresh client configuration and the same ready appliance, without lifecycle or host package changes. A full CodeRabbit review found one minor issue in the installer test's fixed temporary output path; it now uses the test's isolated directory and cleanup trap.

A second full CodeRabbit review completed with one minor finding: the Homebrew timeout test's log-based assertion did not establish that its child exited. The fixture now records its PID, and the test confirms that PID no longer exists when the timed-out command returns. That strengthened test and strict formatting passed.

The final committed implementation review completed with zero findings. The first PR CI run exposed short fixture deadlines while synchronous subprocess waits occupied Swift's cooperative executor. Executable fixtures now await the bounded subprocess runner, and successful-response tests allow cold process startup without changing the deliberate one-second timeout tests. Canonical checks passed again with all 50 Swift tests; hardware acceptance and production timeout behavior are unchanged by this fixture correction.

The focused review of that fixture correction completed with zero findings. The Homebrew timeout fixture records its PID in a shell before executing a sleeping install, avoiding Python startup as part of the measured failure. Its test verifies the actual `brew install incus` arguments and that the child PID is gone on return.

## PR #2 review follow-up — 2026-10-05

The installer now refuses symlinked bin directories, symlinked executable destinations (including dangling links), and non-file executable destinations before copying either tool. Isolated regressions verify that outside targets and existing sibling binaries retain their contents. The setup acceptance runner records the default before setup and requires the post-setup default to match it exactly; fixture checks prove that switching to an unrelated remote fails acceptance and an unreadable initial default prevents setup. The canonical SwiftPM delivery requirement now names both executables.

Canonical checks passed with 50 Swift tests and 7 Python tests (4 guest bridge checks and 3 acceptance-runner regressions), strict formatting, release builds and isolated installation. All 6 strict OpenSpec items passed. Read-only real-client acceptance against the already-ready isolated appliance also passed: the default was `local` both before and after setup, registration and connectivity succeeded, and repeated setup was idempotent. The appliance and existing installation were untouched; no host Homebrew installation or new lifecycle gate ran.

CodeRabbit CLI completed an uncommitted review of all five implementation/spec/test changes with zero findings. This follow-up addresses the three current GitHub review comments; the added documentation records the independently checked evidence.

## Macus rename — 2026-10-06

`macus` now combines foreground serving, host capabilities and the former tim client commands in one executable; the Swift library is `Macus`. Earlier dual-executable descriptions and reports above record historical runs and are superseded for current installation instructions. Existing default state paths and persistent reset/guest identifiers remain compatible.

Canonical `Integration/scripts/check.sh` passed: warnings-as-errors debug/release builds, 51 Swift tests, strict formatting, guest shell/Python syntax, 46 Python tests and an isolated signed single-binary install. Strict OpenSpec validation passed all 8 items. A separately signed debug `macus serve` was run against a disposable `/private/tmp` state directory: the control socket returned API version 1 and absent state, selected `MACUS_STATE_DIR` over legacy `TIM_STATE_DIR`, created no guest disks and terminated gracefully. No VM was booted and no hardware acceptance of the renamed binary is claimed.

Local diff review verified that runtime/configuration fields and the persisted reset marker remain compatible, and current command/module/installer names agree. CodeRabbit authentication succeeded, but automatic approval review rejected uploading the source diff without explicit user authorization; no remote review result is claimed.

## Rename review and CI fixes — 2026-10-07

Greptile CLI reviewed PR #4 at `84049ac` with 4/5 confidence and one P2 finding: host capability output bypassed the public CLI runner's custom streams. Daemon output now uses the supplied `MacusStreams`, including capabilities and help, and the CLI forwards those streams. A capture regression failed before the fix and passes afterward.

The first rename CI run failed in `chunkedFramingSurvivesByteSizedReads` with `Local socket connection failed`. Its raw HTTP fixture responded and closed without first reading the POST request, racing the client's write. The HTTP transport fixtures now consume complete requests before responding and retain descriptor ownership through the handler. The chunked test verifies received method, path and body for both 2-byte and 256 KiB requests; the larger case reproduced the failure before the fix. Production transport behavior and deadlines were preserved.

Canonical checks passed with 52 Swift tests (including both chunked request sizes), 46 Python tests, debug/release builds, strict formatting and an isolated signed install. Both regressions passed 20 consecutive repeated runs. Strict OpenSpec validation passed all 8 items, and diff whitespace checks passed. No guest was booted; hardware acceptance remains separate.

The next hosted CI run passed both chunked request sizes but exposed concurrent subprocess-startup timeouts and a deadline fixture reporting a client's early disconnect. Canonical Swift checks now explicitly use `--no-parallel`; all internal concurrency, cancellation and deadline assertions remain in place. Only the two deadline HTTP fixtures tolerate incomplete requests on disconnect; other fixture read errors still fail validation. The final canonical run again passed 52 Swift tests, 46 Python tests, builds, formatting, isolated signed installation and all 8 OpenSpec items. Hosted Greptile reviewed `163f993` with 5/5 confidence and no actionable findings; that review precedes this scheduling follow-up.

Native CI passed at `4feb7e8`. Hosted Greptile also passed with 5/5 confidence but left a P2 observation that the disconnect opt-out could let deadline tests pass without executing their response handlers. The follow-up removes that opt-out: all HTTP fixture read errors are reported, and both delayed/trickled tests explicitly assert a thread-safe handler-start observation. The original deadline bounds remain intact. Canonical validation of this stricter follow-up passed all 52 Swift tests, 46 Python tests, builds, formatting, isolated signed installation and strict OpenSpec validation.

## Start experience — 2026-10-07

This is a separate hardware gate from the earlier Alpine and client reports. Unit success does not establish it.

An installed `macus` at `/private/tmp/ms7e/install/bin/macus` was started from `/private/tmp`, with state `/private/tmp/ms7e/st`, client config `/private/tmp/ms7e/client`, and remote `macus-acc`. The checkout was not on `PATH`. `~/.tama/incus-mac`, the default Incus remote, and any persistent `com.upmaru.macus` agent were not used. The session agent was `com.upmaru.macus.42ae29138d65`; its parent was launchd after `macus start` returned.

The successful run verified a cache copied from an earlier isolated download of the 626,889,284-byte archive. It did not download again. Progress showed the expected kernel reboot, the reboot allowance was consumed, and live health reported Incus 7.0.1 with KVM. Official Homebrew installed Incus 7.5.1 during that start; it had been absent. Repeat start finished in about one second, skipped acquisition, and reused the client.

A Debian 13 container resolved `deb.debian.org` and kept a `macus-ok` marker across a successful runtime restart and across bootout/bootstrap of the isolated agent. The first runtime restart after the initial boot failed with an invalid boot loader; disks were kept and a following start recovered. The first bootstrap immediately after bootout returned an I/O error; the retry succeeded. Live capabilities reported `vm` and nested virtualization, and Incus reported `lxc | qemu`. No nested guest was booted in this run.

The smoke container was deleted, the owned runtime was stopped, and the session agents were unloaded. Failure directories under `/private/tmp/ms7acc`, `ms7b`, `ms7c`, and `ms7d` were retained. [The report](testing/start-experience-acceptance.json) records the versions and results. That run is not completion of the unavailable-checkout or restart gates: the checkout remained on disk, acquisition reused a copied cache, the first runtime restart failed with an invalid boot loader, and a manual bootstrap returned I/O error 5 after the binary was replaced under a live job.

## Start experience follow-up — 2026-10-07

A later installed binary was built from an owned `/private/tmp/ms7src` copy. That copy was removed before `macus start`. The shared checkout was not renamed or deleted. From `/private/tmp`, with isolated state and `INCUS_CONF`, start downloaded and verified the 626,889,284-byte archive, observed the expected reboot, and connected to the already installed Incus client. It did not install Homebrew again and did not boot a nested guest. Live capabilities reported VM and nested virtualization support.

Two immediate `macus runtime restart` commands returned ready. The workload marker survived, and the EFI store and data disk inodes were unchanged. An owned PTY session listed the remote and was closed; the launchd daemon and guest stayed ready. Booting out only the session agent and then running `macus start` after that job left the domain restored the marker. An overlapping start while the previous daemon was still stopping conflicted and preserved disks. [The follow-up report](testing/start-experience-follow-up.json) records this separately from the earlier failures.

## Homebrew candidate packaging

The local candidate at source revision `7e071e383d630ffe0a72c019dc8a28af02446dde`, version `0.0.0-dev.20261008123735.7e071e383d63`, passed Homebrew source compilation, formula style/audit/test, bottle generation and a subsequent poured-bottle install on ARM64 macOS 27.0.1. Its installed signature and virtualization entitlement verified, help/capabilities ran outside the checkout, and the install left ordinary runtime/client/service state unchanged. [Package evidence](testing/homebrew-package-acceptance.json) records the measured bottle digest and receipt. This verifies only the `arm64_golden_gate` bottle; macOS 15/26 bottle coverage and remote tap installation are not claimed. Development signing is ad hoc, without notarization.

The separately opted-in installed-bottle hardware run booted a fresh isolated Alpine appliance and consumed its single expected kernel restart, but live Incus readiness did not arrive after the second boot; the retained serial log showed `tama-bootstrap` stopped. The test VM was force-stopped and its owned launchd job unloaded. Its disks/logs were preserved. [Hardware evidence](testing/homebrew-hardware-acceptance.json) explicitly records unsuccessful acceptance. First/repeated ready startup, package-upgrade marker persistence and uninstall retention remain unverified; passing package checks does not complete them. Guest bootstrap repair and artifact publication are pending user scope/authorization decisions.

Readable CLI presentation acceptance is recorded in
[testing/readable-cli-output-acceptance.json](testing/readable-cli-output-acceptance.json).
These 21 transcripts come from the signed release executable with isolated Unix
socket and Incus-client fixtures, under a pseudo-terminal and redirected streams.
They cover help, host capabilities (both JSON placements), runtime status, doctor,
startup reuse, JSON, error, timeout, SIGINT exit 130 and foreground serve notices.
The checks preserve fixture disks/configuration, assert read-only requests for
inspection, and never boot a VM. They are presentation evidence, separate from
guest/hardware qualification. The canonical isolated-prefix install check reruns
`Integration/scripts/presentation-acceptance.py --binary <signed-macus>`.
On a CI host that reports Apple virtualization unavailable, the signed runner
verifies startup's unsupported-host rejection and records that mode explicitly;
it does not bypass production preflight or claim the startup success/timeout
matrix ran there. Supported-host runs exercise that full matrix. Runtime-wait
failure, timeout and interruption cases must observe an actual fixture start
request; preflight failures cannot satisfy their assertions.

Native Noora startup steps are verified separately in
[testing/native-noora-step-acceptance.json](testing/native-noora-step-acceptance.json).
These 23 signed executable transcripts include rendered screens for successful
reuse, operational failure, timeout and SIGINT. Success runs cover ordinary
newline translation plus disabled `ONLCR`, with and without color. Screen checks
verify intact native step prefixes/timings, explicit skipped-resource labels, a
single success heading, no stale spinner and a visible cursor. The run used only
isolated socket/client fixtures and preserved their disk/configuration sentinels;
no VM was booted. Strict builds, 132 Swift tests and 71 Python tests passed.

The startup screen checker requires all nine resolved rows exactly once, including
the five skipped-resource labels and each native elapsed-time suffix. Negative
regressions remove, duplicate, clip, mislabel or remove timing from every skipped
row, ensuring a `9/9` footer alone cannot satisfy presentation acceptance.

## Flow-controlled relay — 2026-11-08 UTC

The flow-controlled Incus relay passed [opt-in hardware acceptance](testing/flow-relay-acceptance.json) on an isolated appliance booted by a release build of Macus `1085025` on a Mac16,5 with macOS 27.0.1. The guest reported `flow_relay_version` 1.

- **Idle streams:** 80 open Incus streams; all 60 control, health and Incus probes succeeded, with a maximum of 13 ms.
- **Stalled reader:** 400 pipelined `/1.0` responses were left unread for 10 seconds. All 144 probes on new and existing Incus connections, runtime status and guest health answered, with a maximum of 62 ms, and the stream then drained all 400 responses.
- **Bidirectional relay:** a 1.04 GiB image export was streamed directly into an image import on a second connection in 5.35 s, about 194 MiB/s with both directions crossing the vsock device at once. The import succeeded with the same fingerprint, and 24 concurrent new-connection probes answered within 6 ms.

**Deviation:** Alpine v3.24 no longer serves the committed `linux-lts`/`zfs-lts` 6.18.60-r0 pair, so this run used an uncommitted payload pinned to 6.18.62-r0. The relay does not depend on the kernel version, but that kernel/ZFS pair is unqualified and this run is not ZFS evidence. A relay-mode `incus copy` between two remote names for the same socket completed server-side and is not counted.

**Follow-up:** after this run, review found a guest close race. The guest sent END before recording it, so a host that had already ended could close in between and make the guest abort with host bytes still queued for Incus. The guest now records END before sending it. Payload revision `11acf521…` contains the fix, which is covered by a deterministic bridge unit test. The hardware run above used the earlier payload and has not been repeated with this revision.

On 2026-11-09, the same appliance also served the opsmaru-incus real-Incus gateway gate. That run passed all twelve relay/pull/push copies and all six instance moves through the vsock relay. It is opsmaru-incus evidence, not Macus hardware qualification.

## Two-component Homebrew candidate — 2026-11-20

The Homebrew candidate payload changed: it now carries the Swift `macus` executable and the paired bundled-ERTS Macus server release at `libexec/macus` (add-elixir-server tasks 9.2–9.5, 9.7), built from one commit and verified as a pair. The Swift-only candidate evidence above remains historical.

The candidate workflow in `.github/workflows/homebrew-candidate.yml` prepares the candidate from the PR head, assembles the release with the mise-pinned Elixir/OTP, downloads the locked opsmaru_incus cassette and verifies its `.sha256` sidecar and attestation, builds and pours the bottle on the `xcode-27` runner, and retains per run: `candidate.json`, the bottle JSON, the release log, and the separate `source-build-acceptance.json` (built as a bottle, not poured) and `package-acceptance.json` (poured) reports. Offline, the real bottle from the candidate run on `68766e3` was compared entry by entry with the archived release: 2355 of its 2356 entries were identical, and the remaining one, exqlite's `sqlite3_nif.so`, install name pointed at its `opt` path by Homebrew and was re-signed ad hoc — accepted because the Mach-O's code, data and link-edit content are otherwise unchanged. No Mach-O in the bottle links outside the system, and the receipt records no runtime dependencies, so the installed package needs no host Swift, Elixir, Erlang or OpenSSL.

This is candidate evidence only: the run verifies a local-tap install on the CI runner. Nothing was pushed to the shared tap, no formula is distributed outside the candidate, no VM was booted, and installed-package hardware acceptance remains opt-in and unexecuted for the two-component package. The earlier installed-bottle hardware failure above (`7e071e38`) predates the paired release and does not count for it. The origin and verification of each packaged artifact is traced in [the candidate documentation](../Packaging/homebrew/README.md#artifact-provenance).

## Incus boot crash recovery — 2026-11-22 UTC

The `recover-incus-boot-crash` change passed [opt-in hardware acceptance](testing/incus-crash-recovery-acceptance.json) on a fresh isolated appliance (`/tmp/macus-icr1`, LTS image, ZFS) started by a release build of Macus. Crashes were injected by a test-only `start_post()` in the guest `/etc/conf.d/incusd` that sent SIGABRT to incusd 1 s after each launch, for a set number of launches.

- **Fresh start:** ready in 126 s. Both incusd log files exist, and the guard ran from bootstrap and `tama-bridge` without restarts.
- **One crash:** the guard restarted incusd once, the serial log held the evidence block and `TAMA_INCUSD_RECOVERED restarts=1`, and `macus start` was ready in 41 s with no user action.
- **Persistent crash (6 launches):** two boots of three launches each, six evidence blocks with the `SIGABRT: abort` header, one automatic host restart, then `macus start` failed with `incus_crashed` after 109 s instead of waiting 1800 s. `macus runtime stop --force` and `macus start` then reached ready in 37 s with the workload container intact.
- **Crash recovered by the host restart (3 launches):** ready in 94 s, twice.

Two fixes came out of the run and were verified on the same appliance: the evidence now copies the start of the last Go crash dump, which a plain tail cut off, and a guard that gives up zaps the dead incusd so OpenRC's shutdown no longer fails at incusd. Even then, the export failed. A diagnostic shutdown hook showed incusd's tmpfs mounts (`devices`, `shmounts`, `guestapi`) and an orphaned `dnsmasq` holding its lease file under `/var/lib/incus`. Storage stop now releases those when incusd's daemon is gone and retries. On the next 3-crash run, the recovery shutdown terminated `dnsmasq`, unmounted the three tmpfs mounts and exported the pool (`TAMA_ZFS_EXPORT_OK`, no OpenRC stop errors), and start was ready in 93 s. A plain graceful stop still exported on the first attempt with nothing released. **Deviation:** later guard revisions were copied into the provisioned guest by sha256 rather than provisioned on a second fresh state. The hook, its counter and the helper container were removed, `conf.d` was restored, a clean boot was ready in 37 s, and the isolated agent was unloaded.

## Installed two-component package — 2026-11-23

Task 4.2 of `add-homebrew-tap` passed [opt-in hardware acceptance](testing/homebrew-two-component-hardware-acceptance.json) from the Homebrew-installed two-component package on ARM64 macOS 27.0.1.

**Candidate.** The candidate was built from `develop` at `ac86fe90f4fd54cadedd569d3ade170b2152ddee`:

- version `0.0.0-dev.20261123073709.ac86fe90f4fd`, Macus 0.1.0;
- opsmaru_incus 0.2.9, with cassette `e95571af…`;
- ERTS 15.2.7.12.

`candidate.py` built it through Homebrew from source, uninstalled that test keg, and then poured the `arm64_golden_gate` bottle `00f64875…` from the local tap. The package report recorded `poured-bottle`, a verified signature and virtualization entitlement, system-only linkage, no runtime dependencies, no Homebrew service, and a passive install.

**Run.** `start-acceptance.py --opt-in --hardware` ran from outside the checkout against the installed `opt/macus` pair. It used a fresh short isolated state, its own `INCUS_CONF`, remote `macus-brew-42`, and hashed labels for both jobs.

**First use.** The runner downloaded the 785 MiB appliance in 60 s, and Incus was ready at 66 s. The serial log showed `stage=image state=verified`, then storage, Incus and ready. The prebuilt LTS image booted `6.18.62-0-lts` directly, so its reboot allowance stayed available. The guest ran Incus 7.0.1 on Alpine 3.24.4 with ZFS, `lxc` and `qemu`.

**Repeated start.** The second start was ready again with the same runtime and server PIDs.

**Client and isolation.**

- The standard Incus 7.5.1 client was trusted over native HTTPS. `incus list` exited 0, and the default remote was unchanged.
- The runtime job ran `opt/macus/bin/macus serve`, and the server job ran `opt/macus/libexec/macus/bin/macus start` from the keg's bundled ERTS. No process came from the checkout.
- The server opened one loopback listener.
- Public runtime control returned 200 for status and start-when-ready, and 403 for a stop with a read-only token.
- The default jobs and endpoint did not change during the run.

All 14 checks passed. The isolated runtime was then stopped, both of its jobs were unloaded, and its state was retained.

**Upgrade from an earlier package (not 4.3 evidence).** The machine's default state had been created on 2026-11-04 by the Swift-only candidate `64a2ec08`. After the run, that state was started on this package. Two things failed:

- `start` refused the earlier direct-socket `macus` remote as a conflict. With the user's approval, that remote was removed.
- `start` then booted the existing VM and stopped with `unavailable`, because its guest bridge predates the flow-controlled relay. The disks were kept.

With the user's approval, the old state was moved aside intact and a fresh default state was started on the package. The [pre-relay observation](#pre-relay-state-on-a-later-package--2026-11-23-utc) below records that state in detail; `macus runtime upgrade` from the add-runtime-upgrade change now handles such a guest, and [the candidate documentation](../Packaging/homebrew/README.md#upgrade) describes the remote step.

Task 4.3 is still open: upgrading between two server-era revisions with marker persistence, then removal.

## Pre-relay state on a later package — 2026-11-23 UTC

This is an observation, not acceptance. It motivated the [add-runtime-upgrade change](../openspec/changes/add-runtime-upgrade/proposal.md).

The default state (`~/.tama/incus-mac`) was created on 2026-11-04 by an earlier package, with ZFS storage. On 2026-11-23 it was started with `macus start` on the current package. Start activated both launchd jobs and booted the VM. After about 33 s at the Provisioning Linux stage it failed with `unavailable`: the guest bridge predates the flow-controlled Incus relay. The message offered only recreating the appliance. Start left both services registered and deleted no runtime data. The workloads stayed on disks that only the earlier package could serve.

What the state shows:

- The guest bridge answers health but not the flow relay, so the current host cannot reach that guest's Incus API. Its inventory cannot be read before an upgrade.
- The guest reports no storage identity, guest contract, payload revision or Incus package in health. At the time the state had no `guest-record.json` or `storage-identity.json`, so its Incus package is unknown, and any upgrade of it is migrating.
- `serial.log` is append-only, and the seed's `bootcmd` copies `/var/log/tama-storage.log` to the console on every boot. Each boot of the state therefore wrote a `TAMA_STORAGE_ZFS_READY <guid>` line, which is the only host-readable source of its pool GUID.

The change answers this with `macus runtime upgrade`: start now records such a guest as contract 0 and names the upgrade command, and the upgrade reads the pool GUID from `serial.log`, skips the inventory comparison (it says why) and clones the data disk before booting a new root. The original state is retained untouched. Hardware acceptance (task 5.7 of that change) must run on an isolated copy of a state with this shape, never on the original, and has not run yet.

## Reversible runtime upgrade and rollback — 2026-11-24 UTC

Task 5.3 of `add-runtime-upgrade` passed [opt-in hardware acceptance](testing/runtime-upgrade-reversible-acceptance.json) on an isolated state (`/tmp/macus-r53`) on a Mac16,5 with macOS 27.0.1. The source package was `develop` (`ac86fe9`), which predates guest identity reporting. The target was `56685b2`. Both were release builds installed in turn into one isolated prefix. The package change followed the Homebrew upgrade sequence without Homebrew: stop, unload both jobs, remove the server plist, install, start.

- **Source state:** created by `start-acceptance.py` on the develop package, with a container, an attached custom volume and a profile in the default project, a container in a second project, and a random marker in each container and on the volume.
- **Start on the new package:** ready in 41 s. It reported an upgrade as available, recorded the Incus package `7.0.1-r2` from the catalog, and the workloads ran.
- **Dry run:** reversible (`7.0.1-r2` to `7.0.1-r2`), pool `3952008500462468296` from `serial.log`, no data copy. Nothing in the state directory changed and the runtime stayed ready.
- **Upgrade:** 49 s. The new root adopted the pool (`TAMA_STORAGE_ADOPTED`), and Incus listed every earlier instance, volume, network and profile in both projects. The old root, firmware store and seed moved into the backup with the same inodes, and the data disk kept its inode. The guest record and storage identity now come from health. Every marker was intact and a second dry run reported the state current.
- **Rollback:** a marker was written after the upgrade, then `runtime upgrade --rollback` ran in 7 s. It restored the original root, firmware store and seed by inode, kept the data disk without `--discard-data-since-upgrade`, restored the earlier guest record, left the runtime stopped and kept the replaced state as a new backup.
- **Restored root:** `start` was ready in 39 s on the develop root and reported an upgrade available. The original markers and the one written after the upgrade were all intact.

**Finding:** the develop seed copies the storage log to the console 20 s after boot. On the provisioning boot storage was still starting, so the first boot wrote no `TAMA_STORAGE_ZFS_READY` line; the second boot did. A develop-era state that has booted only once has no pool identity source, and its upgrade would be refused. A package rollback to the develop build after the state rollback was not run. Tasks 5.4 to 5.7 are not covered by this run. The state directory is retained and both of its jobs are unloaded.

## Failed upgrade by adoption refusal — 2026-11-24 UTC

Task 5.5 of `add-runtime-upgrade` passed [opt-in hardware acceptance](testing/runtime-upgrade-adoption-refusal-acceptance.json) on the retained isolated state from task 5.3 (`/tmp/macus-r53`). That state was on the develop root, with its workload markers, and `56685b2` was installed.

- **Forced refusal:** with the runtime ready, one digit of the pool GUID in `runtime/storage-identity.json` was changed, so the plan, the staged seed and the adoption record all named a pool that does not exist. The dry run showed the forged GUID.
- **Upgrade:** failed after 39 s with exit 1. The guest logged `stage=failed code=storage_adoption_refused`: the named pool could not be imported from `/dev/vdb1` without force, and the disk was preserved. The error named the code and said the previous root and configuration were restored. Root, firmware store and seed were back on their original inodes, and the data disk kept its inode. The guest record and `config.json` matched the copies taken before the stop. No intent or staging directory remained, and the runtime was stopped. The rejected root, firmware store and seed were kept under the backup's `failed/`, and the backup lists as not restorable (incomplete).
- **Earlier package:** the real record was restored. The develop package was reinstalled into the same prefix (same binary SHA-256 as in 5.3) after unloading both jobs and removing the server plist. `macus start` was ready in 42 s with the server job registered for the develop revision. Both containers ran and every marker was intact. The develop package ignores the guest record, storage identity and `backups/` that this change adds.

**Finding:** the failure message ended with the generic boot-failure remedy (`macus runtime stop --force`, then `macus start`), although automatic rollback had already stopped the runtime. After this run the message was changed to drop that remedy, say the runtime is stopped and end with `Run macus start to boot the previous root.`; `refusedAdoptionRollsBackAndNamesOnlyStart` covers it. The hardware run used the earlier wording and was not repeated. The new root never imported the pool in this run, so a forced stop with the pool imported remains task 5.6. The state directory is retained, the develop package is installed in its prefix, and both of its jobs are unloaded.

## Migrating runtime upgrade — 2026-11-25 UTC

Task 5.4 of `add-runtime-upgrade` is [blocked](testing/runtime-upgrade-migrating-acceptance.json): no second appliance with a different Incus package exists. The catalog's only qualified entry is `alpine-3.24.2-lts-1` (Incus `7.0.1-r2`). The draft `alpine-3.24.2-stable-1`, which is unqualified, ships the same `incus-7.0.1-r2` and changes only the kernel and ZFS module, which the design classifies as reversible. The task stays open until an appliance with another Incus package is qualified.

A substitute run on the retained isolated state (`/tmp/macus-r53`) exercised the migrating path with `56a2513` installed. That state was on the develop root with its workload markers.

- **Forced class:** with the runtime ready, the recorded Incus package in `runtime/guest-record.json` was changed to `7.0.0-r2`. The dry run then planned a migrating upgrade (`7.0.0-r2` to `7.0.1-r2`) that named the data clone, and it changed nothing.
- **Upgrade:** upgraded in 50 s, with the inventory compared. The live `data.raw` kept its inode, and the backup holds a clonefile copy with a new inode. `data_copied_at` (08:28:23Z) precedes the backup's `created_at` (08:28:55Z). The old root, firmware store and seed moved into the backup by inode. The guest record came from health (`7.0.1-r2`, payload `50670a7d…`). Every marker was intact.
- **Rollback:** a token written to the custom volume after the upgrade, plus a new volume, stood for later writes. Without `--discard-data-since-upgrade`, rollback was refused with `conflict`: the error named the copy time, nothing changed, and the runtime stayed ready. With the flag, it was restored in 7 s. The data disk is the clone's inode, the original root, firmware store and seed inodes are back, and the migrated data and new root were kept as safety backup `20261125T082933Z-63eb2a91`.
- **Restored state:** `macus start` was ready. Both containers ran. The pre-upgrade markers, including a token written just before the upgrade, were intact, and the post-upgrade token and volume were gone. The host went into clamshell sleep for 295 s during this start; the boot resumed after wake, and without the sleep the start took about 34 s.

**Not covered:** an Incus database migration, since both roots ran `7.0.1-r2`.

**Findings:**
- On a refused rollback, the client printed `Stopping the runtime to restore the latest backup…` before the request, although nothing is stopped.
- When the copy is the backup's own, the refusal named that backup twice.

Both were fixed after this run. The client now prints `Checking the latest backup; the runtime is stopped only if it can be restored…`, and the refusal names a second backup only when the copy comes from a later one (`copy from backup Y taken at …`). `migratingUpgradeShowsWhatHappensBeforeTheStopAndRollbackNeedsTheDiscardFlag`, `discardWarningNamesWhenTheDataCopyWasTaken` and `rollbackAcrossALaterMigrationUsesTheLaterDataCopy` cover the fixes. The hardware run used the earlier wording and was not repeated.

The state directory is retained, `56a2513` is installed in its prefix, and both jobs are unloaded.

## Forced stop of the new root with the pool imported — 2026-11-25 UTC

Task 5.6 of `add-runtime-upgrade` passed [opt-in hardware acceptance](testing/runtime-upgrade-forced-stop-acceptance.json) on the retained isolated state (`/tmp/macus-r53`), on the develop root with its workload markers. `4183af2` (develop with upmaru/macus#20 merged) was installed.

- **Forced stop:** an upgrade can only end before commit by the readiness timeout or daemon death, so a watcher sent SIGKILL to the runtime service once the new root's storage service had finished (`stage=storage`, then the first `stage=incus`) while `upgrade.pending` existed. The new root had adopted and imported the pool and Incus was starting. The VM process ended with the daemon, with no guest shutdown or pool export. The client failed after 45 s with `unavailable`.
- **Journal rollback:** launchd restarted the daemon within 12 s, and it rolled the journal back before anything else. Root, firmware store, seed and data disk were on the earlier root's inodes. The guest record, storage identity and `config.json` were byte-identical to the copies taken before the upgrade. `upgrade.pending` was gone, the new root, firmware store and seed were kept under the backup's `failed/`, and the runtime was stopped with a last error saying the uncommitted upgrade was rolled back.
- **Earlier root:** `macus start` was ready in 37 s. The develop root imports its owned pool only without `-f` and refuses otherwise, and no refusal appeared, so it imported the pool the killed root left imported. Both containers ran, every marker (including one written just before the upgrade) was intact and the custom volume was present.

A first attempt keyed the kill on `TAMA_STORAGE_ZFS_READY`, which the guest prints only in a log dump after bootstrap readiness. The upgrade committed before that line appeared, so nothing was killed. It was rolled back explicitly (`runtime upgrade --rollback`, root only, 6 s) and the develop root started again before the second attempt.

**Not covered:** a forced stop during a migrating upgrade. No findings. The state directory is retained, `4183af2` is installed in its prefix, and both jobs are unloaded.
