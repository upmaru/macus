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

  func emit(_ event: StartupProgressEvent) {
    lock.withLock { record(event) }
    sink.emit(event)
  }

  func diagnostic(_ text: String) { sink.diagnostic(text) }

  func begin(_ stage: StartupStage, detail: String? = nil) { send(stage, .active, detail: detail) }
  func complete(_ stage: StartupStage) { send(stage, .complete) }

  func download(completed: Int64, total: Int64?) {
    lock.withLock { downloaded = true }
    send(.acquisition, .active, completed: completed, total: total)
  }

  /// A verified cache needs no download, so the acquisition is shown as skipped.
  func finishAcquisition() {
    send(.acquisition, lock.withLock { downloaded } ? .complete : .skipped)
    send(.verification, .complete)
  }

  /// Marks the stage that was active when the command failed, so the failure names it.
  func fail(_ error: any Error) {
    guard let stage = lock.withLock({ active }) else { return }
    let failure = error as? RuntimeError
    send(
      stage, .failed, detail: failure?.message ?? (error as? StartupInterrupted)?.message,
      code: failure?.code.rawValue)
  }

  /// The runtime service now owns the operation. A runtime that was stopped beforehand is
  /// never stopped again, so its stop is shown as skipped rather than performed.
  func beginDispatch(runtimeWasStopped: Bool, detail: String? = nil) {
    var events: [StartupProgressEvent] = []
    lock.withLock {
      self.runtimeWasStopped = runtimeWasStopped
      var first = 0
      let stages = action.dispatchStages
      if runtimeWasStopped, stages.first == .runtimeStop {
        events.append(event(.runtimeStop, .skipped))
        first = 1
      }
      position = first
      events.append(event(stages[first], .active, detail: detail))
      for event in events { record(event) }
    }
    for event in events { sink.emit(event) }
  }

  /// One `GET /runtime/progress` observation during the dispatch.
  func observe(operation: String?, phase: String?, expectedReboot: Bool) {
    var events: [StartupProgressEvent] = []
    lock.withLock {
      guard !dispatchClosed, operation == action.serviceOperation, let position,
        let phase
      else { return }
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
        events.append(event(stages[position], .complete))
        for index in (position + 1)..<target {
          let skipped = stages[index] == .runtimeStop && runtimeWasStopped
          events.append(event(stages[index], skipped ? .skipped : .complete))
        }
        self.position = target
      }
      let named = ["stopping", "booting", "verifying", "ready"].contains(phase)
      events.append(
        event(
          stages[target], .active, detail: named ? nil : phase,
          reboot: expectedReboot && stages[target] == .upgradeBoot))
      for event in events { record(event) }
    }
    for event in events { sink.emit(event) }
  }

  /// The runtime service answered: later observations are ignored, and on success every
  /// remaining stage resolves in order.
  func closeDispatch(succeeded: Bool) {
    var events: [StartupProgressEvent] = []
    lock.withLock {
      dispatchClosed = true
      guard succeeded, let position else { return }
      let stages = action.dispatchStages
      for index in position..<stages.count {
        let skipped = index > position && stages[index] == .runtimeStop && runtimeWasStopped
        events.append(event(stages[index], skipped ? .skipped : .complete))
      }
      self.position = nil
      for event in events { record(event) }
    }
    for event in events { sink.emit(event) }
  }

  private func send(
    _ stage: StartupStage, _ state: StartupStageState, completed: Int64? = nil,
    total: Int64? = nil, detail: String? = nil, code: String? = nil
  ) {
    let event = lock.withLock {
      let event = event(
        stage, state, completed: completed, total: total, detail: detail, code: code)
      record(event)
      return event
    }
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
