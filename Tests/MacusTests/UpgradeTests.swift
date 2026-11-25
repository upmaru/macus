import Darwin
import Foundation
import Testing

@testable import Macus

// MARK: Fixtures

let oldRevision = String(repeating: "a", count: 64)
let poolGuid = "1234567890"
let oldRootBytes = Data("old-root".utf8)
let dataMarker = Data("migrated-by-new-root".utf8)

/// A guest whose health and boot side effects the test controls.
actor UpgradeVM: VirtualMachineDriver {
  var running = false
  var health: GuestHealth?
  var startCount = 0
  var shutdownWorks = true
  var forceStopWorks = true
  /// Root disk contents at each boot, to tell the old root from the new one.
  var bootedRoots: [Data] = []
  /// Whether the backup's data copy existed when each boot began.
  var copyExistedAtBoot: [Bool] = []
  var backupData: URL?
  var writesData = false
  var gate: CheckedContinuation<Void, Never>?
  var gated = false
  var healthCalls = 0
  /// What the guest reports once it boots next, as a new root would.
  var nextBootHealth: GuestHealth?
  var bootSerial: String?

  func capabilities() async -> HostCapabilities {
    HostCapabilities(supported: true, nestedVirtualization: true)
  }
  func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws {
    running = true
    startCount += 1
    if let nextBootHealth {
      health = nextBootHealth
      self.nextBootHealth = nil
    }
    let root = try FileHandle(forReadingFrom: paths.rootDisk)
    bootedRoots.append(try root.read(upToCount: 16) ?? Data())
    try root.close()
    if let backupData {
      copyExistedAtBoot.append(FileManager.default.fileExists(atPath: backupData.path))
    }
    // VZ creates a variable store when none is attached.
    if !FileManager.default.fileExists(atPath: paths.efiStore.path) {
      try Data("new-efi".utf8).write(to: paths.efiStore)
    }
    if let bootSerial {
      // The guest's console line for this boot, as VZ appends it to serial.log.
      if !FileManager.default.fileExists(atPath: paths.serialLog.path) {
        try Data().write(to: paths.serialLog)
      }
      let serial = try FileHandle(forWritingTo: paths.serialLog)
      try serial.seekToEnd()
      try serial.write(contentsOf: Data(bootSerial.utf8))
      try serial.close()
      self.bootSerial = nil
    }
    if writesData {
      let handle = try FileHandle(forWritingTo: paths.dataDisk)
      try handle.write(contentsOf: dataMarker)
      try handle.close()
    }
  }
  func requestStop() async throws { if shutdownWorks { running = false } }
  func forceStop() async throws { if forceStopWorks { running = false } }
  func isRunning() async -> Bool { running }
  /// When set, each stream is one end of a socket pair whose other end is kept here.
  var servesStreams = false
  var guestEnds: [SocketDescriptor] = []
  func openStream(port: UInt32) async throws -> GuestStream {
    guard servesStreams else { throw RuntimeError(.unavailable, "No stream in fake") }
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw RuntimeError(.io, "socketpair")
    }
    let near = try SocketDescriptor(pair[0])
    guestEnds.append(try SocketDescriptor(pair[1]))
    return GuestStream(socket: near) {}
  }
  func setServesStreams(_ value: Bool) { servesStreams = value }
  func health() async throws -> GuestHealth {
    healthCalls += 1
    guard running, let health else { throw RuntimeError(.unavailable, "not ready") }
    if gated { await withCheckedContinuation { gate = $0 } }
    return health
  }
  func set(_ value: GuestHealth?) { health = value }
  func setAfterBoot(_ value: GuestHealth?) { nextBootHealth = value }
  func setBootSerial(_ value: String?) { bootSerial = value }
  func setRunning(_ value: Bool) { running = value }
  func setShutdownWorks(_ value: Bool) { shutdownWorks = value }
  func setForceStopWorks(_ value: Bool) { forceStopWorks = value }
  func setWritesData(_ value: Bool, backup: URL?) {
    writesData = value
    backupData = backup
  }
  func hold() { gated = true }
  func release() {
    gated = false
    gate?.resume()
    gate = nil
  }
  var waiting: Bool { gate != nil }
}

func upgradeHealth(
  guid: String = poolGuid, payload: String?, appliance: String?, package: String? = "7.0.1-r2",
  flowRelay: Int? = FlowRelayProtocol.version, contract: Int? = 1
) -> GuestHealth {
  GuestHealth(
    incusVersion: "7.0.1", apiExtensions: [], kvm: true, flowRelayVersion: flowRelay,
    guestContract: contract, payloadRevision: payload, applianceId: appliance,
    incusPackage: package,
    storage: GuestStorageIdentity(backend: "zfs", poolGuid: guid, layout: "zfs-v1", phase: "ready"))
}

