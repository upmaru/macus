import Darwin
import Foundation
import Testing

@testable import Macus

// MARK: Inventory comparison (3.7)

private func decodeInventory(_ url: URL) throws -> IncusInventory {
  try JSON.decoder().decode(IncusInventory.self, from: Data(contentsOf: url))
}

private func without(instance name: String) -> IncusInventory {
  var inventory = FakeInventory.standard
  inventory.projects[0].instances.removeAll { $0 == name }
  return inventory
}

@Test func preservedInventoryCommitsAndIsKeptInTheBackup() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  var grown = FakeInventory.standard
  grown.projects[0].instances.append("db")
  let inventory = FakeInventory([.success(FakeInventory.standard), .success(grown)])
  let service = try fixture.service(driver, inventory: inventory)
  _ = try await service.start()
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  let result = try await service.upgrade(stagingID: id)
  // A new name is allowed; every earlier one is still there.
  #expect(result.inventory.compared)
  #expect(result.inventory.skippedReason == nil)
  #expect(result.inventory.current == grown)
  #expect(await inventory.reads == 2)
  let backup = fixture.paths.backup(id)
  #expect(
    try decodeInventory(backup.appendingPathComponent("inventory-before.json"))
      == FakeInventory.standard)
  #expect(try decodeInventory(backup.appendingPathComponent("inventory-after.json")) == grown)
}

@Test func missingInstanceFailsVerificationAndRestoresThePreviousState() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let inventory = FakeInventory([
    .success(FakeInventory.standard), .success(without(instance: "web")),
  ])
  let service = try fixture.service(driver, inventory: inventory)
  _ = try await service.start()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("no longer lists instance web (project default)") == true)
  #expect(error?.message.contains("previous root and configuration were restored") == true)
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: false)
  // Both inventories stay with the failed upgrade for diagnosis.
  #expect(exists(fixture.paths.backup(id).appendingPathComponent("inventory-after.json")))
}

@Test func unreachablePreviousGuestSkipsTheComparison() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  let inventory = FakeInventory()
  let service = try fixture.service(driver, inventory: inventory)
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  let result = try await service.upgrade(stagingID: id)
  #expect(!result.inventory.compared)
  #expect(result.inventory.skippedReason?.contains("comparison was skipped") == true)
  #expect(result.inventory.current == FakeInventory.standard)
  #expect(await inventory.reads == 1)
  let backup = fixture.paths.backup(id)
  #expect(!exists(backup.appendingPathComponent("inventory-before.json")))
  #expect(exists(backup.appendingPathComponent("inventory-after.json")))
}

@Test func unreadableInventoryOfAReadyGuestIsRefusedBeforeTheStop() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let inventory = FakeInventory([.failure(RuntimeError(.unavailable, "relay refused"))])
  let service = try fixture.service(driver, inventory: inventory)
  _ = try await service.start()
  let before = try fixture.snapshot()
  let id = try await fixture.stage(try await service.upgradePlan())
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("relay refused") == true)
  #expect(error?.message.contains("Nothing was changed") == true)
  #expect(await driver.running)
  #expect(await service.status().state == .ready)
  #expect(!exists(fixture.paths.upgradeIntent))
  #expect(!exists(fixture.paths.backup(id)))
  #expect(try fixture.snapshot() == before)
}

@Test func newRootThatDoesNotServeIncusIsRolledBack() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  let inventory = FakeInventory([.failure(RuntimeError(.unavailable, "no relay"))])
  let service = try fixture.service(driver, inventory: inventory)
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message.contains("did not serve the Incus API") == true)
  try expectRestored(
    fixture, before: before, identities: identities, id: id, migratedAside: false)
}

private struct CannedIncus: IncusQuerying {
  let responses: [String: String]
  func get(_ path: String) async throws -> Data {
    guard let response = responses[path] else { throw RuntimeError(.notFound, path) }
    return Data(response.utf8)
  }
}

