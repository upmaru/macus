import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Macus

/// A private state directory (0700, under /private/tmp) and a private output directory.
private struct AdminFixture {
  let state: URL
  let outputs: URL
  var store: BearerTokenStore { BearerTokenStore(stateDirectory: state) }
  var storeFile: URL { store.file }

  init() throws {
    let root = URL(fileURLWithPath: "/private/tmp/macus-admin-\(UUID().uuidString.prefix(8))")
    state = root.appendingPathComponent("state", isDirectory: true)
    outputs = root.appendingPathComponent("out", isDirectory: true)
    for directory in [root, state, outputs] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard chmod(directory.path, 0o700) == 0 else { throw RuntimeError(.io, "chmod failed") }
    }
  }

  func output(_ name: String) -> URL { outputs.appendingPathComponent(name) }

  func remove() {
    try? FileManager.default.removeItem(at: state.deletingLastPathComponent())
  }

  func document() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as! [String: Any]
  }

  func records() throws -> [[String: Any]] { try document()["tokens"] as! [[String: Any]] }

  func writeStore(_ object: Any, mode: mode_t = 0o600) throws {
    try FileManager.default.createDirectory(
      at: store.gatewayDirectory, withIntermediateDirectories: true)
    _ = chmod(store.gatewayDirectory.path, 0o700)
    try JSONSerialization.data(withJSONObject: object).write(to: storeFile)
    _ = chmod(storeFile.path, mode)
  }
}

private func mode(_ url: URL) -> mode_t {
  var info = stat()
  _ = lstat(url.path, &info)
  return info.st_mode & 0o777
}

private func token(at url: URL) throws -> (id: String, secret: String) {
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.hasSuffix("\n"))
  let parts = text.trimmingCharacters(in: .newlines).split(separator: ".").map(String.init)
  #expect(parts.count == 3 && parts[0] == "macus")
  return (parts[1], parts[2])
}

private func sha256(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func validRecord(id: String, extra: [String: Any] = [:]) -> [String: Any] {
  [
    "id": id, "verifier": String(repeating: "a", count: 64), "principal": "other",
    "scopes": ["runtime.read"], "created_at": "2026-01-01T00:00:00Z", "expires_at": NSNull(),
    "revoked_at": NSNull(),
  ].merging(extra) { _, new in new }
}

@Test func issuanceWritesOnlyTheTokenToANewPrivateFileAndStoresItsVerifier() throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  let now = Date(timeIntervalSince1970: 1_800_000_000.75)
  let output = fixture.output("laptop.token")

  let summary = try fixture.store.issue(
    principal: "laptop", scopes: ["incus.read", "runtime.write"],
    expiresAt: now.addingTimeInterval(3_600), output: output, now: now)

  let (id, secret) = try token(at: output)
  #expect(id == summary.id && id.count == 16)
  #expect(secret.count == 43)
  #expect(secret.utf8.allSatisfy { $0 == 45 || $0 == 95 || isalnum(Int32($0)) != 0 })
  #expect(mode(output) == 0o600)
  #expect(mode(fixture.store.gatewayDirectory) == 0o700)
  #expect(mode(fixture.storeFile) == 0o600)

  let records = try fixture.records()
  #expect(records.count == 1)
  let record = records[0]
  #expect(record["id"] as? String == id)
  #expect(record["verifier"] as? String == sha256(secret))
  #expect(record["principal"] as? String == "laptop")
  #expect(record["scopes"] as? [String] == ["incus.read", "runtime.write"])
  #expect(record["created_at"] as? String == "2027-01-15T08:00:00Z")
  #expect(record["expires_at"] as? String == "2027-01-15T09:00:00Z")
  #expect(record["revoked_at"] is NSNull)
  #expect(try fixture.document()["schema_version"] as? Int == 1)
  let stored = try String(contentsOf: fixture.storeFile, encoding: .utf8)
  #expect(!stored.contains(secret))
}

@Test func nativeScopesAreIssuedOnlyWhenNamed() throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  let composite = try fixture.store.issue(
    principal: "agent", scopes: ["incus.read", "incus.write", "incus.exec", "incus.delete"],
    expiresAt: nil, output: fixture.output("composite"))
  #expect(!composite.scopes.contains { $0.hasPrefix("incus.native.") })
  let native = try fixture.store.issue(
    principal: "admin-agent", scopes: ["incus.read", "incus.native.read", "incus.native.admin"],
    expiresAt: nil, output: fixture.output("native"))
  #expect(native.scopes == ["incus.read", "incus.native.read", "incus.native.admin"])
  #expect(
    BearerTokenStore.scopes.filter { $0.hasPrefix("incus.native.") } == [
      "incus.native.read", "incus.native.write", "incus.native.delete", "incus.native.admin",
    ])
}

