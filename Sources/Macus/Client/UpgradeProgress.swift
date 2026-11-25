import Foundation

extension RuntimeUpgradeAction {
  /// What the progress display counts for this action: the activation stages, then its own.
  var progressOperation: ProgressOperation {
    switch self {
    case .upgrade(dryRun: true):
      ProgressOperation(title: "Upgrade dry run", stages: 3, confirmation: nil)
    case .upgrade:
      ProgressOperation(title: "Upgrade", stages: 9, confirmation: nil)
    case .rollback:
      ProgressOperation(title: "Rollback", stages: 5, confirmation: nil)
    }
  }

  /// The runtime service's operation name in `GET /runtime/progress` while it carries this out.
  var serviceOperation: String {
    switch self {
    case .upgrade: "upgrade"
    case .rollback: "rollback"
    }
  }

  /// The stages the runtime service carries out after the client hands the request over, in
  /// order.
  var dispatchStages: [StartupStage] {
    switch self {
    case .upgrade: [.runtimeStop, .upgradeBoot, .upgradeVerification]
    case .rollback: [.backupCheck, .runtimeStop, .backupRestore]
    }
  }

  /// The step a runtime service phase belongs to, or nil when the phase names none.
  func dispatchStage(phase: String) -> StartupStage? {
    switch (self, phase) {
    case (.upgrade, "reading_inventory"), (.upgrade, "stopping"): .runtimeStop
    case (.upgrade, "verifying"), (.upgrade, "ready"): .upgradeVerification
    case (.upgrade, "rolling_back"), (.upgrade, ""): nil
    // Copying the data disk, booting, the guest's own provisioning phases and the expected
    // reboot all happen while the new appliance boots.
    case (.upgrade, _): .upgradeBoot
    case (.rollback, "stopping"): .runtimeStop
    case (.rollback, "rolling_back"): .backupRestore
    case (.rollback, _): nil
    }
  }
}