@Test func inventoryReaderListsNamesPerProject() async throws {
  let pool = "/1.0/storage-pools/default/volumes"
  let incus = CannedIncus(responses: [
    "/1.0/projects": #"["/1.0/projects/default","/1.0/projects/team%20a"]"#,
    "/1.0/instances?project=default": #"["/1.0/instances/web"]"#,
    "\(pool)?project=default":
      #"["\#(pool)/container/web","\#(pool)/custom/data","\#(pool)/image/abc123"]"#,
    "/1.0/networks?project=default&recursion=1":
      #"[{"name":"incusbr0","managed":true},{"name":"eth0","managed":false}]"#,
    "/1.0/profiles?project=default": #"["/1.0/profiles/default"]"#,
    "/1.0/instances?project=team%20a": #"["/1.0/instances/db?project=team%20a"]"#,
    "\(pool)?project=team%20a": #"["\#(pool)/custom/my%2Fvol?project=team%20a"]"#,
    "/1.0/networks?project=team%20a&recursion=1": "[]",
    "/1.0/profiles?project=team%20a": #"["/1.0/profiles/default?project=team%20a"]"#,
  ])
  let inventory = try await IncusInventoryReader.read(incus)
  #expect(
    inventory
      == IncusInventory(projects: [
        IncusProjectInventory(
          name: "team a", instances: ["db"], volumes: ["custom/my/vol"], networks: [],
          profiles: ["default"]),
        IncusProjectInventory(
          name: "default", instances: ["web"], volumes: ["container/web", "custom/data"],
          networks: ["incusbr0"], profiles: ["default"]),
      ]))
  #expect(inventory.projects.map(\.name) == ["default", "team a"])
  var later = inventory
  later.projects[0].instances = ["web", "new"]
  #expect(later.missing(from: inventory).isEmpty)
  later.projects[0].volumes = ["custom/data"]
  later.projects.removeLast()
  #expect(
    later.missing(from: inventory) == ["volume container/web (project default)", "project team a"])
}

/// A guest end of the flow relay: answers one HTTP request with `response`, framed.
private func flowGuest(response: String) throws -> (
  open: @Sendable () async throws -> GuestStream, request: Task<String, Error>
) {
  var pair: [Int32] = [-1, -1]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
    throw RuntimeError(.io, "socketpair failed")
  }
  let host = try SocketDescriptor(pair[0])
  let guest = try SocketDescriptor(pair[1])
  let served = Task {
    try await SocketIO.run { () throws -> String in
      var parser = FlowFrameParser()
      var request = Data()
      var answered = false
      while true {
        let chunk = try guest.read()
        if chunk.isEmpty { break }
        var ended = false
        for frame in try chunk.withUnsafeBytes({ try parser.append($0) }) {
          if case .data(let bytes) = frame { request.append(bytes) }
          if frame == .end { ended = true }
        }
        if !answered, request.range(of: Data("\r\n\r\n".utf8)) != nil {
          answered = true
          try guest.write(FlowRelayProtocol.encode(.data(Data(response.utf8))))
          try guest.write(FlowRelayProtocol.encode(.end))
        }
        if ended { break }
      }
      guest.shutdown()
      return String(decoding: request, as: UTF8.self)
    }
  }
  return ({ GuestStream(socket: host, release: {}) }, served)
}

@Test func relayQueryReadsIncusThroughTheFlowRelay() async throws {
  let body =
    #"{"type":"sync","status":"Success","status_code":200,"metadata":["/1.0/projects/default"]}"#
  let chunked =
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
    + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n0\r\n\r\n"
  let guest = try flowGuest(response: chunked)
  let data = try await RelayIncusQuery(open: guest.open, timeout: 5).get("/1.0/projects")
  #expect(try JSONDecoder().decode([String].self, from: data) == ["/1.0/projects/default"])
  #expect(try await guest.request.value.hasPrefix("GET /1.0/projects HTTP/1.1\r\n"))

  let missing = try flowGuest(
    response: "HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await RelayIncusQuery(open: missing.open, timeout: 5).get("/1.0/projects/gone")
  }
  #expect(error?.message.contains("404") == true)
  _ = try await missing.request.value
}

// MARK: Explicit rollback (3.8)

private let packageP = "7.0.1-r2"
private let packageQ = "7.0.2-r0"

private func backupID(_ offset: TimeInterval) -> String {
  UpgradeID.make(now: Date(timeIntervalSince1970: 1_700_000_000 + offset))
}