@Test func issuanceRefusesUnsupportedScopesPrincipalsAndExpiryWithoutWriting() throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  let now = Date()
  let cases: [(String, [String], Date?)] = [
    ("laptop", ["incus.native.instances.write"], nil),
    ("laptop", ["incus.read", "incus.native"], nil),
    ("laptop", ["admin"], nil),
    ("laptop", ["incus.read", "incus.read"], nil),
    ("laptop", [], nil),
    ("", ["incus.read"], nil),
    ("has space", ["incus.read"], nil),
    ("-leading", ["incus.read"], nil),
    ("laptop", ["incus.read"], now.addingTimeInterval(-1)),
  ]
  for (principal, scopes, expiry) in cases {
    #expect(throws: RuntimeError.self) {
      try fixture.store.issue(
        principal: principal, scopes: scopes, expiresAt: expiry, output: fixture.output("t"),
        now: now)
    }
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.output("t").path))
  #expect(!FileManager.default.fileExists(atPath: fixture.store.gatewayDirectory.path))
}

@Test func issuanceNeverReplacesAFileOrWritesToAnUnsafeDirectory() throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  let existing = fixture.output("existing")
  try Data("keep me\n".utf8).write(to: existing)

  #expect(throws: RuntimeError.self) {
    try fixture.store.issue(
      principal: "laptop", scopes: ["incus.read"], expiresAt: nil, output: existing)
  }
  #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me\n")

  // A symbolic link at the destination is not followed.
  let target = fixture.output("target")
  try Data("target\n".utf8).write(to: target)
  let link = fixture.output("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  #expect(throws: RuntimeError.self) {
    try fixture.store.issue(
      principal: "laptop", scopes: ["incus.read"], expiresAt: nil, output: link)
  }
  #expect(try String(contentsOf: target, encoding: .utf8) == "target\n")

  // Group-writable and missing destination directories are refused.
  let shared = fixture.outputs.appendingPathComponent("shared", isDirectory: true)
  try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
  _ = chmod(shared.path, 0o770)
  for output in [
    shared.appendingPathComponent("t"), fixture.outputs.appendingPathComponent("missing/t"),
  ] {
    #expect(throws: RuntimeError.self) {
      try fixture.store.issue(
        principal: "laptop", scopes: ["incus.read"], expiresAt: nil, output: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }
  #expect((try? fixture.records()) == nil)
}

@Test func issuanceAndRevocationPreserveOtherRecordsAndUnknownFields() throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  let other = validRecord(id: "0123456789abcdef", extra: ["note": "kept"])
  try fixture.writeStore(["schema_version": 1, "tokens": [other], "comment": "top-level kept"])

  let issued = try fixture.store.issue(
    principal: "laptop", scopes: ["incus.read"], expiresAt: nil, output: fixture.output("t"))
  var document = try fixture.document()
  #expect(document["comment"] as? String == "top-level kept")
  var records = document["tokens"] as! [[String: Any]]
  #expect(records.count == 2)
  #expect(NSDictionary(dictionary: records[0]).isEqual(to: other))

  let now = Date(timeIntervalSince1970: 1_900_000_000)
  let revoked = try fixture.store.revoke(id: issued.id, now: now)
  #expect(!revoked.alreadyRevoked)
  #expect(revoked.record.revokedAt == "2030-03-17T17:46:40Z")

  document = try fixture.document()
  records = document["tokens"] as! [[String: Any]]
  #expect(NSDictionary(dictionary: records[0]).isEqual(to: other))
  #expect(records[1]["revoked_at"] as? String == "2030-03-17T17:46:40Z")
  #expect(records[1]["verifier"] as? String == sha256(try token(at: fixture.output("t")).secret))

  // Revoking again keeps the original time.
  let again = try fixture.store.revoke(id: issued.id, now: now.addingTimeInterval(60))
  #expect(again.alreadyRevoked)
  #expect(again.record.revokedAt == "2030-03-17T17:46:40Z")

  #expect(throws: RuntimeError(.notFound, "No bearer token has ID ffffffffffffffff")) {
    try fixture.store.revoke(id: "ffffffffffffffff")
  }
  #expect(throws: RuntimeError.self) { try fixture.store.revoke(id: "../../etc") }
}

