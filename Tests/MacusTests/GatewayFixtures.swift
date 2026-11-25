import CryptoKit
import Darwin
import Foundation
import Network
import Security
import Testing

@testable import Macus

/// A self-signed RSA identity held in memory only (never in a keychain), and its DER
/// certificate.
struct TestIdentity: @unchecked Sendable {
  let identity: SecIdentity
  let certificate: Data
  var fingerprint: String {
    SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
  }

  static func make() throws -> TestIdentity {
    let directory = URL(
      fileURLWithPath: "/private/tmp/macus-id-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = directory.appendingPathComponent("key.pem").path
    let cert = directory.appendingPathComponent("cert.pem").path
    let p12 = directory.appendingPathComponent("id.p12").path
    try openssl([
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=127.0.0.1",
      "-addext", "subjectAltName=IP:127.0.0.1",
    ])
    try openssl([
      "pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:macus",
      "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1",
    ])
    let data = try Data(contentsOf: URL(fileURLWithPath: p12))
    var items: CFArray?
    let options: [String: Any] = [
      kSecImportExportPassphrase as String: "macus",
      kSecImportToMemoryOnly as String: true,
    ]
    guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
      let first = (items as? [[String: Any]])?.first,
      let value = first[kSecImportItemIdentity as String]
    else { throw RuntimeError(.io, "Cannot import the test identity") }
    let identity = value as! SecIdentity
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate
    else { throw RuntimeError(.io, "Cannot read the test certificate") }
    return TestIdentity(
      identity: identity, certificate: SecCertificateCopyData(certificate) as Data)
  }

  private static func openssl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw RuntimeError(.io, "openssl \(arguments[0]) failed")
    }
  }
}

/// A local TLS server standing in for the Macus gateway. Each connection serves one request:
/// `responder(method, path, body)` returns the complete HTTP response bytes. The fixture's state
/// directory holds the `server/endpoint.json` and `server/local-cli.token` a running gateway and
/// `macus start` would have written.
final class ScriptedGateway: @unchecked Sendable {
  struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  static let token = "macus.0123456789abcdef.\(String(repeating: "A", count: 43))"

  let directory: URL
  let identity: TestIdentity
  private(set) var port: UInt16 = 0
  private let listener: NWListener
  private let queue = DispatchQueue(label: "macus.test.gateway")
  private let lock = NSLock()
  private var recorded: [Request] = []
  private var connections = 0
  var responder: @Sendable (String, String, Data) -> Data
  var delay: Double = 0

  var url: String { "https://127.0.0.1:\(port)" }
  var server: URL { directory.appendingPathComponent("server") }

  init(
    directory: URL? = nil, tlsVersion: tls_protocol_version_t = .TLSv13,
    publish: Bool = true,
    responder: @escaping @Sendable (String, String, Data) -> Data
  ) throws {
    self.directory =
      directory
      ?? URL(fileURLWithPath: "/tmp/macusg\(UUID().uuidString.prefix(8))", isDirectory: true)
    identity = try TestIdentity.make()
    self.responder = responder
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_local_identity(options, sec_identity_create(identity.identity)!)
    sec_protocol_options_set_min_tls_protocol_version(options, tlsVersion)
    sec_protocol_options_set_max_tls_protocol_version(options, tlsVersion)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
      throw RuntimeError(.io, "The test gateway did not start")
    }
    self.port = port
    try FileManager.default.createDirectory(
      at: self.directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard chmod(self.directory.path, 0o700) == 0 else {
      throw RuntimeError(.io, "Cannot secure the test state directory")
    }
    if publish { try self.publish() }
  }

  /// Writes the endpoint metadata and local CLI credential, as the gateway and `macus start` do.
  func publish(fingerprint: String? = nil, url: String? = nil) throws {
    try writeGatewayState(
      directory: directory, url: url ?? self.url,
      fingerprint: fingerprint ?? identity.fingerprint)
  }

