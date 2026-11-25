# Spec Delta

## ADDED Requirements

### Requirement: Runtime upgrade progress

`runtime upgrade`, its dry run and `--rollback` SHALL report progress on stderr through the same stage renderer and terminal rules as start: one native step per stage, activity and elapsed time while a stage is active, its elapsed time when it resolves, a failure marker naming the stage that failed, and a final resolved-stage count for the operation. Upgrade SHALL identify host checks, service activation, planning, appliance download, appliance verification, staging, stopping the runtime, booting the new appliance and verifying the pool and inventory; a dry run and a current runtime SHALL end after planning. Rollback SHALL identify host checks, service activation, checking the backup, stopping the runtime and restoring the backup. The download SHALL show measured byte progress when its length is known and SHALL be shown as skipped when a verified cached appliance is reused. While the runtime service performs the upgrade or rollback, the client SHALL advance the steps from the phases the runtime service reports for that operation, never moving back to an earlier stage, and MUST NOT report the operation complete before the runtime service's response. `runtime upgrade` SHALL accept `--progress auto|plain|none` with start's meaning. `--json` SHALL keep the upgrade, dry run and rollback stdout objects unchanged and SHALL keep progress on stderr without animation. Plan, result and backup tables and error messages SHALL be unchanged and SHALL begin after progress has finished.

#### Scenario: Interactive upgrade

- **WHEN** `macus runtime upgrade` runs on an interactive terminal
- **THEN** each stage is shown as a native step with a spinner while active and its elapsed time when done, the plan table is shown before the runtime is stopped, and the result table follows a final resolved-stage count

#### Scenario: Long upgrade dispatch

- **WHEN** the runtime service is stopping the guest, booting the new root or comparing the inventory
- **THEN** the active step names that stage and its elapsed time instead of showing nothing until the response

#### Scenario: Failed stage

- **WHEN** a stage of the upgrade or rollback fails
- **THEN** that stage is shown with a failure marker before the error message, and no later stage is shown as started or complete

#### Scenario: Refused rollback

- **WHEN** the runtime service refuses a rollback before stopping anything
- **THEN** the backup check is shown as failed and no stop step is shown

#### Scenario: Redirected or machine output

- **WHEN** `macus --json runtime upgrade` runs, or stderr is redirected
- **THEN** stdout carries only the unchanged JSON object or human result, and progress on stderr has no cursor escapes or animation

#### Scenario: Progress disabled

- **WHEN** `macus runtime upgrade --progress none` runs
- **THEN** no progress is written while the plan, result and errors remain available