@Test func unsafeOrMalformedStoresArePreservedAndRefused() throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  let good = validRecord(id: "0123456789abcdef")
  let cases: [(Any, mode_t)] = [
    (["schema_version": 1, "tokens": [good]], 0o644),
    (["schema_version": 2, "tokens": [good]], 0o600),
    (["schema_version": 1, "tokens": [good, good]], 0o600),
    (["schema_version": 1, "tokens": [validRecord(id: "XYZ")]], 0o600),
    (
      [
        "schema_version": 1,
        "tokens": [validRecord(id: "0123456789abcdef", extra: ["expires_at": "soon"])],
      ], 0o600
    ),
    (["schema_version": 1, "tokens": [good, "not a record"]], 0o600),
  ]
  for (index, (object, fileMode)) in cases.enumerated() {
    try? FileManager.default.removeItem(at: fixture.storeFile)
    try fixture.writeStore(object, mode: fileMode)
    let before = try Data(contentsOf: fixture.storeFile)
    let output = fixture.output("t\(index)")
    #expect(throws: RuntimeError.self) {
      try fixture.store.issue(
        principal: "laptop", scopes: ["incus.read"], expiresAt: nil, output: output)
    }
    #expect(throws: RuntimeError.self) { try fixture.store.revoke(id: "0123456789abcdef") }
    #expect(throws: RuntimeError.self) { try fixture.store.list() }
    #expect(try Data(contentsOf: fixture.storeFile) == before)
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  // A symbolic link in place of the store, and a gateway directory others can read.
  try FileManager.default.removeItem(at: fixture.storeFile)
  let real = fixture.state.appendingPathComponent("real.json")
  try JSONSerialization.data(withJSONObject: ["schema_version": 1, "tokens": [good]]).write(
    to: real)
  _ = chmod(real.path, 0o600)
  try FileManager.default.createSymbolicLink(at: fixture.storeFile, withDestinationURL: real)
  #expect(throws: RuntimeError.self) { try fixture.store.list() }
  try FileManager.default.removeItem(at: fixture.storeFile)
  _ = chmod(fixture.store.gatewayDirectory.path, 0o755)
  #expect(throws: RuntimeError.self) {
    try fixture.store.issue(
      principal: "laptop", scopes: ["incus.read"], expiresAt: nil, output: fixture.output("x"))
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.storeFile.path))
}

@Test func listingCreatesNothingAndAMissingStateDirectoryIsNeverCreated() throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  #expect(try fixture.store.list().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: fixture.store.gatewayDirectory.path))

  let missing = BearerTokenStore(
    stateDirectory: fixture.state.appendingPathComponent("absent", isDirectory: true))
  #expect(throws: RuntimeError.self) { try missing.list() }
  #expect(throws: RuntimeError.self) {
    try missing.issue(
      principal: "laptop", scopes: ["incus.read"], expiresAt: nil, output: fixture.output("t"))
  }
  #expect(!FileManager.default.fileExists(atPath: missing.stateDirectory.path))
  #expect(!FileManager.default.fileExists(atPath: fixture.output("t").path))
}

@Test func concurrentIssuanceKeepsEveryRecord() async throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  let store = fixture.store
  let outputs = (0..<12).map { fixture.output("t\($0)") }
  try await withThrowingTaskGroup(of: String.self) { group in
    for output in outputs {
      group.addTask {
        try store.issue(principal: "ci", scopes: ["incus.read"], expiresAt: nil, output: output).id
      }
    }
    var ids = Set<String>()
    for try await id in group { ids.insert(id) }
    #expect(ids.count == outputs.count)
  }
  let records = try fixture.records()
  #expect(records.count == outputs.count)
  for output in outputs {
    let (id, secret) = try token(at: output)
    #expect(
      records.contains { $0["id"] as? String == id && $0["verifier"] as? String == sha256(secret) })
  }
}