  func requests() -> [Request] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var connectionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return connections
  }

  func stop() {
    listener.cancel()
    try? FileManager.default.removeItem(at: directory)
  }

  private func accept(_ connection: NWConnection) {
    lock.lock()
    connections += 1
    lock.unlock()
    connection.start(queue: queue)
    receive(connection, Data())
  }

  private func receive(_ connection: NWConnection, _ buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if let request = Self.parse(buffer) {
        self.respond(connection, request)
      } else if complete || error != nil {
        connection.cancel()
      } else {
        self.receive(connection, buffer)
      }
    }
  }

  private func respond(_ connection: NWConnection, _ request: Request) {
    lock.lock()
    recorded.append(request)
    let responder = responder
    let delay = delay
    lock.unlock()
    let reply = responder(request.method, request.path, request.body)
    queue.asyncAfter(deadline: .now() + delay) {
      connection.send(
        content: reply, contentContext: .finalMessage, isComplete: true,
        completion: .contentProcessed { _ in connection.cancel() })
    }
  }

  private static func parse(_ data: Data) -> Request? {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ")
    guard first.count == 3 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    let body = data[end.upperBound...]
    guard body.count >= length else { return nil }
    return Request(
      method: String(first[0]), path: String(first[1]), headers: headers,
      body: Data(body.prefix(length)))
  }
}

/// Writes `server/endpoint.json` and `server/local-cli.token` (0600, in a 0700 directory).
func writeGatewayState(directory: URL, url: String, fingerprint: String) throws {
  try writeEndpointMetadata(directory: directory, url: url, fingerprint: fingerprint)
  try writePrivate(
    Data((ScriptedGateway.token + "\n").utf8),
    to: directory.appendingPathComponent("server/local-cli.token"))
}

