import Darwin
import Foundation

/// One `backups/<id>/` directory as rollback, the listing and prune see it.
struct BackupEntry: Sendable, Equatable {
  let id: String
  /// Nil for a rolled-back or interrupted upgrade, which only holds diagnostics.
  let record: UpgradeBackupRecord?
  let hasRoot: Bool
  let hasConfig: Bool
  /// Recorded and still present: a later rollback may have moved it back into `runtime/`.
  let hasDataCopy: Bool
  let allocatedBytes: UInt64

  var status: String {
    guard record != nil else { return BackupSummary.incomplete }
    return hasRoot && hasConfig ? BackupSummary.available : BackupSummary.restored
  }
}

/// What an explicit rollback does with `data.raw` (decision 5, explicit rollback).
enum RestoreData: String, Codable, Sendable {
  /// Case 1: the root's package equals the current data's; the data disk stays.
  case kept
  /// Case 2: the backup's own data copy, at its root's package.
  case own
  /// Case 3: the earliest later backup's data copy recorded at the root's package.
  case later
}

struct RestoreDecision: Equatable, Sendable {
  var data: RestoreData
  /// The backup whose data copy is restored; nil when the data disk stays.
  var dataFrom: String?
}

public struct BackupSummary: Codable, Sendable, Equatable {
  public var id: String
  /// `available`, `restored` (its root was put back by a rollback) or `incomplete` (a
  /// rolled-back or interrupted upgrade, kept for diagnosis).
  public var status: String
  public var operation: String?
  public var createdAt: String?
  public var upgradeClass: UpgradeClass?
  public var fromCatalogId: String?
  public var toCatalogId: String?
  public var rootIncusPackage: String?
  public var rootIncusPackageSource: String?
  /// Whether the backup still holds its data disk copy.
  public var dataCopy: Bool
  /// Blocks allocated to the backup's files. A clone shares blocks with the disk it was
  /// taken from, so this is the most removing the backup can free.
  public var allocatedBytes: UInt64
  /// Whether rollback to this backup can run now, under the pairing rules.
  public var restorable: Bool
  /// `kept`, `own` or `later`: what rollback would do with the data disk.
  public var restoreData: String?
  public var dataFrom: String?
  /// When rollback restores a data copy: that copy's time. Everything written since is lost,
  /// so rollback requires the discard confirmation.
  public var discardsDataSince: String?
  public var refusal: String?
  /// Backups that would stop being restorable if this one were pruned.
  public var pruneBreaks: [String]

  static let available = "available"
  static let restored = "restored"
  static let incomplete = "incomplete"
}

public struct BackupRollbackResult: Codable, Sendable {
  public var schemaVersion = 1
  public var restoredBackupId: String
  /// The backup now holding the state the rollback replaced.
  public var safetyBackupId: String
  public var restoreData: String
  public var dataFrom: String?
  public var dataCopyCreatedAt: String?
  public var rootIncusPackage: String?
  public var status: RuntimeStatus
}

public struct BackupPruneResult: Codable, Sendable, Equatable {
  public var schemaVersion = 1
  public var removed: String
  public var allocatedBytes: UInt64
  public var noLongerRestorable: [String]
}

enum BackupCatalog {
  static let dataName = "data.raw"

  /// Every backup directory with a valid ID, oldest first. Other entries are ignored.
  static func load(paths: RuntimePaths) throws -> [BackupEntry] {
    guard try PrivateFile.isOwnedDirectory(paths.backupsDirectory) else { return [] }
    let names = try FileManager.default.contentsOfDirectory(atPath: paths.backupsDirectory.path)
    return try names.filter(UpgradeID.isValid).sorted().compactMap { id in
      try PrivateFile.isOwnedDirectory(paths.backup(id)) ? try entry(id, paths: paths) : nil
    }
  }

  static func entry(_ id: String, paths: RuntimePaths) throws -> BackupEntry {
    let directory = paths.backup(id)
    let recordURL = directory.appendingPathComponent(UpgradeJournal.backupRecordName)
    var record: UpgradeBackupRecord?
    if try FileIdentity.of(recordURL) != nil {
      record = try? JSON.decoder().decode(
        UpgradeBackupRecord.self, from: Data(contentsOf: recordURL))
      if record?.id != id { record = nil }
    }
    let dataPresent = try FileIdentity.of(directory.appendingPathComponent(dataName)) != nil
    let hasData = record?.dataCopy == true && dataPresent
    return BackupEntry(
      id: id, record: record,
      hasRoot: try FileIdentity.of(directory.appendingPathComponent("root.raw")) != nil,
      hasConfig: try FileIdentity.of(directory.appendingPathComponent("config.json")) != nil,
      hasDataCopy: hasData, allocatedBytes: allocated(directory))
  }

