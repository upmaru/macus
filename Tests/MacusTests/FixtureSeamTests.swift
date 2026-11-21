import Darwin
import Foundation
import Testing

@testable import Macus

/// A fresh owner-private directory beneath /private/tmp, as fixture seams require.
private func isolatedDirectory() throws -> URL {
  let url = URL(
    fileURLWithPath: "/private/tmp/macus-fx-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return url
}

private func refusal(_ body: () throws -> URL?) -> String? {
  do {
    _ = try body()
    return nil
  } catch let error as RuntimeError {
    #expect(error.code == .invalidConfiguration)
    return error.message
  } catch {
    return "\(error)"
  }
}

@Test func fixtureSeamsAreOffUnlessNamed() throws {
  let path = try FixtureSeam.path(
    FixtureSeam.guestVariable, environment: [:],
    stateDirectory: URL(fileURLWithPath: "/Users/nobody/state"), kind: .directory)
  #expect(path == nil)
}

@Test func fixtureSeamsAcceptOnlyIsolatedPrivateTemporaryPaths() throws {
  let root = try isolatedDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let state = root.appendingPathComponent("state")
  let guest = root.appendingPathComponent("guest")
  for url in [state, guest] {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  let variable = FixtureSeam.guestVariable
  func check(_ value: String, state: URL = state, kind: FixtureSeam.Kind = .directory) -> String? {
    refusal {
      try FixtureSeam.path(
        variable, environment: [variable: value], stateDirectory: state, kind: kind)
    }
  }
  #expect(check(guest.path) == nil)
  #expect(
    try FixtureSeam.path(
      variable, environment: [variable: guest.path], stateDirectory: state, kind: .directory)?
      .path == guest.path)

  // The state directory is checked as strictly as the fixture path.
  let home = check(guest.path, state: URL(fileURLWithPath: NSHomeDirectory()))
  #expect(
    home?.contains("\(variable) is refused: the state directory is not beneath /private/tmp")
      == true)
  // The system's /tmp link is followed, as for state paths; no other link is.
  #expect(check("/tmp/" + guest.path.dropFirst("/private/tmp/".count)) == nil)
  #expect(
    check(guest.path, state: URL(fileURLWithPath: "/tmp/" + state.path.dropFirst(13))) == nil)
  #expect(check(root.path + "/../" + guest.lastPathComponent)?.contains("not beneath") == true)
  #expect(check("/private/tmp/")?.contains("not beneath") == true)
  #expect(check(root.appendingPathComponent("missing").path)?.contains("does not exist") == true)

  let link = root.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: guest)
  #expect(check(link.path)?.contains("contains a symbolic link") == true)

  let shared = root.appendingPathComponent("shared")
  try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
  #expect(chmod(shared.path, 0o770) == 0)
  #expect(check(shared.path)?.contains("writable by group or others") == true)
  let below = shared.appendingPathComponent("guest")
  try FileManager.default.createDirectory(
    at: below, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  #expect(check(below.path)?.contains("writable by group or others") == true)

  let file = root.appendingPathComponent("file")
  #expect(FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8)))
  #expect(chmod(file.path, 0o600) == 0)
  #expect(check(file.path)?.contains("is not a directory") == true)
  #expect(check(file.path, kind: .executable)?.contains("not an executable file") == true)
  #expect(check(guest.path, kind: .executable)?.contains("not an executable file") == true)
  #expect(chmod(file.path, 0o700) == 0)
  #expect(check(file.path, kind: .executable) == nil)
}

@Test func fixtureGuestOutsideIsolationFailsBeforeTouchingState() async throws {
  let state = URL(
    fileURLWithPath: NSTemporaryDirectory() + "macus-fx-\(UUID().uuidString.prefix(8))")
  let root = try isolatedDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let capture = StartCapture()
  let status = await MacusCLI.run(
    arguments: ["serve", "--state-dir", state.path],
    environment: [FixtureSeam.guestVariable: root.path], streams: capture.streams)
  #expect(status != 0)
  #expect(capture.error.contains("\(FixtureSeam.guestVariable) is refused"))
  #expect(!FileManager.default.fileExists(atPath: state.path))
}

