import Darwin
import Foundation
import Testing

@testable import Macus

/// A private state directory with a `logs` directory, under /private/tmp.
private struct LogFixture {
  let root: URL
  let state: URL
  var logs: URL { state.appendingPathComponent("logs", isDirectory: true) }
  var file: URL { logs.appendingPathComponent("gateway-access.log") }

  init(createLogs: Bool = true) throws {
    root = URL(fileURLWithPath: "/private/tmp/macus-logs-\(UUID().uuidString.prefix(8))")
    state = root.appendingPathComponent("state", isDirectory: true)
    for directory in [root, state] + (createLogs ? [logs] : []) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard chmod(directory.path, 0o700) == 0 else { throw RuntimeError(.io, "chmod failed") }
    }
  }

  func archive(_ n: Int) -> URL { logs.appendingPathComponent("gateway-access.log.\(n)") }

  func write(_ lines: [String], to url: URL? = nil, trailing: String = "") throws {
    let target = url ?? file
    try Data((lines.map { $0 + "\n" }.joined() + trailing).utf8).write(to: target)
    _ = chmod(target.path, 0o600)
  }

  func append(_ lines: [String], to url: URL? = nil) throws {
    let target = url ?? file
    if !FileManager.default.fileExists(atPath: target.path) { try write([], to: target) }
    let handle = try FileHandle(forWritingTo: target)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
  }

  /// The rename `logger_std_h` performs with two archives.
  func rotate() throws {
    if FileManager.default.fileExists(atPath: archive(0).path) {
      _ = Darwin.rename(archive(0).path, archive(1).path)
    }
    guard Darwin.rename(file.path, archive(0).path) == 0 else {
      throw RuntimeError(.io, "rename failed")
    }
  }

  func listing() throws -> [String: Date] {
    var result: [String: Date] = [:]
    let enumerator = FileManager.default.enumerator(atPath: state.path)
    while let name = enumerator?.nextObject() as? String {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: state.appendingPathComponent(name).path)
      result[name] = attributes[.modificationDate] as? Date
    }
    return result
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private func record(
  _ n: Int, admittedAs: String? = "caller", status: Int? = 200, outcome: String = "ok",
  reason: String? = nil, dropped: Int? = nil
) -> String {
  func json(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
  let marker = dropped.map { ",\"dropped_before\":\($0)" } ?? ""
  return
    "{\"v\":1,\"time\":\"2026-11-23T10:15:\(String(format: "%02d", n % 60)).412Z\",\"protocol\":\"http\","
    + "\"method\":\"GET\",\"path\":\"/1.0/instances/n\(n)\",\"project\":null,\"target\":null,"
    + "\"all_projects\":false,\"operation\":null,\"peer\":\"192.168.1.20:51422\","
    + "\"certificate\":\"\(String(repeating: "3f9a", count: 16))\",\"admitted_as\":\(json(admittedAs)),"
    + "\"status\":\(status.map(String.init) ?? "null"),\"outcome\":\"\(outcome)\",\"reason\":\(json(reason)),"
    + "\"duration_ms\":12,\"request_bytes\":0,\"response_bytes\":1834\(marker)}"
}

private final class Capture: @unchecked Sendable {
  private let lock = NSLock()
  private var output = ""
  private var error = ""
  var contents: (output: String, error: String) {
    lock.lock()
    defer { lock.unlock() }
    return (output, error)
  }
  var outputLines: [String] { contents.output.split(separator: "\n").map(String.init) }
  var streams: MacusStreams {
    MacusStreams(
      writeOutput: { text in
        self.lock.lock()
        self.output += text
        self.lock.unlock()
      },
      writeError: { text in
        self.lock.lock()
        self.error += text
        self.lock.unlock()
      })
  }
}

/// A transport that fails the test if anything is requested.
private final class NoNetwork: GatewayTransport, LocalHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var requests: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  private func record() {
    lock.lock()
    count += 1
    lock.unlock()
  }
  func request(
    _ endpoint: GatewayEndpoint, method: String, path: String, body: Data, timeout: Int
  ) async throws -> LocalHTTPResponse {
    record()
    throw RuntimeError(.unavailable, "no network in this test")
  }
  func request(socket: URL, method: String, path: String, body: Data, timeout: Int) async throws
    -> LocalHTTPResponse
  {
    record()
    throw RuntimeError(.unavailable, "no network in this test")
  }
}

private func run(_ arguments: [String], state: URL, network: NoNetwork = NoNetwork()) async
  -> (Int32, Capture)
{
  let capture = Capture()
  var overrides = StartupOverrides()
  overrides.installSignals = false
  let status = await MacusCLI.run(
    arguments: ["--state-dir", state.path] + arguments, environment: [:], transport: network,
    gateway: network, streams: capture.streams, overrides: overrides)
  return (status, capture)
}

