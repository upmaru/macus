import Foundation
import os

public actor RuntimeService {
  private let driver: any VirtualMachineDriver
  private let store: StateStore
  private var configuration: RuntimeConfiguration?
  private var state: RuntimeState
  private var lastError: String?
  private var guestHealth: GuestHealth?
  private var mutationActive = false
  private var generation: UInt64 = 0
  private var startingTask: Task<RuntimeStatus, Error>?
  private var startedAt: Date?
  private let logger = Logger(subsystem: "com.upmaru.macus", category: "runtime")
  private var bootPhase: String?
  private var bootExpectedReboot = false
  private var bootStartedAt: ContinuousClock.Instant?
  private let stallLimit: Duration
  /// The installed package's appliance, for the catalog Incus package fallback and for
  /// reporting whether an upgrade is available.
  private let catalog: ApplianceCatalogEntry
  private let payloadRevision: String
  private let macusPackage: String?
  private let volume: any UpgradeVolume
  /// Test seam: called at labelled points of an upgrade and its rollback.
  private let upgradeHook: UpgradeHook?
  /// Reads the Incus inventory before and after an upgrade.
  private let inventorySource: any IncusInventorySource
  /// The operation progress reports while a mutation runs, when it is not a plain start.
  private var operation: String?
  /// Set when an interrupted upgrade could not be rolled back at daemon start: every
  /// mutation is refused until it is resolved by hand.
  private var recoveryError: String?

  public init(driver: any VirtualMachineDriver, store: StateStore) throws {
    try self.init(driver: driver, store: store, stallLimit: .seconds(300))
  }

  init(
    driver: any VirtualMachineDriver, store: StateStore, stallLimit: Duration,
    catalog: ApplianceCatalogEntry = .current,
    payloadRevision: String = EmbeddedGuestPayload.revision,
    macusPackage: String? = BuildIdentity.current.version,
    volume: any UpgradeVolume = HostVolume(), upgradeHook: UpgradeHook? = nil,
    inventory: any IncusInventorySource = RelayInventorySource()
  ) throws {
    self.driver = driver
    self.store = store
    self.stallLimit = stallLimit
    self.catalog = catalog
    self.payloadRevision = payloadRevision
    self.macusPackage = macusPackage
    self.volume = volume
    self.upgradeHook = upgradeHook
    self.inventorySource = inventory
    // An upgrade or rollback that did not commit is undone before anything else is accepted.
    // The VM runs inside this process, so nothing is running yet.
    var recovered: String?
    var failure: String?
    do {
      if let intent = try UpgradeJournal.load(paths: store.paths) {
        try UpgradeJournal.rollback(intent, paths: store.paths)
        recovered = Self.rolledBackAtStart(intent)
      }
    } catch {
      failure =
        "An interrupted upgrade could not be rolled back automatically: \(error.localizedDescription) Runtime changes are refused until it is resolved."
    }
    if failure == nil {
      do {
        if let intent = try RollbackJournal.load(paths: store.paths) {
          try RollbackJournal.undo(intent, paths: store.paths)
          recovered =
            "A rollback to backup \(intent.source) did not complete before the daemon stopped, so it was undone: the runtime is as it was before the rollback."
        }
      } catch {
        failure =
          "An interrupted rollback could not be undone automatically: \(error.localizedDescription) Runtime changes are refused until it is resolved."
      }
    }
    if let failure {
      recoveryError = failure
      configuration = try? store.load()
      state = .failed
      lastError = failure
    } else {
      configuration = try store.load()
      state = configuration == nil ? .absent : .stopped
      lastError = recovered
    }
  }

  static func rolledBackAtStart(_ intent: UpgradeIntent) -> String {
    let data =
      intent.upgradeClass == .migrating && intent.step >= .booting ? ", data disk" : ""
    return
      "An upgrade (backup \(intent.backupId)) did not commit before the daemon stopped, so it was rolled back: the previous root\(data) and configuration were restored."
  }

  public func status() async -> RuntimeStatus {
    await refresh()
    return snapshot()
  }
  public func capabilities() async -> RuntimeCapabilities {
    await refresh()
    return RuntimeCapabilities(
      host: await driver.capabilities(), health: guestHealth,
      nestingEnabled: configuration?.nestedVirtualization == true)
  }
  public func config() throws -> RuntimeConfiguration {
    guard let configuration else { throw RuntimeError(.notFound, "Runtime has not been created") }
    return configuration
  }
  public func health() async throws -> GuestHealth {
    await refresh()
    guard let guestHealth else {
      throw RuntimeError(.unavailable, lastError ?? "Incus is not ready")
    }
    return guestHealth
  }
  public func create(_ value: RuntimeConfiguration) async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    if let configuration {
      guard configuration == value else {
        throw RuntimeError(.conflict, "Runtime exists with a different configuration")
      }
      return snapshot()
    }
    try value.validate()
    let store = self.store
    try await Task.detached { try GuestImageManager.create(configuration: value, store: store) }
      .value
    configuration = value
    state = .stopped
    lastError = nil
    try RebootAllowanceStore.ensureAvailable(
      paths: store.paths, catalogID: value.applianceManifestPath)
    return snapshot()
  }
  public func update(_ value: RuntimeConfiguration) async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    let current = try config()
    guard !(await driver.isRunning()) else {
      throw RuntimeError(.conflict, "Configuration requires a stopped VM")
    }
    try value.validate()
    guard value.applianceManifestPath == current.applianceManifestPath,
      value.seedPath == current.seedPath
    else {
      throw RuntimeError(
        .invalidConfiguration, "Replace the appliance with macus runtime upgrade")
    }
    guard value.dataDiskGib >= current.dataDiskGib else {
      throw RuntimeError(.invalidConfiguration, "Disk shrink is unsupported")
    }
    try store.resizeData(gib: value.dataDiskGib)
    try store.save(value)
    configuration = value
    state = .stopped
    lastError = nil
    return snapshot()
  }
  public func start() async throws -> RuntimeStatus {
    try await start(remainingSeconds: nil)
  }
  public func start(remainingSeconds: Int?) async throws -> RuntimeStatus {
    if let remainingSeconds, !(1...3_600).contains(remainingSeconds) {
      throw RuntimeError(.invalidRequest, "remaining_seconds must be an integer from 1 to 3600")
    }
    try beginMutation()
    let operationGeneration = generation
    defer { if generation == operationGeneration { mutationActive = false } }
    return try await boot(
      remainingSeconds: remainingSeconds, operationGeneration: operationGeneration)
  }
  public func progress() -> RuntimeProgress {
    let elapsed: Int
    if let bootStartedAt {
      elapsed = max(0, Int(bootStartedAt.duration(to: .now).components.seconds))
    } else {
      elapsed = startedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
    }
    return RuntimeProgress(
      apiVersion: 1, schemaVersion: 1, state: state, ready: state == .ready && guestHealth != nil,
      operation: operation ?? (state == .starting || mutationActive ? "start" : nil),
      phase: bootPhase,
      elapsedSeconds: elapsed, expectedReboot: bootExpectedReboot, detail: nil, lastError: lastError
    )
  }
  public func stop(force: Bool = false) async throws -> RuntimeStatus {
    if force, mutationActive, state == .starting, let startingTask {
      // Emergency stop owns the mutation gate after cancelling the boot task.
      generation &+= 1
      state = .stopping
      startingTask.cancel()
      _ = try? await startingTask.value
      defer { mutationActive = false }
      return try await stopLocked(force: true)
    }
    try beginMutation()
    defer { mutationActive = false }
    return try await stopLocked(force: force)
  }
  public func restart() async throws -> RuntimeStatus {
    try beginMutation()
    let operationGeneration = generation
    defer { if generation == operationGeneration { mutationActive = false } }
    _ = try await stopLocked(force: false)
    return try await boot(remainingSeconds: nil, operationGeneration: operationGeneration)
  }
  public func delete(confirm: Bool) async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    guard confirm else { throw RuntimeError(.invalidRequest, "Deletion requires confirm=true") }
    guard !(await driver.isRunning()) else {
      throw RuntimeError(.conflict, "Stop the VM before deleting runtime data")
    }
    try store.delete()
    configuration = nil
    state = .absent
    guestHealth = nil
    lastError = nil
    startedAt = nil
    return snapshot()
  }
  /// Read-only: what an upgrade to the installed appliance would do. Refusals are errors.
  public func upgradePlan() async throws -> UpgradePlan {
    if let recoveryError { throw RuntimeError(.conflict, recoveryError) }
    _ = try config()
    let paths = store.paths
    let catalog = self.catalog
    let payloadRevision = self.payloadRevision
    let volume = self.volume
    return try await Task.detached {
      try UpgradePlanner.plan(
        paths: paths, catalog: catalog, payloadRevision: payloadRevision, volume: volume)
    }.value
  }

  /// Replaces the root with a staged one and boots it against the same data disk. Everything
  /// that can fail without changing state is checked before the stop; after the intent is
  /// written, any failure restores the previous state before returning.
  public func upgrade(stagingID: String) async throws -> UpgradeResult {
    try beginMutation()
    let operationGeneration = generation
    defer { if generation == operationGeneration { mutationActive = false } }
    operation = "upgrade"
    defer { operation = nil }
    let previous = try config()
    let plan = try await upgradePlan()
    guard !plan.current, let upgradeClass = plan.upgradeClass, let storage = plan.storage else {
      throw RuntimeError(
        .conflict,
        "This runtime already runs the installed appliance and payload; nothing was changed.")
    }
    let paths = store.paths
    let catalog = self.catalog
    let staged = try await Task.detached {
      try UpgradeStaging.verify(id: stagingID, paths: paths, entry: catalog, plan: plan)
    }.value
    var next = previous
    next.applianceManifestPath = staged.manifest.path
    next.seedPath = staged.creationSeed.path
    try next.validate()
    let open = internalIncusStream()
    var before: IncusInventory?
    var skipped: String?
    if state == .ready, await driver.isRunning() {
      bootPhase = "reading_inventory"
      do {
        before = try await inventorySource.read(open: open)
      } catch {
        throw RuntimeError(
          .unavailable,
          "The running guest's Incus inventory could not be read (\(error.localizedDescription)), so it could not be compared after the upgrade. Nothing was changed. To upgrade without the comparison, stop the runtime first."
        )
      }
    } else {
      skipped =
        "The previous guest was not serving Incus to this host, so its inventory was not read and the comparison was skipped."
    }
    if await driver.isRunning() {
      bootPhase = "stopping"
      do {
        _ = try await stopLocked(force: false)
      } catch {
        throw RuntimeError(
          .timeout,
          "The runtime did not stop within \(previous.shutdownTimeoutSeconds) s, so the upgrade stopped before any disk was moved; the guest may still be running. \(error.localizedDescription)"
        )
      }
    }
    guestHealth = nil
    var intent = UpgradeIntent(
      backupId: stagingID, stagingId: stagingID, upgradeClass: upgradeClass, step: .journaled,
      fromCatalogId: plan.fromCatalogId, toCatalogId: catalog.id, poolGuid: storage.poolGuid,
      root: try Self.identity(paths.rootDisk), efi: try FileIdentity.of(paths.efiStore),
      seed: try FileIdentity.of(paths.seed), data: try Self.identity(paths.dataDisk),
      stagedRoot: try Self.identity(staged.root), stagedSeed: try Self.identity(staged.seed))
    try UpgradeJournal.save(intent, paths: paths)
    do {
      try upgradeHook?("journaled")
      try UpgradeJournal.createBackup(&intent, paths: paths, hook: upgradeHook)
      if let before {
        try PrivateFile.write(
          try JSON.encoder().encode(before),
          to: paths.backup(intent.backupId).appendingPathComponent(Self.inventoryBefore))
      }
      if upgradeClass == .migrating {
        bootPhase = "copying_data"
        try UpgradeJournal.copyData(
          &intent, paths: paths, method: plan.dataCopy, volume: volume, hook: upgradeHook)
      }
      try GuestImageManager.prepareRoot(staged.root)
      intent.step = .rootPrepared
      try UpgradeJournal.save(intent, paths: paths)
      try upgradeHook?("root_prepared")
      try UpgradeJournal.swap(
        &intent, paths: paths, staged: staged, configuration: next, store: store,
        hook: upgradeHook)
      configuration = next
      intent.step = .booting
      try UpgradeJournal.save(intent, paths: paths)
      try upgradeHook?("booting")
      guard (await driver.capabilities()).supported else {
        throw RuntimeError(.unavailable, "Apple virtualization is unavailable on this host")
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(next.readinessTimeoutSeconds))
      let health = try await bootGuest(
        next, deadline: deadline, operationGeneration: operationGeneration)
      bootPhase = "verifying"
      try Self.verifyUpgraded(health, poolGuid: storage.poolGuid)
      let after: IncusInventory
      do {
        after = try await inventorySource.read(open: open)
      } catch {
        throw RuntimeError(
          .unavailable,
          "The new root did not serve the Incus API to this host: \(error.localizedDescription)")
      }
      try PrivateFile.write(
        try JSON.encoder().encode(after),
        to: paths.backup(intent.backupId).appendingPathComponent(Self.inventoryAfter))
      if let before { try Self.verifyInventory(after, before: before) }
      intent.step = .verified
      try UpgradeJournal.save(intent, paths: paths)
      try upgradeHook?("verified")
      recordReady(health)
      let record = UpgradeBackupRecord(
        id: intent.backupId, createdAt: ISO8601DateFormatter().string(from: Date()),
        upgradeClass: upgradeClass, fromCatalogId: plan.fromCatalogId, toCatalogId: catalog.id,
        rootIncusPackage: plan.recordedIncusPackage,
        rootIncusPackageSource: plan.recordedIncusPackageSource,
        dataCopy: intent.dataCopy != nil, poolGuid: storage.poolGuid, macusPackage: macusPackage)
      try UpgradeJournal.commit(intent, record: record, paths: paths, hook: upgradeHook)
      // Only now is the relay served to the server and clients.
      guestHealth = health
      state = .ready
      bootPhase = "ready"
      lastError = nil
      logger.notice("Upgrade \(intent.backupId, privacy: .public) committed")
      return UpgradeResult(
        backupId: intent.backupId, upgradeClass: upgradeClass, fromCatalogId: plan.fromCatalogId,
        toCatalogId: catalog.id, poolGuid: storage.poolGuid, dataCopy: plan.dataCopy,
        inventory: UpgradeInventoryOutcome(
          compared: before != nil, skippedReason: skipped, current: after),
        status: snapshot())
    } catch let interruption as UpgradeInterruption {
      throw interruption
    } catch {
      throw await rollBackUpgrade(intent, value: next, reason: error)
    }
  }

  static let inventoryBefore = "inventory-before.json"
  static let inventoryAfter = "inventory-after.json"

  /// Every name Incus listed before the upgrade must still be listed. New names are allowed.
  static func verifyInventory(_ after: IncusInventory, before: IncusInventory) throws {
    let missing = after.missing(from: before)
    guard !missing.isEmpty else { return }
    let shown = missing.prefix(10).joined(separator: ", ")
    let more = missing.count > 10 ? " and \(missing.count - 10) more" : ""
    throw RuntimeError(
      .unavailable, "Incus on the new root no longer lists \(shown)\(more).")
  }

  /// A stream to the guest's Incus relay port for the daemon's own reads. It does not depend
  /// on the runtime being ready, so it works while the relay is closed to clients.
  private func internalIncusStream() -> @Sendable () async throws -> GuestStream {
    let driver = self.driver
    return { try await driver.openStream(port: FlowRelayProtocol.port) }
  }

  private static func identity(_ url: URL) throws -> FileIdentity {
    guard let identity = try FileIdentity.of(url) else {
      throw RuntimeError(.io, "Missing \(url.lastPathComponent)")
    }
    return identity
  }

  /// The new root must serve this host and report the pool the upgrade named.
  static func verifyUpgraded(_ health: GuestHealth, poolGuid: String) throws {
    if let reason = incompatibility(health) {
      throw RuntimeError(.unavailable, "The new root is not compatible with this host: \(reason)")
    }
    guard let storage = health.storage, storage.backend == "zfs", storage.phase == "ready",
      storage.poolGuid == poolGuid
    else {
      throw RuntimeError(
        .unavailable,
        "The new root did not report pool \(poolGuid) as ready (it reported \(health.storage?.poolGuid ?? "no pool"))"
      )
    }
  }

  /// Stops the new root (graceful, then forced: every qualified root shares one host identity,
  /// so the previous root imports a pool the new one left imported) and restores the
  /// previous state. Returns the error to report.
  private func rollBackUpgrade(_ intent: UpgradeIntent, value: RuntimeConfiguration, reason: Error)
    async -> RuntimeError
  {
    bootPhase = "rolling_back"
    logger.error(
      "Upgrade \(intent.backupId, privacy: .public) failed: \(reason.localizedDescription, privacy: .public)"
    )
    guestHealth = nil
    if await driver.isRunning() {
      state = .stopping
      try? await driver.requestStop()
      let deadline = ContinuousClock.now.advanced(by: .seconds(value.shutdownTimeoutSeconds))
      while await driver.isRunning(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if await driver.isRunning() { try? await driver.forceStop() }
    }
    startedAt = nil
    let detail = reason.localizedDescription
    guard !(await driver.isRunning()) else {
      let message =
        "The upgrade failed (\(detail)) and the new root could not be stopped, so nothing was rolled back yet. The daemon rolls the upgrade back when it next starts."
      state = .failed
      lastError = message
      return RuntimeError(.unavailable, message)
    }
    do {
      let current = try UpgradeJournal.load(paths: store.paths) ?? intent
      try UpgradeJournal.rollback(current, paths: store.paths, hook: upgradeHook)
      configuration = try store.load()
      state = .stopped
      let data =
        intent.upgradeClass == .migrating && intent.step >= .booting
        ? ", and the data disk was replaced by its copy" : ""
      let message =
        "The upgrade did not complete: \(detail) The previous root and configuration were restored\(data); diagnostics are in backups/\(intent.backupId)/failed."
      lastError = message
      return RuntimeError((reason as? RuntimeError)?.code ?? .unavailable, message)
    } catch {
      let message =
        "The upgrade failed (\(detail)) and could not be rolled back automatically: \(error.localizedDescription) Runtime changes are refused until it is resolved."
      recoveryError = message
      state = .failed
      lastError = message
      return RuntimeError(.io, message)
    }
  }

  // MARK: Backups

  /// Read-only: every backup with its size and whether it can be restored now.
  public func backups() async throws -> [BackupSummary] {
    let paths = store.paths
    let catalog = self.catalog
    return try await Task.detached {
      let current = try UpgradePlanner.recordedState(paths: paths, catalog: catalog)
      return try BackupCatalog.summaries(paths: paths, currentPackage: current.incusPackage)
    }.value
  }

  /// Restores a backup's root, firmware store, seed and configuration, and a data disk copy
  /// when the pairing rules require one. The state it replaces becomes a new backup, so
  /// nothing is deleted and the rollback can itself be rolled back. The runtime is left
  /// stopped.
  public func rollback(backupID: String?, discardDataSinceUpgrade: Bool) async throws
    -> BackupRollbackResult
  {
    try beginMutation()
    let operationGeneration = generation
    defer { if generation == operationGeneration { mutationActive = false } }
    operation = "rollback"
    defer { operation = nil }
    let previous = try config()
    let paths = store.paths
    let catalog = self.catalog
    let prepared = try await Task.detached {
      try BackupRollback.prepare(
        paths: paths, catalog: catalog, id: backupID, discardData: discardDataSinceUpgrade)
    }.value
    if await driver.isRunning() {
      bootPhase = "stopping"
      do {
        _ = try await stopLocked(force: false)
      } catch {
        throw RuntimeError(
          .timeout,
          "The runtime did not stop within \(previous.shutdownTimeoutSeconds) s, so the rollback stopped before any disk was moved; the guest may still be running. Stop it with macus runtime stop --force first. \(error.localizedDescription)"
        )
      }
    }
    guestHealth = nil
    startedAt = nil
    bootPhase = "rolling_back"
    var intent = try BackupRollback.intent(prepared, paths: paths, macusPackage: macusPackage)
    try RollbackJournal.save(intent, paths: paths)
    do {
      try upgradeHook?("rollback_journaled")
      try RollbackJournal.forward(&intent, paths: paths, hook: upgradeHook)
    } catch let interruption as UpgradeInterruption {
      throw interruption
    } catch {
      let detail = error.localizedDescription
      do {
        try RollbackJournal.undo(intent, paths: paths)
      } catch let undoError {
        let message =
          "The rollback to backup \(prepared.entry.id) failed (\(detail)) and could not be undone automatically: \(undoError.localizedDescription) Runtime changes are refused until it is resolved."
        recoveryError = message
        state = .failed
        lastError = message
        throw RuntimeError(.io, message)
      }
      configuration = try? store.load()
      state = .stopped
      let message =
        "The rollback to backup \(prepared.entry.id) did not complete: \(detail) The runtime was put back as it was before the rollback."
      lastError = message
      throw RuntimeError((error as? RuntimeError)?.code ?? .io, message)
    }
    configuration = try store.load()
    state = .stopped
    bootPhase = nil
    lastError = nil
    logger.notice(
      "Rolled back to backup \(prepared.entry.id, privacy: .public); the replaced state is backup \(intent.id, privacy: .public)"
    )
    return BackupRollbackResult(
      restoredBackupId: prepared.entry.id, safetyBackupId: intent.id,
      restoreData: prepared.decision.data.rawValue, dataFrom: prepared.decision.dataFrom,
      dataCopyCreatedAt: prepared.dataCopyCreatedAt,
      rootIncusPackage: prepared.entry.record?.rootIncusPackage, status: snapshot())
  }

  /// Removes one backup. Without confirmation nothing is removed, and the refusal names the
  /// backups that depend on its data copy.
  public func pruneBackup(id: String, confirm: Bool) async throws -> BackupPruneResult {
    try UpgradeID.validate(id)
    try beginMutation()
    let operationGeneration = generation
    defer { if generation == operationGeneration { mutationActive = false } }
    let paths = store.paths
    let catalog = self.catalog
    return try await Task.detached {
      let all = try BackupCatalog.load(paths: paths)
      guard let entry = all.first(where: { $0.id == id }) else {
        throw RuntimeError(.notFound, "No backup \(id)")
      }
      let current = try UpgradePlanner.recordedState(paths: paths, catalog: catalog)
      let breaks = BackupCatalog.breaks(
        pruning: id, all: all, currentPackage: current.incusPackage)
      let dependents =
        breaks.isEmpty
        ? ""
        : " Backups \(breaks.joined(separator: ", ")) depend on its data disk copy and would no longer be restorable."
      guard confirm else {
        throw RuntimeError(
          .invalidRequest,
          "Pruning backup \(id) permanently removes it (\(entry.allocatedBytes) bytes allocated).\(dependents) Confirm to remove it; nothing was removed."
        )
      }
      try FileManager.default.removeItem(at: paths.backup(id))
      try PrivateFile.sync(paths.backupsDirectory)
      return BackupPruneResult(
        removed: id, allocatedBytes: entry.allocatedBytes, noLongerRestorable: breaks)
    }.value
  }

  public func openIncusStream() async throws -> GuestStream {
    guard state == .ready else { throw RuntimeError(.unavailable, "Incus is not ready") }
    return try await driver.openStream(port: FlowRelayProtocol.port)
  }

  /// Guest bridges are installed once at first boot, so an older appliance keeps serving
  /// unframed bytes on the relay port and cannot be changed in place.
  static let legacyGuestReason =
    "The appliance guest bridge predates the flow-controlled Incus relay this Macus requires."
  static let upgradeRemedy = "Run macus runtime upgrade to replace the appliance root"
  static let legacyGuestBridge =
    "\(legacyGuestReason) \(upgradeRemedy); runtime data was not deleted."

  /// Why a guest that answered health cannot be served, or nil when it can.
  static func incompatibility(_ health: GuestHealth) -> String? {
    guard health.servesFlowRelay else { return legacyGuestReason }
    if let contract = health.guestContract, contract < GuestContract.minimum {
      return
        "The appliance guest reports contract \(contract), below the contract \(GuestContract.minimum) this Macus requires."
    }
    return nil
  }

  static func recordedIncompatible(contract: Int) -> String {
    "This runtime's appliance guest was recorded with contract \(contract), below the contract \(GuestContract.minimum) this Macus requires, so it was not booted. \(upgradeRemedy); runtime data was kept."
  }

  static func guestFailure(_ observation: GuestObservation, hostRestarted: Bool) -> RuntimeError {
    let code = observation.code ?? "unknown"
    let recovery =
      "Disks and Incus data were kept. Inspect serial.log, then run macus runtime stop --force and macus start."
    guard code == GuestObservation.incusCrashed else {
      return RuntimeError(
        .unavailable, "The guest reported a boot failure (code \(code)). \(recovery)")
    }
    let tried = hostRestarted ? " One automatic guest restart was already tried." : ""
    return RuntimeError(
      .unavailable,
      "Incus crashed during guest boot and the guest's bounded restarts were exhausted (code incus_crashed).\(tried) The incusd log tail is in serial.log. \(recovery)"
    )
  }

  static func stalled(phase: String?, after limit: Duration) -> RuntimeError {
    RuntimeError(
      .timeout,
      "The guest stopped making progress after the \(phase ?? "unknown") stage: no Incus health and no serial output for \(limit.components.seconds) s. Disks and Incus data were kept. Inspect serial.log, then run macus runtime stop --force and macus start."
    )
  }

  private func beginMutation() throws {
    if let recoveryError { throw RuntimeError(.conflict, recoveryError) }
    guard !mutationActive else {
      throw RuntimeError(.conflict, "A runtime mutation is already in progress")
    }
    generation &+= 1
    mutationActive = true
  }
  private func boot(remainingSeconds: Int?, operationGeneration: UInt64) async throws
    -> RuntimeStatus
  {
    let task = Task {
      try await self.startLocked(
        remainingSeconds: remainingSeconds, operationGeneration: operationGeneration)
    }
    startingTask = task
    defer { startingTask = nil }
    return try await task.value
  }
  private func startLocked(remainingSeconds: Int?, operationGeneration: UInt64) async throws
    -> RuntimeStatus
  {
    let value = try config()
    // This operation owns the mutation gate, so refresh() intentionally cannot run here.
    if state == .ready {
      if await driver.isRunning() {
        let live = try? await driver.health()
        if let live, live.protocolVersion == 1, live.servesFlowRelay {
          try Task.checkCancellation()
          guestHealth = live
          return snapshot()
        }
        state = .failed
        guestHealth = nil
        lastError =
          live?.protocolVersion == 1
          ? Self.legacyGuestBridge : "Guest health unavailable; stop/start to recover"
      } else {
        state = .failed
        guestHealth = nil
        startedAt = nil
        lastError = "Guest exited unexpectedly"
      }
    }
    guard !(await driver.isRunning()) else {
      throw RuntimeError(.conflict, "VM is running but unhealthy; stop before recovery")
    }
    // Decided from the record before anything boots; an unknown contract boots and is probed.
    if let contract = recordedGuest()?.guestContract, contract < GuestContract.minimum {
      let message = Self.recordedIncompatible(contract: contract)
      lastError = message
      throw RuntimeError(.conflict, message)
    }
    guard (await driver.capabilities()).supported else {
      throw RuntimeError(.unavailable, "Apple virtualization is unavailable on this host")
    }
    let limit =
      remainingSeconds.map { min($0, value.readinessTimeoutSeconds) }
      ?? value.readinessTimeoutSeconds
    let deadline = ContinuousClock.now.advanced(by: .seconds(limit))
    do {
      let health = try await bootGuest(
        value, deadline: deadline, operationGeneration: operationGeneration)
      if let reason = Self.incompatibility(health) {
        // Recorded first, so the next start refuses before booting this guest again.
        recordReady(health)
        throw try await stopIncompatibleGuest(
          value, reason: reason, operationGeneration: operationGeneration)
      }
      guestHealth = health
      state = .ready
      bootPhase = "ready"
      logger.info("Incus ready: \(health.incusVersion, privacy: .public)")
      recordReady(health)
      return snapshot()
    } catch {
      state = .failed
      lastError = error.localizedDescription
      guestHealth = nil
      throw error
    }
  }

  /// Boots the configured disks and waits for the guest to answer health, through the expected
  /// kernel restart and the one Incus crash recovery. It does not decide readiness: start and
  /// upgrade each judge the health it returns.
  private func bootGuest(
    _ value: RuntimeConfiguration, deadline: ContinuousClock.Instant, operationGeneration: UInt64
  ) async throws -> GuestHealth {
    state = .starting
    lastError = nil
    guestHealth = nil
    bootPhase = "booting"
    bootExpectedReboot = false
    bootStartedAt = .now
    logger.info("Starting outer Linux VM")
    do {
      var restarted = false
      var sawReboot = false
      var recoveredIncus = false
      var offset = try GuestObservationParser.endOffset(store.paths.serialLog)
      var attemptOffset = offset
      var progress = BootProgressGuard(limit: stallLimit, size: offset)
      try Task.checkCancellation()
      try await driver.start(configuration: value, paths: store.paths)
      startedAt = Date()
      while true {
        guard ContinuousClock.now < deadline else {
          throw RuntimeError(
            .timeout, "Incus readiness timed out; inspect serial.log, then stop/start to recover")
        }
        try Task.checkCancellation()
        guard generation == operationGeneration, state == .starting else {
          throw CancellationError()
        }
        let read = try GuestObservationParser.read(url: store.paths.serialLog, from: offset)
        offset = read.offset
        if let phase = read.observations.last?.stage { bootPhase = phase }
        if read.observations.contains(where: { $0.expectsKernelReboot }) {
          sawReboot = true
          bootExpectedReboot = true
        }
        if let failure = read.observations.first(where: \.failed) {
          guard failure.code == GuestObservation.incusCrashed, !recoveredIncus else {
            throw Self.guestFailure(failure, hostRestarted: recoveredIncus)
          }
          // One host restart per start operation; a fresh boot recovered this
          // transient crash in manual retries.
          recoveredIncus = true
          try await shutDownForIncusRecovery(
            value, deadline: deadline, operationGeneration: operationGeneration)
          sawReboot = false
          attemptOffset = try GuestObservationParser.endOffset(store.paths.serialLog)
          offset = attemptOffset
          progress = BootProgressGuard(limit: stallLimit, size: offset)
          try await driver.start(configuration: value, paths: store.paths)
          startedAt = Date()
          continue
        }
        if !(await driver.isRunning()) {
          // VZ can report the guest stopped before the serial file receives the
          // marker emitted immediately before poweroff. Drain only this attempt.
          let drainDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(15)))
          var drainedFailure: GuestObservation?
          while !sawReboot && drainedFailure == nil && ContinuousClock.now < drainDeadline {
            try Task.checkCancellation()
            guard generation == operationGeneration, state == .starting else {
              throw CancellationError()
            }
            guard ContinuousClock.now < deadline else { break }
            let end = try GuestObservationParser.endOffset(store.paths.serialLog)
            if offset < attemptOffset { offset = attemptOffset }
            if offset >= end {
              try await Task.sleep(for: .milliseconds(50))
              continue
            }
            let again = try GuestObservationParser.read(url: store.paths.serialLog, from: offset)
            if again.offset <= offset {
              try await Task.sleep(for: .milliseconds(50))
              continue
            }
            offset = again.offset
            if again.observations.contains(where: \.expectsKernelReboot) {
              sawReboot = true
              bootExpectedReboot = true
            }
            if let phase = again.observations.last?.stage { bootPhase = phase }
            drainedFailure = again.observations.first(where: \.failed)
          }
          if !sawReboot, let drainedFailure {
            throw Self.guestFailure(drainedFailure, hostRestarted: recoveredIncus)
          }
          if sawReboot && !restarted {
            try RebootAllowanceStore.consume(paths: store.paths)
            try Task.checkCancellation()
            guard generation == operationGeneration, state == .starting else {
              throw CancellationError()
            }
            guard ContinuousClock.now < deadline else {
              throw RuntimeError(
                .timeout, "Incus readiness timed out before the expected kernel restart")
            }
            restarted = true
            sawReboot = false
            bootPhase = "expected_reboot"
            attemptOffset = try GuestObservationParser.endOffset(store.paths.serialLog)
            offset = attemptOffset
            try await driver.start(configuration: value, paths: store.paths)
            startedAt = Date()
            continue
          }
          if sawReboot && restarted {
            throw RuntimeError(
              .unavailable,
              "The guest requested another kernel restart after the fresh-bootstrap allowance was consumed. The runtime was not deleted."
            )
          }
          throw RuntimeError(
            .unavailable, "Guest exited before Incus became ready; inspect serial.log")
        }
        if let health = try? await driver.health(), health.protocolVersion == 1 {
          try Task.checkCancellation()
          guard generation == operationGeneration else { throw CancellationError() }
          return health
        }
        progress.observe(
          read.observations, size: try GuestObservationParser.endOffset(store.paths.serialLog))
        if progress.stalled() { throw Self.stalled(phase: bootPhase, after: stallLimit) }
        try await Task.sleep(for: .milliseconds(500))
      }
    }
  }
  /// Shuts the guest down for the single host restart after `incus_crashed`:
  /// graceful first so OpenRC exports storage, forced only after a bounded wait.
  private func shutDownForIncusRecovery(
    _ value: RuntimeConfiguration, deadline: ContinuousClock.Instant, operationGeneration: UInt64
  ) async throws {
    bootPhase = "incus_recovery"
    logger.notice("Guest reported incus_crashed; restarting the guest once")
    let graceful = min(
      deadline, ContinuousClock.now.advanced(by: .seconds(min(value.shutdownTimeoutSeconds, 60))))
    var requested = true
    do { try await driver.requestStop() } catch { requested = false }
    while requested, await driver.isRunning(), ContinuousClock.now < graceful {
      try Task.checkCancellation()
      guard generation == operationGeneration, state == .starting else {
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    try Task.checkCancellation()
    guard generation == operationGeneration, state == .starting else { throw CancellationError() }
    if await driver.isRunning() {
      logger.notice("Graceful guest shutdown did not finish; forcing stop for Incus recovery")
      try await driver.forceStop()
    }
    try Task.checkCancellation()
    guard generation == operationGeneration, state == .starting else { throw CancellationError() }
    guard ContinuousClock.now < deadline else {
      throw RuntimeError(
        .timeout,
        "Incus readiness timed out while restarting the guest after an Incus crash. Disks and Incus data were kept."
      )
    }
  }

  private func stopLocked(force: Bool) async throws -> RuntimeStatus {
    let value = try config()
    guestHealth = nil
    if !(await driver.isRunning()) {
      state = .stopped
      startedAt = nil
      return snapshot()
    }
    state = .stopping
    do {
      if force {
        try await driver.forceStop()
      } else {
        try await driver.requestStop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(value.shutdownTimeoutSeconds))
        while await driver.isRunning() {
          guard ContinuousClock.now < deadline else {
            throw RuntimeError(
              .timeout, "Graceful shutdown timed out; explicitly force stop if required")
          }
          try await Task.sleep(for: .milliseconds(100))
        }
      }
      state = .stopped
      startedAt = nil
      lastError = nil
      return snapshot()
    } catch {
      state = .failed
      lastError = error.localizedDescription
      throw error
    }
  }
  private func refresh() async {
    guard state == .ready, !mutationActive else { return }
    let observedGeneration = generation
    let running = await driver.isRunning()
    guard state == .ready, !mutationActive, generation == observedGeneration else { return }
    if !running {
      state = .failed
      lastError = "Guest exited unexpectedly"
      guestHealth = nil
      startedAt = nil
    } else {
      let live = try? await driver.health()
      guard state == .ready, !mutationActive, generation == observedGeneration else { return }
      if let live, live.protocolVersion == 1, live.servesFlowRelay {
        // A guest can report a field later than its first ready, such as its Incus package.
        if live != guestHealth { recordReady(live) }
        guestHealth = live
      } else {
        state = .failed
        guestHealth = nil
        lastError =
          live?.protocolVersion == 1
          ? Self.legacyGuestBridge : "Guest health unavailable; stop/start to recover"
      }
    }
  }
  private func snapshot() -> RuntimeStatus {
    RuntimeStatus(
      state: state, incusSocket: store.paths.incusSocket.path, lastError: lastError,
      uptimeSeconds: startedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0,
      upgradeAvailable: upgradeAvailable())
  }

  /// A corrupt or unreadable record is treated as unknown: start then boots and probes.
  private func recordedGuest() -> GuestRecord? {
    do {
      return try GuestRecordStore.loadGuest(paths: store.paths)
    } catch {
      logger.error("Guest record is unreadable: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Whether the state's recorded guest differs from the installed package's appliance or
  /// payload. Nil when nothing was recorded yet. A guest that predates identity reporting
  /// has no payload revision and is always older than this one.
  private func upgradeAvailable() -> Bool? {
    guard configuration != nil, let record = recordedGuest() else { return nil }
    return record.payloadRevision != payloadRevision || record.applianceId != catalog.id
  }

  /// Writes the daemon-owned guest and storage identity records for a guest that answered
  /// health. Failures are logged and never fail readiness: the post-boot probe still guards
  /// an unknown or stale record.
  private func recordReady(_ health: GuestHealth) {
    let paths = store.paths
    do {
      let previous = recordedGuest()
      let journalCatalog = (try? BootstrapStore.loadJournal(paths.directory))?.catalogID
      let record = GuestRecordStore.observe(
        health, previous: previous,
        catalogPackage: GuestRecordStore.catalogPackage(
          catalogID: health.applianceId ?? journalCatalog, catalog: catalog),
        macusPackage: macusPackage)
      if record != previous { try GuestRecordStore.saveGuest(record, paths: paths) }
      if case .conflict(let recorded, let reported) = try GuestRecordStore.recordStorage(
        health, paths: paths)
      {
        logger.error(
          "Guest reports pool \(reported, privacy: .public), but this state records pool \(recorded, privacy: .public); the record was kept"
        )
      }
    } catch {
      logger.error("Cannot record guest identity: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Stops a booted guest this host cannot serve: graceful only, within the shutdown timeout.
  /// It is never forced, so a guest that does not stop is reported as still running.
  private func stopIncompatibleGuest(
    _ value: RuntimeConfiguration, reason: String, operationGeneration: UInt64
  ) async throws -> RuntimeError {
    bootPhase = "incompatible_guest"
    logger.notice("Guest is incompatible with this host; requesting a graceful stop")
    let deadline = ContinuousClock.now.advanced(by: .seconds(value.shutdownTimeoutSeconds))
    var requested = true
    do { try await driver.requestStop() } catch { requested = false }
    while requested, await driver.isRunning(), ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard generation == operationGeneration, state == .starting else {
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard !(await driver.isRunning()) else {
      return RuntimeError(
        .unavailable,
        "\(reason) The guest did not stop gracefully within \(value.shutdownTimeoutSeconds) s and is still running. Run macus runtime stop --force, then macus runtime upgrade. Runtime data was kept."
      )
    }
    startedAt = nil
    return RuntimeError(
      .unavailable,
      "\(reason) The guest was stopped gracefully. \(Self.upgradeRemedy); runtime data was kept.")
  }
}
