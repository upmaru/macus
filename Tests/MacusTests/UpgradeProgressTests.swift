import Foundation
import Testing

@testable import Macus

private func steps(
  _ action: RuntimeUpgradeAction, into sink: any StartupProgressSink = CollectingProgressSink()
) -> UpgradeSteps {
  UpgradeSteps(
    sink: sink, action: action, operationID: "upgrade-fixture", started: .now, now: { .now })
}

private func transitions(_ sink: CollectingProgressSink) -> [String] {
  sink.snapshot().map { "\($0.stage.rawValue):\($0.state.rawValue)" }
}

@Test func upgradeOperationsCountTheirOwnStagesAndKeepStartsNine() {
  #expect(ProgressOperation.startup.stages == 9)
  #expect(ProgressLedger().count == "0/9 stages")
  #expect(RuntimeUpgradeAction.upgrade(dryRun: false).progressOperation.stages == 9)
  #expect(RuntimeUpgradeAction.upgrade(dryRun: true).progressOperation.stages == 3)
  #expect(RuntimeUpgradeAction.rollback(id: nil, discardData: false).progressOperation.stages == 5)
  // Without a confirmation stage, every resolved stage counts at once.
  var ledger = ProgressLedger(
    operation: RuntimeUpgradeAction.rollback(id: nil, discardData: false)
      .progressOperation)
  for stage in [StartupStage.preflight, .serviceActivation, .backupCheck, .runtimeStop] {
    _ = ledger.observe(
      StartupProgressEvent(
        operationID: "o", stage: stage, state: stage == .runtimeStop ? .skipped : .complete,
        elapsedSeconds: 0))
  }
  #expect(ledger.count == "4/5 stages")
  #expect(ledger.bar == "[####-]")
  for stage in [
    StartupStage.upgradePlan, .upgradeStaging, .runtimeStop, .upgradeBoot, .upgradeVerification,
    .backupCheck, .backupRestore,
  ] {
    #expect(
      !stage.label.isEmpty && !stage.successLabel.isEmpty && stage.label != stage.successLabel)
  }
  #expect(StartupStage.runtimeStop.skippedLabel == "Skipped stop (runtime was not running)")
}

@Test func upgradePhasesAdvanceTheStepsInOrderAndNeverMoveBack() {
  let action = RuntimeUpgradeAction.upgrade(dryRun: false)
  for (phase, stage) in [
    ("reading_inventory", StartupStage.runtimeStop), ("stopping", .runtimeStop),
    ("copying_data", .upgradeBoot), ("booting", .upgradeBoot), ("packages", .upgradeBoot),
    ("expected_reboot", .upgradeBoot), ("incus_recovery", .upgradeBoot),
    ("verifying", .upgradeVerification), ("ready", .upgradeVerification),
  ] {
    #expect(action.dispatchStage(phase: phase) == stage, "\(phase)")
  }
  #expect(action.dispatchStage(phase: "rolling_back") == nil)

  let sink = CollectingProgressSink()
  let tracker = steps(action, into: sink)
  tracker.beginDispatch(runtimeWasStopped: false)
  tracker.observe(operation: "upgrade", phase: "reading_inventory", expectedReboot: false)
  tracker.observe(operation: "upgrade", phase: "stopping", expectedReboot: false)
  // Another operation's progress, an absent phase and a stale earlier phase change nothing.
  tracker.observe(operation: "start", phase: "verifying", expectedReboot: false)
  tracker.observe(operation: "upgrade", phase: nil, expectedReboot: false)
  tracker.observe(operation: "upgrade", phase: "copying_data", expectedReboot: false)
  tracker.observe(operation: "upgrade", phase: "stopping", expectedReboot: false)
  tracker.observe(operation: "upgrade", phase: "expected_reboot", expectedReboot: true)
  tracker.observe(operation: "upgrade", phase: "verifying", expectedReboot: false)
  // Resolution waits for the runtime service's answer, not its `ready` phase.
  tracker.observe(operation: "upgrade", phase: "ready", expectedReboot: false)
  #expect(!transitions(sink).contains("upgrade_verification:complete"))
  tracker.closeDispatch(succeeded: true)
  tracker.observe(operation: "upgrade", phase: "booting", expectedReboot: false)

  let events = sink.snapshot()
  #expect(
    transitions(sink) == [
      "runtime_stop:active", "runtime_stop:active", "runtime_stop:active",
      "runtime_stop:complete", "upgrade_boot:active", "upgrade_boot:active",
      "upgrade_boot:complete", "upgrade_verification:active", "upgrade_verification:active",
      "upgrade_verification:complete",
    ])
  #expect(events[1].detail == "reading_inventory")
  #expect(events[2].detail == nil)
  #expect(events[4].detail == "copying_data")
  #expect(events[5].expectedReboot)
  #expect(Set(events.map(\.operationID)) == ["upgrade-fixture"])
}

