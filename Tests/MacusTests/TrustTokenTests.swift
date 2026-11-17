import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Macus

/// A self-signed P-256 certificate valid until 2126, standing in for the gateway certificate.
private let gatewayPEM = """
  -----BEGIN CERTIFICATE-----
  MIIBlzCCAT2gAwIBAgIUfJgy2Vl3NNQ6AHoLHshB3Biq7fcwCgYIKoZIzj0EAwIw
  IDEeMBwGA1UEAwwVbWFjdXMtZ2F0ZXdheS1maXh0dXJlMCAXDTI2MTExNzExMTkz
  OFoYDzIxMjYxMDI0MTExOTM4WjAgMR4wHAYDVQQDDBVtYWN1cy1nYXRld2F5LWZp
  eHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ7i79aCK0hKNFliFUO/7WJ
  DnQJoNrMEG9omLUi9f+iCE2XF9brLHq9RuiEJWAQX47hkRs4PjRnXI9dOY3wgY9N
  o1MwUTAdBgNVHQ4EFgQUn9tujB4Tat58q5JMhltMa7WJpWYwHwYDVR0jBBgwFoAU
  n9tujB4Tat58q5JMhltMa7WJpWYwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQD
  AgNIADBFAiEAz2E7f5uglsCRoCFgT75xQNJ2XRLrrKOiy/h6mb+UBfQCIFcXSrmW
  gorELxn9Bq7hRcATsNfFyjEdyUloYutLT9ou
  -----END CERTIFICATE-----

  """
/// `openssl x509 -outform DER | shasum -a 256` of `gatewayPEM`.
private let gatewayFingerprint = "d2fef8cb2ac29c64cd990839b059f072fd00e8dba2a16c34151624e7a1738f61"

private struct TrustFixture {
  let root: URL
  let state: URL
  let outputs: URL
  let certificate: URL
  var store: TrustTokenStore { TrustTokenStore(stateDirectory: state) }
  var gatewayDirectory: URL { state.appendingPathComponent("server", isDirectory: true) }

  init() throws {
    root = URL(fileURLWithPath: "/private/tmp/macus-trust-\(UUID().uuidString.prefix(8))")
    state = root.appendingPathComponent("state", isDirectory: true)
    outputs = root.appendingPathComponent("out", isDirectory: true)
    for directory in [root, state, outputs] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard chmod(directory.path, 0o700) == 0 else { throw RuntimeError(.io, "chmod failed") }
    }
    certificate = outputs.appendingPathComponent("gateway.crt")
    try Data(gatewayPEM.utf8).write(to: certificate)
    _ = chmod(certificate.path, 0o644)
  }

  func output(_ name: String) -> URL { outputs.appendingPathComponent(name) }
  func remove() { try? FileManager.default.removeItem(at: root) }

  func records() throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file))
    return (object as! [String: Any])["tokens"] as! [[String: Any]]
  }

  /// Writes a redemption record as the Macus server does (`Macus.Proxy.Enrollment`).
  func redeem(_ id: String, fingerprint: String) throws {
    let object: [String: Any] = [
      "schema_version": 1,
      "redemptions": [
        ["id": id, "redeemed_at": "2026-11-17T10:00:00Z", "fingerprint": fingerprint]
      ],
    ]
    try JSONSerialization.data(withJSONObject: object).write(to: store.redemptionFile)
    _ = chmod(store.redemptionFile.path, 0o600)
  }

  func issue(
    _ name: String = "laptop", addresses: [String] = ["macus.example.net:8443"],
    lifetime: TimeInterval = 3_600, output: String = "laptop.trust-token", now: Date = Date()
  ) throws -> TrustTokenSummary {
    try store.issue(
      name: name, addresses: addresses, serverCertificate: certificate,
      expiresAt: now.addingTimeInterval(lifetime), output: self.output(output), now: now)
  }
}

private func nativeToken(at url: URL) throws -> [String: Any] {
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.hasSuffix("\n"))
  let data = try #require(Data(base64Encoded: text.trimmingCharacters(in: .newlines)))
  return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func fileMode(_ url: URL) -> mode_t {
  var info = stat()
  _ = lstat(url.path, &info)
  return info.st_mode & 0o777
}