/// A committed backup of root `name`, as an earlier upgrade would have left it.
private func writeBackup(
  _ fixture: UpgradeFixture, id: String, root name: String, package: String?, data: String?,
  pool: String = poolGuid
) throws {
  let paths = fixture.paths
  if !(try PrivateFile.isOwnedDirectory(paths.backupsDirectory)) {
    try PrivateFile.makeDirectory(paths.backupsDirectory)
  }
  let directory = paths.backup(id)
  try PrivateFile.makeDirectory(directory)
  func write(_ text: String, _ file: String) throws {
    try PrivateFile.write(Data(text.utf8), to: directory.appendingPathComponent(file))
  }
  try write("root-\(name)", "root.raw")
  try write("efi-\(name)", "efi.bin")
  try write("seed-\(name)", "seed.iso")
  if let data { try write(data, "data.raw") }
  try PrivateFile.write(
    try Data(contentsOf: paths.config), to: directory.appendingPathComponent("config.json"))
  try PrivateFile.write(
    try JSON.encoder().encode(
      GuestRecord(
        guestContract: 1, payloadRevision: oldRevision, applianceId: "app-\(name)",
        incusPackage: package, incusPackageSource: package == nil ? nil : GuestRecord.healthSource)),
    to: directory.appendingPathComponent("guest-record.json"))
  try PrivateFile.write(
    try JSON.encoder().encode(
      UpgradeBackupRecord(
        id: id, createdAt: "created-\(name)", upgradeClass: data == nil ? .reversible : .migrating,
        fromCatalogId: "app-\(name)", toCatalogId: "app-next", rootIncusPackage: package,
        rootIncusPackageSource: package == nil ? nil : GuestRecord.healthSource,
        dataCopy: data != nil, poolGuid: pool, macusPackage: "test")),
    to: directory.appendingPathComponent("backup.json"))
}

/// Root A (Incus P) was upgraded reversibly to root B (Incus P), then B migrated to the
/// current root C (Incus Q): b1 holds A alone, b2 holds B with the data copy at P.
private struct History {
  let fixture: UpgradeFixture
  let b1 = backupID(0)
  let b2 = backupID(100)

  init() throws {
    fixture = try UpgradeFixture()
    try Data("root-C".utf8).write(to: fixture.paths.rootDisk)
    try fixture.record(package: packageQ)
    try writeBackup(fixture, id: b1, root: "A", package: packageP, data: nil)
    try writeBackup(fixture, id: b2, root: "B", package: packageP, data: "data-at-P")
  }

  func file(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
  func head(_ url: URL, _ count: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return String(decoding: try handle.read(upToCount: count) ?? Data(), as: UTF8.self)
  }
  func backups() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: fixture.paths.backupsDirectory.path)
      .sorted()
  }
}

@Test func rollbackAcrossALaterMigrationUsesTheLaterDataCopy() async throws {
  let history = try History()
  let fixture = history.fixture
  defer { fixture.clean() }
  let paths = fixture.paths
  let service = try fixture.service(UpgradeVM())
  let listed = try await service.backups()
  #expect(listed.map(\.id) == [history.b1, history.b2])
  #expect(listed[0].restorable)
  #expect(listed[0].restoreData == "later")
  #expect(listed[0].dataFrom == history.b2)
  #expect(listed[0].discardsDataSince == "created-B")
  #expect(listed[0].pruneBreaks.isEmpty)
  #expect(listed[1].restoreData == "own")
  #expect(listed[1].pruneBreaks == [history.b1])
  #expect(listed.allSatisfy { $0.allocatedBytes > 0 && $0.status == "available" })

  // Never the root alone, and never without the discard confirmation.
  let before = try fixture.snapshot()
  let refused = await #expect(throws: RuntimeError.self) {
    _ = try await service.rollback(backupID: history.b1, discardDataSinceUpgrade: false)
  }
  #expect(refused?.message.contains("--discard-data-since-upgrade") == true)
  #expect(refused?.message.contains("created-B") == true)
  #expect(refused?.message.contains("copy from backup \(history.b2) taken at") == true)
  #expect(try fixture.snapshot() == before)

  let result = try await service.rollback(backupID: history.b1, discardDataSinceUpgrade: true)
  #expect(result.restoredBackupId == history.b1)
  #expect(result.restoreData == "later")
  #expect(result.dataFrom == history.b2)
  #expect(result.status.state == .stopped)
  #expect(try history.file(paths.rootDisk) == "root-A")
  #expect(try history.file(paths.efiStore) == "efi-A")
  #expect(try history.file(paths.seed) == "seed-A")
  #expect(try history.head(paths.dataDisk, 9) == "data-at-P")
  #expect(try GuestRecordStore.loadGuest(paths: paths)?.incusPackage == packageP)
  #expect(try GuestRecordStore.loadGuest(paths: paths)?.applianceId == "app-A")
  // The replaced state is a backup of its own: root C with its data at Q.
  let safety = paths.backup(result.safetyBackupId)
  #expect(try history.file(safety.appendingPathComponent("root.raw")) == "root-C")
  #expect(try history.head(safety.appendingPathComponent("data.raw"), 13) == "original-data")
  let record = try JSON.decoder().decode(
    UpgradeBackupRecord.self, from: Data(contentsOf: safety.appendingPathComponent("backup.json")))
  #expect(record.operation == "rollback")
  #expect(record.restoredFrom == history.b1)
  #expect(record.dataFrom == history.b2)
  #expect(record.rootIncusPackage == packageQ)
  #expect(record.dataCopy)
  #expect(!exists(paths.rollbackIntent))

  let after = try await service.backups()
  #expect(after.map(\.status) == ["restored", "available", "available"])
  // B is at the data's package now, so it is root-only; the safety backup carries its data.
  #expect(after[1].restoreData == "kept")
  #expect(!after[1].dataCopy)
  #expect(after[2].restoreData == "own")

  // The rollback can itself be rolled back.
  _ = try await service.rollback(
    backupID: result.safetyBackupId, discardDataSinceUpgrade: true)
  #expect(try history.file(paths.rootDisk) == "root-C")
  #expect(try history.head(paths.dataDisk, 13) == "original-data")
  #expect(try GuestRecordStore.loadGuest(paths: paths)?.incusPackage == packageQ)
}