@Test func missedPhasesStillResolveInOrderAndAStoppedRuntimeIsNotStoppedAgain() {
  let action = RuntimeUpgradeAction.upgrade(dryRun: false)
  // A fast upgrade: no phase was observed before the answer.
  let quick = CollectingProgressSink()
  let fast = steps(action, into: quick)
  fast.beginDispatch(runtimeWasStopped: false)
  fast.closeDispatch(succeeded: true)
  #expect(
    transitions(quick) == [
      "runtime_stop:active", "runtime_stop:complete", "upgrade_boot:complete",
      "upgrade_verification:complete",
    ])

  let stopped = CollectingProgressSink()
  let idle = steps(action, into: stopped)
  idle.beginDispatch(runtimeWasStopped: true)
  idle.observe(operation: "upgrade", phase: "booting", expectedReboot: false)
  idle.closeDispatch(succeeded: true)
  #expect(
    transitions(stopped) == [
      "runtime_stop:skipped", "upgrade_boot:active", "upgrade_boot:active",
      "upgrade_boot:complete", "upgrade_verification:complete",
    ])

  // A rollback whose stop was skipped because nothing ran: check, skipped stop, restore.
  let rollback = RuntimeUpgradeAction.rollback(id: "x", discardData: false)
  #expect(rollback.dispatchStage(phase: "stopping") == .runtimeStop)
  #expect(rollback.dispatchStage(phase: "rolling_back") == .backupRestore)
  #expect(rollback.dispatchStage(phase: "booting") == nil)
  let restored = CollectingProgressSink()
  let back = steps(rollback, into: restored)
  back.beginDispatch(runtimeWasStopped: true, detail: "backup x")
  back.observe(operation: "rollback", phase: "rolling_back", expectedReboot: false)
  back.closeDispatch(succeeded: true)
  #expect(
    transitions(restored) == [
      "backup_check:active", "backup_check:complete", "runtime_stop:skipped",
      "backup_restore:active", "backup_restore:complete",
    ])
  #expect(restored.snapshot().first?.detail == "backup x")
}

@Test func aFailedOperationMarksOnlyTheActiveStageAndIgnoresLaterPhases() {
  let sink = CollectingProgressSink()
  let tracker = steps(.upgrade(dryRun: false), into: sink)
  tracker.begin(.upgradeStaging)
  tracker.complete(.upgradeStaging)
  tracker.beginDispatch(runtimeWasStopped: false)
  tracker.observe(operation: "upgrade", phase: "booting", expectedReboot: false)
  // The runtime service restores the previous state before it answers with the failure.
  tracker.observe(operation: "upgrade", phase: "rolling_back", expectedReboot: false)
  tracker.closeDispatch(succeeded: false)
  tracker.observe(operation: "upgrade", phase: "verifying", expectedReboot: false)
  tracker.fail(RuntimeError(.unavailable, "The new root did not import the pool."))
  let events = sink.snapshot()
  #expect(
    transitions(sink) == [
      "upgrade_staging:active", "upgrade_staging:complete", "runtime_stop:active",
      "runtime_stop:complete", "upgrade_boot:active", "upgrade_boot:active",
      "upgrade_boot:failed",
    ])
  #expect(events[5].detail == "rolling_back")
  #expect(events.last?.detail == "The new root did not import the pool.")
  #expect(events.last?.errorCode == "unavailable")

  // Activation events are forwarded, so a failure there names the activation stage.
  let activation = CollectingProgressSink()
  let early = steps(.rollback(id: nil, discardData: false), into: activation)
  early.emit(
    StartupProgressEvent(
      operationID: "upgrade-fixture", stage: .serviceActivation, state: .active,
      elapsedSeconds: 0))
  early.fail(RuntimeError(.conflict, "refused"))
  #expect(transitions(activation) == ["service_activation:active", "service_activation:failed"])
  // Nothing active: nothing to mark.
  let none = CollectingProgressSink()
  steps(.upgrade(dryRun: true), into: none).fail(RuntimeError(.io, "x"))
  #expect(none.snapshot().isEmpty)
}

