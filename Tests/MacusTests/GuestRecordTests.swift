import Darwin
import Foundation
import Testing

@testable import Macus

private let revision = String(repeating: "c", count: 64)

private func zfsHealth(
  guid: String = "1234567890", layout: String = "zfs-v1", phase: String = "ready",
  contract: Int? = 1, payload: String? = revision, appliance: String? = "alpine-3.24.2-lts-1",
  package: String? = "7.0.1-r2", flowRelay: Int? = FlowRelayProtocol.version
) -> GuestHealth {
  GuestHealth(
    incusVersion: "7.0.1", apiExtensions: [], kvm: true, flowRelayVersion: flowRelay,
    guestContract: contract, payloadRevision: payload, applianceId: appliance,
    incusPackage: package,
    storage: GuestStorageIdentity(backend: "zfs", poolGuid: guid, layout: layout, phase: phase))
}

private func mode(_ url: URL) throws -> mode_t {
  var info = stat()
  guard lstat(url.path, &info) == 0 else { throw RuntimeError(.io, "missing \(url.path)") }
  return info.st_mode & 0o777
}

/// A prebuilt catalog entry, as the installed package knows it.
private let prebuilt = ApplianceCatalogEntry.current

// MARK: Storage identity record

@Test func storageIdentityIsWrittenOnceAndPrivately() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  #expect(try GuestRecordStore.loadStorageIdentity(paths: fixture.paths) == nil)
  #expect(try GuestRecordStore.recordStorage(zfsHealth(), paths: fixture.paths) == .written)
  let record = try #require(try GuestRecordStore.loadStorageIdentity(paths: fixture.paths))
  #expect(
    record
      == StorageIdentityRecord(
        backend: "zfs", poolGuid: "1234567890", layout: "zfs-v1", source: "health"))
  #expect(try mode(fixture.paths.storageIdentity) == 0o600)
  let written = try Data(contentsOf: fixture.paths.storageIdentity)
  #expect(try GuestRecordStore.recordStorage(zfsHealth(), paths: fixture.paths) == .unchanged)
  #expect(try Data(contentsOf: fixture.paths.storageIdentity) == written)
}

@Test func storageIdentityNeverReplacesADifferentPool() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  _ = try GuestRecordStore.recordStorage(zfsHealth(guid: "111"), paths: fixture.paths)
  let before = try Data(contentsOf: fixture.paths.storageIdentity)
  #expect(
    try GuestRecordStore.recordStorage(zfsHealth(guid: "222"), paths: fixture.paths)
      == .conflict(recorded: "111", reported: "222"))
  #expect(try Data(contentsOf: fixture.paths.storageIdentity) == before)
}

@Test func storageIdentityIgnoresUnreadyAndNonZFSGuests() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let ext4 = GuestHealth(
    incusVersion: "7.0.1", apiExtensions: [], kvm: true,
    storage: GuestStorageIdentity(backend: "ext4"))
  let legacy = GuestHealth(incusVersion: "7.0.1", apiExtensions: [], kvm: true)
  for health in [zfsHealth(phase: "preseed-pending"), ext4, legacy] {
    #expect(try GuestRecordStore.recordStorage(health, paths: fixture.paths) == .notApplicable)
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.paths.storageIdentity.path))
}

@Test func storageIdentityRefusesASymlinkedRecord() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let target = fixture.paths.directory.appendingPathComponent("elsewhere.json")
  try Data("{}".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(
    at: fixture.paths.storageIdentity, withDestinationURL: target)
  #expect(throws: RuntimeError.self) {
    try GuestRecordStore.recordStorage(zfsHealth(), paths: fixture.paths)
  }
  #expect(try Data(contentsOf: target) == Data("{}".utf8))
}

// MARK: Guest record observation

@Test func guestRecordTakesEveryFieldFromHealth() throws {
  let record = GuestRecordStore.observe(
    zfsHealth(), previous: nil, catalogPackage: "9.9.9-r9", macusPackage: "0.4.0")
  #expect(
    record
      == GuestRecord(
        guestContract: 1, payloadRevision: revision, applianceId: "alpine-3.24.2-lts-1",
        incusPackage: "7.0.1-r2", incusPackageSource: "health", lastReadyPackage: "0.4.0"))
}