@Test func prunedDataCopyWarnsThenRefusesTheDependentRollback() async throws {
  let history = try History()
  let fixture = history.fixture
  defer { fixture.clean() }
  let service = try fixture.service(UpgradeVM())
  let warned = await #expect(throws: RuntimeError.self) {
    _ = try await service.pruneBackup(id: history.b2, confirm: false)
  }
  #expect(warned?.message.contains("Backups \(history.b1) depend on its data disk copy") == true)
  #expect(warned?.message.contains("nothing was removed") == true)
  #expect(exists(fixture.paths.backup(history.b2)))
  let pruned = try await service.pruneBackup(id: history.b2, confirm: true)
  #expect(pruned.removed == history.b2)
  #expect(pruned.noLongerRestorable == [history.b1])
  #expect(!exists(fixture.paths.backup(history.b2)))

  let before = try fixture.snapshot()
  let refused = await #expect(throws: RuntimeError.self) {
    _ = try await service.rollback(backupID: history.b1, discardDataSinceUpgrade: true)
  }
  #expect(refused?.message.contains("no data disk copy at \(packageP) remains") == true)
  #expect(try fixture.snapshot() == before)
  let listed = try await service.backups()
  #expect(listed.map(\.restorable) == [false])
  #expect(listed[0].refusal?.contains("Nothing was changed") == true)
  // An unknown root package without a copy of its own is refused too.
  try writeBackup(fixture, id: backupID(200), root: "U", package: nil, data: nil)
  let unknown = await #expect(throws: RuntimeError.self) {
    _ = try await service.rollback(backupID: nil, discardDataSinceUpgrade: true)
  }
  #expect(unknown?.message.contains("Incus package is unknown") == true)
}

@Test func rootOnlyRollbackAfterAReversibleUpgrade() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let old = try fixture.identities()
  let oldConfig = try Data(contentsOf: fixture.paths.config)
  let oldGuest = try Data(contentsOf: fixture.paths.guestRecord)
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  _ = try await service.upgrade(stagingID: id)
  let upgradedRoot = try FileIdentity.of(fixture.paths.rootDisk)

  // The guest is running; rollback stops it gracefully first.
  #expect(await driver.running)
  let result = try await service.rollback(backupID: nil, discardDataSinceUpgrade: false)
  #expect(result.restoredBackupId == id)
  #expect(result.restoreData == "kept")
  #expect(result.dataFrom == nil)
  #expect(result.status.state == .stopped)
  #expect(!(await driver.running))
  let now = try fixture.identities()
  #expect(Array(now[0..<3]) == Array(old[0..<3]))
  #expect(now[3] == old[3])
  #expect(try Data(contentsOf: fixture.paths.config) == oldConfig)
  #expect(try Data(contentsOf: fixture.paths.guestRecord) == oldGuest)
  let safety = fixture.paths.backup(result.safetyBackupId)
  #expect(try FileIdentity.of(safety.appendingPathComponent("root.raw")) == upgradedRoot)
  #expect(!exists(safety.appendingPathComponent("data.raw")))
  // Start boots the previous root and reports the upgrade as available again.
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let status = try await service.start()
  #expect(await driver.bootedRoots.last == oldRootBytes)
  #expect(status.upgradeAvailable == true)
}