@Test func reusedApplianceIsShownAsASkippedDownloadAndADownloadKeepsItsBytes() {
  let reused = CollectingProgressSink()
  let cached = steps(.upgrade(dryRun: false), into: reused)
  cached.begin(.acquisition)
  cached.finishAcquisition()
  #expect(
    transitions(reused) == ["acquisition:active", "acquisition:skipped", "verification:complete"])
  let fetched = CollectingProgressSink()
  let download = steps(.upgrade(dryRun: false), into: fetched)
  download.begin(.acquisition)
  download.download(completed: 512, total: 1024)
  download.finishAcquisition()
  #expect(
    transitions(fetched) == [
      "acquisition:active", "acquisition:active", "acquisition:complete", "verification:complete",
    ])
  #expect(fetched.snapshot()[1].completedBytes == 512)
  #expect(fetched.snapshot()[1].totalBytes == 1024)
}

@Test func animatedUpgradeStepsUseNativeNooraRowsAndTheirOwnCount() async throws {
  let capture = StartCapture()
  let sink = TerminalProgressSink(
    rendering: .animated, operation: RuntimeUpgradeAction.upgrade(dryRun: false).progressOperation,
    environment: ["TERM": "xterm", "NO_COLOR": ""], width: { 140 },
    write: capture.streams.writeError)
  sink.startRefreshing()
  let tracker = steps(.upgrade(dryRun: false), into: sink)
  tracker.begin(.upgradePlan)
  tracker.complete(.upgradePlan)
  await sink.settle()
  // Between steps, a command can write its table: every resolved row is already out.
  #expect(withoutStyling(capture.error).contains("✔︎ Upgrade planned"))
  tracker.beginDispatch(runtimeWasStopped: false)
  tracker.observe(operation: "upgrade", phase: "booting", expectedReboot: false)
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  // Plan and stop are resolved while the boot is the active, animated step.
  func drawn() -> Bool {
    withoutStyling(capture.error).contains("Booting new appliance (")
      && capture.error.contains("[##-------] 2/9 stages")
  }
  while !drawn(), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(drawn())
  #expect(capture.error.contains("\u{1B}[?25l"))
  tracker.closeDispatch(succeeded: false)
  tracker.fail(RuntimeError(.unavailable, "boot failed"))
  await sink.finish()
  let text = withoutStyling(capture.error)
  #expect(text.contains("✔︎ Runtime stopped"))
  #expect(text.contains("⨯ Booting new appliance failed"))
  #expect(!text.contains("Pool and inventory verified"))
  #expect(!text.contains("stages resolved"))
  #expect(capture.error.contains("\u{1B}[?25h"))

  let done = StartCapture()
  let current = TerminalProgressSink(
    rendering: .plain, operation: RuntimeUpgradeAction.upgrade(dryRun: false).progressOperation,
    stderrIsTTY: false, write: done.streams.writeError)
  let plan = steps(.upgrade(dryRun: false), into: current)
  for stage in [StartupStage.preflight, .serviceActivation, .upgradePlan] {
    plan.begin(stage)
    plan.complete(stage)
  }
  // A current runtime ends after the plan, and the count names only the stages that ran.
  current.narrow(to: 3)
  await current.finish(ready: true, connected: true)
  #expect(done.error.contains("Upgrade: 3/3 stages resolved"))
  #expect(!done.error.contains("\u{1B}"))
}