/// Inventories in the order the upgrade reads them; once the script is used up, every read
/// returns `standard`.
actor FakeInventory: IncusInventorySource {
  static let standard = IncusInventory(projects: [
    IncusProjectInventory(
      name: "default", instances: ["web"], volumes: ["custom/data"], networks: ["incusbr0"],
      profiles: ["default"])
  ])
  var script: [Result<IncusInventory, RuntimeError>]
  var reads = 0
  /// `idle` and `read`, in the order the upgrade asked for them.
  var events: [String] = []
  let onRead: (@Sendable () async -> Void)?
  init(
    _ script: [Result<IncusInventory, RuntimeError>] = [],
    onRead: (@Sendable () async -> Void)? = nil
  ) {
    self.script = script
    self.onRead = onRead
  }
  func awaitIdle(open: @escaping @Sendable () async throws -> GuestStream) async throws {
    events.append("idle")
  }
  func read(open: @escaping @Sendable () async throws -> GuestStream) async throws
    -> IncusInventory
  {
    reads += 1
    events.append("read")
    if let onRead { await onRead() }
    guard !script.isEmpty else { return Self.standard }
    return try script.removeFirst().get()
  }
}

/// Files the volume was asked to put on stable storage, with whether each existed then.
final class SyncLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String] = []
  func add(_ name: String) { lock.withLock { entries.append(name) } }
  var names: [String] { lock.withLock { entries } }
}

/// Free space and clone support under the test's control; copies are real.
struct TestVolume: UpgradeVolume {
  var available: UInt64 = 1 << 50
  var cloning = true
  /// Reports clone support but fails the clone itself.
  var cloneFails = false
  var synced: SyncLog? = nil
  func availableBytes(at directory: URL) throws -> UInt64 { available }
  func supportsCloning(at directory: URL) throws -> Bool { cloning }
  func allocatedBytes(of file: URL) throws -> UInt64 { try HostVolume().allocatedBytes(of: file) }
  func clone(_ source: URL, to destination: URL) throws {
    guard cloning, !cloneFails else {
      throw RuntimeError(.io, "clonefile: Operation not supported")
    }
    try HostVolume().clone(source, to: destination)
  }
  func copy(_ source: URL, to destination: URL) throws {
    try HostVolume().copy(source, to: destination)
  }
  func sync(_ file: URL) throws {
    synced?.add(file.lastPathComponent)
    try HostVolume().sync(file)
  }
}

/// An existing state of an older appliance, plus a target appliance this package knows.
struct UpgradeFixture {
  let base: Fixture
  let entry: ApplianceCatalogEntry
  var paths: RuntimePaths { base.paths }
  let targetPayload = EmbeddedGuestPayload.revision

  init(target: String = "7.0.1-r2") throws {
    base = try Fixture()
    let paths = base.paths
    try oldRootBytes.write(to: paths.rootDisk)
    try Data("old-efi".utf8).write(to: paths.efiStore)
    try Data("old-seed".utf8).write(to: paths.seed)
    let handle = try FileHandle(forWritingTo: paths.dataDisk)
    try handle.write(contentsOf: Data("original-data".utf8))
    try handle.close()
    var entry = ApplianceCatalogEntry.current
    entry.id = "alpine-3.24.2-lts-2"
    let image = Data("new-root-image".utf8) + Data(repeating: 0, count: 4082)
    entry.rawBytes = Int64(image.count)
    entry.rawSHA256 = GuestImageManager.digestData(image)
    entry.qualifiedPackages["incus"] = target
    self.entry = entry
    let cache = paths.applianceCache(entry.id)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try image.write(to: cache.appendingPathComponent("root.raw"))
    try BootstrapStore.saveJournal(
      BootstrapJournal(
        catalogID: "alpine-3.24.2-lts-1", payloadRevision: oldRevision, archiveSHA512: "",
        rawSHA256: "", acquired: true, prepared: true), directory: paths.directory)
  }

  func record(
    package: String? = "7.0.1-r2", payload: String? = oldRevision,
    appliance: String? = "alpine-3.24.2-lts-1", storage: Bool = true
  ) throws {
    try GuestRecordStore.saveGuest(
      GuestRecord(
        guestContract: 1, payloadRevision: payload, applianceId: appliance, incusPackage: package,
        incusPackageSource: package == nil ? nil : GuestRecord.healthSource),
      paths: paths)
    if storage {
      _ = try GuestRecordStore.recordStorage(
        upgradeHealth(payload: payload, appliance: appliance), paths: paths)
    }
  }

  func service(
    _ driver: UpgradeVM, volume: TestVolume = TestVolume(),
    inventory: FakeInventory = FakeInventory(), hook: UpgradeHook? = nil
  ) throws -> RuntimeService {
    try RuntimeService(
      driver: driver, store: StateStore(paths: paths), stallLimit: .seconds(300), catalog: entry,
      payloadRevision: targetPayload, macusPackage: "test", volume: volume, upgradeHook: hook,
      inventory: inventory)
  }

  func plan(volume: TestVolume = TestVolume()) throws -> UpgradePlan {
    try UpgradePlanner.plan(
      paths: paths, catalog: entry, payloadRevision: targetPayload, volume: volume)
  }

  func stage(_ plan: UpgradePlan) async throws -> String {
    try await UpgradeStaging.stage(
      plan: plan, cache: paths.applianceCache(entry.id), entry: entry, paths: paths,
      runner: ProcessCommandRunner(), timeout: 30, environment: [:])
  }

  /// Every file rollback must restore, by content and identity.
  func snapshot() throws -> [String: Data] {
    var files: [String: Data] = [:]
    for url in [
      paths.rootDisk, paths.efiStore, paths.seed, paths.config, paths.guestRecord,
      BootstrapStore.journalURL(paths.directory),
    ] where FileManager.default.fileExists(atPath: url.path) {
      files[url.lastPathComponent] = try Data(contentsOf: url)
    }
    let data = try FileHandle(forReadingFrom: paths.dataDisk)
    files["data.raw"] = try data.read(upToCount: 64)
    try data.close()
    return files
  }

