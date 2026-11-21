import Darwin
import Foundation
import Testing

@testable import Macus

/// A private state directory and a private directory for operator certificate files.
private struct ConfigFixture {
  let state: URL
  let certs: URL
  var store: GatewayConfigurationStore { GatewayConfigurationStore(stateDirectory: state) }
  var tokens: BearerTokenStore { BearerTokenStore(stateDirectory: state) }
  var gatewayDirectory: URL { state.appendingPathComponent("server", isDirectory: true) }

  init() throws {
    let root = URL(fileURLWithPath: "/private/tmp/macus-config-\(UUID().uuidString.prefix(8))")
    state = root.appendingPathComponent("state", isDirectory: true)
    certs = root.appendingPathComponent("certs", isDirectory: true)
    for directory in [root, state, certs] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard chmod(directory.path, 0o700) == 0 else { throw RuntimeError(.io, "chmod failed") }
    }
  }

  func remove() { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }

  func identityFile(_ name: String, mode: mode_t) throws -> String {
    let url = certs.appendingPathComponent(name)
    try Data("-----BEGIN PLACEHOLDER-----\n".utf8).write(to: url)
    _ = chmod(url.path, mode)
    return url.path
  }

  func stored() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as! [String: Any]
  }
}

private func mode(_ url: URL) -> mode_t {
  var info = stat()
  _ = lstat(url.path, &info)
  return info.st_mode & 0o777
}

@Test func configCommandsWriteOnlyGatewayJSONAndNeverTouchTheRuntime() async throws {
  let fixture = try ConfigFixture()
  defer { fixture.remove() }
  let runtime = try ScriptedSocket(name: "runtime.sock", directory: fixture.state) { _, _, _ in
    mustJSON(200, statusObject(state: "ready", incus: "/tmp/incus.sock"))
  }
  defer { runtime.stop() }
  let disks = fixture.state.appendingPathComponent("runtime", isDirectory: true)
  try FileManager.default.createDirectory(at: disks, withIntermediateDirectories: false)
  let disk = disks.appendingPathComponent("root.raw")
  try Data(repeating: 7, count: 4096).write(to: disk)
  let state = fixture.state.path
  let certificate = try fixture.identityFile("macus.pem", mode: 0o644)
  let key = try fixture.identityFile("macus.key", mode: 0o600)

  // show reports the loopback defaults and creates nothing.
  let defaults = try await runMacus(["--json", "--state-dir", state, "server", "config", "show"])
  #expect(defaults.status == 0)
  let shown = try jsonObject(Data(defaults.stdout.utf8))["gateway"] as! [String: Any]
  #expect(shown["bind_address"] as? String == "127.0.0.1")
  #expect(shown["port"] as? Int == 8443)
  #expect(shown["url"] as? String == "https://127.0.0.1:8443")
  #expect(shown["default_identity"] as? Bool == true)
  #expect(shown["file"] is NSNull)
  #expect(!FileManager.default.fileExists(atPath: fixture.gatewayDirectory.path))

  let set = try await runMacus([
    "--json", "--state-dir", state, "server", "config", "set", "--bind-address", "192.168.1.20",
    "--advertised-url", "https://macus.example.net:8443", "--certificate-file", certificate,
    "--key-file", key,
  ])
  #expect(set.status == 0, "\(set.stderr)")
  #expect(mode(fixture.gatewayDirectory) == 0o700)
  #expect(mode(fixture.store.file) == 0o600)
  let document = try fixture.stored()
  #expect(document.count == 5)
  #expect(document["schema_version"] as? Int == 1)
  #expect(document["bind_address"] as? String == "192.168.1.20")
  #expect(document["advertised_url"] as? String == "https://macus.example.net:8443")
  #expect(document["certificate_file"] as? String == certificate)
  #expect(document["key_file"] as? String == key)

  // show reports a stored file as machine output too.
  let stored = try await runMacus(["--json", "--state-dir", state, "server", "config", "show"])
  #expect(stored.status == 0, "\(stored.stderr)")
  let storedShown = try jsonObject(Data(stored.stdout.utf8))["gateway"] as! [String: Any]
  #expect(storedShown["bind_address"] as? String == "192.168.1.20")
  #expect(storedShown["url"] as? String == "https://macus.example.net:8443")
  #expect(storedShown["certificate_file"] as? String == certificate)
  #expect(storedShown["key_file"] as? String == key)
  #expect(storedShown["default_identity"] as? Bool == false)
  #expect(storedShown["file"] as? String == fixture.store.file.path)

  // set changes only the fields given.
  let port = try await runMacus([
    "--state-dir", state, "server", "config", "set", "--port", "9443",
  ])
  #expect(port.status == 0)
  #expect(port.stdout.contains("Gateway configuration updated"))
  #expect(port.stdout.contains("next starts"))
  #expect(try fixture.stored()["port"] as? Int == 9443)
  #expect(try fixture.stored()["bind_address"] as? String == "192.168.1.20")

  let human = try await runMacus(["--state-dir", state, "server", "config", "show"])
  #expect(human.stdout.contains("192.168.1.20:9443"))
  #expect(human.stdout.contains("https://macus.example.net:8443"))
  #expect(human.stdout.contains(certificate))

  let reset = try await runMacus(["--json", "--state-dir", state, "server", "config", "reset"])
  #expect(reset.status == 0)
  #expect(try jsonObject(Data(reset.stdout.utf8))["removed"] as? Bool == true)
  #expect(!FileManager.default.fileExists(atPath: fixture.store.file.path))
  let again = try await runMacus(["--json", "--state-dir", state, "server", "config", "reset"])
  #expect(try jsonObject(Data(again.stdout.utf8))["removed"] as? Bool == false)

  try await Task.sleep(for: .milliseconds(50))
  #expect(runtime.requests().isEmpty)
  #expect(try Data(contentsOf: disk) == Data(repeating: 7, count: 4096))
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("config.json").path))
}

