# macus

`macus` is the single command for foreground serving, host capability discovery, local runtime control and standard Incus CLI setup. The executable delegates to the Macus library; Virtualization.framework code lives in `Sources/Macus/Virtualization`. Workload operations belong to the standard `incus` client.

## Commands

```text
macus [--state-dir ABSOLUTE_PATH] [--json] [--timeout SECONDS] <command>

serve [--state-dir ABSOLUTE_PATH]
capabilities
runtime status
runtime start
runtime stop [--force]
runtime restart
runtime upgrade [--dry-run] [--progress auto|plain|none]
runtime upgrade --rollback [ID] [--discard-data-since-upgrade] [--progress auto|plain|none]
runtime backups
runtime backups prune ID [--confirm]
doctor
client setup [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH]
start [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH] [--progress auto|plain|none]
server config show
server config set [--bind-address IP] [--port PORT] [--advertised-url URL]
                  [--certificate-file ABSOLUTE_PATH --key-file ABSOLUTE_PATH]
server config reset
server token issue --principal NAME --scope SCOPE [--scope SCOPE ...]
                   [--expires-in DURATION] --output ABSOLUTE_PATH
server token list
server token revoke ID
server trust token issue --name NAME --address HOST:PORT [--address HOST:PORT ...]
                         --server-certificate ABSOLUTE_PATH [--expires-in DURATION]
                         --output ABSOLUTE_PATH
server trust token list
server trust token revoke ID
server logs [--lines N] [--follow] [--json]
```

The `server` commands are owner-local administration of `<state-dir>/server/`: the gateway listener configuration, bearer tokens and certificate enrollment tokens. `server logs` reads the gateway access log in `<state-dir>/logs/`. They require an existing state directory, never start or restart a service, contact the runtime or Incus, or touch VM disks, do not accept `--timeout`, and never print a token. `macus start` also prepares the local CLI's own runtime token once in `<state-dir>/server/local-cli.token`. See [the Macus server](server.md) for HTTPS configuration, gateway trust and credential rotation.

`macus` and `macus --help` print this contract and exit 0. For client commands, global flags may appear around the command. `macus serve` runs the foreground daemon and accepts only its optional `--state-dir` after `serve`; `macus capabilities` reports host capabilities without contacting the daemon or booting a guest. Serve does not accept JSON/timeout flags. Capabilities accepts only `--json`, before or after the command; its default output is human-readable. Scripts that previously parsed unflagged capabilities must request `macus capabilities --json` or `macus --json capabilities` to retain the existing HostCapabilities object. `--force` is valid only on `runtime stop`. `--dry-run` and `--rollback` are valid only on `runtime upgrade`, and not together; `--discard-data-since-upgrade` only with `--rollback`; `--confirm` only on `runtime backups prune`. A word after `--rollback` is taken as the backup ID only when it has the backup ID form. `--remote`, `--set-default` and `--incus` are valid on `start` and `client setup`. `--progress` is valid only on `start` and `runtime upgrade` (with `--dry-run` or `--rollback` too). `list`, `show` and other workload commands fail before networking or installation. The default remote name is `macus`. `--incus` must be an absolute executable and skips PATH and Homebrew; it is the isolated-acceptance hook.

