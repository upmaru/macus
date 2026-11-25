# Development and appliance preparation

Requires Apple Silicon, macOS 15+, Xcode/Swift 6.4 and the pinned Elixir/OTP
toolchain for `server/`. SwiftPM and native `swift format` cover the VM service;
Mix covers the headless Phoenix/Cowboy gateway. Hardware acceptance is opt-in
and separate from unit tests.

## OpenSpec with mise

Install [mise](https://mise.jdx.dev/getting-started.html), then run these commands from the repository root:

```sh
mise trust
mise install node npm:@fission-ai/openspec
mise install elixir erlang
mise exec -- openspec --version
mise run spec:validate
```

`mise.toml` pins Node.js 26.10.0, OpenSpec 1.14.0, Elixir 1.19.5 (OTP 27 build)
and Erlang/OTP 27.3.4.16. OpenSpec is installed through mise's npm backend
independently of any global npm installation. CI also pins OpenSpec 1.14.0.
Go 1.25.14 is pinned solely for official Incus reference/inventory verification;
it is not a Macus runtime component. Use `mise install go` for those checks.

Use `mise exec -- openspec ...` for planning and implementation commands, including in agent sessions and shells without mise activation:

```sh
mise exec -- openspec list
mise exec -- openspec status --change add-elixir-server --json
mise exec -- openspec instructions apply --change add-elixir-server --json
mise exec -- openspec validate --all --strict --no-interactive
```

The status and apply examples target `add-elixir-server`; substitute another
active change name when needed.

The canonical checks remain:

```sh
Integration/scripts/check.sh
mise run spec:validate
```

Swift and native swift-format come from the selected Xcode toolchain. Hardware acceptance remains explicit and opt-in, uses isolated state directories, and is recorded separately from these checks.

## Headless Elixir server

Run the server checks from its directory so Mix reads its independent project:

```sh
cd server
mise exec -- mix deps.get
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
```

`server/mix.lock` records released dependencies, including Phoenix 1.8.17,
Plug.Cowboy 2.9.0, Cowboy 2.21.0, Mint 1.11.0, TamaMCP 0.2.1,
`opsmaru_incus` 0.2.10 and `tama_dex` 0.1.0 (which brings the exqlite SQLite
NIF). All dependencies are released Hex packages; Hex is the
only distribution route for `opsmaru_incus`, so builds never use a Git revision
or sibling path for it. Macus's own scaffold has no Ecto, HTML,
assets, LiveView or generated nested AGENTS file. `opsmaru_incus` has no
application callback and starts no process or listener. `_build/`, `deps/` and release outputs are
ignored. Tests start the OTP tree in process without a listener or VM.

The initial scaffold is passive: it resolves `MACUS_STATE_DIR`, then legacy
`TIM_STATE_DIR`, then `~/.tama/incus-mac`, without creating that state. Generic
`PHX_SERVER`/`PORT` variables do not enable a cleartext listener. The HTTPS
state, authorization, routes and coordinated two-service startup have since
shipped (change tasks 8.x); the private Unix endpoints remain only the
server's backend and bootstrap mechanics. `Integration/scripts/check.sh` runs
the Swift gates, source installation and packaging checks, then
`Integration/scripts/check-server.sh` (the Hex guard and the Mix format,
compile and test checks above, with the tools pinned in `mise.toml`). The
embedded release smoke is opt-in through `MACUS_RELEASE_SMOKE_CASSETTE`, and
CI runs it with the verified locked cassette (task 10.1).

The [Cowboy transport trial](cowboy-transport-trial.md) exercises native
SFTP/NBD HTTP upgrades with TLS/Unix fixtures and the pinned official client.
Its handlers are test-only; passing that trial does not complete the proxy or
hardware acceptance.

`:opsmaru_incus` (Hex) owns safe library embedding, connection/context values,
codecs, native Incus client coverage, gateway relay mechanics and the shared
operation descriptors and runner. Durable tasks and connector work belong to
later milestones. Macus owns its gateway authentication/policy, private Swift
runtime adapter, runtime operations and the `/mcp` `search`/`execute` tools;
the separate tama-dex index library backs `search`. Avoid a duplicate portable client, task
engine, Opsmaru endpoint or third service. The Cowboy trial is consumer
evidence, not proof that the dependency is implemented or integrated. The
library's coverage is read from the locked package: after changing its lock,
run `mise exec -- mix macus.incus.coverage --diff <previous inventory.json>`
and regenerate `docs/incus-coverage.md` with `mise exec -- mix
macus.incus.coverage` (see [the shared Incus client](incus-client.md)).

The private Swift adapter can be checked independently from that library:

```sh
mise exec -- mix test test/macus/runtime/client_test.exs
```

`Macus.Runtime.Client.new/2` takes trusted `Macus.Configuration` and the
verified host UID. It resolves `runtime.sock` without creating state. Each
request validates private ownership/modes and ancestors, uses one monotonic
deadline, limits request JSON to 1 MiB and responses to 16 MiB/16 KiB headers,
and closes its connection. An uncertain mutation is never replayed. The
public gateway/host adapter supplies that trusted configuration; request
inputs must not select another path or UID. Ordinary read-only startup remains
passive.

The optional central `connect`, passive `connection status` and `disconnect`
commands are later integration work. Normal installation/start must not enroll
or require central login/connectivity. Their outbound workers will share the
existing Elixir job and preserve local runtime/data on central outage.

The combined delivery target is `<prefix>/bin/macus` plus a complete
bundled-ERTS release at `<prefix>/libexec/macus`. Only source builders require
Elixir/Erlang. Each component has its own foreground launchd job; restarting
the gateway must preserve the VM. Both carry the same Macus identity: the
Swift executable embeds `MacusVersion` and `MacusSourceRevision` in its
Info.plist (link with `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker
__info_plist -Xlinker <plist>`), and the release's
`Macus.Release.write_manifest/1` step writes `macus-build.json` (version,
`MACUS_SOURCE_REVISION`, and the bundled `opsmaru_incus` version and
checksum) at the release root. `macus start` refuses to launch a release
whose record differs.

The release is built on macOS ARM64 from `server/`:

```sh
cd server
MIX_ENV=prod MACUS_SOURCE_REVISION="$(git rev-parse HEAD)" \
  MACUS_CASSETTE_SHA256=<sha256 of the bundled cassette> \
  mise exec -- mix release macus --overwrite --path /absolute/release
```

`Packaging/install-local.sh` is the supported way to build it: it obtains the
opsmaru_incus cassette for the locked version (see below) and sets
`MACUS_CASSETTE_SHA256` and `MACUS_CASSETTE_PATH` for you. To run `mix release`
by hand, give it a cassette you have checked the same way. Before recording
anything, `Macus.Release` checks the assembled release and fails the build unless
all of the following hold:

- it was built on `aarch64-apple-darwin`;
- it bundles exactly one ERTS, with an ARM64 `beam.smp`;
- `lib/` holds exactly the locked `opsmaru_incus` and `tama_dex`;
- the cassette is alone in `priv/cassettes/` and matches the pin;
- exqlite's `sqlite3_nif.so`, the SQLite NIF `tama_dex` uses, is ARM64;
- `env.sh` turns distribution off.

exqlite's precompiled NIF is verified by exqlite's own checksums, which the
locked package checksum covers. The manifest then also records the cassette
file and SHA-256, the `tama_dex` and `exqlite` lock entries with the NIF's
SHA-256, the ERTS version and target, and `distribution: none`. It is mode
0444. `rel/env.sh.eex` forces `RELEASE_DISTRIBUTION=none` whatever the
environment says: the server is never an Erlang node, opens no EPMD or
distribution port, and is stopped with SIGTERM, not `bin/macus stop`.

`python3 Integration/scripts/release-smoke.py --release /absolute/release`
copies a built release into a fresh prefix and starts it as launchd would,
but with an empty environment (system PATH, new HOME and state, no host
Elixir/Erlang). It checks:

- every Mach-O links only system libraries;
- the gateway serves TLS 1.3 with the published certificate and refuses
  unauthenticated requests;
- the pinned cassette and the runtime cassette are indexed;
- the gateway port is the only listener, and no distribution flag or EPMD
  contact appears;
- SIGTERM stops the server alone with status 0, leaving a stand-in runtime
  service, `runtime.sock`, the runtime files and the server identity in place.

It boots no VM. The integrated Homebrew candidate workflow
is the packaging baseline, with real measured hashes and passive installation;
see [candidate documentation](../Packaging/homebrew/README.md). The source
installer stages the release (below), and the Homebrew candidate installs the
same release as a checksummed resource built at candidate preparation.

## Build and sign

```sh
swift build -Xswiftc -warnings-as-errors
swift test --no-parallel -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format format --in-place --recursive Package.swift Sources Tests
swift format lint --strict --recursive Package.swift Sources Tests
codesign --force --sign - --entitlements Packaging/virtualization.entitlements .build/debug/macus
.build/debug/macus capabilities
.build/debug/macus --help
```

VZ requires `com.apple.security.virtualization` on the daemon executable. Development signing is ad hoc. Production signing/notarization is a future release task. Apple APIs detect unsupported hardware/policy; nested support is never inferred from the model name.

## Macus command

`macus` is the single command built by this SwiftPM package. `serve` runs the foreground daemon; runtime commands control the outer VM and client setup configures the standard Incus CLI. Workload commands belong to `incus`. Invocation and transport limits are in [the CLI reference](cli.md).

Local source installation requires Swift and the mise-pinned Elixir/Erlang. It installs `<prefix>/bin/macus` and the paired server release at `<prefix>/libexec/macus`:

```sh
Packaging/install-local.sh --prefix /absolute/isolated/prefix
```

Before building anything, it refuses:

- a relative path, a symlinked or non-file/non-directory destination, or an existing `<prefix>/libexec/macus` that is not a Macus release (it holds no `macus-build.json`);
- a checkout without a git revision;
- a missing or unverified pinned dependency. The release build needs the cassette for the opsmaru_incus version `server/mix.lock` locks, and the GitHub CLI (`gh`, signed in) to get and check it:
  - without `--cassette`, it downloads `opsmaru_incus-<version>.tama-cassette` and its `.sha256` from the upmaru/opsmaru-incus `v<version>` GitHub Release, and nothing else; a missing release or asset is refused;
  - with `--cassette /absolute/opsmaru_incus-<version>.tama-cassette`, that file must be named for the locked version and have the release's `.sha256` beside it;
  - either way the file must match its `.sha256`, and `gh attestation verify --repo upmaru/opsmaru-incus` must accept it, so only a cassette built by the opsmaru-incus release workflow is bundled.

  The downloaded files stay in the installer's temporary directory. Only the build fetches the cassette: installed startup imports the bundled file at the pinned SHA-256 and never downloads one.

Both components get one identity: the version in `server/mix.exs` and the checkout's `HEAD`. A checkout with uncommitted changes gets a warning, because both still record `HEAD`. The Swift build embeds that identity as `MacusVersion` and `MacusSourceRevision` in the executable's Info.plist. The release is built with `MIX_ENV=prod`, `MACUS_SOURCE_REVISION`, `MACUS_CASSETTE_SHA256` (from the `.sha256`) and `MACUS_CASSETTE_PATH`. Its `Macus.Release.bundle_cassette/1` step bundles that file as the only cassette, replacing anything `server/priv/cassettes` holds for other versions.

`--release /absolute/release` installs an already assembled release instead of building one. Either way, the staged executable and release are verified before the prefix changes:

- the executable carries the virtualization entitlement and embeds the identity;
- the release's read-only `macus-build.json` records the same version and revision;
- the release bundles exactly the locked `opsmaru_incus` and its cassette at the recorded SHA-256;
- it has one ERTS, its `bin/macus` launcher, and distribution off.

A release built from another revision, or one missing its library or cassette, is refused with nothing installed. Both are then staged and verified beside their destinations, and a copy of any installed executable is kept, before either is replaced. The release and then the executable are replaced by renames and verified again in place; the kept pair is removed only after both pass. Any failure from staging onward puts the previous release and executable back (or removes a first install's partial pair), so a failed update never leaves a release beside an executable from another revision. `Integration/scripts/test-install.sh` (part of `check.sh`) exercises each refusal, a complete install, a reinstall that cannot stage the executable and one restored after its final check fails, in isolated prefixes, using a fixture cassette.

The unified executable receives the virtualization entitlement for serve mode. The command does not create runtime state or register or activate a launch agent; `macus start` does that explicitly. Ad-hoc development signatures are not notarized production artifacts. A future release package or formula must include both components and real checksums; none is published here.

## Git Flow

The long-lived branches are `main` for released history and `develop` for
integration. The server change uses `feature/elixir-server` from `develop`.
Publishing a feature branch does not finish it or mark hardware acceptance
complete.

Create `feature/<name>` from `develop` and merge completed, validated features back into `develop`. Create `release/<version>` from `develop`; finish the validated release into both `main` and `develop` and tag it on `main`. Create urgent `hotfix/<name>` branches from `main` and finish them into both long-lived branches. Branch publication and finishing are separate actions; release readiness requires the acceptance evidence in OpenSpec.

Use normal Git commands or a Git Flow client with these branch names. Local `gitflow.*` configuration records `main`, `develop`, `feature/`, `release/`, `hotfix/` and `support/`; the repository does not require a Git Flow CLI.

## Prebuilt Alpine appliances

A fresh `macus start` downloads the published LTS image pinned in
`Integration/catalog/alpine-3.24.2.json`. Macus verifies the archive and raw
disk, then passes the expected image record into the NoCloud seed. The guest
verifies the installed packages and running kernel offline before initializing
storage and starting Incus. Existing runtimes continue to use their own disks.

[macus-appliance](https://github.com/upmaru/macus-appliance) builds and stages
separate LTS and Stable images as drafts. For each new image ID, follow the
[local hardware runbook](../Integration/qualification/README.md#prebuilt-draft-appliances)
before publication. After publication, record the matching public URL, measured
sizes, digests, upstream and build provenance, and qualified package pins in
the catalog. Run `python3 Integration/scripts/check-catalog.py --write` to
update the embedded entry, then verify a fresh isolated start through the
published URL. LTS is currently the sole shipped channel.

## Manual upstream Alpine preparation

The upstream base is **Alpine 3.24.2 aarch64 cloud-init metal r0**, which includes ARM64 EFI and the Linux kernel/modules needed by VZ and Incus. Download the official raw archive, SHA-512 file and detached signature, plus the signing key linked from [Alpine's cloud image page](https://alpinelinux.org/cloud/). GnuPG is a preparation dependency; runtime operation needs no GnuPG or host VM tool.

```sh
mkdir -p .integration/cache
base=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud
image=alpine-3.24.2-aarch64-cloudinit-metal-r0.raw.tar.gz
curl -fL "$base/$image" -o ".integration/cache/$image"
curl -fL "$base/$image.sha512" -o ".integration/cache/$image.sha512"
curl -fL "$base/$image.asc" -o ".integration/cache/$image.asc"
curl -fL https://alpinelinux.org/keys/tomalok.asc -o .integration/cache/tomalok.asc
python3 Integration/scripts/verify-appliance.py \
  --archive ".integration/cache/$image" \
  --checksum-file ".integration/cache/$image.sha512" \
  --signature ".integration/cache/$image.asc" \
  --signing-key .integration/cache/tomalok.asc \
  --output .integration/cache/verified-alpine
python3 Integration/scripts/prepare-appliance.py \
  --root-disk .integration/cache/verified-alpine/disk.raw \
  --output .integration/appliance --appliance-id alpine-3.24.2-incus-v1
.build/debug/macus serve --state-dir "$PWD/.integration/state"
```

Verification uses an isolated GnuPG keyring and pins the official cloud signer fingerprint `F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22`. It refuses checksum/signature mismatches, unexpected archive members and replacement of a different existing raw image. Preparation records archive provenance and the raw SHA-256 in the manifest, and uses macOS `hdiutil` for the NoCloud ISO. Output and source must be on the same volume for the immutable raw hard link. No qcow conversion is used.

Embedded guest scripts come from `Integration/guest`. Check the generated payload and catalog from the repository root.

```sh
python3 Integration/scripts/sync-guest-payload.py --check
python3 Integration/scripts/check-catalog.py
```

Neither command creates state or boots a VM. A partial download or corrupt cache is discarded or moved aside and rehashed before reuse. It is not booted. Runtime disks are not replaced to recover a bad cache.

In another terminal, create and start the manually prepared base through the [control API](api.md) using `.integration/appliance/config.json`. Its legacy first boot waits for IPv4 DHCP, installs maintained Incus LTS (at least 7.0.1), its OpenRC/VM packages and explicit OCI dependencies from the signed Alpine v3.24 main/community repositories, initializes persistent storage and starts OpenRC services. The helper waits for Incus startup cleanup/autostart readiness on every boot; responding to `/1.0` alone is insufficient. CA installation uses the official HTTP repository with normal APK signature verification before switching all remaining package operations to HTTPS. There are no edge repositories or unsigned-package exceptions. New appliances set `images.auto_update_interval=0`; image refreshes remain explicit standard Incus operations while the selected LTS shutdown/cache behavior is verified. Existing Incus configurations are preserved. Resolved packages are recorded in `/var/log/tama-appliance-packages.txt` and private host `serial.log`. Incus manages QEMU/KVM inside Linux; the Mac invokes no VM CLI. SSH is disabled.

Use a new appliance ID and a new state directory when changing the base image. Existing root/data disks are preserved; there is no automatic Debian-to-Alpine migration. A pre-provisioned appliance can omit `seed_path` (JSON null) while retaining the manifest/vsock contract. The host verifies the source and staged raw SHA-256 before boot; writable root/data disks live under `<state-dir>/runtime`.

## Start acceptance runner

`Integration/scripts/start-acceptance.py` is opt-in and does not boot hardware unless `--hardware` is passed. Its `--report` path is validated before any directory creation or executable invocation. A report inside the state directory, installation prefix, ordinary Incus configuration, or a symlink is refused so runtime disks and configuration cannot be overwritten by the report. The runners that take `--incus-conf` (workload, restart, remote, upgrade and Linux) also refuse a report inside that selected client directory, so its `config.yml` and `client.key` cannot be replaced. Put the report in a separate directory.

It runs only the installed pair: `<prefix>/bin/macus` and the server release beside it at `<prefix>/libexec/macus`. `--macus` may only name that executable. Without `--opt-in` it refuses before it reads, creates or runs anything. With `--opt-in`, and before anything runs or any state is created, it checks the installed pair by reading it:

- **Paired artifacts:** the identity embedded in the executable equals the release's `macus-build.json`.
- **Pinned dependency:** the release bundles exactly the `opsmaru_incus` that `server/mix.lock` locks, plus only its recorded cassette.
- **Service labels:** the state's runtime and server labels differ from each other and from the default `com.upmaru.macus` and `com.upmaru.macus.server`.

Without `--hardware` it records those checks and stops, so `macus` never runs and VZ never starts. It also never touches the ordinary state or client configuration.

With `--hardware` it also:

1. Creates a fresh `INCUS_CONF`.
2. Writes a gateway port of its own to an owner-private `<state>/server/gateway.json`. It keeps an existing file, and never uses the default port 8443.
3. Removes `MACUS_STATE_DIR` and the fixture seams from the environment.
4. Runs `macus start`.

Success then requires all of the following:

- the reported labels and endpoint port are this state's;
- both plists are in `<state>/launchd` and name this state, the installed executable and the paired release revision;
- `server/` holds owner-private credentials;
- a repeated `macus start` is ready again with the same runtime and server processes and no guest reboot (runtime uptime keeps counting);
- the standard `incus` client's remote in that `INCUS_CONF` names exactly the published endpoint, is `trusted`, and `incus list` works;
- public runtime control over HTTPS, pinned to the published certificate: with a `runtime.read` token `GET /runtime/status` is ready; with a `runtime.write` token `POST /runtime/start` on the ready runtime returns it unchanged; a `runtime.read` token's `POST /runtime/stop` is refused with 403 and the runtime stays up. The tokens are issued with `macus server token issue` into a private temporary directory and revoked afterwards;
- `:opsmaru_incus` adds no listener and no service: only this state's two labels exist, the server's process tree listens only on the gateway address, and `macus serve` has no network sockets;
- the default jobs, their plists and the default endpoint are unchanged. The runner only reads these, with `launchctl print` and `stat`.

The report keeps package evidence (the pair checks) and guest evidence (the hardware checks) in separate `evidence` sections. It leaves the isolated runtime running; stop it with `macus --state-dir STATE runtime stop`.

```bash
python3 Integration/scripts/start-acceptance.py --opt-in --hardware \
  --state-dir /tmp/macus-accept --prefix "$(brew --prefix macus)" \
  --report .integration/start-acceptance.json
```

A run that is refused, or that stops before `--hardware`, is not hardware acceptance.

## Workload acceptance runner

`Integration/scripts/workload-acceptance.py` (task 11.3) runs against a state that `start-acceptance.py` already started, with that run's installed pair and isolated `INCUS_CONF` (its report's `incus_conf`). It has the same opt-in steps. Without `--opt-in` it touches nothing. With `--opt-in` it checks the report path, refuses ordinary state, prefix and client configuration, and checks the installed pair. Without `--hardware` nothing reaches the guest. With `--hardware` it first requires the client's remote to name exactly this state's published endpoint; until then it changes nothing.

```bash
python3 Integration/scripts/workload-acceptance.py --opt-in --hardware \
  --state-dir /tmp/macus-accept --prefix "$(brew --prefix macus)" \
  --incus-conf "$(python3 -c 'import json;print(json.load(open(".integration/start-acceptance.json"))["incus_conf"])')" \
  --incus "$(command -v incus)" --remote macus \
  --report "$PWD/.integration/workload-acceptance.json"
```

Through the standard client and the gateway it checks the following:

- **Workload:** it creates one system container (`--image`, default `images:alpine/3.22`), then reuses and keeps it.
- **Exec:** native exec returns stdout, stderr, the exit status and stdin.
- **Console:** an attached console receives what the instance writes to `/dev/console`, then detaches with Ctrl-A q.
- **Events:** a lifecycle event arrives for a snapshot made while `incus monitor` runs.
- **Binary transfers:** 8 MiB of random bytes are pushed, hashed in the guest, then pulled back unchanged.
- **MCP:** `search` and `execute` work over the shared Incus and Macus runtime operations, each with only the scopes it needs.

It also checks that these are refused without affecting the guest:

- no bearer token, an unknown one, or a revoked one (401);
- a token that lacks the scope (`not_found`, not dispatched);
- a missing or empty confirmation (`confirmation_required`, not dispatched), or a wrong one (`operation_error`, nothing deleted);
- a gateway-untrusted client certificate, or a bearer token, on native list, exec and delete routes (403).

The guest's marker file, snapshots, instance status and runtime state must be identical before and after the run. Tokens are revoked afterwards.

The runner never stops, restarts or force-stops the VM. The only thing it deletes is the snapshot it created itself, through the confirmed MCP delete.

It creates the workload with `incus create` and `incus start` rather than `incus launch`. The client always sends `"start": true`, and it starts the instance a second time unless the server advertises `instance_create_start`. Before `opsmaru_incus` 0.2.7 the gateway didn't advertise it, so `incus launch` reported "already running" after the container had started ([opsmaru-incus#88](https://github.com/upmaru/opsmaru-incus/issues/88)). Macus now advertises it, but the runner keeps `create` and `start` so its evidence stays comparable with the 11.3 run, which used a pair built with 0.2.6.

Every child process gets an empty stdin, because `incus snapshot create` and `incus create` read YAML from a stdin that is not a terminal. If a command stalls anyway, the report keeps its `--debug` log, a goroutine dump and a TLS probe of the gateway.

## Access log acceptance runner

`Integration/scripts/access-log-acceptance.py` (`add-gateway-access-log` task 5.1) runs against a state that `start-acceptance.py` already started, with that run's installed pair, isolated `INCUS_CONF` and remote. It refuses to run without `--opt-in` and refuses the ordinary state and client configuration. Before sending anything it also refuses unless the remote's address and `--url` both equal the `url` in the state's `server/endpoint.json`.

```bash
python3 Integration/scripts/access-log-acceptance.py --opt-in \
  --state-dir /tmp/macus-accept --prefix "$(brew --prefix macus)" \
  --incus-conf "$INCUS_CONF_FROM_START_REPORT" --incus "$(command -v incus)" --remote macus \
  --url https://127.0.0.1:PORT --certificate "$INCUS_CONF_FROM_START_REPORT/servercerts/macus.crt" \
  --report "$PWD/.integration/access-log-acceptance.json"
```

Through the standard client it runs `incus list`, `launch`, `exec`, `file push` and an SFTP listener mount read with `sftp`, then sends one request from an untrusted certificate carrying a marked bearer value, query and header. It then reads the log with `macus server logs` and requires one record per exchange with the expected caller, status, outcome and bytes, streams recorded at their end, ids from one boot without a gap, 0600 files in a 0700 directory, only the documented keys, and none of the marked values. It creates one throwaway instance and leaves it and the runtime in place.

## Restart acceptance runner

`Integration/scripts/restart-acceptance.py` (task 11.4) restarts only the server job of a state that `start-acceptance.py` started and `workload-acceptance.py` gave a kept workload. It takes the same arguments as the workload runner (without `--image`) and has the same opt-in steps: nothing without `--opt-in`, the pair and path checks without `--hardware`, and no restart until the client's remote is proved to be this state's endpoint.

```bash
python3 Integration/scripts/restart-acceptance.py --opt-in --hardware \
  --state-dir /tmp/macus-accept --prefix "$(brew --prefix macus)" \
  --incus-conf "$(python3 -c 'import json;print(json.load(open(".integration/start-acceptance.json"))["incus_conf"])')" \
  --incus "$(command -v incus)" --remote macus \
  --report "$PWD/.integration/restart-acceptance.json"
```

It restarts the server job three ways:

- **Crash:** `launchctl kill SIGKILL` while an MCP exec is running in the guest; launchd relaunches the job.
- **Explicit restart:** `launchctl kickstart -k` of the server job.
- **Missing job:** `launchctl bootout` of the server job. `macus runtime status` must then report `unavailable` and name `macus start`, because the client never falls back to the private runtime socket. `macus start` must register the job again.

Around each restart only the server pid may change. The runtime job's pid, the guest kernel's boot id, the kept instance's volatile UUID and init pid, and its marker file must stay the same, and the runtime uptime must only grow. Native `incus list` and an MCP list, with tokens issued before the restart, must work afterwards.

It also checks how interrupted calls are reported:

- **Zero-wait mutation:** an unnamed snapshot with `wait_seconds: 0` must report its native operation as `running`, never `completed`. Polling that id through `incus_operation_get` must reach `Success`.
- **Call in flight during the crash:** the client gets no reply, so the call claims no completion. The runner records the exec's native operation while it runs, then reads the same id through the relaunched server. The command's first effect must happen exactly once.
- **No replay:** after all three restarts there is still exactly one new snapshot and one run of the interrupted command.

The runtime job is never stopped, restarted or relaunched. If the missing-job check fails, `macus start` still registers the job again before the run goes on. Afterwards the runner deletes its snapshot (through the confirmed MCP delete) and its exec log, then requires the guest state to match what it was before. Tokens are revoked.

## Remote acceptance runner

`Integration/scripts/remote-acceptance.py` (task 11.5) proves access from a genuinely separate client. It runs against the same kind of state as the restart runner, and takes the same arguments plus:

- `--bind-address`: this Mac's private or CGNAT address that the client can reach. Loopback, wildcard, multicast and public addresses are refused.
- `--client-remote`: your own `incus` remote for another Incus server, which hosts the client. Unix sockets, loopback, image servers and this Macus are refused.
- `--client-name` and `--client-image` (default `macus-remote-115` and `images:alpine/3.22`).
- `--lock`: the `server/mix.lock` of the installed pair's own revision, when it differs from this checkout's.
- `--remote-opt-in`: without it, nothing is rebound, launched or enrolled; only the pair, the paths, the bind address and this state's own remote are checked.

```bash
python3 Integration/scripts/remote-acceptance.py --opt-in --remote-opt-in \
  --state-dir /tmp/macus-accept --prefix "$(brew --prefix macus)" \
  --incus-conf "$(python3 -c 'import json;print(json.load(open(".integration/start-acceptance.json"))["incus_conf"])')" \
  --incus "$(command -v incus)" --remote macus \
  --bind-address 100.64.0.10 --client-remote otherhost \
  --report "$PWD/.integration/remote-acceptance.json"
```

The client is a throwaway container the runner launches on `--client-remote` with your own incus client. It only creates a name that doesn't exist yet, installs the distribution's `incus-client` and Python, copies in `Integration/scripts/remote-client-probe.py`, and deletes the container at the end, but only if it is still the one it created. Nothing else on that server is touched; the runner compares its instance list before and after.

With `--remote-opt-in` the runner:

1. Rebinds the gateway to `--bind-address` with a throwaway P-384 certificate naming that address, and restarts only the server job. The server must then listen on that address alone.
2. From the client, checks:
   - **TLS identity:** a TLS 1.3 handshake pinned to that certificate, with its SHA-256 matching `endpoint.json`, and a refused handshake for another name. Anonymous `GET /1.0` must answer `untrusted` with no server environment.
   - **Native enrollment:** `incus remote add` with a single-use token from `macus server trust token issue`. The remote must pin the gateway certificate and the token must record the client's certificate. A second client must fail to reuse the token.
   - **Native access:** `incus list`, `incus exec` of the kept marker and `/1.0` reporting `trusted` with the gateway's address.
   - **Combined scopes:** one bearer token with `incus.read` and `runtime.read` reads `/runtime/status`, searches and runs read operations in both cassettes over `/mcp`, and is refused `incus_instance_exec`, `macus_runtime_start`, `PUT /runtime/config` and native routes. Requests without a token get 401.
   - **Revocation:** the bearer token stops working within seconds. Removing the enrolled certificate ends an open `incus exec` and leaves the client `untrusted`. A revoked enrollment token can't be redeemed.
3. Always restores the original `gateway.json` and restarts the server job again. Loopback must answer and the client must no longer connect. Any client certificate or enrollment token left over from a failed check is removed.

The VM, the runtime job and the kept workload are never stopped or restarted, and their identity must match before and after. The report keeps remote evidence under `evidence.remote`, with `loopback_evidence: false`.

Gateway trust is read with a plain `GET /1.0/certificates?recursion=1` that presents the owner's client certificate. The standard `incus config trust list` sends an empty `filter=`, which servers older than this fix refuse, and `incus query` sends a JSON body (`""` without `--data`), which the certificate and discovery handlers of `opsmaru_incus` before 0.2.8 refuse ([opsmaru-incus#91](https://github.com/upmaru/opsmaru-incus/issues/91)). The plain request works against either. The runner records what `incus config trust list` returns under `findings`.

## Upgrade acceptance runner

`Integration/scripts/upgrade-acceptance.py` (task 11.6) changes the installed package under a started state with a kept workload, following [Upgrade, rollback and removal](../Packaging/homebrew/README.md#upgrade-rollback-and-removal) without running Homebrew. It takes the restart runner's state, `--incus-conf`, `--incus` and `--remote` arguments, plus:

- `--old-candidate` and `--new-candidate`: two installed pairs of different revisions, each `bin/macus` with its `libexec/macus` release (for example from `Packaging/install-local.sh --prefix`). Each must pass the pair checks against its own revision's lockfile: `--old-lock`, and `--new-lock` (default: this checkout's `server/mix.lock`).
- `--package-root`: a short isolated directory, never Homebrew's prefix, a system path or ordinary user data. Candidates are poured into `ROOT/Cellar/macus/<version>_<revision>`, and `ROOT/opt/macus` links to the installed one, as Homebrew lays out a keg. The runtime plist therefore names the stable `ROOT/opt/macus/bin/macus`.
- `--hardware`: without it, only the two candidates are checked.

```bash
python3 Integration/scripts/upgrade-acceptance.py --opt-in --hardware \
  --state-dir /tmp/macus-accept --package-root /tmp/macus-pkg/root \
  --old-candidate /tmp/macus-pkg/candidates/old --new-candidate /tmp/macus-pkg/candidates/new \
  --old-lock "$PWD/.integration/mix.lock-old" \
  --incus-conf /absolute/isolated/incus-conf --incus "$(command -v incus)" --remote macus \
  --report "$PWD/.integration/upgrade-acceptance.json"
```

It runs six transitions in order: adopt (the running pair to the old candidate in the package root), upgrade, rollback, upgrade again, removal and reinstall. Each package change stops the runtime through the server, unloads the server job and then the runtime job, and removes only owned plists: the server plist always, and both for adopt (the old runtime plist names a path outside the package root) and removal. Removal then deletes the opt link and every keg, and requires both jobs unloaded, no plist, a closed gateway port and a released runtime disk.

After every start the runner requires:

- the runtime disks (same files), settings, server credentials and trust, and the client configuration unchanged, and the same gateway certificate;
- the server plist registered for the installed revision, and the runtime plist naming the stable opt path, byte-identical across every transition;
- the kept workload with the same `volatile.uuid` and data;
- the client still trusted without enrolling again, and bearer tokens issued before the first transition still accepted over `/runtime` and `/mcp`.

On the new candidate it also checks product fixes on hardware: `incus query` of gateway trust, `incus config trust list`, `macus --json server config show` with a stored `gateway.json`, and `incus launch` of a throwaway instance (deleted afterwards). The first failure stops the sequence and keeps the state, the package root, the plists and the workload as they are.

## Linux acceptance runner

`Integration/scripts/linux-acceptance.py` (task 11.7) boots Linux workloads through the public gateway of a state started from an installed package. It takes `--state-dir`, `--prefix` (the installed package, for example `ROOT/opt/macus`), `--lock`, `--incus-conf`, `--incus`, `--remote`, `--report`, `--fixture` (default `Integration/fixtures/linux-acceptance.json`) and `--hardware`.

With `--hardware` it stops the runtime and starts it again from the installed package. The guest kernel's boot id must change, and `/1.0` must report a trusted Linux guest and its Incus server. It then creates the fixture's own project (refused if it already exists). If the gateway does not advertise the `projects` API extension, which the standard client requires for `--project` (the case with opsmaru_incus 0.2.8 and earlier, [opsmaru-incus#94](https://github.com/upmaru/opsmaru-incus/issues/94); 0.2.9 advertises it), it records that under `findings` and uses the isolated state's default project, refusing any workload name that already exists. It launches each fixture workload with the standard client: a system container, an OCI container through the fixture's own OCI remote in the isolated client configuration, and a nested virtual machine. Each must reach `Running` and pass the fixture's readiness command, with its expected output, within the fixture's timeout. A workload whose capability (`oci`, `vm`) the runtime does not report is recorded under `skipped` with the reported capabilities, never as a pass. The run succeeds only if every workload booted and passed readiness or was skipped for a capability the fixture requires, and the gateway check ran. Cleanup removes the fixture's OCI remote only if this run added it.

Boot, readiness, gateway (HTTP) and capability evidence are recorded separately under `evidence`. On success the workloads, the project and the OCI remote are removed. On failure they, the state and the server logs are kept.

## Integration acceptance

Install a standard native Incus client separately, or point `--incus` at a verified local binary. The runtime has no client dependency. The runner configures a standard `unix:` remote in an isolated client directory, because macOS clients have no implicit local server. It creates uniquely named workloads/remotes and removes workloads on success; failures preserve instances and diagnostics.

Configure dedicated read-only and writable share fixtures before creating the test runtime. Use only disposable directories: the runner writes uniquely named files and removes those files afterward. For example, create `.integration/share-fixtures/readonly` and `writable`, allow the privileged test container to access them with mode 0777, and add these entries to the prepared configuration using absolute paths:

```json
"shares": [
  {"name": "readonly", "path": "/absolute/project/.integration/share-fixtures/readonly", "read_only": true},
  {"name": "writable", "path": "/absolute/project/.integration/share-fixtures/writable", "read_only": false}
]
```

The ready-runtime test exercises an ordinary unprivileged system container, versioned `docker.io/library/alpine:3.23` OCI boot, exec/WebSocket, outbound networking, persistence across an outer restart, stopped-state disk growth verified inside the guest, cached OCI image reuse after restart, and nested VM guest-agent execution where supported. The nested VM explicitly disables Secure Boot because the selected Alpine ARM64 firmware provides the unsigned AAVMF pair, consistent with the v1 scope. A separate privileged container verifies the underlying VZ read-only and writable shares through standard Incus disk devices; this isolates share semantics from unprivileged UID mapping. Configure shares explicitly; no home directory is exposed by default.

```sh
python3 Integration/scripts/acceptance.py \
  --state-dir "$PWD/.integration/state" --incus /absolute/path/to/incus \
  --report .integration/zfs-acceptance.json
```

The opt-in relay regression first holds 80 incomplete Incus requests open while probing control status, guest health and normal Incus API requests. It then leaves one stream of 400 pipelined `/1.0` responses unread for 10 seconds. During that time, new and existing Incus connections, runtime status and guest health must each answer within 1 second, and the stalled stream must then drain completely. Pass `--export-image FINGERPRINT` to also record export throughput for a local image. Run it against an already ready isolated runtime before workload acceptance:

```sh
python3 Integration/scripts/relay-stress.py \
  --state-dir "$PWD/.integration/state" --report .integration/relay-stress.json
```

Host relays use nonblocking readiness notifications. Virtualization.framework services the whole virtio-vsock device on one serial queue, and that queue blocks while writing guest bytes into any host connection descriptor that is full. A host relay that stops reading one guest connection therefore stalls every vsock connection, including new connection requests and health probes.

The guest bridge serves only a flow-controlled relay on vsock port 8443, and its health reports `flow_relay_version: 1`. Each connection carries DATA, CREDIT and END frames. Each direction has a fixed 256 KiB window, and credit is granted only after bytes reach the local peer. As a result, the host drains every guest descriptor while buffering at most one window per direction. The guest bridge is installed once at first boot, so appliances provisioned with an older payload still serve unframed bytes on 8443 and omit the health field. Macus refuses to become ready for them and reports that the appliance must be recreated; it deletes no runtime data. Recreating an appliance deletes its Incus data, so export anything you need first.

Health also reports the guest's identity once Incus is ready. `guest_contract` is a constant in `bridge.py`, raised only when a host can no longer serve an older guest; 1 covers the flow relay. `payload_revision` and `appliance_id` come from `/etc/macus-guest`, which the seed writes beside the payload because the revision is a hash of the payload. `incus_package` is the installed `incus` package as `apk info -v` reports it, read once in the background so health never runs APK. `storage` comes from `/run/tama-storage-backend` and the root's `/etc/tama-storage` record. A field that is missing or malformed is omitted, never guessed.

A fatal listener failure exits the entire guest helper so OpenRC can restart it; transient accept failures retry. Guest health becomes available only after the relay listener starts.

Swift tests run with explicit `--no-parallel` so unrelated subprocess fixture startup does not consume another test's short deadline on CI. Concurrency and cancellation tests still launch their own concurrent work and keep their original timing assertions.

Unit tests never boot VMs. `Integration/scripts/check.sh` runs debug/release builds, Swift tests, strict formatting, shell syntax, Python compilation and guest-listener regression tests. GitHub Actions runs these and pinned OpenSpec strict validation on the `xcode-27` macOS ARM64 runner. Hardware acceptance stays opt-in on a physical supported Mac with the virtualization entitlement; hosted CI success does not establish hardware acceptance.

## ZFS qualification

Fresh appliances provision ZFS when the data disk is blank, the data disk is at least 4 GiB, and guest MemTotal is at least 3670016 KiB. The hardware-qualified host configuration is 4096 MiB RAM. The guest check does not reject every host configuration below 4096 MiB. The current LTS image pins Alpine v3.24 `linux-lts` and `zfs-lts` at 6.18.62-r0 with ZFS userland 2.4.4-r0. The prebuilt image boots its pinned kernel directly. Legacy bootstraps from the upstream Alpine base retain the expected kernel reboot handling described in the [control API](api.md). A label alone is not a recognized ext4 appliance; repair and writable mount happen only after a read-only `noload` inspection finds the Incus layout. The appliance does not change Incus-owned workload datasets. Workload reservations are requested through Incus pool configuration. Filesystem creation-time reservations are hardware-measured; zvol refreservation remains none. Mixed workloads were measured on 8–11 GiB data disks, not at the 4 GiB guest floor. A storage failure is logged in `/var/log/tama-storage.log` and readiness stays withheld; do not format or replace the disk to clear it. See the [qualification results](zfs-qualification.md).

## Recovery and safety

Keep the state directory private (0700) and sockets/config private (0600). The daemon holds a nonblocking process lock; a second process cannot replace its sockets. Custom symlink roots/endpoints are rejected, while macOS's standard /var and /tmp ancestor aliases are recognized. Darwin limits Unix socket paths to 103 bytes; use a short state path.

After daemon crash, durable configuration is loaded as stopped; readiness is never reused. A boot failure retains disks and a private `serial.log`; inspect it before stopping/retrying. The guest keeps incusd's log in `/var/log/incus/incusd.log` and its stdout/stderr, including Go panics, in `/var/log/incus/incusd.err`. At boot, `tama-incus-guard` (used by bootstrap and `tama-bridge`) restarts a crashed incusd at most twice per boot and copies `incusd| `-prefixed tails of both logs to `serial.log` after `TAMA_INCUSD_CRASHED`; a recovered boot logs `TAMA_INCUSD_RECOVERED`. When restarts are exhausted it emits `stage=failed code=incus_crashed` (or `incus_not_ready` when a live incusd stays unready for 120 s). Start then fails at once with that code, after one automatic guest restart for `incus_crashed`. If storage stop cannot export the pool and incusd's daemon is gone, it terminates processes still holding paths under `/var/lib/incus` (for example an orphaned `dnsmasq`), unmounts incusd's tmpfs mounts there and retries once, logging each step in `/var/log/tama-storage.log`; it never touches Incus datasets or a running incusd. Appliances provisioned before this payload keep their old guest scripts and get none of this guest behaviour. A graceful stop timeout leaves the running guest intact, allowing an explicit forced stop. Do not shrink or replace a live disk. Disk growth and configuration must occur while stopped. The next boot grows a recognized ext4 filesystem or expands the owned ZFS vdev with `zpool online -e`; it does not recreate the pool. A partial create retains its disks for explicit recovery/reset rather than erasing potential data. Reset with DELETE and `confirm=true` only after stopping. It destroys all appliance Incus data. Confirmed reset records durable intent before removing files; restart completes interrupted cleanup. Invalid intent or unmarked incomplete state is preserved for explicit recovery.

Guest initialization records persistent pending/started markers on a newly formatted data disk. A failure before preseed begins can retry on reboot. If preseed starts and fails or is interrupted, provisioning refuses to replay it automatically; preserve the disk and inspect diagnostics before explicit recovery/reset. Reused disks without pending initialization keep their existing Incus configuration, including custom pool names.

Do not replace root disks in place to upgrade Incus. A future upgrade protocol must back up data, validate guest/helper/Incus schema compatibility, and provide rollback. Local FileVault and account permissions are the v1 host security basis; no Secure Boot/TPM requirement is imposed.

Human CLI presentation uses the exact Noora 0.57.5 SwiftPM release, locked in
`Package.resolved`. Its library links Rainbow 4.2.2, Logging 1.16.0 and Path
0.3.8. SwiftPM also resolves ArgumentParser 1.8.2 for Noora's example executable;
Macus does not link it or replace its parser. Strict Swift 6 debug and release
builds (`-warnings-as-errors`, Xcode Swift 6.4 toolchain) passed during integration.
Always inject Macus's signal-neutral terminal and stream pipelines into Noora.
