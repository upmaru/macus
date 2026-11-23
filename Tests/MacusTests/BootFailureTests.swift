import Foundation
import Testing

@testable import Macus

private func bootService(
  _ driver: FakeVM, readiness: Int = 30, shutdown: Int = 1, stall: Duration = .seconds(300)
) throws -> (Fixture, RuntimeService) {
  let fixture = try Fixture()
  var configuration = fixture.configuration
  configuration.readinessTimeoutSeconds = readiness
  configuration.shutdownTimeoutSeconds = shutdown
  try StateStore(paths: fixture.paths).save(configuration)
  let service = try RuntimeService(
    driver: driver, store: StateStore(paths: fixture.paths), stallLimit: stall)
  return (fixture, service)
}

private func appendSerial(_ fixture: Fixture, _ text: String) throws {
  let url = fixture.paths.serialLog
  if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(text.utf8))
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
  for _ in 0..<200 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(25))
  }
  Issue.record("Condition was not reached")
}

private func startError(_ task: Task<RuntimeStatus, Error>) async -> RuntimeError? {
  do {
    _ = try await task.value
    return nil
  } catch {
    return error as? RuntimeError
  }
}

@Test func guestFailureObservationFailsStartPromptlyAndKeepsTheGuest() async throws {
  let driver = FakeVM()
  await driver.setHealthy(false)
  let (fixture, service) = try bootService(driver)
  defer { fixture.clean() }
  let began = ContinuousClock.now
  let start = Task { try await service.start() }
  try await waitUntil { await driver.running }
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=failed code=storage_refused\n")
  let error = await startError(start)
  #expect(error?.code == .unavailable)
  #expect(error?.message.contains("code storage_refused") == true)
  #expect(error?.message.contains("Disks and Incus data were kept") == true)
  #expect(began.duration(to: .now) < .seconds(10))
  #expect(await driver.running)
  #expect(await driver.startCount == 1)
  #expect(await driver.stopCount == 0)
  #expect(await service.status().state == .failed)
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
  _ = try await service.stop(force: true)
}

@Test func failureObservationFromAnEarlierBootIsIgnored() async throws {
  let driver = FakeVM()
  let (fixture, service) = try bootService(driver)
  defer { fixture.clean() }
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=failed code=incus_crashed\n")
  #expect(try await service.start().state == .ready)
  #expect(await driver.startCount == 1)
}

@Test func incusCrashRestartsTheGuestOnceAndThenBecomesReady() async throws {
  let driver = FakeVM()
  await driver.setHealthy(false)
  let (fixture, service) = try bootService(driver)
  defer { fixture.clean() }
  let start = Task { try await service.start() }
  try await waitUntil { await driver.running }
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=failed code=incus_crashed\n")
  try await waitUntil { await driver.startCount == 2 }
  #expect(await driver.stopCount == 1)
  #expect(await service.progress().phase == "incus_recovery")
  await driver.setHealthy(true)
  #expect(try await start.value.state == .ready)
  #expect(await driver.startCount == 2)
}

@Test func repeatedIncusCrashFailsAfterOneHostRestart() async throws {
  let driver = FakeVM()
  await driver.setHealthy(false)
  let (fixture, service) = try bootService(driver)
  defer { fixture.clean() }
  let start = Task { try await service.start() }
  try await waitUntil { await driver.running }
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=failed code=incus_crashed\n")
  try await waitUntil { await driver.startCount == 2 }
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=failed code=incus_crashed\n")
  let error = await startError(start)
  #expect(error?.code == .unavailable)
  #expect(error?.message.contains("code incus_crashed") == true)
  #expect(error?.message.contains("One automatic guest restart was already tried") == true)
  #expect(error?.message.contains("Disks and Incus data were kept") == true)
  #expect(await driver.startCount == 2)
  #expect(await driver.running)
  _ = try await service.stop(force: true)
}

@Test func incusRecoveryForcesStopOnlyAfterGracefulShutdownHangs() async throws {
  let driver = FakeVM()
  await driver.setHealthy(false)
  await driver.setShutdownWorks(false)
  let (fixture, service) = try bootService(driver, shutdown: 1)
  defer { fixture.clean() }
  let start = Task { try await service.start() }
  try await waitUntil { await driver.running }
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=failed code=incus_crashed\n")
  try await waitUntil { await driver.startCount == 2 }
  // One graceful request, then one forced stop.
  #expect(await driver.stopCount == 2)
  await driver.setHealthy(true)
  #expect(try await start.value.state == .ready)
}

