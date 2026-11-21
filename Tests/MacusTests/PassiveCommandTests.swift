import CryptoKit
import Foundation
import Testing

@testable import Macus

// Read-only commands stay passive now that the CLI is a client of the Macus server: they send
// only GET requests to the published HTTPS endpoint, never reach the private Unix sockets, run no
// subprocess (no brew, incus or launchctl), touch no launchd job and leave the state directory
// byte-for-byte unchanged. `client setup` against a runtime that is not ready is held to the same.

private final class PassiveGateway: GatewayTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [(method: String, path: String)] = []

  var requests: [(method: String, path: String)] {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func request(
    _ endpoint: GatewayEndpoint, method: String, path: String, body: Data, timeout: Int
  ) async throws -> LocalHTTPResponse {
    lock.withLock { calls.append((method, path)) }
    let (status, object): (Int, Any) =
      switch path {
      case "/runtime/status": (200, publicStatus(state: "stopped"))
      case "/runtime/capabilities": (200, ["supported": true])
      default: (503, errorObject(code: "unavailable", message: "Incus is not ready"))
      }
    return LocalHTTPResponse(
      status: status, body: try JSONSerialization.data(withJSONObject: object))
  }
}

/// Fails any private-socket request, so a command that reaches for one is visible.
private final class RefusingSocket: LocalHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var paths: [String] = []

  var used: [String] {
    lock.lock()
    defer { lock.unlock() }
    return paths
  }

  func request(socket: URL, method: String, path: String, body: Data, timeout: Int) async throws
    -> LocalHTTPResponse
  {
    lock.withLock { paths.append("\(method) \(socket.lastPathComponent)\(path)") }
    throw RuntimeError(.unavailable, "Private socket requested")
  }
}

private final class RefusingRunner: LocalCommandRunner, @unchecked Sendable {
  private let lock = NSLock()
  private var commands: [[String]] = []

  var ran: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return commands
  }

  func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Int
  ) async throws -> LocalCommandResult {
    try await run(
      executable: executable, arguments: arguments, environment: environment, timeout: timeout,
      input: nil)
  }

  func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Int,
    input: Data?
  ) async throws -> LocalCommandResult {
    lock.withLock { commands.append([executable] + arguments) }
    throw RuntimeError(.unavailable, "Subprocess requested")
  }
}

private final class RefusingLaunch: LaunchControl, @unchecked Sendable {
  private let lock = NSLock()
  private var actions: [String] = []

  var used: [String] {
    lock.lock()
    defer { lock.unlock() }
    return actions
  }

  private func record(_ action: String) {
    lock.lock()
    actions.append(action)
    lock.unlock()
  }

  func printJob(label: String, timeout: Int) async throws -> LaunchJob? {
    record("print \(label)")
    return nil
  }
  func bootstrap(plist: URL, timeout: Int) async throws { record("bootstrap \(plist.path)") }
  func kickstart(label: String, timeout: Int) async throws { record("kickstart \(label)") }
  func plist(at url: URL) throws -> [String: Any]? {
    record("plist \(url.path)")
    return nil
  }
}

private final class Streams: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""

  var streams: MacusStreams {
    MacusStreams(
      writeOutput: { value in self.append(value) }, writeError: { value in self.append(value) })
  }

  var all: String {
    lock.lock()
    defer { lock.unlock() }
    return text
  }

  private func append(_ value: String) {
    lock.lock()
    text += value
    lock.unlock()
  }
}

/// Every entry under `root` with its type, mode, size, modification time and, for files, a
/// content digest.
private func snapshot(_ root: URL) throws -> [String: String] {
  let manager = FileManager.default
  var entries: [String: String] = [:]
  func describe(_ url: URL, as key: String) throws {
    let attributes = try manager.attributesOfItem(atPath: url.path)
    var line = [
      "\(attributes[.type] ?? "")", "\(attributes[.posixPermissions] ?? "")",
      "\(attributes[.size] ?? "")", "\(attributes[.modificationDate] ?? "")",
    ].joined(separator: " ")
    if attributes[.type] as? FileAttributeType == .typeRegular {
      line += " " + SHA256.hash(data: try Data(contentsOf: url)).description
    }
    entries[key] = line
  }
  try describe(root, as: ".")
  let enumerator = try #require(manager.enumerator(atPath: root.path))
  while let relative = enumerator.nextObject() as? String {
    try describe(root.appendingPathComponent(relative), as: relative)
  }
  return entries
}

@Test func readOnlyCommandsArePassiveClientsOfThePublishedServer() async throws {
  let state = URL(fileURLWithPath: "/private/tmp/macuspc\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(
    at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: state) }
  try writeGatewayState(
    directory: state, url: "https://127.0.0.1:8443",
    fingerprint: FixtureCertificate.server.fingerprint)
  let before = try snapshot(state)

  let gateway = PassiveGateway()
  let socket = RefusingSocket()
  let runner = RefusingRunner()
  let launch = RefusingLaunch()
  var overrides = StartupOverrides()
  overrides.runner = runner
  overrides.launchControl = launch
  overrides.installSignals = false

  let commands: [[String]] = [
    [], ["--help"], ["capabilities"], ["--json", "capabilities"],
    ["runtime", "status"], ["--json", "runtime", "status"],
    ["doctor"], ["--json", "doctor"],
    ["server", "config", "show"], ["--json", "server", "config", "show"],
    ["server", "token", "list"], ["--json", "server", "token", "list"],
    ["server", "trust", "token", "list"], ["--json", "server", "trust", "token", "list"],
    // Not read-only, but a runtime that is not ready stops it before it touches anything.
    ["--json", "client", "setup"], ["client", "setup", "--remote", "elsewhere"],
  ]
  for arguments in commands {
    let output = Streams()
    let status = await MacusCLI.run(
      arguments: arguments, environment: ["MACUS_STATE_DIR": state.path, "HOME": state.path],
      transport: socket, gateway: gateway, streams: output.streams, overrides: overrides)
    #expect(status == 0 || status == 1, "\(arguments): \(output.all)")
    #expect(!output.all.isEmpty, "\(arguments)")
  }

  let requests = gateway.requests
  #expect(!requests.isEmpty)
  #expect(requests.allSatisfy { $0.method == "GET" }, "\(requests)")
  #expect(
    Set(requests.map(\.path)).isSubset(
      of: ["/runtime/status", "/runtime/capabilities", "/runtime/health"]),
    "\(requests)")
  #expect(socket.used.isEmpty, "\(socket.used)")
  #expect(runner.ran.isEmpty, "\(runner.ran)")
  #expect(launch.used.isEmpty, "\(launch.used)")
  #expect(try snapshot(state) == before)
}