  private static func allocated(_ directory: URL) -> UInt64 {
    var total: UInt64 = 0
    guard
      let walker = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil, options: [])
    else { return 0 }
    for case let url as URL in walker {
      var info = stat()
      if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
        total += UInt64(info.st_blocks) * 512
      }
    }
    return total
  }

  /// The pairing rules: a restored root never boots against data at another Incus package.
  static func decide(_ entry: BackupEntry, all: [BackupEntry], currentPackage: String?)
    -> Result<RestoreDecision, RuntimeError>
  {
    guard let record = entry.record, entry.hasRoot, entry.hasConfig else {
      let reason =
        entry.record == nil
        ? "is an incomplete upgrade kept for diagnosis" : "no longer holds its root disk"
      return .failure(
        RuntimeError(.conflict, "Backup \(entry.id) \(reason); it cannot be restored."))
    }
    let package = record.rootIncusPackage
    if let package, package == currentPackage {
      return .success(RestoreDecision(data: .kept))
    }
    if entry.hasDataCopy {
      return .success(RestoreDecision(data: .own, dataFrom: entry.id))
    }
    if let package,
      let later = all.first(where: {
        $0.id > entry.id && $0.hasDataCopy && $0.record?.rootIncusPackage == package
      })
    {
      return .success(RestoreDecision(data: .later, dataFrom: later.id))
    }
    guard let package else {
      return .failure(
        RuntimeError(
          .conflict,
          "Backup \(entry.id) holds a root whose Incus package is unknown and no data disk copy of its own, so no data disk is known to match it. Nothing was changed."
        ))
    }
    return .failure(
      RuntimeError(
        .conflict,
        "Backup \(entry.id) holds a root that ran Incus package \(package), but the data disk is now at \(currentPackage ?? "an unknown package") and no data disk copy at \(package) remains. Restoring the root alone would boot it against a different Incus database. Nothing was changed."
      ))
  }

  static func summaries(paths: RuntimePaths, currentPackage: String?) throws -> [BackupSummary] {
    let all = try load(paths: paths)
    return all.map { entry in
      let decision = decide(entry, all: all, currentPackage: currentPackage)
      let record = entry.record
      var summary = BackupSummary(
        id: entry.id, status: entry.status,
        operation: record?.operation
          ?? record.map { _ in
            UpgradeBackupRecord.upgradeOperation
          }, createdAt: record?.createdAt, upgradeClass: record?.upgradeClass,
        fromCatalogId: record?.fromCatalogId, toCatalogId: record?.toCatalogId,
        rootIncusPackage: record?.rootIncusPackage,
        rootIncusPackageSource: record?.rootIncusPackageSource, dataCopy: entry.hasDataCopy,
        allocatedBytes: entry.allocatedBytes, restorable: false,
        pruneBreaks: breaks(pruning: entry.id, all: all, currentPackage: currentPackage))
      switch decision {
      case .success(let value):
        summary.restorable = true
        summary.restoreData = value.data.rawValue
        summary.dataFrom = value.dataFrom
        summary.discardsDataSince = value.dataFrom.flatMap { id in
          all.first { $0.id == id }?.record?.createdAt
        }
      case .failure(let error):
        summary.refusal = entry.status == BackupSummary.available ? error.message : nil
      }
      return summary
    }
  }

  /// Backups restorable now that would not be once `id` is removed.
  static func breaks(pruning id: String, all: [BackupEntry], currentPackage: String?) -> [String] {
    let remaining = all.filter { $0.id != id }
    return remaining.filter { entry in
      guard case .success = decide(entry, all: all, currentPackage: currentPackage) else {
        return false
      }
      guard case .failure = decide(entry, all: remaining, currentPackage: currentPackage) else {
        return false
      }
      return true
    }.map(\.id)
  }
}

// MARK: Explicit rollback

/// One rename, by the identity of the file it moves. Paths are relative to the state
/// directory and validated before use.
struct StateMove: Codable, Sendable, Equatable {
  var from: String
  var to: String
  var identity: FileIdentity
}

enum RollbackStep: String, Codable, Sendable, Comparable {
  case journaled
  case backupCreated = "backup_created"
  case moving
  case moved
  case recordsRestored = "records_restored"