@Test func otherFailureCodesNeverRestartTheGuest() async throws {
  let driver = FakeVM()
  await driver.setHealthy(false)
  let (fixture, service) = try bootService(driver)
  defer { fixture.clean() }
  let start = Task { try await service.start() }
  try await waitUntil { await driver.running }
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=failed code=incus_not_ready\n")
  let error = await startError(start)
  #expect(error?.message.contains("code incus_not_ready") == true)
  #expect(await driver.startCount == 1)
  #expect(await driver.stopCount == 0)
  _ = try await service.stop(force: true)
}

@Test func failureObservedAsTheGuestExitsIsReported() async throws {
  let driver = FakeVM()
  await driver.setHealthy(false)
  let (fixture, service) = try bootService(driver)
  defer { fixture.clean() }
  let start = Task { try await service.start() }
  try await waitUntil { await driver.running }
  await driver.setRunning(false)
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=failed code=image_mismatch\n")
  let error = await startError(start)
  #expect(error?.message.contains("code image_mismatch") == true)
}

@Test func silentStallAfterStorageFailsBeforeTheDeadline() async throws {
  let driver = FakeVM()
  await driver.setHealthy(false)
  let (fixture, service) = try bootService(driver, readiness: 30, stall: .milliseconds(600))
  defer { fixture.clean() }
  let began = ContinuousClock.now
  let start = Task { try await service.start() }
  try await waitUntil { await driver.running }
  try appendSerial(fixture, "MACUS_OBSERVATION v1 stage=storage\n")
  let error = await startError(start)
  #expect(error?.code == .timeout)
  #expect(error?.message.contains("stopped making progress after the storage stage") == true)
  #expect(error?.message.contains("Disks and Incus data were kept") == true)
  #expect(began.duration(to: .now) < .seconds(10))
  #expect(await driver.running)
  _ = try await service.stop(force: true)
}

@Test func progressGuardStaysDisarmedWithoutObservations() async throws {
  let driver = FakeVM()
  await driver.setHealthy(false)
  let (fixture, service) = try bootService(driver, readiness: 2, stall: .milliseconds(100))
  defer { fixture.clean() }
  let error = await startError(Task { try await service.start() })
  #expect(error?.code == .timeout)
  #expect(error?.message.contains("Incus readiness timed out") == true)
  _ = try await service.stop(force: true)
}

@Test func progressGuardArmsAfterStorageAndResetsOnSerialGrowth() {
  let origin = ContinuousClock.now
  let storage = GuestObservation(stage: "storage", state: nil, code: nil)
  let packages = GuestObservation(stage: "packages", state: nil, code: nil)
  var progress = BootProgressGuard(limit: .seconds(10), size: 0, now: origin)
  progress.observe([packages], size: 4, now: origin)
  #expect(!progress.stalled(at: origin.advanced(by: .seconds(60))))
  progress.observe([storage], size: 8, now: origin.advanced(by: .seconds(20)))
  #expect(progress.armed)
  #expect(!progress.stalled(at: origin.advanced(by: .seconds(29))))
  #expect(progress.stalled(at: origin.advanced(by: .seconds(30))))
  progress.observe([], size: 9, now: origin.advanced(by: .seconds(31)))
  #expect(!progress.stalled(at: origin.advanced(by: .seconds(40))))
  progress.observe([], size: 9, now: origin.advanced(by: .seconds(40)))
  #expect(progress.stalled(at: origin.advanced(by: .seconds(41))))
}

@Test func guardObservationsParseAndCopiedLogLinesDoNot() {
  let crashed = GuestObservationParser.parse(
    line: "MACUS_OBSERVATION v1 stage=failed code=incus_crashed")
  #expect(crashed?.failed == true)
  #expect(crashed?.code == GuestObservation.incusCrashed)
  let restarting = GuestObservationParser.parse(
    line: "MACUS_OBSERVATION v1 stage=incus state=restarting")
  #expect(restarting?.stage == "incus")
  #expect(restarting?.armsProgressGuard == true)
  #expect(restarting?.failed == false)
  #expect(
    GuestObservationParser.parse(
      line: "incusd| MACUS_OBSERVATION v1 stage=failed code=incus_crashed") == nil)
  #expect(GuestObservationParser.parse(line: "incusd| TAMA_ZFS_KERNEL_REBOOT_REQUIRED") == nil)
  #expect(readableDetail("incus_recovery") == "Restarting the guest after an Incus crash")
}