private func hex256(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test func trustTokenIssuanceWritesANativeTokenAndStoresOnlyItsVerifier() throws {
  let fixture = try TrustFixture()
  defer { fixture.remove() }
  let now = Date(timeIntervalSince1970: 1_800_000_000.5)
  let output = fixture.output("laptop.trust-token")

  let summary = try fixture.issue(
    addresses: ["macus.example.net:8443", "[2001:db8::7]:8443"], lifetime: 7_200, now: now)

  // The exact shape `incus remote add NAME TOKEN` decodes (api.CertificateAddToken).
  let token = try nativeToken(at: output)
  #expect(Set(token.keys) == ["client_name", "fingerprint", "addresses", "secret", "expires_at"])
  #expect(token["client_name"] as? String == "laptop")
  #expect(token["fingerprint"] as? String == gatewayFingerprint)
  #expect(token["addresses"] as? [String] == ["macus.example.net:8443", "[2001:db8::7]:8443"])
  #expect(token["expires_at"] as? String == "2027-01-15T10:00:00Z")
  let secret = try #require(token["secret"] as? String)
  #expect(secret.count == 64 && GatewayDocument.isHex64(secret))
  #expect(fileMode(output) == 0o600)

  let records = try fixture.records()
  #expect(records.count == 1)
  #expect(records[0]["id"] as? String == summary.id)
  #expect(records[0]["verifier"] as? String == hex256(secret))
  #expect(records[0]["name"] as? String == "laptop")
  #expect(records[0]["created_at"] as? String == "2027-01-15T08:00:00Z")
  #expect(records[0]["expires_at"] as? String == "2027-01-15T10:00:00Z")
  #expect(records[0]["revoked_at"] is NSNull)
  #expect(fileMode(fixture.store.file) == 0o600)
  #expect(fileMode(fixture.gatewayDirectory) == 0o700)
  let stored = try String(contentsOf: fixture.store.file, encoding: .utf8)
  #expect(!stored.contains(secret))
  #expect(summary.redeemedAt == nil && summary.revokedAt == nil)
  // Issuance never writes gateway trust or redemptions.
  #expect(!FileManager.default.fileExists(atPath: fixture.store.redemptionFile.path))
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.gatewayDirectory.appendingPathComponent("trusted-certificates.json").path))
}

@Test func trustTokenRefusalsWriteNothing() throws {
  let fixture = try TrustFixture()
  defer { fixture.remove() }
  let manyAddresses = (1...9).map { "host\($0).example.net:8443" }
  let attempts: [() throws -> TrustTokenSummary] = [
    { try fixture.issue("") },
    { try fixture.issue("-laptop") },
    { try fixture.issue("lap top") },
    { try fixture.issue(addresses: []) },
    { try fixture.issue(addresses: manyAddresses) },
    { try fixture.issue(addresses: ["a.example.net:8443", "a.example.net:8443"]) },
    { try fixture.issue(addresses: ["https://macus.example.net:8443"]) },
    { try fixture.issue(addresses: ["macus.example.net"]) },
    { try fixture.issue(addresses: ["macus.example.net:0"]) },
    { try fixture.issue(addresses: ["macus.example.net:65536"]) },
    { try fixture.issue(addresses: ["2001:db8::7:8443x"]) },
    { try fixture.issue(addresses: ["[zz::1]:8443"]) },
    { try fixture.issue(addresses: ["macus example:8443"]) },
    { try fixture.issue(lifetime: 59) },
    { try fixture.issue(lifetime: 30 * 86_400 + 1) },
    { try fixture.issue(lifetime: -60) },
  ]
  for attempt in attempts {
    #expect(throws: RuntimeError.self) { _ = try attempt() }
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.gatewayDirectory.path))
  #expect(!FileManager.default.fileExists(atPath: fixture.output("laptop.trust-token").path))
  #expect(GatewayDocument.date(nil) == nil)
  #expect(TrustTokenStore.isAddress("127.0.0.1:8443"))
  #expect(TrustTokenStore.isAddress("[::1]:8443"))
}