/// Writes only `server/endpoint.json`, as a serving server publishes it.
func writeEndpointMetadata(directory: URL, url: String, fingerprint: String) throws {
  let server = directory.appendingPathComponent("server")
  if !FileManager.default.fileExists(atPath: server.path) {
    try FileManager.default.createDirectory(
      at: server, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  let metadata: [String: Any] = [
    "schema_version": 1, "url": url, "addresses": ["127.0.0.1"], "listen": "127.0.0.1",
    "certificate": "-----BEGIN CERTIFICATE-----", "certificate_fingerprint": fingerprint,
    "pid": "1", "started_at": "2026-11-19T00:00:00Z",
    "build": ["version": "0.1.0", "revision": String(repeating: "a", count: 40)],
  ]
  try writePrivate(
    try JSONSerialization.data(withJSONObject: metadata),
    to: server.appendingPathComponent("endpoint.json"))
}

func writePrivate(_ data: Data, to url: URL) throws {
  try? FileManager.default.removeItem(at: url)
  guard FileManager.default.createFile(atPath: url.path, contents: data),
    chmod(url.path, 0o600) == 0
  else { throw RuntimeError(.io, "Cannot write \(url.path)") }
}

/// A public `/runtime/status` object as the gateway projects it.
func publicStatus(state: String, url: String = "https://127.0.0.1:8443") -> [String: Any] {
  let endpoint: [String: Any] = [
    "url": url, "certificate_fingerprint": String(repeating: "0", count: 64),
  ]
  return [
    "api_version": 1, "state": state, "last_error": NSNull(), "uptime_seconds": 4,
    "server_endpoint": endpoint, "incus_endpoint": endpoint, "server_ready": true,
    "runtime_ready": state == "ready",
  ]
}

/// Stands in for the Macus server: answers the probe as a serving (or absent) server and counts
/// asks, and serves the public `/runtime` API the way the gateway does, relaying each request to
/// the state's private `runtime.sock` beneath `/v1/runtime` and projecting the status.
///
/// With `publishes`, a serving answer also publishes `server/endpoint.json` for that state (the
/// credential is the one `macus start` prepared), so gateway discovery succeeds.
final class FakeServerProbe: ServerProbe, GatewayTransport, @unchecked Sendable {
  struct Request: Equatable {
    let method: String
    let path: String
    let body: String
  }

  private let lock = NSLock()
  private var answer: Bool
  private var count = 0
  private let publishes: Bool
  private var states: [String: URL] = [:]
  private var recorded: [Request] = []
  private var drops: [String: Drop] = [:]

  /// How a scripted request loses its connection: before it reaches Swift, or after Swift has
  /// accepted it (the gateway connection then breaks while Swift keeps working).
  /// `interruptAfterDispatch` stands for the user interrupting start while Swift works on it.
  enum Drop { case beforeDispatch, afterDispatch, interruptAfterDispatch }

  init(serving: Bool = true, publishes: Bool = false) {
    answer = serving
    self.publishes = publishes
  }
  var serving: Bool {
    get { lock.withLock { answer } }
    set { lock.withLock { answer = newValue } }
  }
  var asks: Int { lock.withLock { count } }
  /// The public requests received, in order.
  var requests: [Request] { lock.withLock { recorded } }
  /// The next `method path` request loses its connection once.
  func drop(_ method: String, _ path: String, _ drop: Drop) {
    lock.withLock { drops["\(method) \(path)"] = drop }
  }

  func serving(stateDirectory: URL, timeout: Int) async throws -> Bool {
    let answer: Bool = lock.withLock {
      count += 1
      return self.answer
    }
    if answer && publishes { try publish(stateDirectory) }
    return answer
  }

  private func publish(_ directory: URL) throws {
    let url: String = lock.withLock {
      if let existing = states.first(where: { $0.value == directory })?.key { return existing }
      let url = "https://127.0.0.1:\(20_000 + states.count)"
      states[url] = directory
      return url
    }
    try writeEndpointMetadata(
      directory: directory, url: url, fingerprint: FixtureCertificate.server.fingerprint)
  }

  func request(
    _ endpoint: GatewayEndpoint, method: String, path: String, body: Data, timeout: Int
  ) async throws -> LocalHTTPResponse {
    let (directory, drop, up): (URL?, Drop?, Bool) = lock.withLock {
      recorded.append(
        Request(method: method, path: path, body: String(decoding: body, as: UTF8.self)))
      let drop = drops.removeValue(forKey: "\(method) \(path)")
      return (states[endpoint.url.absoluteString], drop, answer)
    }
    guard let directory, up else {
      throw RuntimeError(.unavailable, "Cannot connect to the Macus server (fixture)")
    }
    if drop == .beforeDispatch {
      throw RuntimeError(.unavailable, "Cannot connect to the Macus server (fixture)")
    }
    let socket = directory.appendingPathComponent("runtime.sock")
    let response: LocalHTTPResponse
    do {
      response = try await UnixHTTPClient().request(
        socket: socket, method: method, path: "/v1" + path,
        body: Self.privateBody(path: path, body: body), timeout: timeout)
    } catch let error as RuntimeError where error.code == .invalidRequest {
      throw error
    } catch {
      var object: [String: Any] = [
        "error": [
          "code": "unavailable", "message": "The Swift runtime service did not answer.",
          "outcome": "not_dispatched",
        ]
      ]
      if path == "/runtime/status" {
        object["server_ready"] = true
        object["runtime_ready"] = false
      }
      return LocalHTTPResponse(
        status: 503, body: try JSONSerialization.data(withJSONObject: object))
    }
    if drop == .afterDispatch {
      throw RuntimeError(.unavailable, "The Macus server connection was lost (fixture)")
    }
    if drop == .interruptAfterDispatch { throw CancellationError() }
    return project(response, url: endpoint.url.absoluteString)
  }

  private func project(_ response: LocalHTTPResponse, url: String) -> LocalHTTPResponse {
    guard (200...299).contains(response.status),
      var object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    else { return response }
    // An upgrade or rollback result carries the runtime status, projected the same way.
    if var status = object["status"] as? [String: Any], status["incus_socket"] != nil,
      let state = status["state"] as? String
    {
      Self.project(&status, state: state, url: url)
      object["status"] = status
      return LocalHTTPResponse(
        status: response.status,
        body: (try? JSONSerialization.data(withJSONObject: object)) ?? response.body)
    }
    guard object["incus_socket"] != nil, let state = object["state"] as? String else {
      return response
    }
    Self.project(&object, state: state, url: url)
    return LocalHTTPResponse(
      status: response.status,
      body: (try? JSONSerialization.data(withJSONObject: object)) ?? response.body)
  }

  /// The server turns a public confirmation token into the private boolean; other bodies
  /// pass through, and the private routes ignore keys they do not read.
  private static func privateBody(path: String, body: Data) -> Data {
    guard path == "/runtime/backups/prune",
      var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return body }
    object["confirm"] = object["confirm"] as? String == "prune-backup"
    return (try? JSONSerialization.data(withJSONObject: object)) ?? body
  }

  private static func project(_ object: inout [String: Any], state: String, url: String) {
    object.removeValue(forKey: "incus_socket")
    let endpoint: [String: Any] = [
      "url": url, "certificate_fingerprint": String(repeating: "0", count: 64),
    ]
    object["server_endpoint"] = endpoint
    object["incus_endpoint"] = endpoint
    object["server_ready"] = true
    object["runtime_ready"] = state == "ready"
  }
}
