import CryptoKit
import Darwin
import Foundation

/// A stored bearer credential, as listed. The secret never appears here: the store keeps only its
/// SHA-256 verifier, and listing omits even that.
public struct BearerTokenSummary: Sendable, Equatable {
  public let id: String
  public let principal: String
  public let scopes: [String]
  public let createdAt: String
  public let expiresAt: String?
  public let revokedAt: String?

  var jsonObject: [String: Any] {
    [
      "id": id, "principal": principal, "scopes": scopes, "created_at": createdAt,
      "expires_at": expiresAt ?? NSNull(), "revoked_at": revokedAt ?? NSNull(),
    ]
  }
}

/// Owner-local administration of `<state-dir>/server/bearer-tokens.json`, the store the Macus
/// server verifies bearer credentials against (`Macus.Auth.Bearer`).
///
/// Tokens are `macus.<id>.<secret>`: 8 random bytes as lowercase hex and 32 random bytes as
/// unpadded base64url. Records hold the SHA-256 of the secret, never the secret. The gateway
/// directory is 0700 and the store a 0600 regular file owned by this user, below ancestors only
/// this user or root can write. Listing never creates state. Issuance and revocation hold an
/// exclusive lock, refuse a store that is unsafe, oversized or malformed (preserving it), keep
/// every other record and unknown field unchanged and replace the store atomically. Nothing
/// here touches runtime disks, Incus or services.
public struct BearerTokenStore: Sendable {
  public static let scopes = [
    "incus.read", "incus.write", "incus.exec", "incus.delete",
    "runtime.read", "runtime.write", "runtime.delete",
  ]
  static let maxBytes = 1_048_576
  static let maxTokens = 4_096
  static let schemaVersion = 1

  public let stateDirectory: URL
  public init(stateDirectory: URL) { self.stateDirectory = stateDirectory.standardizedFileURL }

  public var gatewayDirectory: URL {
    stateDirectory.appendingPathComponent("server", isDirectory: true)
  }
  public var file: URL { gatewayDirectory.appendingPathComponent("bearer-tokens.json") }
  var lockFile: URL { gatewayDirectory.appendingPathComponent("bearer-tokens.lock") }

  // MARK: Listing

  /// Lists stored records. A missing gateway directory or store lists nothing and creates nothing.
  public func list() throws -> [BearerTokenSummary] {
    try requireStateDirectory()
    switch try gatewayDirectoryState() {
    case .absent: return []
    case .present: break
    }
    guard let document = try load() else { return [] }
    return try records(document).map(Self.summary)
  }

  // MARK: Issuance

  /// Issues one credential: writes the token, and only the token, to a new 0600 file at `output`,
  /// then adds its record. If the store cannot be updated the output file is removed.
  public func issue(
    principal: String, scopes: [String], expiresAt: Date?, output: URL, now: Date = Date()
  ) throws -> BearerTokenSummary {
    guard Self.isPrincipal(principal) else {
      throw RuntimeError(
        .invalidRequest,
        "--principal must be 1-128 characters: letters, digits, '.', '_', '@' or '-', starting with a letter or digit"
      )
    }
    try Self.validateScopes(scopes)
    if let expiresAt, expiresAt <= now {
      throw RuntimeError(.invalidRequest, "The expiry must be in the future")
    }
    try Self.validateOutput(output)
    try requireStateDirectory()
    try prepareGatewayDirectory()
    return try withLock {
      var document = try load() ?? ["schema_version": Self.schemaVersion, "tokens": [Any]()]
      var tokens = try records(document)
      guard tokens.count < Self.maxTokens else {
        throw RuntimeError(
          .conflict, "The token store holds \(Self.maxTokens) records; revoke and prune first")
      }
      let ids = Set(tokens.compactMap { $0["id"] as? String })
      var id = Self.randomHex(bytes: 8)
      while ids.contains(id) { id = Self.randomHex(bytes: 8) }
      let secret = Self.randomBase64URL(bytes: 32)
      let record: [String: Any] = [
        "id": id,
        "verifier": Self.verifier(secret),
        "principal": principal,
        "scopes": scopes,
        "created_at": Self.timestamp(now),
        "expires_at": expiresAt.map(Self.timestamp) ?? NSNull(),
        "revoked_at": NSNull(),
      ]
      tokens.append(record)
      document["tokens"] = tokens
      let data = try Self.encode(document)
      try Self.writeExclusive(Data("macus.\(id).\(secret)\n".utf8), to: output)
      do {
        try replaceStore(with: data)
      } catch {
        unlink(output.path)
        throw error
      }
      return Self.summary(record)
    }
  }