@Test func trustTokenIssuanceRequiresTheGatewayCertificate() throws {
  let fixture = try TrustFixture()
  defer { fixture.remove() }
  let certificate = fixture.certificate

  func refused(_ contents: String, mode: mode_t = 0o644) throws {
    try? FileManager.default.removeItem(at: certificate)
    try Data(contents.utf8).write(to: certificate)
    _ = chmod(certificate.path, mode)
    #expect(throws: RuntimeError.self) { _ = try fixture.issue() }
  }

  try refused("not a certificate")
  try refused(gatewayPEM + gatewayPEM)
  try refused(gatewayPEM.replacingOccurrences(of: "MIIBlzCC", with: "MIIBlzCD"))
  try refused(gatewayPEM, mode: 0o666)

  try? FileManager.default.removeItem(at: certificate)
  let real = fixture.output("real.crt")
  try Data(gatewayPEM.utf8).write(to: real)
  try FileManager.default.createSymbolicLink(at: certificate, withDestinationURL: real)
  #expect(throws: RuntimeError.self) { _ = try fixture.issue() }

  try FileManager.default.removeItem(at: certificate)
  #expect(throws: RuntimeError.self) { _ = try fixture.issue() }
  #expect(!FileManager.default.fileExists(atPath: fixture.gatewayDirectory.path))

  try Data(gatewayPEM.utf8).write(to: certificate)
  _ = chmod(certificate.path, 0o644)
  #expect(try TrustTokenStore.certificateFingerprint(certificate) == gatewayFingerprint)
}

@Test func trustTokensListRedemptionsAndRevokeWithoutTouchingOtherRecords() throws {
  let fixture = try TrustFixture()
  defer { fixture.remove() }
  #expect(try fixture.store.list().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: fixture.gatewayDirectory.path))

  let laptop = try fixture.issue("laptop", output: "laptop")
  let phone = try fixture.issue("phone", output: "phone")
  #expect(throws: RuntimeError.self) { _ = try fixture.issue("again", output: "phone") }

  // Unknown fields survive revocation.
  var records = try fixture.records()
  records[1]["note"] = "kept"
  try JSONSerialization.data(withJSONObject: ["schema_version": 1, "tokens": records])
    .write(to: fixture.store.file)
  try fixture.redeem(laptop.id, fingerprint: String(repeating: "b", count: 64))

  let listed = try fixture.store.list()
  #expect(listed.map(\.id) == [laptop.id, phone.id])
  #expect(listed[0].redeemedAt == "2026-11-17T10:00:00Z")
  #expect(listed[0].redeemedBy == String(repeating: "b", count: 64))
  #expect(listed[1].redeemedAt == nil)

  let revoked = try fixture.store.revoke(id: phone.id)
  #expect(!revoked.alreadyRevoked)
  let first = try #require(revoked.record.revokedAt)
  let again = try fixture.store.revoke(id: phone.id, now: Date().addingTimeInterval(60))
  #expect(again.alreadyRevoked && again.record.revokedAt == first)
  let redeemed = try fixture.store.revoke(id: laptop.id)
  #expect(redeemed.record.redeemedAt != nil)

  records = try fixture.records()
  #expect(records[1]["note"] as? String == "kept")
  #expect(records[1]["revoked_at"] as? String == first)
  #expect(throws: RuntimeError.self) { _ = try fixture.store.revoke(id: "ffffffffffffffff") }
  #expect(throws: RuntimeError.self) { _ = try fixture.store.revoke(id: "nope") }
}