@Test func serverVersionAloneLeavesThePackageUnknown() throws {
  let health = GuestHealth(incusVersion: "7.0.1", apiExtensions: [], kvm: true)
  let record = GuestRecordStore.observe(
    health, previous: nil, catalogPackage: nil, macusPackage: nil)
  #expect(record.incusPackage == nil)
  #expect(record.incusPackageSource == nil)
  #expect(record.guestContract == nil)
}

@Test func catalogFallbackOnlyForAKnownPrebuiltEntry() throws {
  #expect(prebuilt.prebuiltIdentity != nil)
  #expect(
    GuestRecordStore.catalogPackage(catalogID: prebuilt.id, catalog: prebuilt)
      == prebuilt.qualifiedPackages["incus"])
  #expect(GuestRecordStore.catalogPackage(catalogID: "alpine-3.20-old", catalog: prebuilt) == nil)
  #expect(GuestRecordStore.catalogPackage(catalogID: nil, catalog: prebuilt) == nil)
  var upstream = prebuilt
  upstream.prebuiltIdentity = nil
  #expect(GuestRecordStore.catalogPackage(catalogID: upstream.id, catalog: upstream) == nil)

  let health = GuestHealth(incusVersion: "7.0.1", apiExtensions: [], kvm: true)
  let record = GuestRecordStore.observe(
    health, previous: nil, catalogPackage: "7.0.1-r2", macusPackage: nil)
  #expect(record.incusPackage == "7.0.1-r2")
  #expect(record.incusPackageSource == "catalog")
}

@Test func reportedPackageIsKeptOnlyForTheSameAppliance() throws {
  let previous = GuestRecordStore.observe(
    zfsHealth(), previous: nil, catalogPackage: nil, macusPackage: nil)
  // The bridge finds its package in the background, so a later health can lack it.
  let same = GuestRecordStore.observe(
    zfsHealth(package: nil), previous: previous, catalogPackage: nil, macusPackage: nil)
  #expect(same.incusPackage == "7.0.1-r2")
  #expect(same.incusPackageSource == "health")
  let other = GuestRecordStore.observe(
    zfsHealth(appliance: "alpine-3.25-lts-1", package: nil), previous: previous,
    catalogPackage: nil, macusPackage: nil)
  #expect(other.incusPackage == nil)
}

@Test func olderGuestHealthCorrectsAStaleRecord() throws {
  let previous = GuestRecordStore.observe(
    zfsHealth(), previous: nil, catalogPackage: nil, macusPackage: nil)
  let older = GuestHealth(incusVersion: "7.0.1", apiExtensions: [], kvm: true)
  let record = GuestRecordStore.observe(
    older, previous: previous, catalogPackage: nil, macusPackage: nil)
  #expect(record.guestContract == nil)
  #expect(record.payloadRevision == nil)
  #expect(record.applianceId == nil)
  #expect(record.incusPackage == nil)
}

@Test func guestWithoutTheFlowRelayIsRecordedAsContractZero() throws {
  let health = GuestHealth(
    incusVersion: "7.0.1", apiExtensions: [], kvm: true, flowRelayVersion: nil)
  let record = GuestRecordStore.observe(
    health, previous: nil, catalogPackage: nil, macusPackage: nil)
  #expect(record.guestContract == GuestContract.preFlowRelay)
}

@Test func guestRecordRoundTripsAndIsPrivate() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths) == nil)
  let record = GuestRecordStore.observe(
    zfsHealth(), previous: nil, catalogPackage: nil, macusPackage: "0.4.0")
  try GuestRecordStore.saveGuest(record, paths: fixture.paths)
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths) == record)
  #expect(try mode(fixture.paths.guestRecord) == 0o600)
}

// MARK: Runtime service