  func identities() throws -> [FileIdentity?] {
    try [paths.rootDisk, paths.efiStore, paths.seed, paths.dataDisk].map(FileIdentity.of)
  }

  func clean() { base.clean() }
}

extension GuestImageManager {
  static func digestData(_ data: Data) -> String {
    let url = URL(fileURLWithPath: "/private/tmp/macus-digest-\(UUID().uuidString)")
    try! data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try! digest(url)
  }
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

// MARK: Incus direction (3.2)

@Test func incusPackageClassesFollowFullVersions() throws {
  #expect(try UpgradePlanner.classify(recorded: "7.0.1-r2", target: "7.0.1-r2") == .reversible)
  #expect(try UpgradePlanner.classify(recorded: "7.0.1-r2", target: "7.0.1-r3") == .migrating)
  #expect(try UpgradePlanner.classify(recorded: "7.0.9-r5", target: "7.0.10-r0") == .migrating)
  #expect(try UpgradePlanner.classify(recorded: "6.9-r1", target: "7.0.1-r2") == .migrating)
  #expect(try UpgradePlanner.classify(recorded: nil, target: "7.0.1-r2") == .migrating)
  for (recorded, target) in [
    ("7.0.1-r3", "7.0.1-r2"), ("7.1.0-r0", "7.0.1-r2"), ("7.0.1", "7.0.1-r2"),
    ("7.0.1-r2", "7.0.1"), ("7.1-r0", "7.1.0-r0"), ("v7.0.1-r2", "7.0.1-r3"),
  ] {
    #expect(throws: RuntimeError.self) {
      try UpgradePlanner.classify(recorded: recorded, target: target)
    }
  }
  #expect(throws: RuntimeError.self) { try UpgradePlanner.classify(recorded: nil, target: nil) }
  let older = #expect(throws: RuntimeError.self) {
    try UpgradePlanner.classify(recorded: "7.0.1-r3", target: "7.0.1-r2")
  }
  #expect(older?.message.contains("Incus 7.0.1-r3 or newer") == true)
}

// MARK: Plan (3.2)

@Test func planReportsCurrentOnlyWhenCatalogAndPayloadMatch() throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record(payload: fixture.targetPayload, appliance: fixture.entry.id)
  let current = try fixture.plan()
  #expect(current.current)
  #expect(current.upgradeClass == nil)
  // Same appliance, older or unknown payload: the seed's scripts still differ.
  for payload in [oldRevision, nil] {
    try fixture.record(payload: payload, appliance: fixture.entry.id)
    let plan = try fixture.plan()
    #expect(!plan.current)
    #expect(plan.upgradeClass == .reversible)
    #expect(
      plan.storage == UpgradeStorageIdentity(poolGuid: poolGuid, layout: "zfs-v1", source: "health")
    )
  }
}

@Test func planClassesFromRecordedAndCatalogPackages() throws {
  // Same package: reversible, nothing copied.
  var fixture = try UpgradeFixture()
  try fixture.record()
  var plan = try fixture.plan()
  #expect(plan.upgradeClass == .reversible)
  #expect(plan.dataCopy == "none")
  #expect(plan.backupWorstCaseBytes == 0)
  fixture.clean()
  // Newer target: migrating with a clone.
  fixture = try UpgradeFixture(target: "7.0.2-r0")
  try fixture.record()
  plan = try fixture.plan()
  #expect(plan.upgradeClass == .migrating)
  #expect(plan.dataCopy == "clone")
  #expect(plan.recordedIncusPackage == "7.0.1-r2")
  fixture.clean()
  // A guest that reported only server_version and an appliance this package does not know.
  fixture = try UpgradeFixture()
  try fixture.record(package: nil, appliance: "alpine-3.20-legacy")
  plan = try fixture.plan()
  #expect(plan.recordedIncusPackage == nil)
  #expect(plan.upgradeClass == .migrating)
  fixture.clean()
  // No package reported, but the state's catalog entry is the prebuilt one this package knows.
  fixture = try UpgradeFixture()
  try fixture.record(package: nil, payload: oldRevision, appliance: fixture.entry.id)
  plan = try fixture.plan()
  #expect(plan.recordedIncusPackage == "7.0.1-r2")
  #expect(plan.recordedIncusPackageSource == "catalog")
  #expect(plan.upgradeClass == .reversible)
  fixture.clean()
  // Older target: refused.
  fixture = try UpgradeFixture(target: "7.0.1-r1")
  defer { fixture.clean() }
  try fixture.record()
  #expect(throws: RuntimeError.self) { try fixture.plan() }
}

@Test func planResolvesIdentityFromSerialLogAndRefusesWithoutOne() throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record(storage: false)
  // No record and no marker: refused, nothing guessed.
  let missing = #expect(throws: RuntimeError.self) { try fixture.plan() }
  #expect(missing?.message.contains("no recorded pool identity") == true)
  try Data(
    "boot 1\nTAMA_STORAGE_ZFS_READY 111\n[  2.1] noise TAMA_STORAGE_ZFS_READY 222\r\nTAMA_STORAGE_ZFS_READY 12x\n"
      .utf8
  ).write(to: fixture.paths.serialLog)
  let plan = try fixture.plan()
  #expect(
    plan.storage == UpgradeStorageIdentity(poolGuid: "222", layout: "zfs-v1", source: "serial"))
  // A later ext4 marker means the state is legacy storage.
  let handle = try FileHandle(forWritingTo: fixture.paths.serialLog)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("TAMA_STORAGE_EXT4_READY\n".utf8))
  try handle.close()
  let ext4 = #expect(throws: RuntimeError.self) { try fixture.plan() }
  #expect(ext4?.message.contains("ext4") == true)
}

