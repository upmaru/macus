import Foundation
import Testing

@testable import Macus

// MARK: Daemon routes (4.1)

@Test func upgradeAndBackupRoutesReachTheServiceAndCheckTheirBodies() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let routes = RuntimeRoutes(service: try fixture.service(UpgradeVM()))
  func call(_ method: String, _ path: String, _ body: String = "") async -> HTTPResponse {
    await routes.handle(HTTPRequest(method: method, path: path, body: Data(body.utf8)))
  }

  let planned = await call("POST", "/v1/runtime/upgrade/plan")
  #expect(planned.status == 200)
  let plan = try JSON.decoder().decode(UpgradePlan.self, from: planned.body)
  #expect(plan.upgradeClass == .reversible)
  #expect(plan.toCatalogId == fixture.entry.id)
  #expect(await call("POST", "/v1/runtime/upgrade/plan", "{}").status == 400)

  let listed = await call("GET", "/v1/runtime/backups")
  #expect(listed.status == 200)
  #expect(try JSON.decoder().decode(BackupList.self, from: listed.body).backups.isEmpty)

  let id = "20261124T120000Z-0a1b2c3d"
  for (path, body) in [
    ("/v1/runtime/upgrade", ""),
    ("/v1/runtime/upgrade", #"{"staging_id":"../runtime"}"#),
    ("/v1/runtime/upgrade/rollback", #"{"backup_id":"latest"}"#),
    ("/v1/runtime/backups/prune", #"{"backup_id":"\#(id)"}"#),
    ("/v1/runtime/backups/prune", #"{"backup_id":"../runtime","confirm":true}"#),
  ] {
    #expect(await call("POST", path, body).status == 400, "\(path) \(body)")
  }
  #expect(await call("POST", "/v1/runtime/upgrade", #"{"staging_id":"\#(id)"}"#).status == 404)
  #expect(
    await call("POST", "/v1/runtime/backups/prune", #"{"backup_id":"\#(id)","confirm":true}"#)
      .status == 404)
  #expect(await call("POST", "/v1/runtime/upgrade/rollback").status != 200)
  #expect(await call("DELETE", "/v1/runtime/backups").status == 404)
  // Nothing above changed the state.
  #expect(try BackupCatalog.load(paths: fixture.paths).isEmpty)
  #expect(try fixture.plan() == plan)
}

@Test func newIDsSortAfterEveryBackupEvenWithinOneSecond() throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  try PrivateFile.makeDirectory(fixture.paths.backupsDirectory)
  #expect(UpgradeID.next(paths: fixture.paths, now: now).hasPrefix("20231114T221320Z-"))
  // Same second, then a clock that went back: both take the second after the newest.
  try PrivateFile.makeDirectory(fixture.paths.backup("20231114T221320Z-ffffffff"))
  #expect(UpgradeID.next(paths: fixture.paths, now: now).hasPrefix("20231114T221321Z-"))
  try PrivateFile.makeDirectory(fixture.paths.backup("20231114T221330Z-00000000"))
  #expect(UpgradeID.next(paths: fixture.paths, now: now).hasPrefix("20231114T221331Z-"))
  // A later clock is used as it is.
  #expect(
    UpgradeID.next(paths: fixture.paths, now: now.addingTimeInterval(60))
      .hasPrefix("20231114T221420Z-"))
}

// MARK: Client grammar (4.2)

@Test func upgradeFlagsAreValidatedBeforeAnyRequest() async throws {
  let invalid: [[String]] = [
    ["runtime", "upgrade", "--dry-run", "--rollback"],
    ["runtime", "upgrade", "--discard-data-since-upgrade"],
    ["runtime", "status", "--dry-run"],
    ["runtime", "start", "--rollback"],
    ["runtime", "backups", "--confirm"],
    ["runtime", "upgrade", "--confirm"],
    ["runtime", "backups", "prune"],
    ["runtime", "backups", "prune", "latest"],
    ["runtime", "upgrade", "--rollback", "latest"],
    ["runtime", "upgrade", "--rollback", "--rollback"],
  ]
  for arguments in invalid {
    let capture = StartCapture()
    let status = await MacusCLI.run(
      arguments: ["--state-dir", "/private/tmp/macus-never-\(UUID())"] + arguments,
      environment: [:], streams: capture.streams)
    #expect(status == 2, "\(arguments): \(capture.error)")
  }
  #expect(MacusCLI.helpText.contains("runtime upgrade --rollback [ID]"))
  #expect(MacusCLI.helpText.contains("runtime backups prune ID [--confirm]"))
}

// MARK: End to end through the gateway

/// The real runtime service behind the pair's fake gateway, served once its job is activated.
private final class ServedRuntime: @unchecked Sendable {
  private let lock = NSLock()
  private var server: APIServer?
  let service: RuntimeService
  let paths: RuntimePaths

  init(service: RuntimeService, paths: RuntimePaths) {
    self.service = service
    self.paths = paths
  }

  var serving: Bool { lock.withLock { server != nil } }

  @MainActor func serve() throws {
    guard !serving else { return }
    let server = try APIServer(service: service, paths: paths)
    lock.withLock { self.server = server }
  }

  @MainActor func stop() {
    lock.withLock { server }?.stop()
  }
}

/// An older appliance whose start was refused: its guest is recorded as incompatible, so the
/// runtime service stays up and nothing is booted.
private func refusedState(_ fixture: UpgradeFixture) async throws -> (UpgradeVM, RuntimeService) {
  try fixture.record()
  try GuestRecordStore.saveGuest(
    GuestRecord(
      guestContract: 0, payloadRevision: oldRevision, applianceId: "alpine-3.24.2-lts-1",
      incusPackage: "7.0.1-r2", incusPackageSource: GuestRecord.healthSource),
    paths: fixture.paths)
  let driver = UpgradeVM()
  let service = try fixture.service(driver)
  await #expect(throws: RuntimeError.self) { _ = try await service.start() }
  #expect(await driver.startCount == 0)
  return (driver, service)
}

@Test func upgradeAfterARefusedStartActivatesWithoutBootingThenRollsBackAndPrunes()
  async throws
{
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  let (driver, service) = try await refusedState(fixture)
  let pair = try PairFixture(state: fixture.paths.directory)
  defer { pair.remove() }
  let served = ServedRuntime(service: service, paths: fixture.paths)
  // Neither job is running: upgrade activates both, and the runtime service boots nothing.
  pair.launch.register(pair.runtimeJob(loaded: false))
  pair.launch.register(pair.serverJob(loaded: false))
  let runtimeJob = pair.runtimeJob(loaded: true)
  let launch = pair.launch
  launch.runtimeActivation = {
    try await MainActor.run { try served.serve() }
    launch.register(runtimeJob)
  }
  await driver.set(upgradeHealth(payload: fixture.targetPayload, appliance: fixture.entry.id))

  let capture = StartCapture()
  #expect(
    await pair.run(["--json", "runtime", "upgrade"], capture: capture, catalog: fixture.entry)
      == 0, "\(capture.error)")
  #expect(pair.launch.kickstarted.sorted() == [pair.runtimeLabel, pair.serverLabel].sorted())
  #expect(pair.launch.bootstrapped.isEmpty)
  #expect(pair.downloader.calls == 0)
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any])
  #expect(object["upgraded"] as? Bool == true)
  let plan = try #require(object["plan"] as? [String: Any])
  #expect(plan["upgrade_class"] as? String == "reversible")
  let result = try #require(object["result"] as? [String: Any])
  let backupID = try #require(result["backup_id"] as? String)
  let status = try #require(result["status"] as? [String: Any])
  #expect(status["state"] as? String == "ready")
  #expect(status["incus_socket"] == nil)
  let inventory = try #require(result["inventory"] as? [String: Any])
  // The refused runtime was not ready, so the comparison was skipped and says so.
  #expect(inventory["compared"] as? Bool == false)
  #expect((inventory["skipped_reason"] as? String)?.isEmpty == false)
  // The client planned, staged and handed over; only the upgrade booted the guest.
  let posts = pair.probe.requests.filter { $0.method == "POST" }.map(\.path)
  #expect(posts == ["/runtime/upgrade/plan", "/runtime/upgrade"])
  #expect(await driver.startCount == 1)
  #expect(!exists(fixture.paths.staging(backupID)))
  #expect(try await service.upgradePlan().current)

  // Rollback restores the root alone (same Incus package) and leaves the runtime stopped.
  let rolled = StartCapture()
  #expect(
    await pair.run(["--json", "runtime", "upgrade", "--rollback"], capture: rolled) == 0,
    "\(rolled.error)")
  let rollback = try #require(
    try JSONSerialization.jsonObject(with: Data(rolled.output.utf8)) as? [String: Any])
  #expect(rollback["restored_backup_id"] as? String == backupID)
  #expect(rollback["restore_data"] as? String == "kept")
  #expect((rollback["status"] as? [String: Any])?["state"] as? String == "stopped")
  let safety = try #require(rollback["safety_backup_id"] as? String)
  #expect(try Data(contentsOf: fixture.paths.rootDisk) == oldRootBytes)

  let listed = StartCapture()
  #expect(await pair.run(["--json", "runtime", "backups"], capture: listed) == 0)
  let backups = try #require(
    (try JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [String: Any])?[
      "backups"] as? [[String: Any]])
  #expect(backups.compactMap { $0["id"] as? String } == [backupID, safety])
  #expect(backups[0]["status"] as? String == "restored")
  #expect(backups[1]["restorable"] as? Bool == true)

  let human = StartCapture()
  #expect(await pair.run(["runtime", "backups"], capture: human) == 0)
  #expect(human.output.contains(safety))
  #expect(human.output.contains("Restorable: Yes, root only"))

  // Without confirmation nothing is removed.
  let refused = StartCapture()
  #expect(await pair.run(["runtime", "backups", "prune", safety], capture: refused) == 1)
  #expect(refused.error.contains("nothing was removed"))
  #expect(exists(fixture.paths.backup(safety)))
  let pruned = StartCapture()
  #expect(
    await pair.run(["--json", "runtime", "backups", "prune", safety, "--confirm"], capture: pruned)
      == 0, "\(pruned.error)")
  #expect(!exists(fixture.paths.backup(safety)))
  #expect(exists(fixture.paths.backup(backupID)))
  await MainActor.run { served.stop() }
}

