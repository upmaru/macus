import Foundation

/// A full APK package version with its release suffix, such as `7.0.1-r2`. Only the dotted
/// numeric upstream form with an `-rN` release has a direction; anything else is refused.
struct IncusPackageVersion: Comparable, Sendable {
  let upstream: [Int]
  let release: Int

  init?(_ text: String) {
    guard let dash = text.range(of: "-r", options: .backwards) else { return nil }
    let upstreamText = text[..<dash.lowerBound]
    let releaseText = text[dash.upperBound...]
    let parts = upstreamText.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 8,
      parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isASCIIDigit) }),
      !releaseText.isEmpty, releaseText.count <= 9, releaseText.allSatisfy(\.isASCIIDigit),
      let release = Int(releaseText)
    else { return nil }
    self.upstream = parts.map { Int($0)! }
    self.release = release
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    let count = max(lhs.upstream.count, rhs.upstream.count)
    for index in 0..<count {
      let left = index < lhs.upstream.count ? lhs.upstream[index] : 0
      let right = index < rhs.upstream.count ? rhs.upstream[index] : 0
      if left != right { return left < right }
    }
    return lhs.release < rhs.release
  }

}

extension Character {
  fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

public enum UpgradeClass: String, Codable, Sendable {
  /// The Incus package is exactly equal: only the root is replaced.
  case reversible
  /// The Incus package is newer or unknown: the data disk is copied before the new root boots.
  case migrating
}

/// The pool the upgrade seed names. The GUID only selects the pool; the guest proves it.
public struct UpgradeStorageIdentity: Codable, Sendable, Equatable {
  public let poolGuid: String
  public let layout: String
  /// `health` from the daemon's record, `serial` from the last storage marker in serial.log.
  public let source: String
}

public struct UpgradePlan: Codable, Sendable, Equatable {
  public var schemaVersion = 1
  /// The state's catalog ID and recorded payload revision both match the installed package.
  public var current: Bool
  public var fromCatalogId: String?
  public var toCatalogId: String
  public var fromPayloadRevision: String?
  public var toPayloadRevision: String
  /// Nil only when current.
  public var upgradeClass: UpgradeClass?
  public var recordedIncusPackage: String?
  public var recordedIncusPackageSource: String?
  public var targetIncusPackage: String?
  public var storage: UpgradeStorageIdentity?
  /// `none`, `clone` or `full`: how the data disk is copied.
  public var dataCopy: String
  /// Free space the upgrade needs before it stops the runtime.
  public var requiredFreeBytes: UInt64
  public var availableBytes: UInt64
  /// What keeping the backup can cost once the guest has rewritten the whole data disk.
  public var backupWorstCaseBytes: UInt64

  static let noCopy = "none"
  static let cloneCopy = "clone"
  static let fullCopy = "full"
}

/// What the last storage line in serial.log says about the pool.
enum SerialStorageMarker: Equatable {
  case zfs(guid: String)
  case ext4
}

enum UpgradePlanner {
  /// Read-only: evaluates the installed appliance against the state and writes nothing. Every
  /// refusal is a thrown error that names its reason.
  static func plan(
    paths: RuntimePaths, catalog: ApplianceCatalogEntry, payloadRevision: String,
    volume: any UpgradeVolume
  ) throws -> UpgradePlan {
    let record = try GuestRecordStore.loadGuest(paths: paths)
    let journal = try BootstrapStore.loadJournal(paths.directory)
    // A guest that predates identity reporting has a record without these fields: unknown.
    let fromCatalog = record?.applianceId ?? journal?.catalogID
    // The journal names the creation payload only while no guest has been recorded.
    let fromPayload = record == nil ? journal?.payloadRevision : record?.payloadRevision
    let recordedPackage: String?
    let recordedSource: String?
    if let package = record?.incusPackage {
      recordedPackage = package
      recordedSource = record?.incusPackageSource
    } else if let package = GuestRecordStore.catalogPackage(
      catalogID: fromCatalog, catalog: catalog)
    {
      recordedPackage = package
      recordedSource = GuestRecord.catalogSource
    } else {
      recordedPackage = nil
      recordedSource = nil
    }
    let target = catalog.qualifiedPackages["incus"]
    var plan = UpgradePlan(
      current: fromCatalog == catalog.id && fromPayload == payloadRevision,
      fromCatalogId: fromCatalog, toCatalogId: catalog.id, fromPayloadRevision: fromPayload,
      toPayloadRevision: payloadRevision, recordedIncusPackage: recordedPackage,
      recordedIncusPackageSource: recordedSource, targetIncusPackage: target,
      dataCopy: UpgradePlan.noCopy, requiredFreeBytes: 0,
      availableBytes: try volume.availableBytes(at: paths.directory), backupWorstCaseBytes: 0)
    if plan.current { return plan }
    plan.storage = try identity(paths: paths)
    let upgradeClass = try classify(recorded: recordedPackage, target: target)
    plan.upgradeClass = upgradeClass
    let root = GuestImageManager.rootBytes(imageBytes: UInt64(max(catalog.rawBytes, 0)))
    plan.requiredFreeBytes = root
    if upgradeClass == .migrating {
      let allocated = try volume.allocatedBytes(of: paths.dataDisk)
      plan.backupWorstCaseBytes = allocated
      if try volume.supportsCloning(at: paths.directory) {
        plan.dataCopy = UpgradePlan.cloneCopy
      } else {
        plan.dataCopy = UpgradePlan.fullCopy
        plan.requiredFreeBytes = root + allocated
      }
    }
    guard plan.availableBytes > plan.requiredFreeBytes else {
      throw RuntimeError(
        .conflict,
        "Upgrade needs more than \(plan.requiredFreeBytes) bytes free on the state volume (\(plan.dataCopy == UpgradePlan.fullCopy ? "the volume cannot clone the data disk, so it would be copied in full" : "a fully allocated new root")); \(plan.availableBytes) are available. Nothing was changed."
      )
    }
    return plan
  }