@Test func planRequiresSpaceForTheRootAndAFullCopyWithoutClones() throws {
  let fixture = try UpgradeFixture(target: "7.0.2-r0")
  defer { fixture.clean() }
  try fixture.record()
  let root = GuestImageManager.minimumRootBytes
  let allocated = try HostVolume().allocatedBytes(of: fixture.paths.dataDisk)
  let noClone = TestVolume(cloning: false)
  let plan = try fixture.plan(volume: noClone)
  #expect(plan.dataCopy == "full")
  #expect(plan.requiredFreeBytes == root + allocated)
  #expect(plan.backupWorstCaseBytes == allocated)
  let short = #expect(throws: RuntimeError.self) {
    try fixture.plan(volume: TestVolume(available: root + allocated, cloning: false))
  }
  #expect(short?.message.contains("copied in full") == true)
  #expect(throws: RuntimeError.self) { try fixture.plan(volume: TestVolume(available: root)) }
}

// MARK: Staging (3.3)

@Test func stagingWritesPrivateFilesAndNeverTheSharedSeed() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let plan = try fixture.plan()
  let id = try await fixture.stage(plan)
  #expect(UpgradeID.isValid(id))
  let directory = fixture.paths.staging(id)
  for name in ["root.raw", "seed.iso", "staging.json"] {
    #expect(exists(directory.appendingPathComponent(name)))
  }
  #expect(!exists(directory.appendingPathComponent("seed")))
  let adopt = Data("path: \(StorageAdoption.path)".utf8)
  #expect(
    try Data(contentsOf: directory.appendingPathComponent("seed.iso")).range(of: adopt) != nil)
  let cache = fixture.paths.applianceCache(fixture.entry.id)
  #expect(try Data(contentsOf: cache.appendingPathComponent("seed.iso")).range(of: adopt) == nil)
  let staged = try UpgradeStaging.verify(
    id: id, paths: fixture.paths, entry: fixture.entry, plan: plan)
  #expect(staged.manifest == cache.appendingPathComponent("manifest.json"))
}

@Test func stagingVerificationRefusesMismatches() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let plan = try fixture.plan()
  let id = try await fixture.stage(plan)
  let verify = { (plan: UpgradePlan) in
    try UpgradeStaging.verify(id: id, paths: fixture.paths, entry: fixture.entry, plan: plan)
  }
  // Another pool than staged.
  var other = plan
  other.storage = UpgradeStorageIdentity(poolGuid: "999", layout: "zfs-v1", source: "health")
  #expect(throws: RuntimeError.self) { try verify(other) }
  // IDs that are not upgrade IDs never name a path.
  for bad in ["../x", "", "20261123T000000Z-zzzzzzzz"] {
    #expect(throws: RuntimeError.self) {
      try UpgradeStaging.verify(id: bad, paths: fixture.paths, entry: fixture.entry, plan: plan)
    }
  }
  // A seed whose user data names another pool.
  let seed = fixture.paths.staging(id).appendingPathComponent("seed.iso")
  let original = try Data(contentsOf: seed)
  var forged = original
  let needle = Data("pool_guid=\(poolGuid)".utf8)
  let range = try #require(forged.range(of: needle))
  forged.replaceSubrange(range, with: Data("pool_guid=9876543210".utf8))
  try forged.write(to: seed)
  #expect(throws: RuntimeError.self) { try verify(plan) }
  try original.write(to: seed)
  _ = try verify(plan)
  // A root that is not the catalog's image.
  let root = fixture.paths.staging(id).appendingPathComponent("root.raw")
  let handle = try FileHandle(forWritingTo: root)
  try handle.write(contentsOf: Data("x".utf8))
  try handle.close()
  #expect(throws: RuntimeError.self) { try verify(plan) }
}

@Test func mismatchedStagingIsRefusedBeforeTheStop() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let id = try await fixture.stage(try fixture.plan())
  try Data("tampered".utf8).write(to: fixture.paths.staging(id).appendingPathComponent("root.raw"))
  let driver = UpgradeVM()
  await driver.setRunning(true)
  let service = try fixture.service(driver)
  let before = try fixture.snapshot()
  await #expect(throws: RuntimeError.self) { _ = try await service.upgrade(stagingID: id) }
  #expect(await driver.running)
  #expect(!exists(fixture.paths.upgradeIntent))
  #expect(!exists(fixture.paths.staging(id)))
  #expect(try fixture.snapshot() == before)
}

// MARK: Upgrade (3.4)