@Test func dryRunPrintsThePlanAndDownloadsStagesAndStopsNothing() async throws {
  let fixture = try UpgradeFixture()
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let service = try fixture.service(driver)
  _ = try await service.start()
  // Without its root the cache would have to be downloaded again.
  try FileManager.default.removeItem(
    at: fixture.paths.applianceCache(fixture.entry.id).appendingPathComponent("root.raw"))
  let pair = try PairFixture(state: fixture.paths.directory)
  defer { pair.remove() }
  let served = ServedRuntime(service: service, paths: fixture.paths)
  try await MainActor.run { try served.serve() }
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  pair.probe.serving = true
  let state = fixture.paths.directory.path
  let cache = fixture.paths.applianceCache(fixture.entry.id).path
  let cached = try FileManager.default.contentsOfDirectory(atPath: cache)

  let capture = StartCapture()
  #expect(
    await pair.run(["runtime", "upgrade", "--dry-run"], capture: capture, catalog: fixture.entry)
      == 0, "\(capture.error)")
  #expect(capture.output.contains("Class: Reversible (Incus 7.0.1-r2 to 7.0.1-r2)"))
  #expect(capture.output.contains("The data disk stays in place."))
  #expect(capture.output.contains("every workload restarts"))
  #expect(capture.output.contains("Dry run: nothing was downloaded, staged or stopped."))
  // Activation keeps its lock and credential files; nothing else appears.
  let before = try FileManager.default.contentsOfDirectory(atPath: state)
  #expect(!before.contains { $0.hasPrefix("upgrade-") || $0.hasPrefix("appliance-staging-") })

  let json = StartCapture()
  #expect(
    await pair.run(["--json", "runtime", "upgrade", "--dry-run"], capture: json) == 0,
    "\(json.error)")
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
  #expect(object["dry_run"] as? Bool == true)
  #expect((object["plan"] as? [String: Any])?["data_copy"] as? String == "none")

  #expect(pair.downloader.calls == 0)
  #expect(try FileManager.default.contentsOfDirectory(atPath: state).sorted() == before.sorted())
  #expect(try FileManager.default.contentsOfDirectory(atPath: cache) == cached)
  #expect(!exists(fixture.paths.backupsDirectory))
  #expect(await driver.startCount == 1)
  #expect(await service.status().state == .ready)
  #expect(
    pair.probe.requests.filter { $0.method == "POST" }.allSatisfy {
      $0.path == "/runtime/upgrade/plan"
    })
  await MainActor.run { served.stop() }
}

