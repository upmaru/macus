import Darwin
import Foundation

/// Upgrade and backup IDs: a UTC time that sorts, then random hex. Validated before any ID
/// names a path.
enum UpgradeID {
  static func make(now: Date = Date()) -> String {
    let random = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    return "\(stamp().string(from: now))-\(random)"
  }

  /// A new ID that sorts after every backup's. Rollback restores the latest backup by ID, so
  /// an ID made within the second of the newest backup, or before it under a clock change,
  /// takes the second after it.
  static func next(paths: RuntimePaths, now: Date = Date()) -> String {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: paths.backupsDirectory.path)) ?? []
    guard let newest = names.filter(isValid).max(),
      let newestTime = stamp().date(from: String(newest.prefix(16))),
      now < newestTime.addingTimeInterval(1)
    else { return make(now: now) }
    return make(now: newestTime.addingTimeInterval(1))
  }

  /// Whether `id` sorts after every backup's, so a backup under it is the latest.
  static func sortsAfterBackups(_ id: String, paths: RuntimePaths) -> Bool {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: paths.backupsDirectory.path)) ?? []
    return names.filter(isValid).allSatisfy { $0 < id }
  }

  private static func stamp() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }

  static func isValid(_ id: String) -> Bool {
    let bytes = Array(id.utf8)
    guard bytes.count == 25 else { return false }
    func digits(_ range: Range<Int>) -> Bool {
      bytes[range].allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }
    let hex = bytes[17..<25].allSatisfy {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
    }
    return digits(0..<8) && bytes[8] == UInt8(ascii: "T") && digits(9..<15)
      && bytes[15] == UInt8(ascii: "Z") && bytes[16] == UInt8(ascii: "-") && hex
  }

  static func validate(_ id: String) throws {
    guard isValid(id) else { throw RuntimeError(.invalidRequest, "Invalid upgrade ID") }
  }
}

/// What the client staged, written last so a partial staging directory has no record.
struct UpgradeStagingRecord: Codable, Sendable, Equatable {
  var schemaVersion = 1
  var id: String
  var catalogId: String
  var payloadRevision: String
  var rawSha256: String
  var upgradeClass: UpgradeClass
  var poolGuid: String
  var layout: String
}

/// A staged upgrade the daemon has verified: every path is inside the state directory.
struct StagedUpgrade: Sendable {
  let record: UpgradeStagingRecord
  let directory: URL
  let root: URL
  let seed: URL
  /// The installed appliance in the shared cache, which the new configuration names.
  let manifest: URL
  let creationSeed: URL
}

enum UpgradeStaging {
  static let recordName = "staging.json"