@Test func serverTokenCommandsNeverPrintSecretsOrTouchTheRuntime() async throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  // A live control socket and runtime disks in the same state directory.
  let runtime = try ScriptedSocket(name: "runtime.sock", directory: fixture.state) { _, _, _ in
    mustJSON(200, statusObject(state: "ready", incus: "/tmp/incus.sock"))
  }
  defer { runtime.stop() }
  let disks = fixture.state.appendingPathComponent("runtime", isDirectory: true)
  try FileManager.default.createDirectory(at: disks, withIntermediateDirectories: false)
  let disk = disks.appendingPathComponent("root.raw")
  try Data(repeating: 7, count: 4096).write(to: disk)
  let diskBefore = try FileManager.default.attributesOfItem(atPath: disk.path)
  let state = fixture.state.path

  let human = try await runMacus([
    "--state-dir", state, "server", "token", "issue", "--principal", "laptop",
    "--scope", "incus.read", "--scope", "runtime.read", "--expires-in", "30d",
    "--output", fixture.output("human").path,
  ])
  #expect(human.status == 0)
  let humanToken = try token(at: fixture.output("human"))
  #expect(human.stdout.contains("Bearer token issued"))
  #expect(human.stdout.contains(humanToken.id))
  #expect(human.stdout.contains("server token revoke \(humanToken.id)"))

  let json = try await runMacus([
    "--json", "--state-dir", state, "server", "token", "issue", "--principal", "ci@host",
    "--scope", "incus.exec", "--output", fixture.output("json").path,
  ])
  #expect(json.status == 0)
  let jsonToken = try token(at: fixture.output("json"))
  let issued = try jsonObject(Data(json.stdout.utf8))["token"] as! [String: Any]
  #expect(issued["id"] as? String == jsonToken.id)
  #expect(issued["expires_at"] is NSNull)
  #expect(issued["output"] as? String == fixture.output("json").path)
  #expect(issued["verifier"] == nil)

  let list = try await runMacus(["--json", "--state-dir", state, "server", "token", "list"])
  #expect(list.status == 0)
  let tokens = try jsonObject(Data(list.stdout.utf8))["tokens"] as! [[String: Any]]
  #expect(tokens.map { $0["id"] as? String } == [humanToken.id, jsonToken.id])
  #expect(tokens.allSatisfy { $0["verifier"] == nil })

  let humanList = try await runMacus(["--state-dir", state, "server", "token", "list"])
  #expect(humanList.stdout.contains("Active until"))
  #expect(humanList.stdout.contains("Active, no expiry"))

  let revoke = try await runMacus([
    "--json", "--state-dir", state, "server", "token", "revoke", humanToken.id,
  ])
  #expect(revoke.status == 0)
  #expect(try jsonObject(Data(revoke.stdout.utf8))["already_revoked"] as? Bool == false)
  let revokedList = try await runMacus(["--state-dir", state, "server", "token", "list"])
  #expect(revokedList.stdout.contains("Revoked"))

  let unknown = try await runMacus([
    "--state-dir", state, "server", "token", "revoke", "ffffffffffffffff",
  ])
  #expect(unknown.status == 1)

  for result in [human, json, list, humanList, revoke, revokedList, unknown] {
    for secret in [humanToken.secret, jsonToken.secret] {
      #expect(!result.stdout.contains(secret))
      #expect(!result.stderr.contains(secret))
    }
    #expect(!result.stdout.contains(sha256(humanToken.secret)))
  }

  try await Task.sleep(for: .milliseconds(50))
  #expect(runtime.requests().isEmpty)
  #expect(try Data(contentsOf: disk) == Data(repeating: 7, count: 4096))
  let diskAfter = try FileManager.default.attributesOfItem(atPath: disk.path)
  #expect(diskAfter[.modificationDate] as? Date == diskBefore[.modificationDate] as? Date)
  #expect(
    !FileManager.default.fileExists(
      atPath: fixture.state.appendingPathComponent("config.json").path))
}

@Test func serverTokenGrammarFailsBeforeAnyState() async throws {
  let fixture = try AdminFixture()
  defer { fixture.remove() }
  let state = fixture.state.path
  let output = fixture.output("t").path
  let rejected: [[String]] = [
    ["server", "token", "issue", "--scope", "incus.read", "--output", output],
    ["server", "token", "issue", "--principal", "laptop", "--output", output],
    ["server", "token", "issue", "--principal", "laptop", "--scope", "incus.read"],
    ["server", "token", "issue", "--principal", "a", "--scope", "incus.read", "--output", "rel"],
    [
      "server", "token", "issue", "--principal", "a", "--scope", "incus.read", "--output", output,
      "--expires-in", "30",
    ],
    [
      "server", "token", "issue", "--principal", "a", "--scope", "incus.read", "--output", output,
      "--expires-in", "30s",
    ],
    [
      "server", "token", "issue", "--principal", "a", "--principal", "b", "--scope", "incus.read",
      "--output", output,
    ],
    ["--timeout", "5", "server", "token", "list"],
    ["server", "token", "list", "--scope", "incus.read"],
    ["runtime", "status", "--output", output],
    ["server", "token", "revoke"],
    ["server", "token"],
    ["server"],
  ]
  for arguments in rejected {
    let result = try await runMacus(["--state-dir", state] + arguments)
    #expect(result.status == 2, "\(arguments)")
    #expect(result.stdout.isEmpty)
  }
  #expect(!FileManager.default.fileExists(atPath: output))
  #expect(!FileManager.default.fileExists(atPath: fixture.store.gatewayDirectory.path))

  let help = try await runMacus(["--help"])
  for text in ["server token issue", "--principal", "--scope", "--output", "server token revoke"] {
    #expect(help.stdout.contains(text))
  }
  #expect(ServerAdministration.expiry("1m") == 60)
  #expect(ServerAdministration.expiry("3650d") == 3_650 * 86_400)
  #expect(ServerAdministration.expiry("3651d") == nil)
  #expect(ServerAdministration.expiry("59s") == nil)
  #expect(ServerAdministration.expiry("-1d") == nil)
}

@Test func verifiersMatchTheServerGoldenVector() {
  // The same vector is asserted by server/test/macus/auth/bearer_test.exs.
  #expect(
    BearerTokenStore.verifier("secret")
      == "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b")
}