@Test func configurationIsValidatedAsTheServerValidatesIt() throws {
  let fixture = try ConfigFixture()
  defer { fixture.remove() }
  let url = "https://macus.example.net:8443"
  let refused: [GatewayConfiguration] = [
    GatewayConfiguration(bindAddress: "0.0.0.0"),
    GatewayConfiguration(bindAddress: "::"),
    GatewayConfiguration(bindAddress: "192.168.1.20"),
    GatewayConfiguration(bindAddress: "localhost"),
    GatewayConfiguration(bindAddress: "224.0.0.1"),
    GatewayConfiguration(bindAddress: "255.255.255.255"),
    GatewayConfiguration(bindAddress: "ff02::1", advertisedURL: url),
    GatewayConfiguration(port: 0),
    GatewayConfiguration(port: 65_536),
    GatewayConfiguration(advertisedURL: "http://127.0.0.1:8443"),
    GatewayConfiguration(advertisedURL: "https://127.0.0.1:8443/macus"),
    GatewayConfiguration(advertisedURL: "https://127.0.0.1:8443/"),
    GatewayConfiguration(advertisedURL: "https://me@127.0.0.1:8443"),
    GatewayConfiguration(advertisedURL: "https://127.0.0.1:8443?x=1"),
    GatewayConfiguration(advertisedURL: "https://0.0.0.0:8443"),
    GatewayConfiguration(advertisedURL: "https://bad_host:8443"),
    GatewayConfiguration(bindAddress: "192.168.1.20", advertisedURL: "https://localhost:8443"),
    GatewayConfiguration(bindAddress: "192.168.1.20", advertisedURL: "https://127.0.0.1:8443"),
    GatewayConfiguration(certificateFile: "relative.pem", keyFile: "/k.pem"),
    GatewayConfiguration(certificateFile: "/c.pem"),
  ]
  for configuration in refused {
    #expect(throws: RuntimeError.self, "\(configuration)") { try configuration.validate() }
  }
  for configuration in [
    GatewayConfiguration(),
    GatewayConfiguration(bindAddress: "::1", port: 9443),
    GatewayConfiguration(bindAddress: "127.0.0.2", advertisedURL: "https://localhost:8443"),
    GatewayConfiguration(bindAddress: "192.168.1.20", advertisedURL: url),
    GatewayConfiguration(bindAddress: "10.0.0.5", advertisedURL: "https://macmini"),
    GatewayConfiguration(bindAddress: "fd00::5", advertisedURL: "https://[fd00::5]:8443"),
  ] {
    #expect(throws: Never.self, "\(configuration)") { try configuration.validate() }
  }
  #expect(GatewayConfiguration(bindAddress: "::1").effectiveURL == "https://[::1]:8443")

  // A refused change leaves the stored configuration as it was.
  let certificate = try fixture.identityFile("c.pem", mode: 0o644)
  let key = try fixture.identityFile("k.pem", mode: 0o600)
  _ = try fixture.store.update {
    $0.bindAddress = "192.168.1.20"
    $0.advertisedURL = url
    $0.certificateFile = certificate
    $0.keyFile = key
  }
  let before = try Data(contentsOf: fixture.store.file)
  #expect(throws: RuntimeError.self) { try fixture.store.update { $0.bindAddress = "0.0.0.0" } }
  #expect(throws: RuntimeError.self) {
    try fixture.store.update { $0.advertisedURL = "https://localhost:8443" }
  }
  #expect(try Data(contentsOf: fixture.store.file) == before)
}