  // MARK: Revocation

  /// Marks a record revoked. The server refuses it from the next request. Revoking an already
  /// revoked record keeps its original time and reports `alreadyRevoked`.
  public func revoke(id: String, now: Date = Date()) throws -> (
    record: BearerTokenSummary, alreadyRevoked: Bool
  ) {
    guard Self.isID(id) else {
      throw RuntimeError(.invalidRequest, "A token ID is 16 lowercase hexadecimal characters")
    }
    try requireStateDirectory()
    guard case .present = try gatewayDirectoryState() else {
      throw RuntimeError(.notFound, "No bearer token has ID \(id)")
    }
    return try withLock {
      guard var document = try load() else {
        throw RuntimeError(.notFound, "No bearer token has ID \(id)")
      }
      var tokens = try records(document)
      guard let index = tokens.firstIndex(where: { $0["id"] as? String == id }) else {
        throw RuntimeError(.notFound, "No bearer token has ID \(id)")
      }
      if tokens[index]["revoked_at"] is String {
        return (Self.summary(tokens[index]), true)
      }
      tokens[index]["revoked_at"] = Self.timestamp(now)
      document["tokens"] = tokens
      try replaceStore(with: Self.encode(document))
      return (Self.summary(tokens[index]), false)
    }
  }

  // MARK: Store I/O