  /// Client side: stages the target root and the upgrade seed from a verified appliance
  /// cache into a new private `STATE/upgrade-<id>/`. It also makes sure the cache has the
  /// manifest and the creation seed the new configuration names. Returns the staging ID.
  static func stage(
    plan: UpgradePlan, cache: URL, entry: ApplianceCatalogEntry, paths: RuntimePaths,
    runner: any LocalCommandRunner, timeout: Int, environment: [String: String],
    volume: any UpgradeVolume = HostVolume(), now: Date = Date()
  ) async throws -> String {
    guard !plan.current, let upgradeClass = plan.upgradeClass, let storage = plan.storage,
      plan.toCatalogId == entry.id
    else {
      throw RuntimeError(.invalidRequest, "Only a planned upgrade to this appliance can be staged")
    }
    let adoption = try StorageAdoption(poolGuid: storage.poolGuid, layout: storage.layout)
    // The creation seed and manifest in the cache, exactly as start prepares them.
    _ = try await SeedPreparation.prepare(
      entry: entry, cache: cache, runner: runner, timeout: timeout, environment: environment)
    let id = UpgradeID.next(paths: paths, now: now)
    let directory = paths.staging(id)
    try PrivateFile.makeDirectory(directory)
    do {
      let root = directory.appendingPathComponent("root.raw")
      let cached = cache.appendingPathComponent("root.raw")
      try requireOwnedRegular(cached)
      // A clone costs nothing on the state volume; otherwise the image is copied.
      do { try volume.clone(cached, to: root) } catch { try volume.copy(cached, to: root) }
      guard chmod(root.path, 0o600) == 0 else { throw RuntimeError(.io, "Cannot secure root") }
      _ = try await SeedPreparation.prepareUpgradeSeed(
        entry: entry, adoption: adoption, directory: directory, runner: runner,
        timeout: timeout, environment: environment)
      let record = UpgradeStagingRecord(
        id: id, catalogId: entry.id, payloadRevision: plan.toPayloadRevision,
        rawSha256: entry.rawSHA256, upgradeClass: upgradeClass, poolGuid: storage.poolGuid,
        layout: storage.layout)
      try PrivateFile.write(
        try JSON.encoder().encode(record), to: directory.appendingPathComponent(recordName),
        syncDirectory: true)
      return id
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Client side: removes a staged upgrade the runtime service never received.
  static func discard(_ id: String, paths: RuntimePaths) {
    guard UpgradeID.isValid(id) else { return }
    try? FileManager.default.removeItem(at: paths.staging(id))
  }

  /// Daemon side: the staged files are input from another process, so each one is checked
  /// against what this executable would produce for the plan. The root's digest must match
  /// the installed catalog entry, and the seed must contain exactly the user data this
  /// package renders for the planned pool.
  static func verify(
    id: String, paths: RuntimePaths, entry: ApplianceCatalogEntry, plan: UpgradePlan
  ) throws -> StagedUpgrade {
    try UpgradeID.validate(id)
    let directory = paths.staging(id)
    guard try PrivateFile.isOwnedDirectory(directory) else {
      throw RuntimeError(.notFound, "No staged upgrade \(id)")
    }
    let recordURL = directory.appendingPathComponent(recordName)
    try requireOwnedRegular(recordURL)
    let record = try JSON.decoder().decode(
      UpgradeStagingRecord.self, from: Data(contentsOf: recordURL))
    guard let upgradeClass = plan.upgradeClass, let storage = plan.storage else {
      throw RuntimeError(.conflict, "Nothing to upgrade")
    }
    guard record.schemaVersion == 1, record.id == id, record.catalogId == entry.id,
      record.payloadRevision == plan.toPayloadRevision, record.rawSha256 == entry.rawSHA256
    else {
      throw RuntimeError(
        .conflict, "Staged upgrade \(id) is for another appliance or payload; stage it again")
    }
    guard record.upgradeClass == upgradeClass, record.poolGuid == storage.poolGuid,
      record.layout == storage.layout
    else {
      throw RuntimeError(
        .conflict,
        "Staged upgrade \(id) was planned as a \(record.upgradeClass.rawValue) upgrade of pool \(record.poolGuid), but the state now plans \(upgradeClass.rawValue) for pool \(storage.poolGuid). Stage it again; nothing was changed."
      )
    }
    let root = directory.appendingPathComponent("root.raw")
    try requireOwnedRegular(root)
    guard try fileSize(root) == entry.rawBytes, try sha256(root) == entry.rawSHA256 else {
      throw RuntimeError(.conflict, "Staged root disk does not match the installed appliance")
    }
    let seed = directory.appendingPathComponent("seed.iso")
    try requireOwnedRegular(seed)
    let adoption = try StorageAdoption(poolGuid: storage.poolGuid, layout: storage.layout)
    let expected = Data(try SeedPreparation.userData(entry: entry, adoption: adoption).utf8)
    // The ISO stores user data uncompressed and contiguous.
    guard try Data(contentsOf: seed).range(of: expected) != nil else {
      throw RuntimeError(
        .conflict,
        "Staged seed does not carry this package's user data for pool \(storage.poolGuid)")
    }
    let cache = paths.applianceCache(entry.id)
    let manifest = cache.appendingPathComponent("manifest.json")
    let creationSeed = cache.appendingPathComponent("seed.iso")
    try requireOwnedRegular(manifest)
    try requireOwnedRegular(creationSeed)
    let decoded = try JSON.decoder().decode(
      ApplianceManifest.self, from: Data(contentsOf: manifest))
    guard decoded.id == entry.id, decoded.sha256 == entry.rawSHA256 else {
      throw RuntimeError(.conflict, "The appliance cache manifest does not match this package")
    }
    return StagedUpgrade(
      record: record, directory: directory, root: root, seed: seed, manifest: manifest,
      creationSeed: creationSeed)
  }
}