`start` is the high-level first-use command. It validates the host, entitlement and Incus/Homebrew prerequisite, acquires the pinned Alpine appliance, prepares its seed, activates the per-user background services when no compatible ones are serving, creates an absent runtime, waits through the expected kernel restart, and registers the standard Incus client. `serve`, `runtime`, `doctor` and `client setup` stay explicit lower-level commands. They do not download an appliance or activate a service. `runtime start` still fails when the runtime has not been created and does not provision an absent installation. `runtime upgrade` is the one lower-level command that downloads an appliance and activates the jobs; see [Appliance upgrade](#appliance-upgrade).

### Service pair

Each state has two per-user launchd jobs: `com.upmaru.macus` runs `<prefix>/bin/macus serve --state-dir STATE` (the Swift daemon that owns the VM), and `com.upmaru.macus.server` runs the bundled-ERTS release launcher `<prefix>/libexec/macus/bin/macus start` in the foreground with `MACUS_STATE_DIR=STATE`, `MACUS_SERVE=1`, `RELEASE_DISTRIBUTION=none` and `MACUS_EXPECTED_REVISION` (this executable's source revision, which the release's own build must equal before it serves) in its environment. A Homebrew installation registers both through the stable `opt/macus` link. The default state uses those labels with plists in `~/Library/LaunchAgents`. Any other state gets the same state-hash suffix on both labels (`com.upmaru.macus.<hash>`, `com.upmaru.macus.server.<hash>`), keeps both plists in `STATE/launchd/` so neither is loaded at login, and leaves the default jobs untouched. Logs are `STATE/logs/service.*.log` and `STATE/logs/server.*.log`, and the server's gateway access log `STATE/logs/gateway-access.log` (see [Gateway access log](#gateway-access-log)).

Before starting or creating either job, `start` reads both from `launchctl print`. Each job's actual program, full arguments and, for the server, its environment's selected state and serve flag must match; otherwise start fails with `conflict` and preserves the plist and runtime data. A plist that targets the state through its arguments or `MACUS_STATE_DIR`/`TIM_STATE_DIR`, but is a legacy job or outside the `com.upmaru.macus` namespace, is also a conflict. No third job (Opsmaru or other) is ever created. A matching running job is waited for, a matching stopped job is kickstarted alone, and an absent one is bootstrapped, Swift first. Recovering the server job never stops or restarts the Swift job or the VM. A foreground `macus serve` is reused as before. A server already answering an authenticated `/runtime/status` on the state's pinned published endpoint is reused outside launchd; a port that merely accepts connections is not. A server job registered by another package revision (only its `MACUS_EXPECTED_REVISION` differs) is a `conflict` that names the `launchctl bootout` and plist removal to perform; start never replaces it.

No `macus` command stops or unloads the pair. Before changing the package, run `runtime stop`, unload the server job and then the Swift job with `launchctl bootout`, and remove the server job's plist (both plists for removal). [Upgrade, rollback and removal](../Packaging/homebrew/README.md#upgrade-rollback-and-removal) gives the exact sequence and what it keeps: runtime disks, server credentials and the Incus client configuration.

Before any appliance download, job activation or guest request, start also checks the server side inside the bootstrap lock and the same deadline. The selected `server/gateway.json` (if any) must be valid and its certificate and key acceptable, as `macus server config` requires. Unless a server already serves the state outside launchd, the release that launchd would run must be paired with this executable: launcher, `releases/` and exactly one bundled `erts-*`; a `macus-build.json` at the release root (schema 1, not writable by others) whose `version` and `revision` equal this executable's embedded `MacusVersion` and `MacusSourceRevision`; and exactly one `lib/opsmaru_incus-<version>` at the version that record names, whose application resource declares it. A plain `swift build` records no identity and cannot be paired. Any mismatch fails with `invalid_configuration` and reinstall guidance; nothing is downloaded, no job is started or created and the guest is not contacted.

Once both jobs serve, every lifecycle request `start` makes goes through the server's public `/runtime` API over the same pinned HTTPS endpoint and local credential as `runtime`: `POST /runtime/create` for an absent runtime, `GET /runtime/status`, `POST /runtime/start` with `{"remaining_seconds": N}` (the rest of the start deadline), `GET /runtime/progress` (including the expected kernel restart), and live readiness from `GET /runtime/health` and `GET /runtime/capabilities`. The private `runtime.sock` is only used to identify a Swift daemon that is already serving the state while the jobs are activated. If the connection to the server is lost while the boot request is outstanding, Swift may already have accepted it, so start never sends it again: it keeps reading the status through the server, within the same deadline, while the server restarts. A runtime that becomes ready completes the start. One that is no longer starting is reported as `unavailable`, so you can rerun `macus start`. An interrupt reports the runtime state the server last observed and leaves the guest running.

State directory precedence is `--state-dir`, then `MACUS_STATE_DIR`, then legacy `TIM_STATE_DIR`, then `~/.tama/incus-mac`. Every selected path must be absolute. Selecting it does not create the directory. Status, doctor and lifecycle commands never run `brew` or change Incus client configuration.

Timeout is an integer from 1 to 3600 seconds and one monotonic deadline for each request or subprocess, including connect, write, read and child output. The default is 10 seconds for status, doctor and `runtime backups`, and 650 seconds for runtime start, stop, restart, `runtime upgrade --dry-run`, `runtime upgrade --rollback`, `runtime backups prune` and client setup. `runtime upgrade` defaults to 1800 seconds, like `start`, because it downloads the appliance and boots the new root. `macus start` defaults to 1800 seconds so first provisioning, the expected kernel restart and client installation share one deadline. Later stages, including each Incus or Homebrew child, receive only the remaining whole seconds. A partial second is not rounded up into a new per-command timeout. Standalone `client setup` still gives each of its own commands the selected timeout. Restart includes shutdown plus boot. Setup uses the 650-second default because installing the Incus CLI can be slow. Raise `--timeout` when those operations need longer.

`--progress auto` animates on an interactive stderr terminal whose `TERM` is not `dumb`. Redirected stderr, `TERM=dumb`, `--progress plain` and `--json` use plain stage lines without cursor escapes. `--progress none` suppresses progress. `--json` writes one result object to stdout. Progress, when enabled, stays on stderr. Byte percentages appear only when a trustworthy total length is known. Exit 130 means start was interrupted; the command does not force-stop a daemon-owned guest.

The `start --json` result keeps its fields: `ready`, `connected`, `remote`, `incus`, `installed`, `next_commands`, `state_directory`, `capabilities`, optional `path_guidance`, and `service_ownership` (`launchd` or `foreground`) with `service_label` under launchd, both describing the Swift runtime service. It adds the Elixir server's `server_ownership`, its `server_label` under launchd, and `server_endpoint` (`url` and `certificate_fingerprint`, the public endpoint the CLI pins). The human report adds a matching Server section. A start is successful only when the runtime is ready and the client is connected. Anything less exits 1 (or 130 when interrupted) with no result on stdout and the usual error object. Once both services were serving, the error message also says what start left in place: the runtime service and the server, each as its launchd label or a foreground process, and the server URL. Start never stops, unloads or replaces either job, and it activates nothing besides that pair. The failed progress row keeps the stage's own message.

Exit status is 0 on success, 1 on operational failure and 2 on invalid arguments. `--json` writes the result to stdout. Operational and usage errors go to stderr as `{"error":{"code":"...","message":"..."}}` when `--json` is set. Setup installation progress also goes to stderr so the JSON result stays valid. Stable codes include `conflict`, `timeout`, `unavailable`, `invalid_configuration`, `invalid_request` and `io`.

### Gateway access log

While it serves, the Macus server appends one JSON line per finished native Incus exchange to `STATE/logs/gateway-access.log`: relayed HTTP requests, locally served discovery and trust, WebSocket and raw (SFTP/NBD) upgrades, and refused requests. A line is written when the exchange has really ended, so a stream appears when it closes. Requests to `/runtime` and `/mcp` are not recorded here.

```json
{"v":1,"id":"9c1f6a02b47de853-4127","time":"2026-11-23T10:15:02.412Z","protocol":"http","method":"GET","path":"/1.0/instances/web","project":"default","target":null,"all_projects":false,"operation":null,"peer":"192.168.1.20:51422","certificate":"3f9a…","admitted_as":"caller","status":200,"outcome":"ok","reason":null,"duration_ms":12,"request_bytes":0,"response_bytes":1834}
```

- `v` is the schema version. Adding a key keeps it; renaming or removing one increments it. Keys appear in the order above.
- `id` is `BOOT-SEQ`. `BOOT` is 64 random bits chosen when the server starts, as 16 lowercase hexadecimal digits, so ids from different server runs do not collide. `SEQ` is a decimal counter from 1 for that run. Within one run it orders the records, and a gap marks a record that was not written. Concurrent exchanges can reach the file slightly out of `SEQ` order.
- `time` is when the exchange ended, UTC with milliseconds. `peer` is `address:port`, IPv6 in brackets.
- `certificate` is the SHA-256 of the client certificate the caller presented, or `null`. With `admitted_as: "caller"` it is the trusted certificate that authorized the request; for a refusal it is only what was presented.
- `admitted_as` is `caller`, `anonymous`, `operation_peer`, `image_peer`, or `null` when the request was not admitted. `outcome` is `ok` when the exchange completed as relayed or served, whatever the native status, otherwise `not_sent`, `uncertain` or `sent`, with a `reason` such as `unauthorized`, `capacity`, `revoked`, `idle`, `lifetime` or `caller_closed`. `project` is `null` when the caller selected none.
- `duration_ms`, `request_bytes` and `response_bytes` count the exchange's lifetime and body (or frame payload, or tunnelled) bytes each way.
- `dropped_before: N` follows the other keys on the first line written after `N` records were dropped.

The log never contains bearer or enrollment tokens, `authorization` values, query strings, operation or image secrets, headers, bodies, WebSocket frames, private keys or certificate bodies. The server writes only the keys above and ignores any other value the shared library supplies.

The log is bounded and owner-private: it rotates at 10 MiB and keeps 5 archives (`gateway-access.log.0`, newest, to `gateway-access.log.4`, oldest), at most about 60 MiB. The files are created 0600 (the release runs with `umask 077`) inside the 0700 `STATE/logs`, which the server creates only when absent. An unsafe `STATE/logs` disables the access log with one error line in the server's launchd log and the gateway still serves. Recording never delays an exchange: when the writer falls behind, records are dropped, counted and marked with `dropped_before`. This is an access log, not an audit trail: a dropped record, a handler error or a crash between the exchange and the write loses a line, and no line is signed.

`macus server logs` prints the most recent records, newest last, reading the files directly after checking that the state directory and `STATE/logs` are owner-private (otherwise it fails with `invalid_configuration`). It contacts neither the server nor the runtime, so it works while the server is stopped, and it starts, issues and changes nothing. `--lines N` (1 to 100000, default 50) reads into the archives, oldest first, when the current file holds fewer lines. Human output is one row per exchange: time, caller (certificate prefix, `anonymous`, `operation-peer`, `image-peer` or `refused`), status, method and path, outcome and reason when not `ok`, duration and bytes in and out; malformed lines are skipped and counted. `--json` prints the stored lines unchanged, one per line. `--follow` keeps printing new records across rotation, without repeating or skipping one, until interrupted (exit status 130). Without a log, the command prints nothing and exits 0.

## Appliance upgrade

`start` never replaces the root disk of an existing state. The daemon records each ready guest's contract, guest payload revision, appliance and Incus package beside the disks. With that record, `start` and `runtime status` report `upgrade_available` when the appliance or payload is older than the installed package's, and `start` refuses with `conflict` before booting a guest this Macus can no longer serve. A state without a record is booted and probed; a guest without the flow-controlled relay is then stopped gracefully, recorded, and reported as `unavailable`. Each message names `macus runtime upgrade`, and no runtime data is removed.

```text
macus runtime upgrade --dry-run
macus runtime upgrade
macus runtime upgrade --rollback [ID] [--discard-data-since-upgrade]
macus runtime backups
macus runtime backups prune ID [--confirm]
```

`runtime upgrade` activates the runtime and server jobs the way `start` does, under the same bootstrap lock, but boots nothing, so it works after `start` refused the guest. It then asks the daemon for a read-only plan (`POST /runtime/upgrade/plan`). The plan is refused for an ext4 state, an older target Incus package, a pool identity that cannot be found (neither `runtime/storage-identity.json` nor a `TAMA_STORAGE_ZFS_READY` line in `serial.log`) or too little free space. Otherwise it names:

- the current and target catalog IDs;
- the class: `reversible` when the recorded Incus package equals the target's exactly, `migrating` when the target is newer or the recorded one is unknown;
- the data copy: none, a `clonefile(2)` clone, or a full copy where the volume cannot clone;
- the space needed, and that every workload restarts.

The human output prints the plan before anything is stopped. `--dry-run` ends there, and downloads, stages and stops nothing. A state that is already current reports so and changes nothing.

Otherwise the command acquires the appliance this executable ships (never a draft qualification catalog) and stages its root with an upgrade seed in `STATE/upgrade-<id>/`. It then posts the staging ID (`POST /runtime/upgrade`); if that request certainly never reached the runtime service, the staging is removed. A plan from a runtime service still running from another package (another appliance or guest payload) is refused, even when it reports nothing to do. `runtime stop` does not end that process: the refusal names the `launchctl bootout` of the runtime job, after which the next `runtime upgrade` starts it from the installed package; a foreground `macus serve` is ended and started again by hand. The daemon re-plans, verifies the staged root against the installed catalog and the seed against the planned pool, and then:

1. closes Incus to clients until the upgrade ends, waits for running Incus tasks and reads the Incus inventory of a ready guest; a stopped guest, or one whose start was refused, is not read, so the comparison is skipped and the result says so (check the inventory it returns);
2. stops the guest gracefully (a timeout leaves it running with nothing moved);
3. journals every file in `STATE/upgrade.pending`;
4. clones the data disk for a migrating upgrade;
5. moves the old root, firmware store and seed into `STATE/backups/<id>/`;
6. boots the new root, which adopts the existing pool by its GUID without force;
7. requires the same pool, a compatible guest and, when it was read, every earlier instance, volume, network and profile name in Incus, then commits.

Instances come back according to their own Incus autostart settings; the upgrade starts, stops and changes none. Any failure after the stop restores the previous files, and for a migrating upgrade the data disk copy, and the command names the failure. An interrupted upgrade is rolled back the next time the daemon starts. `--json` writes `{"upgraded":true,"plan":...,"result":...}`; a dry run writes `{"dry_run":true,"upgraded":false,"plan":...}` and a current state `{"upgraded":false,"plan":...}`. The human result names the new appliance, the backup ID and the inventory comparison.

`runtime upgrade --rollback` restores the latest backup that still holds a root, or the one named, and leaves the runtime stopped; `start` then boots it. A root never boots against data at a different Incus package or holding a different pool:

- when the backup's Incus package and pool equal the current data's, only the root, firmware store and seed are restored and the data disk stays;
- otherwise its own data copy, or the earliest later backup's copy at its package and pool, is restored with it;
- otherwise rollback is refused.

Restoring a data copy discards everything written since that copy, so it needs `--discard-data-since-upgrade`, and the error without it names when that copy was taken. Rollback only renames files. The state it replaces becomes a new backup, so a rollback can itself be rolled back.

Upgrade, its dry run and rollback show progress on stderr with the same native steps, `--progress` modes and `--json` handling as `start`, and end with a resolved-stage count (`Upgrade: 9/9 stages resolved`, `Upgrade dry run: 3/3`, `Rollback: 5/5`). Upgrade steps: checking the host, activating the service, planning, downloading the appliance (a measured bar, or `Skipped download` when the verified cache is reused), verifying it, staging the new root and seed, stopping the runtime, booting the new appliance and verifying the pool and inventory. Rollback steps: checking the host, activating the service, checking the backup, stopping the runtime and restoring the backup. A dry run, or a runtime that is already current, ends after planning. The plan table is printed between planning and the download, before anything is stopped. While the runtime service works, the client reads `GET /runtime/progress` and advances the steps from its `upgrade` or `rollback` phases (for example reading the inventory, copying the data disk, the guest's own boot phases, restoring the previous state after a failure); the last steps resolve only with the runtime service's answer. A stop the runtime service did not need, because the runtime was already stopped, is shown as skipped. A failure marks the step it happened in before the error. Interrupting the command still ends it at once; an animated display restores the cursor first.

`runtime backups` lists each backup with its time, operation, class, catalog IDs, Incus package, whether it holds a data copy, its allocated size and whether it can be restored now. Nothing removes a backup automatically, and runtime reset keeps them. `runtime backups prune ID` without `--confirm` removes nothing and names any backup that depends on that one's data copy; with `--confirm` it removes it.

None of these commands runs a package manager or changes the installed package. To change the package itself, follow [Upgrade, rollback and removal](../Packaging/homebrew/README.md#upgrade-rollback-and-removal). These commands have passed unit and fixture tests; hardware acceptance is recorded separately in [the acceptance record](acceptance.md).

## Outer runtime and the standard Incus CLI

`runtime` commands and `doctor` describe the outer Apple VZ appliance through the Macus server's public `/runtime/*` API (see [the API contract](api.md#public-runtime-api)). `runtime stop` sends `{"force":false}`; `runtime stop --force` sends `{"confirm":"force-stop","force":true}`. These commands do not list or mutate instances. `runtime upgrade` reads instance, volume, network and profile names through Incus to compare them and changes none.

`client setup` reads `/runtime/status` from the Macus server and continues only when API version is 1, the outer runtime is ready and `runtime_ready` is not false. It does not boot a stopped appliance, and a stopped runtime leaves Incus client configuration, `INCUS_CONF` and gateway trust untouched. It then registers the server's public HTTPS endpoint from `server/endpoint.json` (for example `https://127.0.0.1:8443`), using only standard `incus` commands under the caller's `INCUS_CONF`; it never writes Incus configuration itself and never registers the private `incus.sock`. For a new remote it asks `incus remote get-client-certificate` for the certificate the client will present (incus creates one if there is none) and enrolls that certificate in gateway trust. Usually that means issuing an expiring (5-minute) single-use enrollment token, recorded in `server/trust-tokens.json` and bound to that certificate's SHA-256 fingerprint, and running `incus remote add NAME TOKEN`. The token names the gateway certificate, so incus checks the server before sending it. Because the token is on that command line, the server refuses it, without consuming it, from any other certificate, and setup revokes it if `incus remote add` fails. When the gateway already trusts the certificate (another remote name for the same client), setup runs `incus remote add NAME URL` and answers incus's certificate prompt with the pinned fingerprint instead of issuing a token. Either way `incus query NAME:/1.0` must then report the client trusted by a server presenting the endpoint's certificate, and `incus list NAME:` must succeed, so instance listing stays an Incus operation. Repeating setup for a remote that already names this endpoint issues nothing and only repeats those checks; if they fail (the client's trust was removed, or the remote stored an earlier server identity), setup reports it and leaves the remote alone. A name that points elsewhere fails with `conflict` and is not overwritten. A name holding a direct-socket `unix:` registration from an earlier macus is also a `conflict`: keep it and choose another `--remote`, or remove it yourself with `incus remote remove NAME` and rerun. The default remote changes only with `--set-default`. Unrelated remotes, projects, aliases and certificates are left in place.

If `--incus` is omitted, setup uses an `incus` executable on `PATH`. Otherwise, when Homebrew is already installed (`PATH`, `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`), it runs `brew install incus` for the official formula and discovers the binary through `brew --prefix` even if that bin directory is not on `PATH`. `HOMEBREW_NO_AUTO_UPDATE=1` is set when absent so setup does not update unrelated formulae. An existing Homebrew copy is reused without reinstalling. If Homebrew is missing, setup tells the operator to install it from https://brew.sh and does not install Homebrew, use a shell installer, sudo, another package manager or a custom tap. `MACUS_BREW_FALLBACK=0` disables the two standard Homebrew locations for tests; users should not set it.

Subprocesses use fixed argument arrays, preserve the relevant environment, drain bounded output while the child runs, and are terminated and reaped on failure, deadline or cancellation. Full client configuration and credentials are not printed.

## Transport limits

`runtime`, `doctor` and the readiness check in `client setup` use only the published HTTPS server. The client reads `<state-dir>/server/endpoint.json` and its own credential `<state-dir>/server/local-cli.token`, both 0600 regular files owned by the current user in the 0700 `server` directory, opened without following links and with safe ancestry; it creates and repairs nothing. The endpoint must be schema version 1 with an `https` base URL (no user information, path, query or fragment) and a lowercase SHA-256 `certificate_fingerprint`. Each request sends `Authorization: Bearer` with that credential to a `/runtime/*` path only, requires TLS 1.3 and the exact leaf certificate the metadata records (checked before any request byte is sent), and uses no proxy, cache, cookies, stored credentials or redirects. A missing endpoint or credential, a refused connection or a rejected credential is `unavailable` and asks for `macus start`; the client never falls back to `runtime.sock`. Responses are limited to 16 MiB and the selected timeout is one deadline for the whole exchange.

`macus start` still reaches the daemon directly, only to recognize one that is already serving, while it activates the services. It opens a new nonblocking Unix connection per control request. Headers are limited to 16 KiB and bodies to 16 MiB. It accepts content-length, chunked and connection-close bodies, and rejects ambiguous or truncated framing. Before connecting, it rejects unsafe symlink ancestry, a non-socket endpoint, and a socket or parent directory that is not mode-private and owned by the current user. The peer UID must match. These checks do not create or chmod state.

## Installation

Local installation from source requires Swift and Elixir/Erlang and is documented in [development](development.md) and [packaging](../Packaging/README.md). It installs the release executable with the virtualization entitlement at `<prefix>/bin/macus` and the paired Macus server release at `<prefix>/libexec/macus`, both recording one Macus version and source revision. It does not install the Incus CLI, register or activate a launch agent, or create runtime state. `macus client setup` is the explicit later step for the standard Incus CLI. On an installation without a paired release, `macus start` fails with `invalid_configuration` and reinstall guidance before any download, job activation or guest request. A server already serving the state outside launchd is the exception. The release bundles its own ERTS and the `:opsmaru_incus` library, which needs no separate install, job or activation. Production signed, notarized or Homebrew delivery of the release remains future work.

`macus` replaces both legacy executable names. The existing state path and persisted formats are retained. New registrations use `macus`; pass `--remote tama-mac` to reuse the earlier default remote.

Human reports use readable labels and explicit Supported, Unsupported and
Unavailable observations. `doctor` groups Runtime, Host support, Workload support
and Guest health. Host nesting and host file-sharing support appear only in Host
support; Workload support reports effective container/OCI/VM availability,
separately from usable guest KVM and configured nesting. Missing live observations
are unavailable; only JSON includes the full API-extension list. Paths, failure details and next commands are printed in full.

The following are presentation examples based on fixtures, not hardware evidence.
Spacing and optional Noora table borders depend on terminal width.

```text
Macus is ready

Runtime
  Status: Ready
  State directory: /tmp/macus-demo

Client
  Connection: Connected
  Remote: macus
  Executable: /opt/homebrew/bin/incus
  Installation: Reused existing client

Service
  Ownership: Foreground
  Closing the owning terminal stops the daemon.

Server
  Ownership: Launchd
  Label: com.upmaru.macus.server
  Endpoint: https://127.0.0.1:8443

Next steps
  incus list macus:
```

```text
Macus runtime: Stopped

Runtime
  Status: Stopped
  Uptime: 1m 12s
  Server: https://127.0.0.1:8443

Next steps
  macus --state-dir /tmp/macus-demo runtime start
```

```text
Incus client is connected

Client
  Connection: Connected
  Remote: macus
  Endpoint: https://127.0.0.1:8443
  Executable: /opt/homebrew/bin/incus
  Installation: Reused existing client
  Default remote: Existing selection preserved

Next steps
  incus list macus:
```

A stopped doctor fixture reports `Macus needs attention`, retains the runtime
status and any last error, labels missing host/workload/guest observations
Unavailable, and offers `macus --state-dir /tmp/macus-demo runtime start`.
Incompatible API versions offer `macus --help`; failed or changing runtimes offer
an explicit status inspection. A healthy fixture reports `Macus is healthy`.

Interactive startup counts **resolved stages out of nine**, counting complete
and skipped stages once. This is not a time percentage or ETA. Only a successful
live-ready and connected startup result confirms completion. Acquisition can
show a separate measured byte percentage when the total is positive; unknown
length downloads show bytes and elapsed time. Waits name the observed stage. A fresh prebuilt LTS start shows image
verification before storage preparation. Noora's 30-cell download bar is used where it fits;
compact text or plain output handles narrow, unknown or resized widths.

Illustrative progress (fixtures, not a VM run):

```text
✔︎ Host checked [0.1s]
⠋ Downloading appliance 128.0 MiB / 785.4 MiB, 16% (3s)
⠋ Provisioning Linux (1m 12s) | Verifying installed appliance image
```

Stages use Noora’s native progress-step component: completed stages retain a
checkmark and elapsed time, failures retain a cross, and skipped stages explicitly
name the reused resource. Macus owns the spinner refresh and cursor cleanup.
Completed lines and human reports return to the left margin even when the terminal
disables automatic newline translation.

Plain mode preserves state/detail transitions immediately and throttles repeated
byte/elapsed updates to at most one per five seconds. Automatic refresh is
bounded to ten frames per second. `TERM=dumb`, redirected stderr and JSON use
plain output, while `NO_COLOR` suppresses optional styling. `--progress none`
suppresses progress entirely. The active row and cursor are restored before any
final result or error. Human diagnostic lines escape controls, including embedded
newlines; bounded Homebrew diagnostics retain their deliberate line boundaries.