actor IdentityFakeVM: VirtualMachineDriver {
  var health: GuestHealth
  var running = false
  var startCount = 0
  var requestStopCount = 0
  var forceStopCount = 0
  var shutdownWorks = true
  init(health: GuestHealth) { self.health = health }
  func setHealth(_ value: GuestHealth) { health = value }
  func setShutdownWorks(_ value: Bool) { shutdownWorks = value }
  func capabilities() async -> HostCapabilities {
    HostCapabilities(supported: true, nestedVirtualization: true)
  }
  func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws {
    running = true
    startCount += 1
  }
  func requestStop() async throws {
    requestStopCount += 1
    if shutdownWorks { running = false }
  }
  func forceStop() async throws {
    forceStopCount += 1
    running = false
  }
  func isRunning() async -> Bool { running }
  func openStream(port: UInt32) async throws -> GuestStream {
    throw RuntimeError(.unavailable, "No stream in fake")
  }
  func health() async throws -> GuestHealth {
    guard running else { throw RuntimeError(.unavailable, "Guest not running") }
    return health
  }
}

private func service(_ driver: IdentityFakeVM, _ fixture: Fixture) throws -> RuntimeService {
  try RuntimeService(
    driver: driver, store: StateStore(paths: fixture.paths), stallLimit: .seconds(300),
    catalog: prebuilt, payloadRevision: revision, macusPackage: "0.4.0")
}

@Test func readyStartRecordsGuestAndStorageIdentity() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = IdentityFakeVM(health: zfsHealth(appliance: prebuilt.id))
  let runtime = try service(driver, fixture)
  let status = try await runtime.start()
  #expect(status.state == .ready)
  let record = try #require(try GuestRecordStore.loadGuest(paths: fixture.paths))
  #expect(record.guestContract == 1)
  #expect(record.incusPackage == "7.0.1-r2")
  #expect(record.lastReadyPackage == "0.4.0")
  #expect(try GuestRecordStore.loadStorageIdentity(paths: fixture.paths)?.poolGuid == "1234567890")
  // Same appliance and payload as the installed package: nothing to upgrade.
  #expect(status.upgradeAvailable == false)
}

@Test func laterHealthUpdatesTheRecord() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = IdentityFakeVM(health: zfsHealth(appliance: prebuilt.id, package: nil))
  let runtime = try service(driver, fixture)
  _ = try await runtime.start()
  // No package reported yet: the known prebuilt catalog entry fills it.
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths)?.incusPackageSource == "catalog")
  await driver.setHealth(zfsHealth(appliance: prebuilt.id, package: "7.0.1-r2"))
  _ = await runtime.status()
  let record = try #require(try GuestRecordStore.loadGuest(paths: fixture.paths))
  #expect(record.incusPackage == "7.0.1-r2")
  #expect(record.incusPackageSource == "health")
}

@Test func repeatedStartRecordsALaterPackage() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = IdentityFakeVM(health: zfsHealth(appliance: prebuilt.id, package: nil))
  let runtime = try service(driver, fixture)
  _ = try await runtime.start()
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths)?.incusPackageSource == "catalog")
  // The package appears, and a repeated start (the already-ready path) sees it first.
  await driver.setHealth(zfsHealth(appliance: prebuilt.id, package: "7.0.1-r2"))
  _ = try await runtime.start()
  var record = try #require(try GuestRecordStore.loadGuest(paths: fixture.paths))
  #expect(record.incusPackageSource == "health")
  // A later status with the same health still leaves it recorded.
  _ = await runtime.status()
  record = try #require(try GuestRecordStore.loadGuest(paths: fixture.paths))
  #expect(record.incusPackage == "7.0.1-r2")
  #expect(record.incusPackageSource == "health")
  #expect(await driver.startCount == 1)
}

@Test func recordedIncompatibleStateIsRefusedBeforeBoot() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try GuestRecordStore.saveGuest(GuestRecord(guestContract: 0), paths: fixture.paths)
  let driver = IdentityFakeVM(health: zfsHealth())
  let runtime = try service(driver, fixture)
  do {
    _ = try await runtime.start()
    Issue.record("start succeeded for a recorded incompatible guest")
  } catch let error as RuntimeError {
    #expect(error.code == .conflict)
    #expect(error.message.contains("macus runtime upgrade"))
    #expect(error.message.contains("not booted"))
  }
  #expect(await driver.startCount == 0)
  let status = await runtime.status()
  #expect(status.state == .stopped)
  #expect(status.lastError?.contains("macus runtime upgrade") == true)
  await #expect(throws: RuntimeError.self) { try await runtime.restart() }
  #expect(await driver.startCount == 0)
}