@Test func fixtureLaunchctlOutsideIsolationFailsBeforeTouchingStateOrLaunchd() async throws {
  let state = URL(
    fileURLWithPath: NSTemporaryDirectory() + "macus-fx-\(UUID().uuidString.prefix(8))")
  let launch = FakeLaunchControl()
  let downloader = RecordingDownloader()
  let capture = StartCapture()
  let status = await MacusCLI.run(
    arguments: ["--state-dir", state.path, "--json", "start"],
    environment: ["PATH": "/usr/bin:/bin", FixtureSeam.launchctlVariable: "/usr/bin/true"],
    streams: capture.streams,
    overrides: StartupOverrides(
      capabilities: { HostCapabilities(supported: true, nestedVirtualization: false) },
      hasEntitlement: { true }, downloader: downloader, launchControl: launch,
      installSignals: false))
  #expect(status != 0)
  #expect(capture.error.contains("\(FixtureSeam.launchctlVariable) is refused"))
  #expect(downloader.calls == 0)
  #expect(launch.bootstrapped.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: state.path))
}

@Test func processLaunchControlGivesTheStandInLaunchctlArguments() async throws {
  let runner = RecordingLaunchRunner()
  let control = ProcessLaunchControl(
    runner: runner, environment: ["HOME": "/private/tmp/h"], uid: 501,
    executable: "/private/tmp/fx/launchctl")
  _ = try await control.printJob(label: "com.upmaru.macus.x", timeout: 5)
  try await control.kickstart(label: "com.upmaru.macus.x", timeout: 5)
  try await control.bootstrap(plist: URL(fileURLWithPath: "/private/tmp/p.plist"), timeout: 5)
  #expect(
    runner.calls == [
      ["/private/tmp/fx/launchctl", "print", "gui/501/com.upmaru.macus.x"],
      ["/private/tmp/fx/launchctl", "kickstart", "gui/501/com.upmaru.macus.x"],
      ["/private/tmp/fx/launchctl", "bootstrap", "gui/501", "/private/tmp/p.plist"],
    ])
  #expect(
    ProcessLaunchControl(runner: runner, environment: [:], uid: 501).executable == "/bin/launchctl")
}

private final class RecordingLaunchRunner: LocalCommandRunner, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []
  var calls: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
  func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Int
  ) async throws -> LocalCommandResult {
    lock.withLock { recorded.append([executable] + arguments) }
    // `print` reports no job; kickstart and bootstrap succeed.
    return LocalCommandResult(
      status: arguments.first == "print" ? 113 : 0, stdout: Data(), stderr: Data())
  }
}

@Test func fixtureGuestServesPortsFromItsDirectory() async throws {
  let root = try isolatedDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let driver = FixtureGuestDriver(directory: root)
  let paths = RuntimePaths(directory: root.appendingPathComponent("state"))
  await #expect(throws: RuntimeError.self) { _ = try await driver.openStream(port: 8444) }

  let body = try JSONSerialization.data(withJSONObject: [
    "protocol_version": 1, "incus_version": "7.0.1", "api_extensions": ["instances"],
    "kvm": false, "flow_relay_version": FlowRelayProtocol.version,
  ])
  let health = try PrivateUNIXSocket(name: "vsock-8444.sock", directory: root)
  defer { health.stop() }
  health.serveHTTP { request, descriptor in
    #expect(request.method == "GET" && request.path == "/health")
    writeAll(
      descriptor, httpMessage(headers: ["Content-Length: \(body.count)"], body: body))
  }

  try await driver.start(
    configuration: RuntimeConfiguration(applianceManifestPath: "/private/tmp/manifest.json"),
    paths: paths)
  #expect(await driver.isRunning())
  await #expect(throws: RuntimeError.self) {
    try await driver.start(
      configuration: RuntimeConfiguration(applianceManifestPath: "/private/tmp/manifest.json"),
      paths: paths)
  }
  let reported = try await driver.health()
  #expect(reported.incusVersion == "7.0.1" && reported.apiExtensions == ["instances"])
  #expect(reported.flowRelayVersion == FlowRelayProtocol.version)
  // A port nothing serves is unavailable rather than a hang.
  await #expect(throws: RuntimeError.self) { _ = try await driver.openStream(port: 8443) }

  try await driver.requestStop()
  #expect(!(await driver.isRunning()))
  await #expect(throws: RuntimeError.self) { _ = try await driver.openStream(port: 8444) }
}