@Test func reversibleUpgradeSwapsTheRootAndCommits() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let old = try fixture.identities()
  let oldConfig = try Data(contentsOf: fixture.paths.config)
  let driver = UpgradeVM()
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let service = try fixture.service(driver)
  _ = try await service.start()
  // Start rewrote the record from health; the backup must hold that one.
  let oldGuest = try Data(contentsOf: fixture.paths.guestRecord)
  let plan = try await service.upgradePlan()
  #expect(plan.upgradeClass == .reversible)
  let id = try await fixture.stage(plan)
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  let result = try await service.upgrade(stagingID: id)
  #expect(result.upgradeClass == .reversible)
  #expect(result.backupId == id)
  #expect(result.status.state == .ready)
  #expect(await driver.bootedRoots.last?.starts(with: Data("new-root-image".utf8)) == true)
  let paths = fixture.paths
  let backup = paths.backup(id)
  // The old trio is in the backup, by identity, beside copies of the records.
  #expect(try FileIdentity.of(backup.appendingPathComponent("root.raw")) == old[0])
  #expect(try FileIdentity.of(backup.appendingPathComponent("efi.bin")) == old[1])
  #expect(try FileIdentity.of(backup.appendingPathComponent("seed.iso")) == old[2])
  #expect(try Data(contentsOf: backup.appendingPathComponent("config.json")) == oldConfig)
  #expect(try Data(contentsOf: backup.appendingPathComponent("guest-record.json")) == oldGuest)
  #expect(!exists(backup.appendingPathComponent("data.raw")))
  // The data disk never moved, and the firmware store was created anew.
  #expect(try FileIdentity.of(paths.dataDisk) == old[3])
  #expect(try Data(contentsOf: paths.efiStore) == Data("new-efi".utf8))
  #expect(try fileSize(paths.rootDisk) == Int64(GuestImageManager.minimumRootBytes))
  let record = try JSON.decoder().decode(
    UpgradeBackupRecord.self, from: Data(contentsOf: backup.appendingPathComponent("backup.json")))
  #expect(record.rootIncusPackage == "7.0.1-r2")
  #expect(!record.dataCopy)
  #expect(!exists(paths.upgradeIntent))
  #expect(!exists(paths.staging(id)))
  let configuration = try await service.config()
  #expect(
    configuration.applianceManifestPath.hasSuffix(
      "appliance-cache/\(fixture.entry.id)/manifest.json"))
  let guest = try #require(try GuestRecordStore.loadGuest(paths: paths))
  #expect(guest.payloadRevision == fixture.targetPayload)
  #expect(guest.applianceId == fixture.entry.id)
  // Now current.
  #expect(try await service.upgradePlan().current)
  await #expect(throws: RuntimeError.self) { _ = try await service.upgrade(stagingID: id) }
}

@Test func migratingUpgradeCopiesDataBeforeTheNewRootBoots() async throws {
  let fixture = try UpgradeFixture(target: "7.0.2-r0")
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(
    upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id, package: "7.0.2-r0"))
  await driver.setWritesData(
    true, backup: fixture.paths.backup(id).appendingPathComponent("data.raw"))
  let result = try await service.upgrade(stagingID: id)
  #expect(result.upgradeClass == .migrating)
  #expect(result.dataCopy == "clone")
  #expect(await driver.copyExistedAtBoot == [true])
  let copy = fixture.paths.backup(id).appendingPathComponent("data.raw")
  let saved = try FileHandle(forReadingFrom: copy)
  #expect(try saved.read(upToCount: 13) == Data("original-data".utf8))
  try saved.close()
  let record = try JSON.decoder().decode(
    UpgradeBackupRecord.self,
    from: Data(contentsOf: fixture.paths.backup(id).appendingPathComponent("backup.json")))
  #expect(record.dataCopy)
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths)?.incusPackage == "7.0.2-r0")
}

@Test func dataCopyIsSyncedBeforeItIsRecordedAndTheNewRootBoots() async throws {
  for cloning in [true, false] {
    let fixture = try UpgradeFixture(target: "7.0.2-r0")
    defer { fixture.clean() }
    try fixture.record()
    let driver = UpgradeVM()
    let log = SyncLog()
    let service = try fixture.service(
      driver, volume: TestVolume(cloning: cloning, synced: log),
      hook: { label in
        // The contents are synced while the copy still has its partial name.
        if label == "data_copy_written" { #expect(log.names == ["data.raw.partial"]) }
      })
    let id = try await fixture.stage(try await service.upgradePlan())
    await driver.set(
      upgradeHealth(
        payload: fixture.targetPayload, appliance: fixture.entry.id, package: "7.0.2-r0"))
    let result = try await service.upgrade(stagingID: id)
    #expect(result.dataCopy == (cloning ? UpgradePlan.cloneCopy : UpgradePlan.fullCopy))
    #expect(log.names == ["data.raw.partial"])
  }
}

@Test func failedRecordWriteAtCommitRollsTheUpgradeBack() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  let record = fixture.paths.guestRecord.path
  // The verified guest's record cannot replace the old one; the first rollback step frees it.
  let service = try fixture.service(
    driver,
    hook: { label in
      if label == "verified" { #expect(chflags(record, UInt32(UF_IMMUTABLE)) == 0) }
      if label == "rollback:root.raw" { #expect(chflags(record, 0) == 0) }
    })
  defer { _ = chflags(record, 0) }
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("previous root and configuration were restored") == true)
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: false)
  // Never committed with a record that still names the old appliance.
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths)?.payloadRevision == oldRevision)
}