/// The steps of `runtime upgrade` and its rollback on start's progress sink. It forwards the
/// activation events start's coordinator emits, emits the client's own stages, and advances
/// the runtime service's stages from the phases it reports. Each stage moves only forward,
/// and the dispatch stages resolve only when the runtime service has answered.
final class UpgradeSteps: StartupProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private let sink: any StartupProgressSink
  private let action: RuntimeUpgradeAction
  private let operationID: String
  private let started: ContinuousClock.Instant
  private let now: @Sendable () -> ContinuousClock.Instant
  private var active: StartupStage?
  private var position: Int?
  private var runtimeWasStopped = false
  private var dispatchClosed = false
  private var downloaded = false
  private var verifying = false
  /// The phase the runtime service reported before the request: the end of its last
  /// operation, such as `ready` after a start. It says nothing about this operation, so it
  /// is ignored until the service reports a phase of its own.
  private var stalePhase: String?
  private var operationReported = false

  init(
    sink: any StartupProgressSink, action: RuntimeUpgradeAction, operationID: String,
    started: ContinuousClock.Instant, now: @escaping @Sendable () -> ContinuousClock.Instant
  ) {
    self.sink = sink
    self.action = action
    self.operationID = operationID
    self.started = started
    self.now = now
  }

  func emit(_ event: StartupProgressEvent) { lock.withLock { deliver(event) } }

  func diagnostic(_ text: String) { sink.diagnostic(text) }

  func begin(_ stage: StartupStage, detail: String? = nil) { send(stage, .active, detail: detail) }
  func complete(_ stage: StartupStage) { send(stage, .complete) }

  func download(completed: Int64, total: Int64?) {
    lock.withLock {
      downloaded = true
      deliver(event(.acquisition, .active, completed: completed, total: total))
    }
  }

  /// The archive is downloaded; its size, digests and extracted disk are checked next.
  func beginVerification() {
    lock.withLock {
      verifying = true
      deliver(event(.acquisition, .complete))
      deliver(event(.verification, .active))
    }
  }

  /// A verified cache needs no download, so the acquisition is shown as skipped.
  func finishAcquisition() {
    lock.withLock {
      if !verifying { deliver(event(.acquisition, downloaded ? .complete : .skipped)) }
      deliver(event(.verification, .complete))
    }
  }

  /// Marks the stage that was active when the command failed, so the failure names it.
  func fail(_ error: any Error) {
    lock.withLock {
      guard let stage = active else { return }
      let failure = error as? RuntimeError
      deliver(
        event(
          stage, .failed, detail: failure?.message ?? (error as? StartupInterrupted)?.message,
          code: failure?.code.rawValue))
    }
  }

  /// The runtime service now owns the operation. A runtime that was stopped beforehand is
  /// never stopped again, so its stop is shown as skipped rather than performed.
  /// `previousPhase` is the phase the runtime service reported before the request.
  func beginDispatch(
    runtimeWasStopped: Bool, previousPhase: String? = nil, detail: String? = nil
  ) {
    lock.withLock {
      self.runtimeWasStopped = runtimeWasStopped
      stalePhase = previousPhase
      var first = 0
      let stages = action.dispatchStages
      if runtimeWasStopped, stages.first == .runtimeStop {
        deliver(event(.runtimeStop, .skipped))
        first = 1
      }
      position = first
      deliver(event(stages[first], .active, detail: detail))
    }
  }

  /// One `GET /runtime/progress` observation during the dispatch.
  func observe(operation: String?, phase: String?, expectedReboot: Bool) {
    lock.withLock {
      guard !dispatchClosed, operation == action.serviceOperation, let position,
        let phase
      else { return }
      if !operationReported {
        // Until the operation reports a phase of its own, the service may still show the one
        // its last operation ended in; an upgrade's own `ready` comes only after verifying.
        let stale =
          phase == stalePhase || (action.serviceOperation == "upgrade" && phase == "ready")
        guard !stale else { return }
        operationReported = true
      }
      let stages = action.dispatchStages
      var target = position
      if let stage = action.dispatchStage(phase: phase),
        let index = stages.firstIndex(of: stage)
      {
        // A phase of a stage already resolved is stale; the display never moves back.
        guard index >= position else { return }
        target = index
      }
      if target > position {
        deliver(event(stages[position], .complete))
        for index in (position + 1)..<target {
          let skipped = stages[index] == .runtimeStop && runtimeWasStopped
          deliver(event(stages[index], skipped ? .skipped : .complete))
        }
        self.position = target
      }
      let named = ["stopping", "booting", "verifying", "ready"].contains(phase)
      deliver(
        event(
          stages[target], .active, detail: named ? nil : phase,
          reboot: expectedReboot && stages[target] == .upgradeBoot))
    }
  }

  /// The runtime service answered: later observations are ignored, and on success every
  /// remaining stage resolves in order.
  func closeDispatch(succeeded: Bool) {
    lock.withLock {
      dispatchClosed = true
      guard succeeded, let position else { return }
      let stages = action.dispatchStages
      for index in position..<stages.count {
        let skipped = index > position && stages[index] == .runtimeStop && runtimeWasStopped
        deliver(event(stages[index], skipped ? .skipped : .complete))
      }
      self.position = nil
    }
  }

  private func send(
    _ stage: StartupStage, _ state: StartupStageState, detail: String? = nil
  ) {
    lock.withLock { deliver(event(stage, state, detail: detail)) }
  }

  /// Records and emits under the lock, so the poll and the request deliver their events to
  /// the sink in the order the steps changed. The sink never calls back into the steps.
  private func deliver(_ event: StartupProgressEvent) {
    record(event)
    sink.emit(event)
  }

  private func record(_ event: StartupProgressEvent) {
    if event.state == .active {
      active = event.stage
    } else if active == event.stage {
      active = nil
    }
  }

  private func event(
    _ stage: StartupStage, _ state: StartupStageState, completed: Int64? = nil,
    total: Int64? = nil, detail: String? = nil, reboot: Bool = false, code: String? = nil
  ) -> StartupProgressEvent {
    StartupProgressEvent(
      operationID: operationID, stage: stage, state: state,
      elapsedSeconds: max(0, Int(started.duration(to: now()).components.seconds)),
      completedBytes: completed, totalBytes: total, detail: detail, errorCode: code,
      expectedReboot: reboot)
  }
}