@Test func rollbackWithAnUnknownPackageRestoresTheBackupsOwnCopy() async throws {
  let fixture = try UpgradeFixture(target: packageQ)
  defer { fixture.clean() }
  try fixture.record(package: nil)
  let old = try fixture.identities()
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let plan = try await service.upgradePlan()
  #expect(plan.upgradeClass == .migrating)
  let id = try await fixture.stage(plan)
  await driver.set(
    upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id, package: packageQ))
  await driver.setWritesData(true, backup: nil)
  _ = try await service.upgrade(stagingID: id)
  let migrated = try FileIdentity.of(fixture.paths.dataDisk)

  let before = try fixture.snapshot()
  await #expect(throws: RuntimeError.self) {
    _ = try await service.rollback(backupID: id, discardDataSinceUpgrade: false)
  }
  #expect(try fixture.snapshot() == before)
  let result = try await service.rollback(backupID: id, discardDataSinceUpgrade: true)
  #expect(result.restoreData == "own")
  #expect(result.rootIncusPackage == nil)
  let now = try fixture.identities()
  #expect(now[0] == old[0])
  // The copy is the disk now, and the migrated disk is kept with the replaced root.
  #expect(now[3] != migrated)
  let data = try FileHandle(forReadingFrom: fixture.paths.dataDisk)
  #expect(try data.read(upToCount: 13) == Data("original-data".utf8))
  try data.close()
  let safety = fixture.paths.backup(result.safetyBackupId)
  #expect(try FileIdentity.of(safety.appendingPathComponent("data.raw")) == migrated)
  #expect(try GuestRecordStore.loadGuest(paths: fixture.paths)?.incusPackage == nil)
}

private let rollbackPoints = [
  "rollback_journaled", "rollback_backup_created", "move:runtime/root.raw",
  "move:runtime/efi.bin", "move:runtime/seed.iso", "move:runtime/data.raw", "moved",
  "records_restored", "rollback_recorded",
]

@Test(arguments: rollbackPoints)
func daemonStartUndoesAnInterruptedRollback(point: String) async throws {
  let history = try History()
  let fixture = history.fixture
  defer { fixture.clean() }
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let b1Root = try FileIdentity.of(
    fixture.paths.backup(history.b1).appendingPathComponent("root.raw"))
  let b2Data = try FileIdentity.of(
    fixture.paths.backup(history.b2).appendingPathComponent("data.raw"))
  let service = try fixture.service(UpgradeVM()) { label in
    if label == point { throw UpgradeInterruption() }
  }
  await #expect(throws: UpgradeInterruption.self) {
    _ = try await service.rollback(backupID: history.b1, discardDataSinceUpgrade: true)
  }
  #expect(exists(fixture.paths.rollbackIntent))
  let restarted = try fixture.service(UpgradeVM())
  let status = await restarted.status()
  #expect(status.state == .stopped)
  #expect(status.lastError?.contains("was undone") == true)
  #expect(try fixture.snapshot() == before)
  #expect(try fixture.identities() == identities)
  #expect(
    try FileIdentity.of(fixture.paths.backup(history.b1).appendingPathComponent("root.raw"))
      == b1Root)
  #expect(
    try FileIdentity.of(fixture.paths.backup(history.b2).appendingPathComponent("data.raw"))
      == b2Data)
  #expect(try history.backups() == [history.b1, history.b2])
  #expect(!exists(fixture.paths.rollbackIntent))
  // The same rollback runs to completion afterwards.
  _ = try await restarted.rollback(backupID: history.b1, discardDataSinceUpgrade: true)
  #expect(try history.file(fixture.paths.rootDisk) == "root-A")
}

@Test func failedRollbackMoveIsUndoneAtOnce() async throws {
  let history = try History()
  let fixture = history.fixture
  defer { fixture.clean() }
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let service = try fixture.service(UpgradeVM()) { label in
    if label == "move:runtime/data.raw" { throw RuntimeError(.io, "disk unplugged") }
  }
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.rollback(backupID: history.b1, discardDataSinceUpgrade: true)
  }
  #expect(error?.message.contains("disk unplugged") == true)
  #expect(error?.message.contains("put back as it was before the rollback") == true)
  #expect(try fixture.snapshot() == before)
  #expect(try fixture.identities() == identities)
  #expect(try history.backups() == [history.b1, history.b2])
  #expect(!exists(fixture.paths.rollbackIntent))
  #expect(await service.status().state == .stopped)
}

@Test func unreadableRollbackJournalPreservesEverything() async throws {
  let history = try History()
  let fixture = history.fixture
  defer { fixture.clean() }
  try Data("{".utf8).write(to: fixture.paths.rollbackIntent)
  let service = try fixture.service(UpgradeVM())
  let status = await service.status()
  #expect(status.state == .failed)
  #expect(status.lastError?.contains("rollback.pending cannot be read") == true)
  await #expect(throws: RuntimeError.self) {
    _ = try await service.rollback(backupID: history.b1, discardDataSinceUpgrade: true)
  }
  await #expect(throws: RuntimeError.self) {
    _ = try await service.pruneBackup(id: history.b2, confirm: true)
  }
  #expect(exists(fixture.paths.rollbackIntent))
  #expect(try history.backups() == [history.b1, history.b2])
}