@Test func unstoppableNewRootRefusesChangesUntilAForcedStopRollsBack() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let id = try await fixture.stage(try await service.upgradePlan())
  // The new root reports another pool and then cannot be stopped at all.
  await driver.set(
    upgradeHealth(guid: "555", payload: fixture.targetPayload, appliance: fixture.entry.id))
  await driver.setShutdownWorks(false)
  await driver.setForceStopWorks(false)
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("could not be stopped") == true)
  #expect(error?.message.contains("macus runtime stop --force") == true)
  #expect(exists(fixture.paths.upgradeIntent))
  #expect(await driver.running)
  // The uncommitted root is neither served nor replaced.
  for attempt in ["start", "stop", "plan", "restart"] {
    await #expect(throws: RuntimeError.self, "\(attempt)") {
      switch attempt {
      case "start": _ = try await service.start()
      case "stop": _ = try await service.stop(force: false)
      case "plan": _ = try await service.upgradePlan()
      default: _ = try await service.restart()
      }
    }
  }
  await #expect(throws: RuntimeError.self) { _ = try await service.openIncusStream() }
  #expect(await driver.startCount == 1)
  // A forced stop that still fails changes nothing.
  await #expect(throws: RuntimeError.self) { _ = try await service.stop(force: true) }
  #expect(exists(fixture.paths.upgradeIntent))
  // Once the guest can be stopped, the forced stop finishes the rollback.
  await driver.setForceStopWorks(true)
  let status = try await service.stop(force: true)
  #expect(status.state == .stopped)
  #expect(status.lastError?.contains("previous root and configuration were restored") == true)
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: false)
  _ = try await service.upgradePlan()
}

@Test func relayStaysClosedUntilTheUpgradeCommits() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  await driver.hold()
  let upgrade = Task { try await service.upgrade(stagingID: id) }
  for _ in 0..<400 where !(await driver.waiting) { try await Task.sleep(for: .milliseconds(10)) }
  #expect(await driver.waiting)
  // The guest is answering health, but the runtime is not ready and serves no relay.
  let progress = await service.progress()
  #expect(progress.operation == "upgrade")
  #expect(!progress.ready)
  #expect(progress.state == .starting)
  await #expect(throws: RuntimeError.self) { _ = try await service.openIncusStream() }
  await #expect(throws: RuntimeError.self) { _ = try await service.stop(force: true) }
  await driver.release()
  let result = try await upgrade.value
  #expect(result.status.state == .ready)
  #expect(await service.progress().operation == nil)
}

@Test func gracefulStopTimeoutAbortsBeforeAnyDiskMoves() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let service = try fixture.service(driver)
  _ = try await service.start()
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.setShutdownWorks(false)
  let before = try fixture.snapshot()
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.code == .timeout)
  #expect(error?.message.contains("before any disk was moved") == true)
  #expect(await driver.running)
  #expect(!exists(fixture.paths.upgradeIntent))
  #expect(!exists(fixture.paths.backup(id)))
  // Refused before the journal: the staged files are removed, and the next try stages anew.
  #expect(!exists(fixture.paths.staging(id)))
  #expect(try fixture.snapshot() == before)
}

@Test func nothingToUpgradeAndLegacyStorageChangeNothing() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record(payload: fixture.targetPayload, appliance: fixture.entry.id)
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  #expect(try await service.upgradePlan().current)
  let before = try fixture.snapshot()
  await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: UpgradeID.make())
  }
  #expect(try fixture.snapshot() == before)
  try fixture.record(storage: false)
  try FileManager.default.removeItem(at: fixture.paths.storageIdentity)
  try Data("TAMA_STORAGE_EXT4_READY\n".utf8).write(to: fixture.paths.serialLog)
  let ext4 = await #expect(throws: RuntimeError.self) { _ = try await service.upgradePlan() }
  #expect(ext4?.message.contains("ext4") == true)
  #expect(await driver.startCount == 0)
}

// MARK: Rollback (3.5)

func expectRestored(
  _ fixture: UpgradeFixture, before: [String: Data], identities: [FileIdentity?], id: String,
  migratedAside: Bool, written: Bool = true
) throws {
  let after = try fixture.snapshot()
  #expect(after == before)
  let now = try fixture.identities()
  #expect(Array(now[0..<3]) == Array(identities[0..<3]))
  #expect(!exists(fixture.paths.upgradeIntent))
  #expect(!exists(fixture.paths.staging(id)))
  #expect(!exists(fixture.paths.backup(id).appendingPathComponent("backup.json")))
  let failedData = fixture.paths.backup(id).appendingPathComponent("failed/data.raw")
  #expect(exists(failedData) == migratedAside)
  if migratedAside {
    let handle = try FileHandle(forReadingFrom: failedData)
    let head = try handle.read(upToCount: dataMarker.count)
    #expect((head == dataMarker) == written)
    try handle.close()
  } else {
    #expect(now[3] == identities[3])
  }
}

@Test func refusedAdoptionRollsBackAndNamesOnlyStart() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let id = try await fixture.stage(try await service.upgradePlan())
  // The new root refuses the named pool, as on hardware with a wrong GUID (task 5.5).
  await driver.setBootSerial("MACUS_OBSERVATION v1 stage=failed code=storage_adoption_refused\n")
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  let message = error?.message ?? ""
  #expect(message.contains("code storage_adoption_refused"))
  #expect(
    message.contains("previous root and configuration were restored and the runtime is stopped"))
  #expect(message.hasSuffix("Run macus start to boot the previous root."))
  // The guest was already stopped and its root restored: no forced stop to suggest.
  #expect(!message.contains("stop --force"))
  #expect(!message.contains(RuntimeService.bootFailureRecovery))
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: false)
  #expect(await service.status().state == .stopped)
  #expect(await service.status().lastError == message)
  #expect(!(await driver.running))
}

