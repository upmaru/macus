import Darwin
import Foundation
import Testing

@testable import Macus

// Task 8.1: the CLI reaches the runtime through the public HTTPS server only, with the published
// certificate pinned, its own private credential, one deadline and bounded responses.

private func ok(_ object: Any = ["ok": true]) -> Data { mustJSON(200, object) }

@Test func discoveryReadsOnlyOwnerPrivateEndpointAndCredential() throws {
  let missing = URL(fileURLWithPath: "/private/tmp/macusd\(UUID().uuidString.prefix(8))")
  #expect(throws: RuntimeError(.unavailable, "")) {
    try discoveryCode(missing)
  }
  #expect(!FileManager.default.fileExists(atPath: missing.path))

  let gateway = try ScriptedGateway(publish: false) { _, _, _ in ok() }
  defer { gateway.stop() }
  let state = gateway.directory
  // No server directory, then no endpoint: not set up, and nothing is created.
  #expect(try discoveryError(state)?.code == .unavailable)
  #expect(!FileManager.default.fileExists(atPath: gateway.server.path))
  try FileManager.default.createDirectory(
    at: gateway.server, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  #expect(try discoveryError(state)?.message.contains("macus start") == true)

  try gateway.publish()
  let endpoint = try GatewayEndpoint.discover(stateDirectory: state)
  #expect(endpoint.url.absoluteString == gateway.url)
  #expect(endpoint.fingerprint == gateway.identity.fingerprint)
  #expect(!"\(endpoint)".contains("macus.0123"))

  let metadata = gateway.server.appendingPathComponent("endpoint.json")
  let token = gateway.server.appendingPathComponent("local-cli.token")

  // Readable by others: refused, not read.
  #expect(chmod(metadata.path, 0o644) == 0)
  #expect(try discoveryError(state)?.code == .invalidConfiguration)
  #expect(chmod(metadata.path, 0o600) == 0)

  // A link in place of the metadata is refused.
  let real = gateway.server.appendingPathComponent("real.json")
  #expect(rename(metadata.path, real.path) == 0)
  #expect(symlink(real.path, metadata.path) == 0)
  #expect(try discoveryError(state)?.code == .invalidConfiguration)
  unlink(metadata.path)
  #expect(rename(real.path, metadata.path) == 0)

  // A credential others can read is not used.
  #expect(chmod(token.path, 0o644) == 0)
  #expect(try discoveryError(state)?.message.contains("local-cli.token") == true)
  #expect(chmod(token.path, 0o600) == 0)

  // A loose gateway directory is refused.
  #expect(chmod(gateway.server.path, 0o755) == 0)
  #expect(try discoveryError(state)?.code == .invalidConfiguration)
  #expect(chmod(gateway.server.path, 0o700) == 0)

  for url in [
    "http://127.0.0.1:8443", "https://127.0.0.1:8443/runtime", "https://u@127.0.0.1:8443",
    "https://127.0.0.1:8443?x=1", "not a url",
  ] {
    try gateway.publish(url: url)
    #expect(try discoveryError(state)?.code == .invalidConfiguration, "\(url)")
  }
  try gateway.publish(fingerprint: "ABCDEF")
  #expect(try discoveryError(state)?.code == .invalidConfiguration)
}

@Test func requestsCarryTheLocalCredentialOverPinnedTLS13() async throws {
  let gateway = try ScriptedGateway { method, path, body in
    ok(["method": method, "path": path, "body": String(decoding: body, as: UTF8.self)])
  }
  defer { gateway.stop() }
  let endpoint = try GatewayEndpoint.discover(stateDirectory: gateway.directory)
  let client = HTTPSGatewayClient()

  let read = try await client.request(
    endpoint, method: "GET", path: "/runtime/status", body: Data(), timeout: 5)
  #expect(read.status == 200)
  let body = Data(#"{"force":false}"#.utf8)
  let write = try await client.request(
    endpoint, method: "POST", path: "/runtime/stop", body: body, timeout: 5)
  #expect(write.status == 200)

  let requests = gateway.requests()
  #expect(requests.map(\.path) == ["/runtime/status", "/runtime/stop"])
  for request in requests {
    #expect(request.headers["authorization"] == "Bearer \(ScriptedGateway.token)")
    #expect(request.headers["cookie"] == nil)
  }
  #expect(requests[1].body == body)
  #expect(requests[1].headers["content-type"] == "application/json")

  // Paths outside the public runtime API are refused before connecting.
  for path in ["/1.0", "/mcp", "/runtime/../1.0?x", "runtime/status"] {
    await #expect(throws: RuntimeError.self) {
      _ = try await client.request(endpoint, method: "GET", path: path, body: Data(), timeout: 5)
    }
  }
  #expect(gateway.connectionCount == 2)
}