@Test func migratingUpgradeShowsWhatHappensBeforeTheStopAndRollbackNeedsTheDiscardFlag()
  async throws
{
  let fixture = try UpgradeFixture(target: "7.0.1-r3")
  defer { fixture.clean() }
  try fixture.record()
  let driver = UpgradeVM()
  await driver.set(upgradeHealth(payload: oldRevision, appliance: "alpine-3.24.2-lts-1"))
  let service = try fixture.service(driver)
  _ = try await service.start()
  let pair = try PairFixture(state: fixture.paths.directory)
  defer { pair.remove() }
  let served = ServedRuntime(service: service, paths: fixture.paths)
  try await MainActor.run { try served.serve() }
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  pair.probe.serving = true
  await driver.setAfterBoot(
    upgradeHealth(
      payload: fixture.targetPayload, appliance: fixture.entry.id, package: "7.0.1-r3"))

  let capture = StartCapture()
  #expect(
    await pair.run(["runtime", "upgrade"], capture: capture, catalog: fixture.entry) == 0,
    "\(capture.error)")
  let output = capture.output
  #expect(output.contains("Class: Migrating (Incus 7.0.1-r2 to 7.0.1-r3)"))
  #expect(output.contains("The data disk is cloned into it first"))
  let notice = try #require(output.range(of: "every workload restarts"))
  let stopping = try #require(output.range(of: "Stopping the runtime"))
  let upgraded = try #require(output.range(of: "Upgraded to \(fixture.entry.id)"))
  #expect(notice.lowerBound < stopping.lowerBound && stopping.lowerBound < upgraded.lowerBound)
  #expect(output.contains("Verification: Ready, pool imported, and Incus lists everything"))
  let backupID = try #require(try BackupCatalog.load(paths: fixture.paths).last?.id)
  #expect(output.contains("Backup: \(backupID)"))
  #expect(output.contains("Project default: 1 instances, 1 volumes, 1 networks, 1 profiles"))

  // The migrated data disk cannot run under the old root, so rollback restores the copy,
  // and only with the discard confirmation.
  let refused = StartCapture()
  #expect(await pair.run(["runtime", "upgrade", "--rollback", backupID], capture: refused) == 1)
  #expect(refused.error.contains("--discard-data-since-upgrade"))
  #expect(try Data(contentsOf: fixture.paths.rootDisk) != oldRootBytes)
  let restored = StartCapture()
  #expect(
    await pair.run(
      ["runtime", "upgrade", "--rollback", backupID, "--discard-data-since-upgrade"],
      capture: restored) == 0, "\(restored.error)")
  #expect(restored.output.contains("Restored backup \(backupID)"))
  #expect(restored.output.contains("Data disk: Restored from this backup's copy of"))
  #expect(try Data(contentsOf: fixture.paths.rootDisk) == oldRootBytes)
  await MainActor.run { served.stop() }
}