@Test func failedBootRestoresThePreviousStateWithTheDataCopy() async throws {
  let fixture = try UpgradeFixture(target: "7.0.2-r0")
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let id = try await fixture.stage(try await service.upgradePlan())
  // The new root migrates the data disk but never becomes ready.
  await driver.setWritesData(true, backup: nil)
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("previous root and configuration were restored") == true)
  #expect(error?.message.contains("data disk was replaced by its copy") == true)
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: true)
  let failed = fixture.paths.backup(id).appendingPathComponent("failed")
  #expect(try Data(contentsOf: failed.appendingPathComponent("efi.bin")) == Data("new-efi".utf8))
  #expect(exists(failed.appendingPathComponent("root.raw")))
  #expect(exists(failed.appendingPathComponent("seed.iso")))
  #expect(await service.status().state == .stopped)
  #expect(!(await driver.running))
}

@Test func failedVerificationRollsBackAReversibleUpgrade() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let id = try await fixture.stage(try await service.upgradePlan())
  // Ready, but reporting another pool.
  await driver.set(
    upgradeHealth(guid: "555", payload: fixture.targetPayload, appliance: fixture.entry.id))
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("did not report pool \(poolGuid)") == true)
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: false)
  // The guest record still describes the previous root.
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths)?.payloadRevision == oldRevision)
}

/// Every labelled point of the forward path, in order.
private let interruptionPoints = [
  "journaled", "backup_created", "data_copy_written", "data_copied", "root_prepared",
  "swap:root.raw", "swap:efi.bin", "swap:seed.iso", "swap:staged-root", "swap:staged-seed",
  "swapped", "booting", "verified", "backup_recorded",
]

@Test(arguments: interruptionPoints)
func daemonStartRollsBackAnInterruptedUpgrade(point: String) async throws {
  let fixture = try UpgradeFixture(target: "7.0.2-r0")
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  await driver.set(
    upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id, package: "7.0.2-r0"))
  await driver.setWritesData(true, backup: nil)
  let service = try fixture.service(driver) { label in
    if label == point { throw UpgradeInterruption() }
  }
  let id = try await fixture.stage(try await service.upgradePlan())
  await #expect(throws: UpgradeInterruption.self) { _ = try await service.upgrade(stagingID: id) }
  #expect(exists(fixture.paths.upgradeIntent))
  // The process died: the next daemon start resolves the journal before anything else.
  let restarted = try fixture.service(UpgradeVM())
  let status = await restarted.status()
  #expect(status.state == .stopped)
  #expect(status.lastError?.contains("was rolled back") == true)
  let index = interruptionPoints.firstIndex(of: point)!
  let booting = interruptionPoints.firstIndex(of: "booting")!
  // From `booting` on, the data disk may have been migrated, so its copy replaces it; the
  // fake writes into it only once it has actually started.
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: index >= booting,
    written: index > booting)
  // Start is accepted again, on the previous root.
  let next = UpgradeVM()
  await next.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let again = try fixture.service(next)
  _ = try await again.start()
  #expect(await next.bootedRoots == [oldRootBytes])
}

@Test func interruptedRollbackFinishesAtTheNextDaemonStart() async throws {
  let fixture = try UpgradeFixture(target: "7.0.2-r0")
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  await driver.setWritesData(true, backup: nil)
  let service = try fixture.service(driver) { label in
    if label == "rollback:efi.bin" { throw RuntimeError(.io, "power lost") }
  }
  let id = try await fixture.stage(try await service.upgradePlan())
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("could not be rolled back automatically") == true)
  // Every mutation is refused until it is resolved.
  await #expect(throws: RuntimeError.self) { _ = try await service.start() }
  await #expect(throws: RuntimeError.self) { _ = try await service.delete(confirm: true) }
  let restarted = try fixture.service(UpgradeVM())
  #expect(await restarted.status().state == .stopped)
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: true)
}

@Test func unreadableJournalPreservesEverything() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  try Data("{not json".utf8).write(to: fixture.paths.upgradeIntent)
  let service = try fixture.service(UpgradeVM())
  let status = await service.status()
  #expect(status.state == .failed)
  #expect(status.lastError?.contains("upgrade.pending cannot be read") == true)
  let refused = await #expect(throws: RuntimeError.self) { _ = try await service.start() }
  #expect(refused?.code == .conflict)
  await #expect(throws: RuntimeError.self) { _ = try await service.upgradePlan() }
  #expect(try fixture.snapshot() == before)
  #expect(exists(fixture.paths.upgradeIntent))
}

@Test func resetKeepsBackups() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  _ = try await service.upgrade(stagingID: id)
  _ = try await service.stop()
  _ = try await service.delete(confirm: true)
  #expect(exists(fixture.paths.backup(id).appendingPathComponent("root.raw")))
  #expect(exists(fixture.paths.backup(id).appendingPathComponent("backup.json")))
}

// MARK: Data copy (3.6)

