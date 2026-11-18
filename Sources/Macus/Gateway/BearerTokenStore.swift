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
/// unpadded base64url. Records hold the SHA-256 of the secret, never the secret. The store has
/// the owner-private checks, locking and atomic replacement of `GatewayDocument`. Listing never
/// creates state.
public struct BearerTokenStore: Sendable {
  public static let scopes = [
    "incus.read", "incus.write", "incus.exec", "incus.delete",
    "runtime.read", "runtime.write", "runtime.delete",
    "incus.native.read", "incus.native.write", "incus.native.delete", "incus.native.admin",
  ]
  static let maxTokens = 4_096
  /// The principal of the credential `macus start` prepares for the local CLI. `token issue`
  /// refuses it, so only `prepareLocalCredential` creates such records.
  public static let localPrincipal = "macus-local-cli"
  public static let localScopes = ["runtime.read", "runtime.write", "runtime.delete"]

  public let stateDirectory: URL
  let document: GatewayDocument

  public init(stateDirectory: URL) {
    self.stateDirectory = stateDirectory.standardizedFileURL
    document = GatewayDocument(
      stateDirectory: self.stateDirectory, name: "bearer-tokens", label: "bearer token store",
      collection: "tokens", maxRecords: Self.maxTokens, isRecord: Self.isRecord)
  }

  public var gatewayDirectory: URL { document.gatewayDirectory }
  public var file: URL { document.file }
  /// The local CLI's own token, `<state-dir>/server/local-cli.token` (0600).
  public var localCredentialFile: URL {
    document.gatewayDirectory.appendingPathComponent("local-cli.token")
  }

  // MARK: Listing

  /// Lists stored records. A missing gateway directory or store lists nothing and creates nothing.
  public func list() throws -> [BearerTokenSummary] {
    try document.existingRecords().map(Self.summary)
  }

  // MARK: Issuance

  /// Issues one credential: writes the token, and only the token, to a new 0600 file at `output`,
  /// then adds its record. If the store cannot be updated the output file is removed.
  public func issue(
    principal: String, scopes: [String], expiresAt: Date?, output: URL, now: Date = Date()
  ) throws -> BearerTokenSummary {
    guard GatewayDocument.isName(principal) else {
      throw RuntimeError(
        .invalidRequest,
        "--principal must be 1-128 characters: letters, digits, '.', '_', '@' or '-', starting with a letter or digit"
      )
    }
    guard principal != Self.localPrincipal else {
      throw RuntimeError(
        .invalidRequest,
        "\(Self.localPrincipal) is reserved for the credential macus start prepares; choose another --principal"
      )
    }
    try Self.validateScopes(scopes)
    if let expiresAt, expiresAt <= now {
      throw RuntimeError(.invalidRequest, "The expiry must be in the future")
    }
    try GatewayDocument.validateOutput(output)
    try document.requireStateDirectory()
    try document.prepareGatewayDirectory()
    return try document.withLock {
      var stored = try document.load() ?? document.empty
      var tokens = try document.records(stored)
      guard tokens.count < Self.maxTokens else {
        throw RuntimeError(
          .conflict, "The token store holds \(Self.maxTokens) records; revoke and prune first")
      }
      let ids = Set(tokens.compactMap { $0["id"] as? String })
      var id = GatewayDocument.randomHex(bytes: 8)
      while ids.contains(id) { id = GatewayDocument.randomHex(bytes: 8) }
      let secret = GatewayDocument.randomBase64URL(bytes: 32)
      let record: [String: Any] = [
        "id": id,
        "verifier": Self.verifier(secret),
        "principal": principal,
        "scopes": scopes,
        "created_at": GatewayDocument.timestamp(now),
        "expires_at": expiresAt.map(GatewayDocument.timestamp) ?? NSNull(),
        "revoked_at": NSNull(),
      ]
      tokens.append(record)
      stored["tokens"] = tokens
      let data = try document.encode(stored)
      try GatewayDocument.writeExclusive(Data("macus.\(id).\(secret)\n".utf8), to: output)
      do {
        try document.replace(with: data)
      } catch {
        unlink(output.path)
        throw error
      }
      return Self.summary(record)
    }
  }

  // MARK: Local CLI credential

