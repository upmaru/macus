import Darwin
import Foundation

/// Guest contract versions this host can serve. A guest reports its contract in health; the
/// value is raised only when a host can no longer serve an older guest. 1 covers the
/// flow-controlled relay. A guest that answers health without the flow relay is recorded as
/// contract 0, so the next start can refuse it before booting.
public enum GuestContract {
  public static let minimum = 1
  static let preFlowRelay = 0
}

/// What the daemon last observed from a ready guest of this state. The daemon is its only
/// writer; it lives beside the disks so a backup carries it. A nil field is unknown.
struct GuestRecord: Codable, Sendable, Equatable {
  var schemaVersion: Int = 1
  var guestContract: Int?
  var payloadRevision: String?
  var applianceId: String?
  /// The full installed Incus package with its release suffix, never `server_version`.
  var incusPackage: String?
  /// `health` when the guest reported it, `catalog` when it came from a known prebuilt entry.
  var incusPackageSource: String?
  /// The Macus package that made the observation, when the build records one.
  var lastReadyPackage: String?

  static let healthSource = "health"
  static let catalogSource = "catalog"
}

/// The ZFS pool this state owns, taken from a ready guest, so ownership survives replacement
/// of the root disk.
struct StorageIdentityRecord: Codable, Sendable, Equatable {
  var schemaVersion: Int = 1
  var backend: String
  var poolGuid: String
  var layout: String
  var source: String

  static let healthSource = "health"
}

enum StorageIdentityOutcome: Sendable, Equatable {
  /// The guest reported no ready ZFS identity; the record, if any, is unchanged.
  case notApplicable
  case written
  case unchanged
  /// An existing record names a different pool. It is never replaced.
  case conflict(recorded: String, reported: String)
}

enum GuestRecordStore {
  static func loadGuest(paths: RuntimePaths) throws -> GuestRecord? {
    guard let data = try read(paths.guestRecord) else { return nil }
    let value = try JSON.decoder().decode(GuestRecord.self, from: data)
    guard value.schemaVersion == 1 else {
      throw RuntimeError(.invalidConfiguration, "Unsupported guest record schema")
    }
    return value
  }

  static func loadStorageIdentity(paths: RuntimePaths) throws -> StorageIdentityRecord? {
    guard let data = try read(paths.storageIdentity) else { return nil }
    let value = try JSON.decoder().decode(StorageIdentityRecord.self, from: data)
    guard value.schemaVersion == 1, value.backend == "zfs", !value.poolGuid.isEmpty else {
      throw RuntimeError(.invalidConfiguration, "Unsupported storage identity record")
    }
    return value
  }

  /// The record for a ready guest's health. Every field reflects this health, so a restored
  /// backup or an older guest cannot leave a stale value, with one exception: a package the
  /// same appliance reported earlier is kept while its guest has not yet reported it again.
  static func observe(
    _ health: GuestHealth, previous: GuestRecord?, catalogPackage: String?,
    macusPackage: String?
  ) -> GuestRecord {
    var record = GuestRecord(
      guestContract: health.guestContract
        ?? (health.servesFlowRelay ? nil : GuestContract.preFlowRelay),
      payloadRevision: health.payloadRevision, applianceId: health.applianceId,
      lastReadyPackage: macusPackage)
    if let package = health.incusPackage {
      record.incusPackage = package
      record.incusPackageSource = GuestRecord.healthSource
    } else if let previous, previous.incusPackageSource == GuestRecord.healthSource,
      let appliance = health.applianceId, previous.applianceId == appliance
    {
      record.incusPackage = previous.incusPackage
      record.incusPackageSource = previous.incusPackageSource
    } else if let catalogPackage {
      record.incusPackage = catalogPackage
      record.incusPackageSource = GuestRecord.catalogSource
    }
    return record
  }

  /// The pinned Incus package of the state's catalog entry, only when the installed package
  /// knows that entry and it is a prebuilt appliance verified against its package manifest
  /// at first boot. Anything else is unknown.
  static func catalogPackage(catalogID: String?, catalog: ApplianceCatalogEntry) -> String? {
    guard let catalogID, catalogID == catalog.id, catalog.prebuiltIdentity != nil else {
      return nil
    }
    return catalog.qualifiedPackages["incus"]
  }

  static func saveGuest(_ record: GuestRecord, paths: RuntimePaths) throws {
    try write(JSON.encoder().encode(record), to: paths.guestRecord)
  }

  /// Records a ready guest's ZFS identity, and refuses to replace a record naming another pool.
  static func recordStorage(_ health: GuestHealth, paths: RuntimePaths) throws
    -> StorageIdentityOutcome
  {
    guard let storage = health.storage, storage.backend == "zfs", storage.phase == "ready",
      let guid = storage.poolGuid, let layout = storage.layout
    else { return .notApplicable }
    let reported = StorageIdentityRecord(
      backend: "zfs", poolGuid: guid, layout: layout, source: StorageIdentityRecord.healthSource)
    if let existing = try loadStorageIdentity(paths: paths) {
      guard existing.poolGuid == guid else {
        return .conflict(recorded: existing.poolGuid, reported: guid)
      }
      if existing == reported { return .unchanged }
    }
    try write(JSON.encoder().encode(reported), to: paths.storageIdentity)
    return .written
  }

  private static func read(_ file: URL) throws -> Data? {
    var info = stat()
    if lstat(file.path, &info) != 0 {
      guard errno == ENOENT else {
        throw RuntimeError(.io, "Cannot inspect \(file.lastPathComponent)")
      }
      return nil
    }
    try requireOwnedRegular(file)
    return try Data(contentsOf: file)
  }

  /// Atomic and private: a 0600 temporary file is synced, then renamed over the record.
  private static func write(_ data: Data, to file: URL) throws {
    var info = stat()
    if lstat(file.path, &info) == 0 {
      try requireOwnedRegular(file)
    }
    let directory = file.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(file.lastPathComponent)-\(UUID().uuidString)")
    let descriptor = open(
      temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw RuntimeError(.io, "Cannot write \(file.lastPathComponent)")
    }
    var written = 0
    let complete = data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return data.isEmpty }
      while written < data.count {
        let result = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
        if result < 0 { return false }
        written += result
      }
      return true
    }
    let synced = complete && fsync(descriptor) == 0
    close(descriptor)
    guard synced, rename(temporary.path, file.path) == 0 else {
      _ = unlink(temporary.path)
      throw RuntimeError(.io, "Cannot write \(file.lastPathComponent)")
    }
  }
}