@Test func hostVolumeClonesAndCopiesSparsely() throws {
  let directory = URL(fileURLWithPath: "/private/tmp/macus-volume-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("data.raw")
  try StateStore.growDisk(source, bytes: 1024 * 1024 * 1024, create: true)
  let handle = try FileHandle(forWritingTo: source)
  try handle.write(contentsOf: Data("payload".utf8))
  try handle.close()
  let volume = HostVolume()
  #expect(try volume.supportsCloning(at: directory))
  let clone = directory.appendingPathComponent("clone.raw")
  try volume.clone(source, to: clone)
  let copy = directory.appendingPathComponent("copy.raw")
  try volume.copy(source, to: copy)
  for file in [clone, copy] {
    #expect(try FileIdentity.of(file) != FileIdentity.of(source))
    #expect(try fileSize(file) == 1024 * 1024 * 1024)
    let read = try FileHandle(forReadingFrom: file)
    #expect(try read.read(upToCount: 7) == Data("payload".utf8))
    try read.close()
  }
  // The full copy keeps the holes of the sparse disk.
  #expect(try volume.allocatedBytes(of: copy) < 16 * 1024 * 1024)
  #expect(throws: RuntimeError.self) { try volume.clone(source, to: copy) }
  #expect(throws: RuntimeError.self) { try volume.copy(source, to: clone) }
}

@Test func volumeWithoutClonesCopiesTheDataDiskInFull() async throws {
  let fixture = try UpgradeFixture(target: "7.0.2-r0")
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  let volume = TestVolume(cloning: false)
  let service = try fixture.service(driver, volume: volume)
  let plan = try await service.upgradePlan()
  #expect(plan.dataCopy == "full")
  let id = try await fixture.stage(plan)
  await driver.set(
    upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id, package: "7.0.2-r0"))
  let result = try await service.upgrade(stagingID: id)
  #expect(result.dataCopy == "full")
  let copy = fixture.paths.backup(id).appendingPathComponent("data.raw")
  #expect(try fileSize(copy) == 1024 * 1024 * 1024)
}

@Test func noSpaceForACopyIsRefusedBeforeTheStop() async throws {
  let fixture = try UpgradeFixture(target: "7.0.2-r0")
  defer { fixture.clean() }
  try fixture.record()
  let id = try await fixture.stage(try fixture.plan())
  let driver = UpgradeVM()
  await driver.setRunning(true)
  let service = try fixture.service(
    driver, volume: TestVolume(available: GuestImageManager.minimumRootBytes, cloning: false))
  let before = try fixture.snapshot()
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("free on the state volume") == true)
  #expect(await driver.running)
  #expect(!exists(fixture.paths.upgradeIntent))
  #expect(try fixture.snapshot() == before)
}

// MARK: Bootstrap journal

@Test func bootstrapJournalRoundTripsAndReadsExistingFiles() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let journal = BootstrapJournal(
    catalogID: "alpine-3.24.2-lts-1", payloadRevision: oldRevision, archiveSHA512: "s5",
    rawSHA256: "s2", acquired: true, prepared: true)
  try BootstrapStore.saveJournal(journal, directory: fixture.paths.directory)
  let text = try String(
    contentsOf: BootstrapStore.journalURL(fixture.paths.directory), encoding: .utf8)
  for key in ["\"catalog_id\"", "\"archive_sha512\"", "\"raw_sha256\"", "\"payload_revision\""] {
    #expect(text.contains(key))
  }
  #expect(try BootstrapStore.loadJournal(fixture.paths.directory) == journal)
  // A journal written by an earlier package.
  try Data(
    #"{"acquired":true,"archive_sha512":"s5","catalog_id":"alpine-3.24.2-lts-1","payload_revision":"p","prepared":true,"raw_sha256":"s2","schema_version":1}"#
      .utf8
  ).write(to: BootstrapStore.journalURL(fixture.paths.directory))
  #expect(
    try BootstrapStore.loadJournal(fixture.paths.directory)?.catalogID == "alpine-3.24.2-lts-1")
}

@Test func failedCloneFallsBackToAFullCopyOnlyWithSpace() async throws {
  for available in [UInt64(1) << 50, GuestImageManager.minimumRootBytes + 1] {
    let fixture = try UpgradeFixture(target: "7.0.2-r0")
    defer { fixture.clean() }
    try fixture.record()
    let before = try fixture.snapshot()
    let driver = UpgradeVM()
    await driver.set(
      upgradeHealth(
        payload: fixture.targetPayload, appliance: fixture.entry.id, package: "7.0.2-r0"))
    let service = try fixture.service(
      driver, volume: TestVolume(available: available, cloneFails: true))
    let id = try await fixture.stage(try await service.upgradePlan())
    if available > GuestImageManager.minimumRootBytes + 1 {
      let result = try await service.upgrade(stagingID: id)
      #expect(result.status.state == .ready)
      // The method actually used, not the planned clone.
      #expect(result.dataCopy == UpgradePlan.fullCopy)
      #expect(exists(fixture.paths.backup(id).appendingPathComponent("data.raw")))
    } else {
      let error = await #expect(throws: RuntimeError.self) {
        _ = try await service.upgrade(stagingID: id)
      }
      #expect(error?.message.contains("lacks space for a full copy") == true)
      #expect(await driver.startCount == 0)
      #expect(try fixture.snapshot() == before)
      #expect(!exists(fixture.paths.backup(id).appendingPathComponent("data.raw")))
    }
  }
}