@Test func unsafeOrRestrictedTrustTokenStoresArePreservedAndRefused() throws {
  let fixture = try TrustFixture()
  defer { fixture.remove() }
  let issued = try fixture.issue(output: "first")
  var records = try fixture.records()

  for (key, value) in [("restricted", true as Any), ("projects", ["default"] as Any)] {
    var changed = records
    changed[0][key] = value
    let bytes = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "tokens": changed])
    try bytes.write(to: fixture.store.file)
    #expect(throws: RuntimeError.self) { _ = try fixture.store.list() }
    #expect(throws: RuntimeError.self) { _ = try fixture.issue(output: "\(key)") }
    #expect(throws: RuntimeError.self) { _ = try fixture.store.revoke(id: issued.id) }
    #expect(try Data(contentsOf: fixture.store.file) == bytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.output(key).path))
  }

  records[0]["restricted"] = false
  records[0]["projects"] = [String]()
  try JSONSerialization.data(withJSONObject: ["schema_version": 1, "tokens": records])
    .write(to: fixture.store.file)
  _ = chmod(fixture.store.file.path, 0o644)
  #expect(throws: RuntimeError.self) { _ = try fixture.store.list() }
  _ = chmod(fixture.store.file.path, 0o600)
  #expect(try fixture.store.list().count == 1)

  try Data("{\"schema_version\":1,\"redemptions\":[{\"id\":\"bad\"}]}".utf8)
    .write(to: fixture.store.redemptionFile)
  _ = chmod(fixture.store.redemptionFile.path, 0o600)
  #expect(throws: RuntimeError.self) { _ = try fixture.store.list() }
}

@Test func serverTrustTokenCommandsNeverPrintTokens() async throws {
  let fixture = try TrustFixture()
  defer { fixture.remove() }
  let state = fixture.state.path
  let certificate = fixture.certificate.path

  let human = try await runMacus([
    "--state-dir", state, "server", "trust", "token", "issue", "--name", "laptop",
    "--address", "macus.example.net:8443", "--server-certificate", certificate,
    "--output", fixture.output("human").path,
  ])
  #expect(human.status == 0, "\(human.stderr)")
  let humanToken = try nativeToken(at: fixture.output("human"))
  let humanRecord = try fixture.records()[0]
  let humanID = try #require(humanRecord["id"] as? String)
  #expect(human.stdout.contains("Trust token issued"))
  #expect(human.stdout.contains("server trust token revoke \(humanID)"))
  #expect(human.stdout.contains("incus remote add"))
  // The default lifetime is one hour.
  let created = try #require(GatewayDocument.date(humanRecord["created_at"]))
  let expires = try #require(GatewayDocument.date(humanRecord["expires_at"]))
  #expect(expires.timeIntervalSince(created) == 3_600)

  let json = try await runMacus([
    "--json", "--state-dir", state, "server", "trust", "token", "issue", "--name", "phone",
    "--address", "macus.example.net:8443", "--address", "203.0.113.7:8443",
    "--server-certificate", certificate, "--expires-in", "30d",
    "--output", fixture.output("json").path,
  ])
  #expect(json.status == 0, "\(json.stderr)")
  let jsonToken = try nativeToken(at: fixture.output("json"))
  let issued = try jsonObject(Data(json.stdout.utf8))["trust_token"] as! [String: Any]
  #expect(issued["name"] as? String == "phone")
  #expect(issued["addresses"] as? [String] == ["macus.example.net:8443", "203.0.113.7:8443"])
  #expect(issued["output"] as? String == fixture.output("json").path)
  #expect(issued["verifier"] == nil && issued["secret"] == nil)

  let tooLong = try await runMacus([
    "--state-dir", state, "server", "trust", "token", "issue", "--name", "tablet",
    "--address", "macus.example.net:8443", "--server-certificate", certificate,
    "--expires-in", "31d", "--output", fixture.output("long").path,
  ])
  #expect(tooLong.status != 0)
  #expect(!FileManager.default.fileExists(atPath: fixture.output("long").path))

  let list = try await runMacus([
    "--json", "--state-dir", state, "server", "trust", "token", "list",
  ])
  #expect(list.status == 0)
  let tokens = try jsonObject(Data(list.stdout.utf8))["trust_tokens"] as! [[String: Any]]
  #expect(tokens.map { $0["name"] as? String } == ["laptop", "phone"])
  #expect(tokens.allSatisfy { $0["verifier"] == nil })

  try fixture.redeem(humanID, fingerprint: String(repeating: "c", count: 64))
  let humanList = try await runMacus(["--state-dir", state, "server", "trust", "token", "list"])
  #expect(humanList.stdout.contains("Redeemed 2026-11-17T10:00:00Z"))
  #expect(humanList.stdout.contains("Active until"))

  let revoke = try await runMacus([
    "--json", "--state-dir", state, "server", "trust", "token", "revoke",
    try #require(issued["id"] as? String),
  ])
  #expect(revoke.status == 0)
  #expect(try jsonObject(Data(revoke.stdout.utf8))["already_revoked"] as? Bool == false)
  let revokedList = try await runMacus(["--state-dir", state, "server", "trust", "token", "list"])
  #expect(revokedList.stdout.contains("Revoked"))

  for result in [human, json, tooLong, list, humanList, revoke, revokedList] {
    for token in [humanToken, jsonToken] {
      let secret = token["secret"] as! String
      #expect(!result.stdout.contains(secret) && !result.stderr.contains(secret))
      #expect(!result.stdout.contains(hex256(secret)))
    }
    let raw = try String(contentsOf: fixture.output("human"), encoding: .utf8)
    #expect(!result.stdout.contains(raw.trimmingCharacters(in: .newlines)))
  }
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.gatewayDirectory.appendingPathComponent("trusted-certificates.json").path))
}

