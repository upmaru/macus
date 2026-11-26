# Proposal

## Why

`macus runtime upgrade` gives almost no feedback while it works. It activates the services silently, ignores the appliance download's byte progress, prints three plain lines to stdout, and then shows nothing during the longest wait: the runtime service's upgrade dispatch, which stops the guest, boots the new root, adopts the ZFS pool and compares the Incus inventory (about 40 to 50 s on hardware). `--rollback` prints one line and then waits silently. `macus start` already renders native Noora steps for the same kind of work: a spinner per active stage, the elapsed time when it resolves, a clear failure marker, a measured download bar and a final resolved-stage count.

## What Changes

- `runtime upgrade`, `runtime upgrade --dry-run` and `runtime upgrade --rollback` render their stages through the same progress sink and stage model as `start`, on stderr: one native step per stage, a spinner while active, its elapsed time when done and a failure marker naming the stage that failed.
- Upgrade stages: host check, service activation, plan, appliance download (with the measured bar, or skipped when the verified cache is reused), appliance verification, staging the new root and seed, stopping the runtime, booting the new appliance and verifying the pool and inventory. A dry run, and an upgrade whose plan says the runtime is current, stop after the plan. Rollback stages: host check, service activation, checking the backup, stopping the runtime and restoring the backup.
- During the dispatch the client polls the runtime service's existing `GET /runtime/progress` (operation `upgrade` or `rollback` and its phase) and advances the steps from the observed phases without moving back. Phases it misses still resolve in order when the request returns.
- `runtime upgrade` accepts `--progress auto|plain|none` with start's meaning. `--json` keeps its stdout objects unchanged and, as for start, keeps progress on stderr without animation.
- The plan, result and backup tables and the error alert are unchanged. The three plain progress lines and the rollback's "Checking backup" line move from stdout into the steps.
- Interrupting an animated upgrade restores the cursor before the process ends as it does today; the runtime service's handling of an interrupted client is unchanged.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `client-cli`: progress steps for runtime upgrade, its dry run and rollback, and `--progress` on `runtime upgrade`.

## Impact

`Sources/Macus/Client/RuntimeUpgrade.swift`, `Sources/Macus/Client/MacusCLI.swift` (grammar and help), `Sources/Macus/Bootstrap/StartupModels.swift`, `ProgressRenderer.swift` and `TerminalProgressSink.swift` (stage labels and a per-operation stage count and summary title), `docs/cli.md`, and the upgrade CLI and progress presentation tests. No daemon, API, server, guest payload or data format changes. Start's rendering and its nine-stage count are unchanged. Hardware acceptance is not required for this presentation change and stays opt-in.