@Test func automaticRollbackRemovesAGuestRecordTheStateNeverHad() async throws {
  let fixture = try UpgradeFixture(target: packageQ)
  defer { fixture.clean() }
  try fixture.record()
  try FileManager.default.removeItem(at: fixture.paths.guestRecord)
  let driver = UpgradeVM()
  await driver.set(
    upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id, package: packageQ))
  // After verification the new root's record is written; the commit is then interrupted.
  let service = try fixture.service(driver) { label in
    if label == "backup_recorded" { throw UpgradeInterruption() }
  }
  let id = try await fixture.stage(try await service.upgradePlan())
  await #expect(throws: UpgradeInterruption.self) { _ = try await service.upgrade(stagingID: id) }
  #expect(exists(fixture.paths.guestRecord))
  _ = try fixture.service(UpgradeVM())
  #expect(!exists(fixture.paths.guestRecord))
  #expect(exists(fixture.paths.backup(id).appendingPathComponent("failed/guest-record.json")))
}

// MARK: Review fixes

@Test func rollbackNeverPairsARootWithAnotherPool() async throws {
  // The runtime was deleted and created again at the same Incus package, so with a new pool.
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record(package: packageP)
  let earlier = backupID(0)
  let later = backupID(100)
  try writeBackup(fixture, id: earlier, root: "A", package: packageP, data: nil, pool: "999")
  // A later data copy at the root's package, but of the current pool, is no match either.
  try writeBackup(fixture, id: later, root: "B", package: packageP, data: "data-new-pool")
  let service = try fixture.service(UpgradeVM())
  let listed = try await service.backups()
  #expect(listed.map(\.id) == [earlier, later])
  #expect(!listed[0].restorable)
  #expect(
    listed[0].refusal?.contains("owns pool 999, but the data disk holds pool \(poolGuid)") == true)
  #expect(listed[1].restoreData == "kept")
  let before = try fixture.snapshot()
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.rollback(backupID: earlier, discardDataSinceUpgrade: true)
  }
  #expect(error?.message.contains("a pool it refuses") == true)
  #expect(try fixture.snapshot() == before)
  // A copy of the root's own pool is still used.
  let own = backupID(200)
  try writeBackup(fixture, id: own, root: "C", package: packageP, data: "data-999", pool: "999")
  let paired = try await service.backups()
  #expect(paired[0].restoreData == "later")
  #expect(paired[0].dataFrom == own)
}

@Test func rollbackRestoresTheStorageIdentityWithTheDataDisk() async throws {
  // The runtime was deleted and created again: the backup holds the earlier pool's disks.
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record(package: packageP)
  let earlier = backupID(0)
  try writeBackup(fixture, id: earlier, root: "A", package: packageP, data: "data-999", pool: "999")
  let replaced = try Data(contentsOf: fixture.paths.storageIdentity)
  let service = try fixture.service(UpgradeVM())
  let result = try await service.rollback(backupID: earlier, discardDataSinceUpgrade: true)
  #expect(result.restoreData == "own")
  // The record names the pool on the restored data disk, not the one it replaced.
  let restored = try #require(try GuestRecordStore.loadStorageIdentity(paths: fixture.paths))
  #expect(restored.poolGuid == "999")
  #expect(restored.source == StorageIdentityRecord.backupSource)
  #expect(BackupCatalog.currentPool(paths: fixture.paths) == "999")
  let safety = fixture.paths.backup(result.safetyBackupId)
  #expect(try Data(contentsOf: safety.appendingPathComponent("storage-identity.json")) == replaced)
  // The replaced root is no longer offered against the earlier pool's data disk.
  let listed = try await service.backups()
  #expect(listed.first { $0.id == result.safetyBackupId }?.restoreData == "own")
  // Rolling the rollback back restores the identity saved with the replaced disks.
  _ = try await service.rollback(
    backupID: result.safetyBackupId, discardDataSinceUpgrade: true)
  #expect(try Data(contentsOf: fixture.paths.storageIdentity) == replaced)
}

@Test func undoneRollbackPutsTheStorageIdentityBack() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record(package: packageP)
  let earlier = backupID(0)
  try writeBackup(fixture, id: earlier, root: "A", package: packageP, data: "data-999", pool: "999")
  let replaced = try Data(contentsOf: fixture.paths.storageIdentity)
  let service = try fixture.service(UpgradeVM()) { label in
    if label == "rollback_recorded" { throw UpgradeInterruption() }
  }
  await #expect(throws: UpgradeInterruption.self) {
    _ = try await service.rollback(backupID: earlier, discardDataSinceUpgrade: true)
  }
  #expect(try GuestRecordStore.loadStorageIdentity(paths: fixture.paths)?.poolGuid == "999")
  let restarted = try fixture.service(UpgradeVM())
  #expect(await restarted.status().state == .stopped)
  #expect(try Data(contentsOf: fixture.paths.storageIdentity) == replaced)
  #expect(!exists(fixture.paths.rollbackIntent))
}