@Test func unknownStateThatProvesIncompatibleIsStoppedGracefully() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let legacy = GuestHealth(
    incusVersion: "7.0.1", apiExtensions: [], kvm: true, flowRelayVersion: nil)
  let driver = IdentityFakeVM(health: legacy)
  let runtime = try service(driver, fixture)
  do {
    _ = try await runtime.start()
    Issue.record("start succeeded for a pre-relay guest")
  } catch let error as RuntimeError {
    #expect(error.code == .unavailable)
    #expect(error.message.hasPrefix(RuntimeService.legacyGuestReason))
    #expect(error.message.contains("stopped gracefully"))
    #expect(error.message.contains("macus runtime upgrade"))
  }
  #expect(await driver.running == false)
  #expect(await driver.requestStopCount == 1)
  #expect(await driver.forceStopCount == 0)
  // Recorded, so the next start refuses before booting the guest again.
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths)?.guestContract == 0)
  await #expect(throws: RuntimeError.self) { try await runtime.start() }
  #expect(await driver.startCount == 1)
}

@Test func lowReportedContractIsIncompatible() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = IdentityFakeVM(health: zfsHealth(contract: GuestContract.minimum - 1))
  let runtime = try service(driver, fixture)
  await #expect(throws: RuntimeError.self) { try await runtime.start() }
  #expect(await driver.running == false)
  #expect(
    try GuestRecordStore.loadGuest(paths: fixture.paths)?.guestContract
      == GuestContract.minimum - 1)
}

@Test func incompatibleGuestThatWillNotStopIsLeftRunningNotForced() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let legacy = GuestHealth(
    incusVersion: "7.0.1", apiExtensions: [], kvm: true, flowRelayVersion: nil)
  let driver = IdentityFakeVM(health: legacy)
  await driver.setShutdownWorks(false)
  let runtime = try service(driver, fixture)
  do {
    _ = try await runtime.start()
    Issue.record("start succeeded for a pre-relay guest")
  } catch let error as RuntimeError {
    #expect(error.message.contains("still running"))
    #expect(error.message.contains("macus runtime stop --force"))
  }
  #expect(await driver.running == true)
  #expect(await driver.forceStopCount == 0)
  #expect(await runtime.status().state == .failed)
}

@Test func upgradeAvailabilityFollowsTheRecord() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = IdentityFakeVM(health: zfsHealth(appliance: prebuilt.id))
  let runtime = try service(driver, fixture)
  // Nothing recorded yet.
  #expect(await runtime.status().upgradeAvailable == nil)
  _ = try await runtime.start()
  #expect(await runtime.status().upgradeAvailable == false)
  _ = try await runtime.stop()
  // An older payload, an older appliance, or a guest without identity are all upgradable.
  for record in [
    GuestRecord(
      guestContract: 1, payloadRevision: "0" + revision.dropFirst(), applianceId: prebuilt.id),
    GuestRecord(guestContract: 1, payloadRevision: revision, applianceId: "alpine-3.20-old"),
    GuestRecord(),
  ] {
    try GuestRecordStore.saveGuest(record, paths: fixture.paths)
    let status = await runtime.status()
    #expect(status.upgradeAvailable == true)
    let encoded = try JSONSerialization.jsonObject(with: JSON.encoder().encode(status))
    #expect((encoded as? [String: Any])?["upgrade_available"] as? Bool == true)
  }
}

@Test func unreadableGuestRecordIsUnknownAndBoots() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try Data("not json".utf8).write(to: fixture.paths.guestRecord)
  let driver = IdentityFakeVM(health: zfsHealth(appliance: prebuilt.id))
  let runtime = try service(driver, fixture)
  #expect(try await runtime.start().state == .ready)
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths)?.guestContract == 1)
}