  /// Reads and validates the store; `nil` when it does not exist.
  private func load() throws -> [String: Any]? {
    var info = stat()
    if lstat(file.path, &info) != 0 {
      guard errno == ENOENT else { throw unsafe("Cannot inspect the bearer token store") }
      return nil
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o777 == 0o600
    else { throw unsafe("The bearer token store must be a 0600 regular file owned by this user") }
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw unsafe("Cannot open the bearer token store") }
    defer { close(descriptor) }
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_size <= Self.maxBytes
    else { throw invalid("The bearer token store exceeds \(Self.maxBytes) bytes") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      guard count >= 0 else { throw RuntimeError(.io, "Cannot read the bearer token store") }
      if count == 0 { break }
      data.append(contentsOf: buffer[0..<count])
      guard data.count <= Self.maxBytes else {
        throw invalid("The bearer token store exceeds \(Self.maxBytes) bytes")
      }
    }
    guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw invalid("The bearer token store is not a JSON object")
    }
    _ = try records(document)
    return document
  }

  /// The validated records, in order. Any malformed or duplicated record rejects the whole store,
  /// as the server does.
  private func records(_ document: [String: Any]) throws -> [[String: Any]] {
    guard jsonInt(document["schema_version"]) == Self.schemaVersion,
      let raw = document["tokens"] as? [Any]
    else { throw invalid("The bearer token store has an unsupported schema") }
    guard raw.count <= Self.maxTokens else {
      throw invalid("The bearer token store holds more than \(Self.maxTokens) records")
    }
    var ids = Set<String>()
    var records: [[String: Any]] = []
    for entry in raw {
      guard let record = entry as? [String: Any], Self.isRecord(record),
        let id = record["id"] as? String, ids.insert(id).inserted
      else { throw invalid("The bearer token store has a malformed or duplicate record") }
      records.append(record)
    }
    return records
  }

  private func replaceStore(with data: Data) throws {
    let temporary = gatewayDirectory.appendingPathComponent(
      ".bearer-tokens.\(Self.randomHex(bytes: 8)).tmp")
    try Self.writeExclusive(data, to: temporary)
    guard rename(temporary.path, file.path) == 0 else {
      unlink(temporary.path)
      throw RuntimeError(.io, "Cannot replace the bearer token store")
    }
    try Self.syncDirectory(gatewayDirectory)
  }

  private func withLock<T>(_ body: () throws -> T) throws -> T {
    let descriptor = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw unsafe("Cannot open the bearer token lock") }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), fchmod(descriptor, 0o600) == 0
    else { throw unsafe("The bearer token lock must be a regular file owned by this user") }
    let deadline = ContinuousClock.now + .seconds(5)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else {
        throw RuntimeError(.conflict, "Another macus command is changing bearer tokens")
      }
      usleep(20_000)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  // MARK: Path checks (mirroring the server's Macus.PrivatePath)

  private enum DirectoryState { case absent, present }

  private func requireStateDirectory() throws {
    let path = Self.systemAlias(stateDirectory.path)
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT {
        throw RuntimeError(
          .notFound,
          "State directory does not exist: \(stateDirectory.path). macus server does not create it; run macus start first"
        )
      }
      throw unsafe("Cannot inspect the state directory")
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o022 == 0, try Self.safeAncestors(path)
    else {
      throw unsafe(
        "The state directory and its ancestors must belong to this user or root and not be writable by others"
      )
    }
  }

  private func gatewayDirectoryState() throws -> DirectoryState {
    var info = stat()
    guard lstat(Self.systemAlias(gatewayDirectory.path), &info) == 0 else {
      guard errno == ENOENT else { throw unsafe("Cannot inspect the gateway directory") }
      return .absent
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o777 == 0o700
    else { throw unsafe("The gateway directory must be a 0700 directory owned by this user") }
    return .present
  }

  private func prepareGatewayDirectory() throws {
    if case .present = try gatewayDirectoryState() { return }
    guard mkdir(gatewayDirectory.path, 0o700) == 0 || errno == EEXIST else {
      throw RuntimeError(.io, "Cannot create the gateway directory")
    }
    var info = stat()
    guard lstat(gatewayDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), chmod(gatewayDirectory.path, 0o700) == 0
    else { throw unsafe("The gateway directory must be a 0700 directory owned by this user") }
    try Self.syncDirectory(stateDirectory)
  }

  /// Every ancestor up to `/` is a directory owned by this user or root and not writable by
  /// group or others, except root-owned sticky directories such as `/private/tmp`.
  static func safeAncestors(_ path: String) throws -> Bool {
    var current = URL(fileURLWithPath: path).deletingLastPathComponent().path
    while true {
      var info = stat()
      guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
      let owner = info.st_uid
      let stickySystem = owner == 0 && info.st_mode & S_ISVTX != 0
      guard owner == 0 || owner == getuid(), info.st_mode & 0o022 == 0 || stickySystem else {
        return false
      }
      if current == "/" { return true }
      current = URL(fileURLWithPath: current).deletingLastPathComponent().path
    }
  }

  /// Rewrites Darwin's `/var` and `/tmp` links to their `/private` destinations.
  static func systemAlias(_ path: String) -> String {
    for alias in ["/var", "/tmp"] where path.hasPrefix(alias + "/") {
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: alias)) == "private" + alias {
        return "/private" + path
      }
    }
    return path
  }

  /// The destination must be a new absolute path in a directory owned by this user, below
  /// ancestors only this user or root can write.
  static func validateOutput(_ output: URL) throws {
    let path = output.path
    guard output.isFileURL, path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\n") else {
      throw RuntimeError(.invalidRequest, "--output requires an absolute file path")
    }
    let parent = systemAlias(output.deletingLastPathComponent().path)
    var info = stat()
    guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o022 == 0,
      try safeAncestors(parent)
    else {
      throw RuntimeError(
        .invalidConfiguration,
        "The --output directory must exist, belong to this user and not be writable by others")
    }
  }

  // MARK: Files

  /// Creates `url` exclusively (never following or replacing anything) as 0600 and syncs it.
  static func writeExclusive(_ data: Data, to url: URL) throws {
    let descriptor = open(
      url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw RuntimeError(.conflict, "Refusing to replace an existing file: \(url.path)")
      }
      throw RuntimeError(.io, "Cannot create \(url.path)")
    }
    var written = 0
    let ok =
      fchmod(descriptor, 0o600) == 0
      && data.withUnsafeBytes { bytes in
        while written < bytes.count {
          let count = write(descriptor, bytes.baseAddress! + written, bytes.count - written)
          if count < 0 {
            if errno == EINTR { continue }
            return false
          }
          written += count
        }
        return true
      } && fsync(descriptor) == 0
    close(descriptor)
    guard ok else {
      unlink(url.path)
      throw RuntimeError(.io, "Cannot write \(url.path)")
    }
  }

  static func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open \(url.path) for sync") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw RuntimeError(.io, "Cannot sync \(url.path)") }
  }

  static func encode(_ document: [String: Any]) throws -> Data {
    guard
      var data = try? JSONSerialization.data(
        withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    else { throw RuntimeError(.io, "Cannot encode the bearer token store") }
    data.append(0x0A)
    guard data.count <= maxBytes else {
      throw RuntimeError(
        .conflict, "The token store would exceed \(maxBytes) bytes; revoke and prune first")
    }
    return data
  }

  // MARK: Values

  static func verifier(_ secret: String) -> String {
    SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    arc4random_buf(&bytes, count)
    return bytes
  }

  static func randomHex(bytes: Int) -> String {
    randomBytes(bytes).map { String(format: "%02x", $0) }.joined()
  }

  static func randomBase64URL(bytes: Int) -> String {
    Data(randomBytes(bytes)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(
      from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
  }

  static func isTimestamp(_ value: Any?) -> Bool {
    guard let text = value as? String, text.hasSuffix("Z") || text.hasSuffix("+00:00") else {
      return false
    }
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) != nil || fractional.date(from: text) != nil
  }

  static func isNullableTimestamp(_ value: Any?) -> Bool {
    value == nil || value is NSNull || isTimestamp(value)
  }

  static func isID(_ value: String) -> Bool {
    value.utf8.count == 16 && value.utf8.allSatisfy(isLowerHex)
  }

  static func isPrincipal(_ value: String) -> Bool {
    guard let first = value.utf8.first, (1...128).contains(value.utf8.count),
      isAlphanumeric(first)
    else { return false }
    return value.utf8.dropFirst().allSatisfy {
      isAlphanumeric($0) || [46, 95, 64, 45].contains($0)
    }
  }

  static func validateScopes(_ scopes: [String]) throws {
    guard !scopes.isEmpty else {
      throw RuntimeError(.invalidRequest, "Issue a token with at least one --scope")
    }
    guard Set(scopes).count == scopes.count else {
      throw RuntimeError(.invalidRequest, "Each --scope may be given once")
    }
    for scope in scopes where !Self.scopes.contains(scope) {
      throw RuntimeError(
        .invalidRequest,
        "Unsupported scope \(terminalSafe(scope)). Macus issues only: \(Self.scopes.joined(separator: ", "))"
      )
    }
  }

  static func isRecord(_ record: [String: Any]) -> Bool {
    guard let id = record["id"] as? String, isID(id),
      let verifier = record["verifier"] as? String, verifier.utf8.count == 64,
      verifier.utf8.allSatisfy(isLowerHex),
      let principal = record["principal"] as? String, isPrincipal(principal),
      let scopes = record["scopes"] as? [Any], scopes.allSatisfy({ $0 is String })
    else { return false }
    return isTimestamp(record["created_at"]) && isNullableTimestamp(record["expires_at"])
      && isNullableTimestamp(record["revoked_at"])
  }

  static func summary(_ record: [String: Any]) -> BearerTokenSummary {
    BearerTokenSummary(
      id: record["id"] as? String ?? "", principal: record["principal"] as? String ?? "",
      scopes: record["scopes"] as? [String] ?? [], createdAt: record["created_at"] as? String ?? "",
      expiresAt: record["expires_at"] as? String, revokedAt: record["revoked_at"] as? String)
  }

  private static func isLowerHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }

  private static func isAlphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }

  private func unsafe(_ message: String) -> RuntimeError {
    RuntimeError(.invalidConfiguration, message + "; the store was preserved")
  }

  private func invalid(_ message: String) -> RuntimeError {
    RuntimeError(.invalidConfiguration, message + "; the store was preserved")
  }
}
