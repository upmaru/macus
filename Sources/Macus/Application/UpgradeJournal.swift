import Darwin
import Foundation

/// The step an upgrade reached. Each step is journaled before it acts, so recovery knows the
/// most an interrupted upgrade could have done.
enum UpgradeStep: String, Codable, Sendable, Comparable {
  case journaled
  case backupCreated = "backup_created"
  case dataCopied = "data_copied"
  case rootPrepared = "root_prepared"
  case swapping
  case swapped
  case booting
  case verified

  private var order: Int {
    switch self {
    case .journaled: 0
    case .backupCreated: 1
    case .dataCopied: 2
    case .rootPrepared: 3
    case .swapping: 4
    case .swapped: 5
    case .booting: 6
    case .verified: 7
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// `STATE/upgrade.pending`: durable intent written before any disk moves. The file
/// identities say, for every path, whether it holds an old file, a new one or nothing.
struct UpgradeIntent: Codable, Sendable, Equatable {
  var schemaVersion = 1
  var backupId: String
  var stagingId: String
  var upgradeClass: UpgradeClass
  var step: UpgradeStep
  var fromCatalogId: String?
  var toCatalogId: String
  var poolGuid: String
  var root: FileIdentity
  var efi: FileIdentity?
  var seed: FileIdentity?
  var data: FileIdentity
  var stagedRoot: FileIdentity
  var stagedSeed: FileIdentity
  /// The data disk copy in the backup, once it is complete.
  var dataCopy: FileIdentity?
}

/// `backups/<id>/backup.json`, written when an upgrade commits.
struct UpgradeBackupRecord: Codable, Sendable, Equatable {
  var schemaVersion = 1
  var id: String
  var createdAt: String
  var upgradeClass: UpgradeClass
  var fromCatalogId: String?
  var toCatalogId: String
  /// The backed-up root's Incus package and its source; nil when unknown.
  var rootIncusPackage: String?
  var rootIncusPackageSource: String?
  var dataCopy: Bool
  var poolGuid: String
  var macusPackage: String?
}

/// Thrown only by the test seam to simulate the daemon dying at a labelled point: the
/// upgrade then does not roll back, exactly as if the process had stopped.
struct UpgradeInterruption: Error {}

typealias UpgradeHook = @Sendable (String) throws -> Void

enum UpgradeJournal {
  static let backupRecordName = "backup.json"
  static let failedName = "failed"
  /// Records copied beside the old disks, restored by rollback.
  static let records = ["config.json", "bootstrap-journal.json"]
  static let guestRecordName = "guest-record.json"
  static let disks = ["root.raw", "efi.bin", "seed.iso"]

  static func load(paths: RuntimePaths) throws -> UpgradeIntent? {
    var info = stat()
    if lstat(paths.upgradeIntent.path, &info) != 0 {
      guard errno == ENOENT else { throw RuntimeError(.io, "Cannot inspect upgrade.pending") }
      return nil
    }
    do {
      try requireOwnedRegular(paths.upgradeIntent)
      let intent = try JSON.decoder().decode(
        UpgradeIntent.self, from: Data(contentsOf: paths.upgradeIntent))
      guard intent.schemaVersion == 1, UpgradeID.isValid(intent.backupId),
        UpgradeID.isValid(intent.stagingId)
      else { throw RuntimeError(.invalidConfiguration, "Unsupported upgrade intent") }
      return intent
    } catch {
      throw RuntimeError(
        .invalidConfiguration,
        "upgrade.pending cannot be read, so the interrupted upgrade was not resolved and every file was preserved. Restore the previous disks from STATE/backups by hand, or ask for help, before removing upgrade.pending."
      )
    }
  }

  static func save(_ intent: UpgradeIntent, paths: RuntimePaths) throws {
    try PrivateFile.write(
      try JSON.encoder().encode(intent), to: paths.upgradeIntent, syncDirectory: true)
  }

  // MARK: Forward steps

  /// Creates the backup and copies the records beside it. Nothing in `runtime/` moves.
  static func createBackup(_ intent: inout UpgradeIntent, paths: RuntimePaths, hook: UpgradeHook?)
    throws
  {
    intent.step = .backupCreated
    try save(intent, paths: paths)
    if !(try PrivateFile.isOwnedDirectory(paths.backupsDirectory)) {
      try PrivateFile.makeDirectory(paths.backupsDirectory)
    }
    let backup = paths.backup(intent.backupId)
    if !(try PrivateFile.isOwnedDirectory(backup)) { try PrivateFile.makeDirectory(backup) }
    for name in records {
      let source = paths.directory.appendingPathComponent(name)
      if try FileIdentity.of(source) != nil {
        try PrivateFile.write(
          try Data(contentsOf: source), to: backup.appendingPathComponent(name))
      }
    }
    if try FileIdentity.of(paths.guestRecord) != nil {
      try PrivateFile.write(
        try Data(contentsOf: paths.guestRecord),
        to: backup.appendingPathComponent(guestRecordName))
    }
    try PrivateFile.sync(backup)
    try PrivateFile.sync(paths.backupsDirectory)
    try hook?("backup_created")
  }

  /// A migrating upgrade copies the data disk into the backup before the new root boots. The
  /// copy appears under its final name only when complete.
  static func copyData(
    _ intent: inout UpgradeIntent, paths: RuntimePaths, method: String,
    volume: any UpgradeVolume, hook: UpgradeHook?
  ) throws {
    let backup = paths.backup(intent.backupId)
    let partial = backup.appendingPathComponent("data.raw.partial")
    let final = backup.appendingPathComponent("data.raw")
    if try FileIdentity.of(partial) != nil { try FileManager.default.removeItem(at: partial) }
    if method == UpgradePlan.cloneCopy {
      do {
        try volume.clone(paths.dataDisk, to: partial)
      } catch {
        // The volume reported clone support; a full copy now still needs the space for it.
        let needed =
          (try volume.allocatedBytes(of: paths.dataDisk))
          + GuestImageManager.minimumRootBytes
        guard try volume.availableBytes(at: paths.directory) > needed else {
          throw RuntimeError(
            .conflict,
            "The data disk could not be cloned (\(error.localizedDescription)) and the volume lacks space for a full copy"
          )
        }
        try volume.copy(paths.dataDisk, to: partial)
      }
    } else {
      try volume.copy(paths.dataDisk, to: partial)
    }
    guard chmod(partial.path, 0o600) == 0 else { throw RuntimeError(.io, "Cannot secure copy") }
    try hook?("data_copy_written")
    try PrivateFile.move(partial, to: final)
    try PrivateFile.sync(backup)
    intent.dataCopy = try FileIdentity.of(final)
    intent.step = .dataCopied
    try save(intent, paths: paths)
    try hook?("data_copied")
  }

  /// Moves the old root, firmware store and seed into the backup and the staged root and seed
  /// into `runtime/`, then saves the new configuration. Every rename is checked against the
  /// journaled identities first.
  static func swap(
    _ intent: inout UpgradeIntent, paths: RuntimePaths, staged: StagedUpgrade,
    configuration: RuntimeConfiguration, store: StateStore, hook: UpgradeHook?
  ) throws {
    intent.step = .swapping
    try save(intent, paths: paths)
    let backup = paths.backup(intent.backupId)
    for (name, identity) in zip(disks, [intent.root, intent.efi, intent.seed]) {
      let current = paths.runtimeDirectory.appendingPathComponent(name)
      guard try FileIdentity.of(current) == identity else {
        throw RuntimeError(.conflict, "runtime/\(name) changed during the upgrade")
      }
      guard identity != nil else { continue }
      try PrivateFile.move(current, to: backup.appendingPathComponent(name))
      try hook?("swap:\(name)")
    }
    try PrivateFile.sync(paths.runtimeDirectory)
    try PrivateFile.sync(backup)
    guard try FileIdentity.of(staged.root) == intent.stagedRoot,
      try FileIdentity.of(staged.seed) == intent.stagedSeed
    else { throw RuntimeError(.conflict, "The staged upgrade changed during the upgrade") }
    try PrivateFile.move(staged.root, to: paths.rootDisk)
    try hook?("swap:staged-root")
    try PrivateFile.move(staged.seed, to: paths.seed)
    try PrivateFile.sync(paths.runtimeDirectory)
    try PrivateFile.sync(staged.directory)
    try hook?("swap:staged-seed")
    try store.save(configuration)
    try PrivateFile.sync(paths.directory)
    intent.step = .swapped
    try save(intent, paths: paths)
    try hook?("swapped")
  }

  /// Writes the backup record and only then removes the staging directory and the intent.
  static func commit(
    _ intent: UpgradeIntent, record: UpgradeBackupRecord, paths: RuntimePaths,
    hook: UpgradeHook?
  ) throws {
    let backup = paths.backup(intent.backupId)
    try PrivateFile.write(
      try JSON.encoder().encode(record), to: backup.appendingPathComponent(backupRecordName),
      syncDirectory: true)
    try hook?("backup_recorded")
    try removeStaging(intent, paths: paths)
    try FileManager.default.removeItem(at: paths.upgradeIntent)
    try PrivateFile.sync(paths.directory)
  }

  // MARK: Rollback

  /// Restores the previous disks, firmware store, seed and configuration from the backup,
  /// whatever step the upgrade reached, and for a migrating upgrade that may have booted the
  /// data disk copy too. New files are moved into `backups/<id>/failed/`, never deleted. Each
  /// path is resolved by identity, so a rollback interrupted part way can run again. A file
  /// that is in neither place it could be stops rollback with everything preserved.
  static func rollback(_ intent: UpgradeIntent, paths: RuntimePaths, hook: UpgradeHook? = nil)
    throws
  {
    let backup = paths.backup(intent.backupId)
    let failed = backup.appendingPathComponent(failedName, isDirectory: true)
    let hasBackup = try PrivateFile.isOwnedDirectory(backup)
    func setAside(_ url: URL, as name: String) throws {
      if !(try PrivateFile.isOwnedDirectory(failed)) { try PrivateFile.makeDirectory(failed) }
      var destination = failed.appendingPathComponent(name)
      var suffix = 1
      while try FileIdentity.of(destination) != nil {
        destination = failed.appendingPathComponent("\(name).\(suffix)")
        suffix += 1
      }
      try PrivateFile.move(url, to: destination)
    }
    for (name, old) in zip(disks, [intent.root, intent.efi, intent.seed]) {
      let current = paths.runtimeDirectory.appendingPathComponent(name)
      let atRuntime = try FileIdentity.of(current)
      if let old {
        if atRuntime == old { continue }
        let saved = backup.appendingPathComponent(name)
        guard hasBackup, try FileIdentity.of(saved) == old else {
          throw RuntimeError(
            .io,
            "The previous \(name) is neither in runtime/ nor in backups/\(intent.backupId); every file was preserved"
          )
        }
        if atRuntime != nil { try setAside(current, as: name) }
        try PrivateFile.move(saved, to: current)
      } else if atRuntime != nil {
        // The previous state had none, such as a firmware store the new root created.
        try setAside(current, as: name)
      }
      try hook?("rollback:\(name)")
    }
    try PrivateFile.sync(paths.runtimeDirectory)
    if intent.upgradeClass == .migrating {
      try restoreData(intent, paths: paths, backup: backup, setAside: setAside)
    }
    if hasBackup {
      for name in records {
        let saved = backup.appendingPathComponent(name)
        if try FileIdentity.of(saved) != nil {
          try PrivateFile.write(
            try Data(contentsOf: saved), to: paths.directory.appendingPathComponent(name))
        }
      }
      let savedGuest = backup.appendingPathComponent(guestRecordName)
      if try FileIdentity.of(savedGuest) != nil {
        try PrivateFile.write(try Data(contentsOf: savedGuest), to: paths.guestRecord)
      }
      // A rolled-back backup is a failure record, never a restorable backup.
      let committed = backup.appendingPathComponent(backupRecordName)
      if try FileIdentity.of(committed) != nil { try setAside(committed, as: backupRecordName) }
      if try PrivateFile.isOwnedDirectory(failed) { try PrivateFile.sync(failed) }
      try PrivateFile.sync(backup)
    }
    try hook?("rollback:records")
    try removeStaging(intent, paths: paths)
    try FileManager.default.removeItem(at: paths.upgradeIntent)
    try PrivateFile.sync(paths.directory)
  }

  private static func restoreData(
    _ intent: UpgradeIntent, paths: RuntimePaths, backup: URL,
    setAside: (URL, String) throws -> Void
  ) throws {
    let current = try FileIdentity.of(paths.dataDisk)
    let saved = backup.appendingPathComponent("data.raw")
    let partial = backup.appendingPathComponent("data.raw.partial")
    if intent.step < .booting {
      // The new root never booted, so the data disk is untouched and its copy is redundant.
      guard current == intent.data else {
        throw RuntimeError(.io, "runtime/data.raw changed before boot; every file was preserved")
      }
      for copy in [saved, partial] {
        if let identity = try FileIdentity.of(copy), identity != intent.data {
          try FileManager.default.removeItem(at: copy)
        }
      }
      return
    }
    guard let copy = intent.dataCopy else {
      throw RuntimeError(.io, "The data disk copy is not recorded; every file was preserved")
    }
    if current == copy { return }
    guard try FileIdentity.of(saved) == copy else {
      throw RuntimeError(
        .io,
        "The data disk copy is missing from backups/\(intent.backupId); every file was preserved")
    }
    // The disk the new root may have migrated is kept for diagnosis.
    if current != nil { try setAside(paths.dataDisk, "data.raw") }
    try PrivateFile.move(saved, to: paths.dataDisk)
    try PrivateFile.sync(paths.runtimeDirectory)
  }

  private static func removeStaging(_ intent: UpgradeIntent, paths: RuntimePaths) throws {
    let staging = paths.staging(intent.stagingId)
    if try PrivateFile.isOwnedDirectory(staging) {
      try FileManager.default.removeItem(at: staging)
    }
  }
}