  /// Decision 4: exact equality is reversible; newer or unknown is migrating; older or an
  /// undeterminable direction is refused.
  static func classify(recorded: String?, target: String?) throws -> UpgradeClass {
    guard let target, let targetVersion = IncusPackageVersion(target) else {
      throw RuntimeError(
        .conflict,
        "The installed appliance's Incus package \(target ?? "is unrecorded"), so the upgrade direction cannot be determined. Nothing was changed."
      )
    }
    guard let recorded else { return .migrating }
    if recorded == target { return .reversible }
    guard let recordedVersion = IncusPackageVersion(recorded) else {
      throw RuntimeError(
        .conflict,
        "This state recorded Incus package \(recorded), which cannot be compared with \(target), so the upgrade direction cannot be determined. Nothing was changed."
      )
    }
    // Equal in value but not in text, such as 7.1-r0 and 7.1.0-r0: not provably the same.
    if !(recordedVersion < targetVersion) && !(targetVersion < recordedVersion) {
      throw RuntimeError(
        .conflict,
        "This state recorded Incus package \(recorded), which is not exactly \(target), so the upgrade direction cannot be determined. Nothing was changed."
      )
    }
    guard recordedVersion < targetVersion else {
      throw RuntimeError(
        .conflict,
        "This state last ran Incus package \(recorded), newer than \(target) in the installed Macus appliance. Incus is never downgraded: install a Macus whose appliance carries Incus \(recorded) or newer. Nothing was changed."
      )
    }
    return .migrating
  }

  /// Decision 2: the daemon's record, then the last storage marker in serial.log. Nothing is
  /// guessed, and a legacy ext4 state is refused.
  static func identity(paths: RuntimePaths) throws -> UpgradeStorageIdentity {
    if let record = try GuestRecordStore.loadStorageIdentity(paths: paths) {
      guard record.layout == StorageAdoption.supportedLayout else {
        throw RuntimeError(
          .conflict,
          "This state's pool uses layout \(record.layout), which upgrade does not support. Nothing was changed."
        )
      }
      return UpgradeStorageIdentity(
        poolGuid: record.poolGuid, layout: record.layout, source: record.source)
    }
    switch try lastStorageMarker(paths.serialLog) {
    case .zfs(let guid):
      // Storage prints the ready marker only after checking the zfs-v1 layout.
      return UpgradeStorageIdentity(
        poolGuid: guid, layout: StorageAdoption.supportedLayout, source: "serial")
    case .ext4:
      throw RuntimeError(
        .conflict,
        "This state uses legacy ext4 storage, which upgrade does not convert. Nothing was changed."
      )
    case nil:
      throw RuntimeError(
        .conflict,
        "This state has no recorded pool identity and serial.log has no storage ready marker, so the pool to keep cannot be named. Nothing was changed."
      )
    }
  }

  static let zfsReadyMarker = "TAMA_STORAGE_ZFS_READY "
  static let ext4ReadyMarker = "TAMA_STORAGE_EXT4_READY"

  /// The last storage ready marker in serial.log, read in bounded chunks. Guest-written
  /// text: the GUID must be digits, and it only selects a pool for the guest to verify.
  static func lastStorageMarker(_ url: URL) throws -> SerialStorageMarker? {
    var info = stat()
    if lstat(url.path, &info) != 0 { return nil }
    try requireOwnedRegular(url)
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var last: SerialStorageMarker?
    var carry = Data()
    func scan(_ line: Data) {
      guard let text = String(data: line, encoding: .utf8) else { return }
      if let range = text.range(of: zfsReadyMarker, options: .backwards) {
        let guid = text[range.upperBound...].prefix { ("0"..."9").contains($0) }
        let rest = text[range.upperBound...].dropFirst(guid.count)
        if (1...20).contains(guid.count), rest.first.map({ $0 == " " || $0 == "\r" }) ?? true {
          last = .zfs(guid: String(guid))
        }
      } else if text.contains(ext4ReadyMarker) {
        last = .ext4
      }
    }
    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      carry.append(chunk)
      while let newline = carry.firstIndex(of: 0x0A) {
        scan(carry[carry.startIndex..<newline])
        carry.removeSubrange(carry.startIndex...newline)
      }
      // A line longer than the console would ever print is dropped, not buffered.
      if carry.count > 64 * 1024 { carry.removeAll() }
    }
    if !carry.isEmpty { scan(carry) }
    return last
  }
}

public struct UpgradeResult: Codable, Sendable {
  public var schemaVersion = 1
  public var backupId: String
  public var upgradeClass: UpgradeClass
  public var fromCatalogId: String?
  public var toCatalogId: String
  public var poolGuid: String
  public var dataCopy: String
  public var status: RuntimeStatus
}