@Test func anotherCertificateOrOlderTLSIsRefusedBeforeAnyRequest() async throws {
  let gateway = try ScriptedGateway { _, _, _ in ok() }
  defer { gateway.stop() }
  try gateway.publish(fingerprint: String(repeating: "0", count: 64))
  let pinned = try GatewayEndpoint.discover(stateDirectory: gateway.directory)
  do {
    _ = try await HTTPSGatewayClient().request(
      pinned, method: "GET", path: "/runtime/status", body: Data(), timeout: 5)
    Issue.record("A server with another certificate was accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .unavailable)
    #expect(error.message.contains("did not present the certificate"))
  }

  let legacy = try ScriptedGateway(tlsVersion: .TLSv12) { _, _, _ in ok() }
  defer { legacy.stop() }
  let endpoint = try GatewayEndpoint.discover(stateDirectory: legacy.directory)
  await #expect(throws: RuntimeError.self) {
    _ = try await HTTPSGatewayClient().request(
      endpoint, method: "GET", path: "/runtime/status", body: Data(), timeout: 5)
  }
  #expect(gateway.requests().isEmpty)
  #expect(legacy.requests().isEmpty)
}

@Test func oneDeadlineAndBoundedResponses() async throws {
  let gateway = try ScriptedGateway { _, path, _ in
    switch path {
    case "/runtime/huge":
      return httpMessage(
        headers: ["Content-Type: application/json", "Content-Length: 20000000"],
        body: Data("{".utf8))
    case "/runtime/chunked":
      let chunk = Data(repeating: 0x20, count: 1_048_576)
      var body = Data()
      for _ in 0..<17 {
        body.append(Data("100000\r\n".utf8))
        body.append(chunk)
        body.append(Data("\r\n".utf8))
      }
      body.append(Data("0\r\n\r\n".utf8))
      return httpMessage(headers: ["Transfer-Encoding: chunked"], body: body)
    case "/runtime/redirect":
      return httpMessage(
        status: "HTTP/1.1 307 Temporary Redirect",
        headers: ["Location: https://example.com/runtime/status", "Content-Length: 0"])
    default:
      return ok()
    }
  }
  defer { gateway.stop() }
  let endpoint = try GatewayEndpoint.discover(stateDirectory: gateway.directory)
  let client = HTTPSGatewayClient()

  for path in ["/runtime/huge", "/runtime/chunked"] {
    do {
      _ = try await client.request(endpoint, method: "GET", path: path, body: Data(), timeout: 10)
      Issue.record("\(path) was not bounded")
    } catch let error as RuntimeError {
      #expect(error.message.contains("16 MiB"), "\(path): \(error.message)")
    }
  }
  await #expect(throws: RuntimeError.self) {
    _ = try await client.request(
      endpoint, method: "GET", path: "/runtime/redirect", body: Data(), timeout: 5)
  }
  #expect(!gateway.requests().contains { $0.path == "/runtime/status" })

  gateway.delay = 3
  let started = ContinuousClock.now
  do {
    _ = try await client.request(
      endpoint, method: "GET", path: "/runtime/status", body: Data(), timeout: 1)
    Issue.record("The deadline did not apply")
  } catch let error as RuntimeError {
    #expect(error.code == .timeout)
  }
  #expect(started.duration(to: .now) < .milliseconds(2_500))
}

@Test func runtimeCommandsNeverFallBackToThePrivateSocket() async throws {
  // The private runtime socket answers, but the published server is not listening.
  let runtime = try ScriptedSocket(name: "runtime.sock") { _, _, _ in
    mustJSON(200, statusObject(state: "ready", incus: "/tmp/incus.sock"))
  }
  defer { runtime.stop() }
  let closed = try ScriptedGateway(directory: runtime.socket.directory) { _, _, _ in ok() }
  let url = closed.url
  closed.stop()
  try FileManager.default.createDirectory(
    at: runtime.socket.directory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  try writeGatewayState(
    directory: runtime.socket.directory, url: url, fingerprint: String(repeating: "0", count: 64))

  for arguments in [
    ["runtime", "status"], ["runtime", "start"], ["doctor"], ["client", "setup"],
  ] {
    let result = try await runMacus(
      ["--state-dir", runtime.socket.directory.path, "--json", "--timeout", "3"] + arguments,
      environment: ["PATH": "/usr/bin:/bin", "MACUS_BREW_FALLBACK": "0"])
    #expect(result.status == 1, "\(arguments)")
    let error = try JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any]
    #expect((error?["error"] as? [String: Any])?["code"] as? String == "unavailable")
  }
  #expect(runtime.requests().isEmpty)
}

@Test func refusedCredentialAsksForANewStart() async throws {
  let gateway = try ScriptedGateway { _, _, _ in
    httpMessage(
      status: "HTTP/1.1 401 Unauthorized",
      headers: [#"WWW-Authenticate: Bearer error="invalid_token""#, "Content-Length: 0"])
  }
  defer { gateway.stop() }
  let result = try await runMacus([
    "--state-dir", gateway.directory.path, "--json", "--timeout", "3", "runtime", "status",
  ])
  #expect(result.status == 1)
  #expect(result.stderr.contains("macus start"))
  #expect(!result.stderr.contains(ScriptedGateway.token))
}

private func discoveryError(_ state: URL) throws -> RuntimeError? {
  do {
    _ = try GatewayEndpoint.discover(stateDirectory: state)
    return nil
  } catch let error as RuntimeError {
    return error
  }
}

/// Throws the discovery error with an empty message so `#expect(throws:)` compares only codes.
private func discoveryCode(_ state: URL) throws {
  if let error = try discoveryError(state) { throw RuntimeError(error.code, "") }
}