@Test func operatorIdentityFilesMustBeThisUsersPrivateFiles() throws {
  let fixture = try ConfigFixture()
  defer { fixture.remove() }
  let url = "https://macus.example.net:8443"
  let certificate = try fixture.identityFile("c.pem", mode: 0o644)
  let readableKey = try fixture.identityFile("readable.key", mode: 0o640)
  let writableCertificate = try fixture.identityFile("writable.pem", mode: 0o666)
  let key = try fixture.identityFile("k.pem", mode: 0o600)
  let link = fixture.certs.appendingPathComponent("link.key").path
  #expect(symlink(key, link) == 0)
  let missing = fixture.certs.appendingPathComponent("missing.pem").path

  for (cert, keyFile) in [
    (missing, key), (certificate, readableKey), (writableCertificate, key), (certificate, link),
  ] {
    #expect(throws: RuntimeError.self, "\(cert) \(keyFile)") {
      try fixture.store.update {
        $0.bindAddress = "192.168.1.20"
        $0.advertisedURL = url
        $0.certificateFile = cert
        $0.keyFile = keyFile
      }
    }
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.store.file.path))
}

@Test func unsafeOrInvalidConfigurationFilesArePreservedAndRefused() throws {
  let fixture = try ConfigFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(
    at: fixture.gatewayDirectory, withIntermediateDirectories: false)
  _ = chmod(fixture.gatewayDirectory.path, 0o700)
  for (contents, fileMode) in [
    (#"{"schema_version": 1}"#, mode_t(0o644)),
    (#"{"schema_version": 1, "listen": "0.0.0.0:8443"}"#, 0o600),
    (#"{"schema_version": 2}"#, 0o600),
    (#"{"schema_version": 1, "port": "8443"}"#, 0o600),
    (#"{"schema_version": 1, "bind_address": "0.0.0.0"}"#, 0o600),
    ("{", 0o600),
  ] {
    try Data(contents.utf8).write(to: fixture.store.file)
    _ = chmod(fixture.store.file.path, fileMode)
    #expect(throws: RuntimeError.self, "\(contents)") { try fixture.store.show() }
    #expect(throws: RuntimeError.self, "\(contents)") {
      try fixture.store.update { $0.port = 9443 }
    }
    #expect(throws: RuntimeError.self, "\(contents)") { try fixture.store.reset() }
    #expect(try String(contentsOf: fixture.store.file, encoding: .utf8) == contents)
  }
}

@Test func configGrammarFailsBeforeAnyState() async throws {
  let fixture = try ConfigFixture()
  defer { fixture.remove() }
  let state = fixture.state.path
  let rejected: [[String]] = [
    ["server", "config", "set"],
    ["server", "config", "set", "--port", "0"],
    ["server", "config", "set", "--port", "70000"],
    ["server", "config", "set", "--port", "84a3"],
    ["server", "config", "set", "--certificate-file", "/c.pem"],
    ["server", "config", "set", "--key-file", "/k.pem"],
    ["server", "config", "set", "--certificate-file", "c.pem", "--key-file", "/k.pem"],
    ["server", "config", "set", "--port", "1", "--port", "2"],
    ["server", "config", "show", "--port", "9443"],
    ["server", "token", "list", "--bind-address", "127.0.0.1"],
    ["--timeout", "5", "server", "config", "show"],
    ["server", "config"],
  ]
  for arguments in rejected {
    let result = try await runMacus(["--state-dir", state] + arguments)
    #expect(result.status == 2, "\(arguments)")
    #expect(result.stdout.isEmpty)
  }
  let invalid = try await runMacus([
    "--state-dir", state, "server", "config", "set", "--bind-address", "0.0.0.0",
  ])
  #expect(invalid.status == 1)
  #expect(invalid.stderr.contains("never binds every interface"))
  #expect(!FileManager.default.fileExists(atPath: fixture.gatewayDirectory.path))

  let missing = try await runMacus([
    "--state-dir", fixture.state.appendingPathComponent("absent").path, "server", "config",
    "set", "--port", "9443",
  ])
  #expect(missing.status == 1)
  #expect(
    !FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("absent").path))

  let help = try await runMacus(["--help"])
  for text in [
    "server config show", "server config set", "--advertised-url", "server config reset",
  ] {
    #expect(help.stdout.contains(text))
  }
}

@Test func localCredentialIsPreparedOnceAndRotatedAfterRevocation() throws {
  let fixture = try ConfigFixture()
  defer { fixture.remove() }
  let store = fixture.tokens
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let other = fixture.certs.appendingPathComponent("laptop.token")
  _ = try store.issue(principal: "laptop", scopes: ["incus.read"], expiresAt: nil, output: other)

  #expect(try store.prepareLocalCredential(now: now) == true)
  #expect(mode(store.localCredentialFile) == 0o600)
  let first = try String(contentsOf: store.localCredentialFile, encoding: .utf8)
  let parts = first.trimmingCharacters(in: .newlines).split(separator: ".").map(String.init)
  #expect(parts.count == 3 && parts[0] == "macus" && parts[2].count == 43)
  let local = try #require(try store.list().first { $0.id == parts[1] })
  #expect(local.principal == BearerTokenStore.localPrincipal)
  #expect(local.scopes == ["runtime.read", "runtime.write", "runtime.delete"])
  #expect(local.expiresAt == nil && local.revokedAt == nil)
  let records =
    try JSONSerialization.jsonObject(with: Data(contentsOf: store.file))
    as! [String: Any]
  let record = (records["tokens"] as! [[String: Any]]).first { $0["id"] as? String == parts[1] }
  #expect(record?["verifier"] as? String == BearerTokenStore.verifier(parts[2]))

  // A valid credential is kept unchanged.
  let storeBefore = try Data(contentsOf: store.file)
  #expect(try store.prepareLocalCredential(now: now) == false)
  #expect(try String(contentsOf: store.localCredentialFile, encoding: .utf8) == first)
  #expect(try Data(contentsOf: store.file) == storeBefore)

  // Revoking it rotates it at the next preparation.
  _ = try store.revoke(id: parts[1])
  #expect(try store.prepareLocalCredential(now: now) == true)
  let second = try String(contentsOf: store.localCredentialFile, encoding: .utf8)
  #expect(second != first)

  // A lost token file revokes the orphaned record and issues a new one.
  unlink(store.localCredentialFile.path)
  #expect(try store.prepareLocalCredential(now: now) == true)
  let tokens = try store.list()
  let active = tokens.filter {
    $0.principal == BearerTokenStore.localPrincipal && $0.revokedAt == nil
  }
  #expect(active.count == 1)
  #expect(tokens.filter { $0.principal == BearerTokenStore.localPrincipal }.count == 3)
  #expect(tokens.first { $0.principal == "laptop" }?.revokedAt == nil)

  // Owners cannot issue the reserved principal.
  #expect(throws: RuntimeError.self) {
    try store.issue(
      principal: BearerTokenStore.localPrincipal, scopes: ["runtime.read"], expiresAt: nil,
      output: fixture.certs.appendingPathComponent("reserved.token"))
  }
}

@Test func documentedConfigCommandWritesTheDocumentedFile() async throws {
  let fixture = try ConfigFixture()
  defer { fixture.remove() }
  let page = try String(
    contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../docs/server.md").standardizedFileURL, encoding: .utf8)
  let blocks = page.components(separatedBy: "```").enumerated().filter { $0.offset % 2 == 1 }
    .map(\.element)
  let command = try #require(blocks.first { $0.contains("server config set") })
  let expected = try #require(blocks.first { $0.hasPrefix("json\n") })

  // The documented arguments, with the operator files moved into the fixture.
  let documentedCertificate = "/Users/me/certs/macus.example.net.pem"
  let documentedKey = "/Users/me/certs/macus.example.net.key"
  let certificate = try fixture.identityFile("macus.example.net.pem", mode: 0o644)
  let key = try fixture.identityFile("macus.example.net.key", mode: 0o600)
  let arguments = command.dropFirst("bash\n".count)
    .replacingOccurrences(of: "\\\n", with: " ")
    .split(whereSeparator: \.isWhitespace).map(String.init)
    .map { $0 == documentedCertificate ? certificate : $0 == documentedKey ? key : $0 }
  #expect(arguments.prefix(4) == ["macus", "server", "config", "set"])

  let result = try await runMacus(["--state-dir", fixture.state.path] + arguments.dropFirst())
  #expect(result.status == 0, "\(result.stderr)")
  let written = try fixture.stored()
  var documented =
    try JSONSerialization.jsonObject(with: Data(expected.dropFirst("json\n".count).utf8))
    as! [String: Any]
  documented["certificate_file"] = certificate
  documented["key_file"] = key
  #expect(NSDictionary(dictionary: written).isEqual(to: documented))
}