  private var order: Int {
    switch self {
    case .journaled: 0
    case .backupCreated: 1
    case .moving: 2
    case .moved: 3
    case .recordsRestored: 4
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// `STATE/rollback.pending`. An interrupted rollback is undone at daemon start: every move is
/// reversed by identity and the records the rollback replaced are restored.
struct RollbackIntent: Codable, Sendable, Equatable {
  var schemaVersion = 1
  /// The new backup that receives the state being replaced.
  var id: String
  /// The backup being restored.
  var source: String
  var restoreData: RestoreData
  var dataFrom: String?
  var step: RollbackStep
  var moves: [StateMove]
  /// Written to `backups/<id>/backup.json` when the rollback commits.
  var record: UpgradeBackupRecord
}

/// A rollback checked against the state before anything stops.
struct PreparedRollback: Sendable {
  let entry: BackupEntry
  let decision: RestoreDecision
  let configuration: RuntimeConfiguration
  let current: UpgradePlanner.RecordedState
  let dataCopyCreatedAt: String?
}

enum BackupRollback {
  /// Selects the named backup, or the latest available one, and applies the pairing rules.
  /// Read-only: every refusal leaves the state unchanged.
  static func prepare(
    paths: RuntimePaths, catalog: ApplianceCatalogEntry, id: String?, discardData: Bool
  ) throws -> PreparedRollback {
    if let id { try UpgradeID.validate(id) }
    let all = try BackupCatalog.load(paths: paths)
    let selected: BackupEntry
    if let id {
      guard let entry = all.first(where: { $0.id == id }) else {
        throw RuntimeError(.notFound, "No backup \(id)")
      }
      selected = entry
    } else {
      guard let latest = all.last(where: { $0.status == BackupSummary.available }) else {
        throw RuntimeError(.notFound, "No backup can be restored")
      }
      selected = latest
    }
    let current = try UpgradePlanner.recordedState(paths: paths, catalog: catalog)
    let decision = try BackupCatalog.decide(
      selected, all: all, currentPackage: current.incusPackage
    ).get()
    let copyTime = decision.dataFrom.flatMap { source in
      all.first { $0.id == source }?.record?.createdAt
    }
    if decision.data != .kept, !discardData {
      throw RuntimeError(
        .conflict,
        "Rolling back to backup \(selected.id) restores the data disk copy taken at \(copyTime ?? "an unrecorded time") (backup \(decision.dataFrom ?? selected.id)); everything written to the data disk since then is discarded. Confirm with --discard-data-since-upgrade. Nothing was changed."
      )
    }
    let directory = paths.backup(selected.id)
    try requireOwnedRegular(directory.appendingPathComponent("root.raw"))
    let configURL = directory.appendingPathComponent("config.json")
    try requireOwnedRegular(configURL)
    let configuration = try JSON.decoder().decode(
      RuntimeConfiguration.self, from: Data(contentsOf: configURL))
    try configuration.validate()
    if let source = decision.dataFrom {
      try requireOwnedRegular(paths.backup(source).appendingPathComponent(BackupCatalog.dataName))
    }
    return PreparedRollback(
      entry: selected, decision: decision, configuration: configuration, current: current,
      dataCopyCreatedAt: copyTime)
  }

  /// The journal for a prepared rollback, with the identities of the files as they are now.
  /// Called after the runtime stopped.
  static func intent(
    _ prepared: PreparedRollback, paths: RuntimePaths, macusPackage: String?, now: Date = Date()
  ) throws -> RollbackIntent {
    let id = UpgradeID.make(now: now)
    let source = "backups/\(prepared.entry.id)"
    let target = "backups/\(id)"
    var moves: [StateMove] = []
    for name in UpgradeJournal.disks {
      if let identity = try FileIdentity.of(paths.runtimeDirectory.appendingPathComponent(name)) {
        moves.append(
          StateMove(from: "runtime/\(name)", to: "\(target)/\(name)", identity: identity))
      } else if name == "root.raw" {
        throw RuntimeError(.io, "Missing runtime/root.raw")
      }
      if let identity = try FileIdentity.of(
        paths.backup(prepared.entry.id).appendingPathComponent(name))
      {
        moves.append(
          StateMove(from: "\(source)/\(name)", to: "runtime/\(name)", identity: identity))
      }
    }
    if let dataFrom = prepared.decision.dataFrom {
      let data = BackupCatalog.dataName
      guard let current = try FileIdentity.of(paths.dataDisk),
        let copy = try FileIdentity.of(paths.backup(dataFrom).appendingPathComponent(data))
      else { throw RuntimeError(.io, "A data disk to exchange is missing") }
      moves.append(StateMove(from: "runtime/\(data)", to: "\(target)/\(data)", identity: current))
      moves.append(
        StateMove(from: "backups/\(dataFrom)/\(data)", to: "runtime/\(data)", identity: copy))
    }
    let replacesData = prepared.decision.dataFrom != nil
    let record = UpgradeBackupRecord(
      id: id, createdAt: ISO8601DateFormatter().string(from: now),
      upgradeClass: replacesData ? .migrating : .reversible,
      fromCatalogId: prepared.current.catalogId, toCatalogId: prepared.entry.record?.fromCatalogId,
      rootIncusPackage: prepared.current.incusPackage,
      rootIncusPackageSource: prepared.current.incusPackageSource, dataCopy: replacesData,
      poolGuid: prepared.entry.record?.poolGuid ?? "", macusPackage: macusPackage,
      operation: UpgradeBackupRecord.rollbackOperation, restoredFrom: prepared.entry.id,
      dataFrom: prepared.decision.dataFrom)
    return RollbackIntent(
      id: id, source: prepared.entry.id, restoreData: prepared.decision.data,
      dataFrom: prepared.decision.dataFrom, step: .journaled, moves: moves, record: record)
  }
}

enum RollbackJournal {
  static func load(paths: RuntimePaths) throws -> RollbackIntent? {
    var info = stat()
    if lstat(paths.rollbackIntent.path, &info) != 0 {
      guard errno == ENOENT else { throw RuntimeError(.io, "Cannot inspect rollback.pending") }
      return nil
    }
    do {
      try requireOwnedRegular(paths.rollbackIntent)
      let intent = try JSON.decoder().decode(
        RollbackIntent.self, from: Data(contentsOf: paths.rollbackIntent))
      guard intent.schemaVersion == 1, UpgradeID.isValid(intent.id),
        UpgradeID.isValid(intent.source), intent.dataFrom.map(UpgradeID.isValid) ?? true
      else { throw RuntimeError(.invalidConfiguration, "Unsupported rollback intent") }
      for move in intent.moves {
        _ = try resolve(move.from, paths: paths)
        _ = try resolve(move.to, paths: paths)
      }
      return intent
    } catch {
      throw RuntimeError(
        .invalidConfiguration,
        "rollback.pending cannot be read, so the interrupted rollback was not resolved and every file was preserved. Put the disks back from STATE/backups by hand, or ask for help, before removing rollback.pending."
      )
    }
  }

  static func save(_ intent: RollbackIntent, paths: RuntimePaths) throws {
    try PrivateFile.write(
      try JSON.encoder().encode(intent), to: paths.rollbackIntent, syncDirectory: true)
  }

  /// A journaled path: `runtime/<disk>` or `backups/<id>/<disk>`, nothing else.
  static func resolve(_ relative: String, paths: RuntimePaths) throws -> URL {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let disk = Set(UpgradeJournal.disks + [BackupCatalog.dataName])
    if parts.count == 2, parts[0] == "runtime", disk.contains(parts[1]) {
      return paths.runtimeDirectory.appendingPathComponent(parts[1])
    }
    if parts.count == 3, parts[0] == "backups", UpgradeID.isValid(parts[1]),
      disk.contains(parts[2])
    {
      return paths.backup(parts[1]).appendingPathComponent(parts[2])
    }
    throw RuntimeError(.invalidConfiguration, "Unexpected journaled path \(relative)")
  }

  /// Copies the records aside, moves the disks, restores the selected backup's records and
  /// commits. Each step is journaled before it acts.
  static func forward(_ intent: inout RollbackIntent, paths: RuntimePaths, hook: UpgradeHook?)
    throws
  {
    let target = paths.backup(intent.id)
    let source = paths.backup(intent.source)
    intent.step = .backupCreated
    try save(intent, paths: paths)
    if !(try PrivateFile.isOwnedDirectory(paths.backupsDirectory)) {
      try PrivateFile.makeDirectory(paths.backupsDirectory)
    }
    if !(try PrivateFile.isOwnedDirectory(target)) { try PrivateFile.makeDirectory(target) }
    try copyRecords(from: paths.directory, guest: paths.guestRecord, into: target)
    try PrivateFile.sync(paths.backupsDirectory)
    try hook?("rollback_backup_created")
    intent.step = .moving
    try save(intent, paths: paths)
    for move in intent.moves {
      let from = try resolve(move.from, paths: paths)
      let to = try resolve(move.to, paths: paths)
      if try FileIdentity.of(to) == move.identity { continue }
      guard try FileIdentity.of(from) == move.identity else {
        throw RuntimeError(.conflict, "\(move.from) changed during the rollback")
      }
      try PrivateFile.move(from, to: to)
      try PrivateFile.sync(from.deletingLastPathComponent())
      try PrivateFile.sync(to.deletingLastPathComponent())
      try hook?("move:\(move.from)")
    }
    intent.step = .moved
    try save(intent, paths: paths)
    try hook?("moved")
    try restoreRecords(from: source, paths: paths)
    intent.step = .recordsRestored
    try save(intent, paths: paths)
    try hook?("records_restored")
    try PrivateFile.write(
      try JSON.encoder().encode(intent.record),
      to: target.appendingPathComponent(UpgradeJournal.backupRecordName), syncDirectory: true)
    try hook?("rollback_recorded")
    try FileManager.default.removeItem(at: paths.rollbackIntent)
    try PrivateFile.sync(paths.directory)
  }

  /// Reverses every move by identity, restores the records the rollback replaced and removes
  /// the new backup, which then holds only copies of those records. A file in neither place
  /// it could be stops the undo with everything preserved.
  static func undo(_ intent: RollbackIntent, paths: RuntimePaths) throws {
    let target = paths.backup(intent.id)
    for move in intent.moves.reversed() {
      let from = try resolve(move.from, paths: paths)
      let to = try resolve(move.to, paths: paths)
      if try FileIdentity.of(from) == move.identity { continue }
      guard try FileIdentity.of(to) == move.identity else {
        throw RuntimeError(
          .io,
          "\(move.from) is neither where the rollback found it nor where it was moving it; every file was preserved"
        )
      }
      try PrivateFile.move(to, to: from)
      try PrivateFile.sync(from.deletingLastPathComponent())
      try PrivateFile.sync(to.deletingLastPathComponent())
    }
    let hasTarget = try PrivateFile.isOwnedDirectory(target)
    // The copies are complete once the moves began; before that nothing was replaced.
    if hasTarget, intent.step >= .moving { try restoreRecords(from: target, paths: paths) }
    if hasTarget {
      for name in UpgradeJournal.disks + [BackupCatalog.dataName] {
        guard try FileIdentity.of(target.appendingPathComponent(name)) == nil else {
          throw RuntimeError(
            .io, "backups/\(intent.id)/\(name) remains after the undo; every file was preserved")
        }
      }
      try FileManager.default.removeItem(at: target)
      try PrivateFile.sync(paths.backupsDirectory)
    }
    try FileManager.default.removeItem(at: paths.rollbackIntent)
    try PrivateFile.sync(paths.directory)
  }

  private static func copyRecords(from directory: URL, guest: URL, into backup: URL) throws {
    for name in UpgradeJournal.records {
      let url = directory.appendingPathComponent(name)
      if try FileIdentity.of(url) != nil {
        try PrivateFile.write(try Data(contentsOf: url), to: backup.appendingPathComponent(name))
      }
    }
    if try FileIdentity.of(guest) != nil {
      try PrivateFile.write(
        try Data(contentsOf: guest),
        to: backup.appendingPathComponent(UpgradeJournal.guestRecordName))
    }
    try PrivateFile.sync(backup)
  }

  /// Puts a backup's records in place. A backup without a guest record had none, so the one
  /// in place, which describes another root, is removed; a copy of it is in the other backup.
  private static func restoreRecords(from backup: URL, paths: RuntimePaths) throws {
    for name in UpgradeJournal.records {
      let saved = backup.appendingPathComponent(name)
      if try FileIdentity.of(saved) != nil {
        try PrivateFile.write(
          try Data(contentsOf: saved), to: paths.directory.appendingPathComponent(name))
      }
    }
    let guest = backup.appendingPathComponent(UpgradeJournal.guestRecordName)
    if try FileIdentity.of(guest) != nil {
      try PrivateFile.write(try Data(contentsOf: guest), to: paths.guestRecord)
    } else if try FileIdentity.of(paths.guestRecord) != nil {
      try FileManager.default.removeItem(at: paths.guestRecord)
    }
    try PrivateFile.sync(paths.runtimeDirectory)
    try PrivateFile.sync(paths.directory)
  }
}