@Test func serverTrustTokenGrammarFailsBeforeAnyState() async throws {
  let fixture = try TrustFixture()
  defer { fixture.remove() }
  let state = fixture.state.path
  let output = fixture.output("t").path
  let cert = fixture.certificate.path
  let base = ["server", "trust", "token", "issue"]
  let rejected: [[String]] = [
    base + ["--address", "a.example:1", "--server-certificate", cert, "--output", output],
    base + ["--name", "a", "--server-certificate", cert, "--output", output],
    base + ["--name", "a", "--address", "a.example:1", "--output", output],
    base + ["--name", "a", "--address", "a.example:1", "--server-certificate", cert],
    base + [
      "--name", "a", "--address", "a.example:1", "--server-certificate", "rel", "--output", output,
    ],
    base + [
      "--name", "a", "--name", "b", "--address", "a.example:1", "--server-certificate", cert,
      "--output", output,
    ],
    base + [
      "--name", "a", "--address", "a.example:1", "--server-certificate", cert, "--output", output,
      "--scope", "incus.read",
    ],
    ["server", "token", "issue", "--principal", "a", "--scope", "incus.read", "--name", "a"],
    ["server", "trust", "token", "list", "--name", "a"],
    ["--timeout", "5", "server", "trust", "token", "list"],
    ["server", "trust", "token", "revoke"],
    ["server", "trust", "token"],
    ["server", "trust"],
    ["runtime", "status", "--address", "a.example:1"],
  ]
  for arguments in rejected {
    let result = try await runMacus(["--state-dir", state] + arguments)
    #expect(result.status == 2, "\(arguments)")
    #expect(result.stdout.isEmpty)
  }
  #expect(!FileManager.default.fileExists(atPath: output))
  #expect(!FileManager.default.fileExists(atPath: fixture.gatewayDirectory.path))

  let help = try await runMacus(["--help"])
  for text in ["server trust token issue", "--address", "--server-certificate", "--name"] {
    #expect(help.stdout.contains(text))
  }
}

@Test func nativeTokenEncodingMatchesTheServerDecoder() throws {
  // server/test/macus/proxy/enrollment_test.exs decodes the same fields.
  let token = try TrustTokenStore.nativeToken(
    name: "user@host", fingerprint: gatewayFingerprint, addresses: ["10.98.30.229:8443"],
    secret: String(repeating: "ab", count: 32), expiresAt: "2026-11-17T12:00:00Z")
  let object =
    try JSONSerialization.jsonObject(with: try #require(Data(base64Encoded: token)))
    as! [String: Any]
  #expect(object["client_name"] as? String == "user@host")
  #expect(object["fingerprint"] as? String == gatewayFingerprint)
  #expect(object["addresses"] as? [String] == ["10.98.30.229:8443"])
  #expect(object["secret"] as? String == String(repeating: "ab", count: 32))
  #expect(object["expires_at"] as? String == "2026-11-17T12:00:00Z")
  #expect(!token.contains("\n") && !token.contains("-") && !token.contains("_"))
}