private func waitFor(_ condition: () -> Bool) async {
  for _ in 0..<200 where !condition() {
    try? await Task.sleep(for: .milliseconds(10))
  }
}

// MARK: Parsing

@Test func serverLogsParsesItsFlagsAndRejectsInvalidCounts() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  for arguments in [
    ["server", "logs", "--lines", "0"], ["server", "logs", "--lines", "100001"],
    ["server", "logs", "--lines", "-3"], ["server", "logs", "--lines", "ten"],
    ["server", "logs", "--lines", "5", "--lines", "6"], ["server", "logs", "--follow", "--follow"],
    ["server", "logs", "--timeout", "5"], ["server", "token", "list", "--lines", "5"],
    ["server", "token", "list", "--follow"], ["server", "logs", "extra"],
  ] {
    let (status, capture) = await run(arguments, state: fixture.state)
    #expect(status == 2, "\(arguments)")
    #expect(capture.contents.output.isEmpty)
  }
  let (status, _) = await run(
    ["server", "logs", "--lines", "100000", "--json"], state: fixture.state)
  #expect(status == 0)
  #expect(MacusCLI.helpText.contains("server logs [--lines N] [--follow] [--json]"))
}

// MARK: Reading

@Test func serverLogsPrintsRecentRecordsAsHumanRowsAndUnchangedJSON() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  let lines = (1...60).map { record($0) }
  try fixture.write(lines)

  let (status, capture) = await run(["server", "logs"], state: fixture.state)
  #expect(status == 0)
  #expect(capture.outputLines.count == 50)
  #expect(
    capture.outputLines.last
      == "2026-11-23T10:15:00.412Z  3f9a3f9a3f9a  200  GET /1.0/instances/n60  12ms  in 0B out 1.8KiB"
  )
  #expect(capture.outputLines.first?.contains("/1.0/instances/n11 ") == true)

  let (jsonStatus, json) = await run(
    ["server", "logs", "--json", "--lines", "3"], state: fixture.state)
  #expect(jsonStatus == 0)
  #expect(json.contents.output == lines.suffix(3).map { $0 + "\n" }.joined())
}

@Test func humanRowsNameTheCallerOutcomeAndDrops() {
  let (rows, malformed) = GatewayAccessLog.rows([
    record(1, admittedAs: nil, status: 403, outcome: "not_sent", reason: "unauthorized"),
    record(2, admittedAs: "anonymous"),
    record(3, admittedAs: "operation_peer"),
    record(4, admittedAs: "image_peer", dropped: 3),
    "not json", "{\"v\":2}",
  ])
  #expect(malformed == 2)
  #expect(rows.count == 5)
  #expect(rows[0].contains("  refused  403  GET /1.0/instances/n1  not_sent unauthorized  12ms"))
  #expect(rows[1].contains("  anonymous  200  "))
  #expect(rows[2].contains("  operation-peer  200  "))
  #expect(rows[3] == "… 3 earlier records dropped")
  #expect(rows[4].contains("  image-peer  200  "))
  #expect(GatewayAccessLog.bytes(5 * 1024 * 1024) == "5.0MiB")
}

@Test func serverLogsReadsAcrossArchivesOldestFirst() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  try fixture.write((1...3).map { record($0) }, to: fixture.archive(1))
  try fixture.write((4...6).map { record($0) }, to: fixture.archive(0))
  try fixture.write((7...8).map { record($0) }, trailing: "{\"v\":1,\"partial")

  let (status, capture) = await run(
    ["server", "logs", "--json", "--lines", "7"], state: fixture.state)
  #expect(status == 0)
  #expect(capture.contents.output == (2...8).map { record($0) + "\n" }.joined())

  let (_, all) = await run(["server", "logs", "--json", "--lines", "100"], state: fixture.state)
  #expect(all.outputLines.count == 8)
}