@Test func repeatedUndoAfterItsRestoreKeepsTheRestoredRecords() async throws {
  let history = try History()
  let fixture = history.fixture
  defer { fixture.clean() }
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let service = try fixture.service(UpgradeVM()) { label in
    if label == "rollback_recorded" { throw UpgradeInterruption() }
  }
  await #expect(throws: UpgradeInterruption.self) {
    _ = try await service.rollback(backupID: history.b1, discardDataSinceUpgrade: true)
  }
  // The first undo stops once everything is put back, before the new backup is removed.
  let first = try fixture.service(UpgradeVM()) { label in
    if label == "undo_restored" { throw UpgradeInterruption() }
  }
  #expect(await first.status().state == .failed)
  let intent = try #require(try RollbackJournal.load(paths: fixture.paths))
  #expect(intent.step == .undone)
  #expect(try fixture.snapshot() == before)
  // Its removal got as far as the saved guest record before the daemon stopped again.
  try FileManager.default.removeItem(
    at: fixture.paths.backup(intent.id).appendingPathComponent("guest-record.json"))
  let restarted = try fixture.service(UpgradeVM())
  #expect(await restarted.status().state == .stopped)
  #expect(try fixture.snapshot() == before)
  #expect(try fixture.identities() == identities)
  #expect(try history.backups() == [history.b1, history.b2])
  #expect(!exists(fixture.paths.rollbackIntent))
}

@Test func discardWarningNamesWhenTheDataCopyWasTaken() async throws {
  let fixture = try UpgradeFixture(target: packageQ)
  defer { fixture.clean() }
  try fixture.record(package: packageP)
  let driver = UpgradeVM()
  // The boot and checks after the copy take time; the backup record is written at the commit.
  let service = try fixture.service(
    driver,
    hook: { label in
      if label == "data_copy_written" { Thread.sleep(forTimeInterval: 1.1) }
    })
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(
    upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id, package: packageQ))
  _ = try await service.upgrade(stagingID: id)
  let record = try JSON.decoder().decode(
    UpgradeBackupRecord.self,
    from: Data(contentsOf: fixture.paths.backup(id).appendingPathComponent("backup.json")))
  let copiedAt = try #require(record.dataCopiedAt)
  #expect(copiedAt < record.createdAt)
  #expect(try await service.backups().first { $0.id == id }?.discardsDataSince == copiedAt)
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.rollback(backupID: id, discardDataSinceUpgrade: false)
  }
  #expect(error?.message.contains("taken at \(copiedAt)") == true)
  // The backup's own copy: the backup is named once.
  #expect(error?.message.components(separatedBy: id).count == 2)
  #expect(error?.message.contains("restores the data disk copy taken at") == true)
  let result = try await service.rollback(backupID: id, discardDataSinceUpgrade: true)
  #expect(result.dataCopyCreatedAt == copiedAt)
  // The state the rollback replaced holds a copy taken when that rollback ran.
  let safety = try JSON.decoder().decode(
    UpgradeBackupRecord.self,
    from: Data(
      contentsOf: fixture.paths.backup(result.safetyBackupId).appendingPathComponent(
        "backup.json")))
  #expect(safety.dataCopiedAt == safety.createdAt)
  #expect(safety.poolGuid == poolGuid)
}

/// Lets a fake inventory reach the service it is read for.
private final class ServiceBox: @unchecked Sendable {
  var service: RuntimeService?
}

