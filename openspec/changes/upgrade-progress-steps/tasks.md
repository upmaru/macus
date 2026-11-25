# Tasks

## 1. Progress model

- [x] 1.1 Add the upgrade and rollback stages to `StartupStage` with readable active, success and skipped labels, and give the ledger and sink a per-operation stage count and summary title, keeping start's nine stages and `Startup:` line; verify with ledger and sink tests.

## 2. Upgrade and rollback steps

- [x] 2.1 Render `runtime upgrade`, `--dry-run` and `--rollback` through `TerminalProgressSink`: activation events, plan, download with byte progress or a skipped download for a verified cache, verification, staging, and the dispatch steps driven by `GET /runtime/progress` phases; mark the active stage failed before the error alert; finish progress before any table or JSON is written.
- [x] 2.2 Accept `--progress auto|plain|none` on `runtime upgrade`, update help and `docs/cli.md`.
- [x] 2.3 Restore the terminal when an animated upgrade is interrupted, keeping today's interruption behaviour.
- [x] 2.4 Verify with Swift tests: the step sequence for upgrade, dry run and rollback, the phase-to-step mapping (monotonic, skipped stop, rollback inside the upgrade), failure rendering at the failing stage, `--progress none`, and `--json` stdout objects unchanged with progress only on stderr.

## 3. Verification

- [x] 3.1 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`.