@Test func serverLogsWithoutALogPrintsNothing() async throws {
  for createLogs in [true, false] {
    let fixture = try LogFixture(createLogs: createLogs)
    defer { fixture.remove() }
    let (status, capture) = await run(["server", "logs"], state: fixture.state)
    #expect(status == 0)
    #expect(capture.contents.output.isEmpty && capture.contents.error.isEmpty)
  }
  let missing = URL(fileURLWithPath: "/private/tmp/macus-logs-missing-\(UUID().uuidString)")
  let (status, capture) = await run(["server", "logs"], state: missing)
  #expect(status == 0)
  #expect(capture.contents.output.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test func serverLogsRefusesAnUnsafeLogDirectoryOrFile() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  try fixture.write([record(1)])

  _ = chmod(fixture.logs.path, 0o755)
  var (status, capture) = await run(["server", "logs", "--json"], state: fixture.state)
  #expect(status == 1)
  #expect(capture.contents.output.isEmpty)
  #expect(capture.contents.error.contains("invalid_configuration"))
  _ = chmod(fixture.logs.path, 0o700)

  _ = chmod(fixture.file.path, 0o666)
  (status, capture) = await run(["server", "logs", "--json"], state: fixture.state)
  #expect(status == 1)
  #expect(capture.contents.output.isEmpty)
  _ = chmod(fixture.file.path, 0o600)

  let real = fixture.root.appendingPathComponent("elsewhere.log")
  try fixture.write([record(2)], to: real)
  try FileManager.default.removeItem(at: fixture.file)
  try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: real)
  (status, capture) = await run(["server", "logs", "--json"], state: fixture.state)
  #expect(status == 1)
  #expect(capture.contents.output.isEmpty)
  #expect(capture.contents.error.contains("invalid_configuration"))
}

@Test func serverLogsSkipsAndCountsMalformedLinesButPassesThemThroughAsJSON() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  try fixture.write([record(1), "garbage", record(2)])

  let (_, human) = await run(["server", "logs"], state: fixture.state)
  #expect(human.outputLines.count == 3)
  #expect(human.outputLines.last == "(1 malformed line skipped)")

  let (_, json) = await run(["server", "logs", "--json"], state: fixture.state)
  #expect(json.outputLines == [record(1), "garbage", record(2)])
}

@Test func serverLogsOpensNoSocketAndWritesNothing() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  try fixture.write((1...3).map { record($0) }, to: fixture.archive(0))
  try fixture.write([record(4)])
  let before = try fixture.listing()
  let network = NoNetwork()

  for arguments in [["server", "logs"], ["server", "logs", "--json", "--lines", "10"]] {
    let (status, _) = await run(arguments, state: fixture.state, network: network)
    #expect(status == 0)
  }
  #expect(network.requests == 0)
  #expect(try fixture.listing() == before)
}

// MARK: Following

@Test func followPrintsNewRecordsAcrossRotationWithoutDuplicatesOrLoss() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  try fixture.write((1...3).map { record($0) })
  let capture = Capture()

  let task = Task {
    try await ServerAdministration.logs(
      lines: 2, follow: true, json: true, directory: fixture.state, streams: capture.streams,
      installSignals: false, interval: .milliseconds(10))
  }
  await waitFor { capture.outputLines.count >= 2 }
  #expect(capture.outputLines == [record(2), record(3)])

  try fixture.append([record(4)])
  await waitFor { capture.outputLines.count >= 3 }
  // Written to the old file just before it is renamed, then the new file starts.
  try fixture.append([record(5)])
  try fixture.rotate()
  try fixture.write([record(6)])
  try fixture.append([record(7)])
  await waitFor { capture.outputLines.count >= 6 }
  try fixture.rotate()
  try fixture.write([record(8)])
  await waitFor { capture.outputLines.count >= 7 }

  task.cancel()
  await #expect(throws: FollowInterrupted.self) { try await task.value }
  #expect(capture.outputLines == (2...8).map { record($0) })
}

@Test func followWaitsForALogThatDoesNotExistYet() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  let capture = Capture()
  let task = Task {
    try await ServerAdministration.logs(
      lines: 50, follow: true, json: false, directory: fixture.state, streams: capture.streams,
      installSignals: false, interval: .milliseconds(10))
  }
  try await Task.sleep(for: .milliseconds(50))
  try fixture.write([record(1)])
  await waitFor { !capture.outputLines.isEmpty }
  task.cancel()
  _ = try? await task.value
  #expect(capture.outputLines.count == 1)
  #expect(capture.outputLines.first?.contains("GET /1.0/instances/n1") == true)
}

@Test func interruptedFollowExitsWith130() async throws {
  let fixture = try LogFixture()
  defer { fixture.remove() }
  try fixture.write([record(1)])
  let capture = Capture()
  let task = Task {
    var overrides = StartupOverrides()
    overrides.installSignals = false
    return await MacusCLI.run(
      arguments: ["--state-dir", fixture.state.path, "server", "logs", "--follow", "--json"],
      environment: [:], transport: NoNetwork(), gateway: NoNetwork(), streams: capture.streams,
      overrides: overrides)
  }
  await waitFor { !capture.outputLines.isEmpty }
  task.cancel()
  #expect(await task.value == 130)
  #expect(capture.outputLines == [record(1)])
  #expect(capture.contents.error.isEmpty)
}