@Test func clientsAreClosedOutBeforeTheInventoryBaseline() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  await driver.setServesStreams(true)
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let box = ServiceBox()
  let inventory = FakeInventory(onRead: {
    guard let service = box.service, await service.status().state == .ready else { return }
    // No client can reach Incus while the baseline is read.
    let refused = await #expect(throws: RuntimeError.self) {
      _ = try await service.openIncusStream()
    }
    #expect(refused?.message.contains("closed to clients") == true)
    // The client connected earlier was ended: its guest end sees the close.
    var byte: UInt8 = 0
    let guest = await driver.guestEnds[0]
    #expect(recv(guest.rawValue, &byte, 1, MSG_DONTWAIT) == 0)
  })
  let service = try fixture.service(driver, inventory: inventory)
  box.service = service
  _ = try await service.start()
  let client = try await service.openIncusStream()
  // The relay of that client ends when its guest stream is shut down.
  let relay = Task {
    var byte: UInt8 = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var closed = false
    while !closed, ContinuousClock.now < deadline {
      closed = recv(client.socket.rawValue, &byte, 1, MSG_DONTWAIT) == 0
      if !closed { try? await Task.sleep(for: .milliseconds(5)) }
    }
    await client.release()
    return closed
  }
  let id = try await fixture.stage(try await service.upgradePlan())
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  let clock = ContinuousClock()
  let started = clock.now
  _ = try await service.upgrade(stagingID: id)
  #expect(await relay.value)
  // Running operations are waited for before the baseline, and the relay ended promptly.
  #expect(await inventory.events == ["idle", "read", "read"])
  #expect(clock.now - started < .seconds(4))
  // Clients are served again once the upgrade ends.
  let after = try await service.openIncusStream()
  await after.release()
}

/// Operations listings, one per poll; the last one repeats.
private final class OperationsScript: IncusQuerying, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [String]
  private var count = 0
  init(_ responses: [String]) { self.responses = responses }
  var calls: Int { lock.withLock { count } }
  func get(_ path: String) async throws -> Data {
    #expect(path == IncusInventoryReader.operationsPath)
    return lock.withLock {
      count += 1
      return Data((responses.count > 1 ? responses.removeFirst() : responses[0]).utf8)
    }
  }
}

@Test func inventoryBaselineWaitsForRunningTasks() async throws {
  let task = #"{"running":[{"class":"task","description":"Deleting instance"}]}"#
  let exec =
    #"{"running":[{"class":"websocket","description":"Executing command"}],"success":[{"class":"task"}]}"#
  let script = OperationsScript([task, task, exec])
  try await IncusInventoryReader.awaitIdle(script, timeout: .seconds(5), poll: .milliseconds(1))
  #expect(script.calls == 3)
  #expect(try IncusInventoryReader.runningTasks(Data("null".utf8)).isEmpty)
  let stuck = OperationsScript([task])
  let error = await #expect(throws: RuntimeError.self) {
    try await IncusInventoryReader.awaitIdle(
      stuck, timeout: .milliseconds(20), poll: .milliseconds(1))
  }
  #expect(error?.message.contains("Deleting instance") == true)
}

@Test func upgradeBackupIsTheLatestEvenAfterARollbackDuringStaging() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record(package: packageP)
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  let stagingID = try await fixture.stage(try await service.upgradePlan())
  // Another client's rollback finished while this one staged: its safety backup is newer.
  let newer = UpgradeID.next(paths: fixture.paths, now: Date().addingTimeInterval(5))
  try writeBackup(fixture, id: newer, root: "X", package: packageP, data: nil)
  #expect(newer > stagingID)
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))
  let result = try await service.upgrade(stagingID: stagingID)
  #expect(result.backupId > newer)
  #expect(exists(fixture.paths.backup(result.backupId).appendingPathComponent("root.raw")))
  #expect(!exists(fixture.paths.staging(stagingID)))
  // An unnamed rollback restores the state this upgrade replaced.
  let rolled = try await service.rollback(backupID: nil, discardDataSinceUpgrade: false)
  #expect(rolled.restoredBackupId == result.backupId)
  #expect(try Data(contentsOf: fixture.paths.rootDisk) == oldRootBytes)
}

@Test(arguments: [false, true])
func failedJournalWriteLeavesNoStagingOrJournal(installed: Bool) async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let before = try fixture.snapshot()
  let identities = try fixture.identities()
  let driver = UpgradeVM()
  let paths = fixture.paths
  // Either the write failed before its rename, or after it, while syncing the directory.
  let service = try fixture.service(
    driver,
    hook: { label in
      guard label == "journaling" else { return }
      if installed { try PrivateFile.write(Data("{}".utf8), to: paths.upgradeIntent) }
      throw RuntimeError(.io, "disk full")
    })
  let id = try await fixture.stage(try await service.upgradePlan())
  let error = await #expect(throws: RuntimeError.self) {
    _ = try await service.upgrade(stagingID: id)
  }
  #expect(error?.message == "disk full")
  #expect(!exists(paths.staging(id)))
  #expect(!exists(paths.upgradeIntent))
  #expect(!exists(paths.backup(id)))
  #expect(try fixture.snapshot() == before)
  #expect(try fixture.identities() == identities)
  // Nothing is left to recover: the next upgrade is accepted.
  #expect(try await service.upgradePlan().current == false)
}