  /// Prepares the local CLI's credential once: a `macus-local-cli` token with the runtime scopes
  /// in `localCredentialFile`. A token file whose record is present, unrevoked, unexpired and
  /// scoped as expected is kept unchanged. Otherwise (first start, a missing or unreadable file,
  /// or a record the owner revoked to rotate it) any other active `macus-local-cli` record is
  /// revoked and a new token replaces the file. Returns whether a token was issued. The token is
  /// never printed.
  @discardableResult
  public func prepareLocalCredential(now: Date = Date()) throws -> Bool {
    try document.requireStateDirectory()
    try document.prepareGatewayDirectory()
    return try document.withLock {
      var stored = try document.load() ?? document.empty
      var tokens = try document.records(stored)
      let current = Self.readLocalToken(localCredentialFile)
      if let current,
        tokens.contains(where: { Self.isActiveLocal($0, now: now) && Self.matches($0, current) })
      {
        return false
      }
      let stamp = GatewayDocument.timestamp(now)
      for index in tokens.indices where Self.isActiveLocal(tokens[index], now: now) {
        tokens[index]["revoked_at"] = stamp
      }
      guard tokens.count < Self.maxTokens else {
        throw RuntimeError(
          .conflict, "The token store holds \(Self.maxTokens) records; revoke and prune first")
      }
      let ids = Set(tokens.compactMap { $0["id"] as? String })
      var id = GatewayDocument.randomHex(bytes: 8)
      while ids.contains(id) { id = GatewayDocument.randomHex(bytes: 8) }
      let secret = GatewayDocument.randomBase64URL(bytes: 32)
      tokens.append([
        "id": id,
        "verifier": Self.verifier(secret),
        "principal": Self.localPrincipal,
        "scopes": Self.localScopes,
        "created_at": stamp,
        "expires_at": NSNull(),
        "revoked_at": NSNull(),
      ])
      stored["tokens"] = tokens
      let data = try document.encode(stored)
      // The new token is written beside the old file first, so a failure leaves the old file.
      let staged = document.gatewayDirectory.appendingPathComponent(
        ".local-cli.\(GatewayDocument.randomHex(bytes: 8)).tmp")
      try GatewayDocument.writeExclusive(Data("macus.\(id).\(secret)\n".utf8), to: staged)
      do {
        try document.replace(with: data)
      } catch {
        unlink(staged.path)
        throw error
      }
      guard rename(staged.path, localCredentialFile.path) == 0 else {
        unlink(staged.path)
        throw RuntimeError(.io, "Cannot write the local CLI credential")
      }
      try GatewayDocument.syncDirectory(document.gatewayDirectory)
      return true
    }
  }

  /// The `(id, secret)` of an owner-private local token file, or nil.
  static func readLocalToken(_ url: URL) -> (id: String, secret: String)? {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_size <= 256,
      let data = FileManager.default.contents(atPath: url.path),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    let parts = text.trimmingCharacters(in: .newlines).split(
      separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "macus", GatewayDocument.isID(String(parts[1])),
      parts[2].utf8.count == 43
    else { return nil }
    return (String(parts[1]), String(parts[2]))
  }

  static func isActiveLocal(_ record: [String: Any], now: Date) -> Bool {
    guard record["principal"] as? String == localPrincipal, !(record["revoked_at"] is String)
    else { return false }
    if let expires = GatewayDocument.date(record["expires_at"]), expires <= now { return false }
    return true
  }

  static func matches(_ record: [String: Any], _ token: (id: String, secret: String)) -> Bool {
    record["id"] as? String == token.id
      && record["verifier"] as? String == verifier(token.secret)
      && record["scopes"] as? [String] == localScopes
  }

  // MARK: Revocation

  /// Marks a record revoked. The server refuses it from the next request. Revoking an already
  /// revoked record keeps its original time and reports `alreadyRevoked`.
  public func revoke(id: String, now: Date = Date()) throws -> (
    record: BearerTokenSummary, alreadyRevoked: Bool
  ) {
    guard GatewayDocument.isID(id) else {
      throw RuntimeError(.invalidRequest, "A token ID is 16 lowercase hexadecimal characters")
    }
    try document.requireStateDirectory()
    guard case .present = try document.gatewayDirectoryState() else {
      throw RuntimeError(.notFound, "No bearer token has ID \(id)")
    }
    return try document.withLock {
      guard var stored = try document.load() else {
        throw RuntimeError(.notFound, "No bearer token has ID \(id)")
      }
      var tokens = try document.records(stored)
      guard let index = tokens.firstIndex(where: { $0["id"] as? String == id }) else {
        throw RuntimeError(.notFound, "No bearer token has ID \(id)")
      }
      if tokens[index]["revoked_at"] is String {
        return (Self.summary(tokens[index]), true)
      }
      tokens[index]["revoked_at"] = GatewayDocument.timestamp(now)
      stored["tokens"] = tokens
      try document.replace(with: document.encode(stored))
      return (Self.summary(tokens[index]), false)
    }
  }

  // MARK: Values

  static func verifier(_ secret: String) -> String { GatewayDocument.sha256Hex(secret) }

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

  @Sendable static func isRecord(_ record: [String: Any]) -> Bool {
    guard let id = record["id"] as? String, GatewayDocument.isID(id),
      GatewayDocument.isHex64(record["verifier"]),
      let principal = record["principal"] as? String, GatewayDocument.isName(principal),
      let scopes = record["scopes"] as? [Any], scopes.allSatisfy({ $0 is String })
    else { return false }
    return GatewayDocument.isTimestamp(record["created_at"])
      && GatewayDocument.isNullableTimestamp(record["expires_at"])
      && GatewayDocument.isNullableTimestamp(record["revoked_at"])
  }

  static func summary(_ record: [String: Any]) -> BearerTokenSummary {
    BearerTokenSummary(
      id: record["id"] as? String ?? "", principal: record["principal"] as? String ?? "",
      scopes: record["scopes"] as? [String] ?? [], createdAt: record["created_at"] as? String ?? "",
      expiresAt: record["expires_at"] as? String, revokedAt: record["revoked_at"] as? String)
  }
}
