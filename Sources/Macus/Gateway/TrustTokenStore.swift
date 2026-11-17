import Darwin
import Foundation
import Security

/// An issued enrollment token, as listed. Neither the token nor its secret appears here.
public struct TrustTokenSummary: Sendable, Equatable {
  public let id: String
  public let name: String
  public let createdAt: String
  public let expiresAt: String
  public let revokedAt: String?
  /// When the server consumed the token, and the certificate fingerprint that presented it.
  public let redeemedAt: String?
  public let redeemedBy: String?

  var jsonObject: [String: Any] {
    [
      "id": id, "name": name, "created_at": createdAt, "expires_at": expiresAt,
      "revoked_at": revokedAt ?? NSNull(), "redeemed_at": redeemedAt ?? NSNull(),
      "redeemed_by": redeemedBy ?? NSNull(),
    ]
  }
}

/// Owner-local issuance of expiring single-use native certificate enrollment tokens, the tokens
/// the Macus server redeems (`Macus.Proxy.Enrollment`) when an untrusted standard Incus client
/// runs `incus remote add NAME TOKEN`.
///
/// A token is the native `api.CertificateAddToken`: base64 of `{"client_name", "fingerprint",
/// "addresses", "secret", "expires_at"}`, with the gateway certificate's SHA-256 fingerprint,
/// which the client checks before sending the token, and 32 random bytes of secret as hex. The
/// token is written only to a new 0600 `--output` file. `trust-tokens.json` keeps the record with
/// the secret's SHA-256 verifier; every token expires, after at most 30 days, and enrolls one
/// unrestricted owner-admin client named by the token. The server alone writes
/// `trust-token-redemptions.json`, which listing reads to show consumed tokens. Nothing here
/// touches gateway trust, runtime disks, Incus or services.
public struct TrustTokenStore: Sendable {
  static let maxTokens = 1_024
  static let maxAddresses = 8
  /// One minute to thirty days.
  static let lifetimes = 60...(30 * 86_400)
  static let defaultLifetime = 3_600

  public let stateDirectory: URL
  let tokens: GatewayDocument
  let redemptions: GatewayDocument

  public init(stateDirectory: URL) {
    self.stateDirectory = stateDirectory.standardizedFileURL
    tokens = GatewayDocument(
      stateDirectory: self.stateDirectory, name: "trust-tokens", label: "trust token store",
      collection: "tokens", maxRecords: Self.maxTokens, isRecord: Self.isRecord)
    redemptions = GatewayDocument(
      stateDirectory: self.stateDirectory, name: "trust-token-redemptions",
      label: "trust token redemption record", collection: "redemptions",
      maxRecords: Self.maxTokens, isRecord: Self.isRedemption)
  }

  public var file: URL { tokens.file }
  public var redemptionFile: URL { redemptions.file }

  // MARK: Listing

  /// Lists issued tokens with their redemption. Creates nothing.
  public func list() throws -> [TrustTokenSummary] {
    let records = try tokens.existingRecords()
    var redeemed: [String: [String: Any]] = [:]
    for record in try redemptions.existingRecords() {
      if let id = record["id"] as? String { redeemed[id] = record }
    }
    return records.map { Self.summary($0, redemption: redeemed[$0["id"] as? String ?? ""]) }
  }

  // MARK: Issuance

  /// Issues one token for a client to enroll as `name`, reachable at `addresses`, for the gateway
  /// certificate at `serverCertificate`. Writes the token, and only the token, to a new 0600 file
  /// at `output`, then adds its record; if the store cannot be updated the file is removed.
  public func issue(
    name: String, addresses: [String], serverCertificate: URL, expiresAt: Date, output: URL,
    now: Date = Date()
  ) throws -> TrustTokenSummary {
    guard GatewayDocument.isName(name) else {
      throw RuntimeError(
        .invalidRequest,
        "--name must be 1-128 characters: letters, digits, '.', '_', '@' or '-', starting with a letter or digit"
      )
    }
    try Self.validateAddresses(addresses)
    let lifetime = expiresAt.timeIntervalSince(now)
    guard lifetime >= TimeInterval(Self.lifetimes.lowerBound),
      lifetime <= TimeInterval(Self.lifetimes.upperBound)
    else {
      throw RuntimeError(.invalidRequest, "A trust token expires in 1 minute to 30 days")
    }
    let fingerprint = try Self.certificateFingerprint(serverCertificate)
    try GatewayDocument.validateOutput(output)
    try tokens.requireStateDirectory()
    try tokens.prepareGatewayDirectory()
    return try tokens.withLock {
      var stored = try tokens.load() ?? tokens.empty
      var records = try tokens.records(stored)
      guard records.count < Self.maxTokens else {
        throw RuntimeError(
          .conflict,
          "The trust token store holds \(Self.maxTokens) records; remove old records first")
      }
      let ids = Set(records.compactMap { $0["id"] as? String })
      var id = GatewayDocument.randomHex(bytes: 8)
      while ids.contains(id) { id = GatewayDocument.randomHex(bytes: 8) }
      let secret = GatewayDocument.randomHex(bytes: 32)
      let expires = GatewayDocument.timestamp(expiresAt)
      let record: [String: Any] = [
        "id": id,
        "verifier": GatewayDocument.sha256Hex(secret),
        "name": name,
        "created_at": GatewayDocument.timestamp(now),
        "expires_at": expires,
        "revoked_at": NSNull(),
      ]
      records.append(record)
      stored["tokens"] = records
      let data = try tokens.encode(stored)
      let token = try Self.nativeToken(
        name: name, fingerprint: fingerprint, addresses: addresses, secret: secret,
        expiresAt: expires)
      try GatewayDocument.writeExclusive(Data((token + "\n").utf8), to: output)
      do {
        try tokens.replace(with: data)
      } catch {
        unlink(output.path)
        throw error
      }
      return Self.summary(record, redemption: nil)
    }
  }

  // MARK: Revocation

  /// Marks an unredeemed token revoked so the server refuses it. Revoking again keeps the original
  /// time and reports `alreadyRevoked`. A certificate the token already enrolled stays trusted;
  /// remove it with `incus config trust remove`.
  public func revoke(id: String, now: Date = Date()) throws -> (
    record: TrustTokenSummary, alreadyRevoked: Bool
  ) {
    guard GatewayDocument.isID(id) else {
      throw RuntimeError(.invalidRequest, "A token ID is 16 lowercase hexadecimal characters")
    }
    try tokens.requireStateDirectory()
    guard case .present = try tokens.gatewayDirectoryState() else {
      throw RuntimeError(.notFound, "No trust token has ID \(id)")
    }
    let redemption = try redemptions.existingRecords().first { $0["id"] as? String == id }
    return try tokens.withLock {
      guard var stored = try tokens.load() else {
        throw RuntimeError(.notFound, "No trust token has ID \(id)")
      }
      var records = try tokens.records(stored)
      guard let index = records.firstIndex(where: { $0["id"] as? String == id }) else {
        throw RuntimeError(.notFound, "No trust token has ID \(id)")
      }
      if records[index]["revoked_at"] is String {
        return (Self.summary(records[index], redemption: redemption), true)
      }
      records[index]["revoked_at"] = GatewayDocument.timestamp(now)
      stored["tokens"] = records
      try tokens.replace(with: tokens.encode(stored))
      return (Self.summary(records[index], redemption: redemption), false)
    }
  }

  // MARK: Values

  /// The native token string, as `api.CertificateAddToken.String()` encodes it.
  static func nativeToken(
    name: String, fingerprint: String, addresses: [String], secret: String, expiresAt: String
  ) throws -> String {
    let object: [String: Any] = [
      "client_name": name, "fingerprint": fingerprint, "addresses": addresses, "secret": secret,
      "expires_at": expiresAt,
    ]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { throw RuntimeError(.io, "Cannot encode the trust token") }
    return data.base64EncodedString()
  }

  /// The SHA-256 fingerprint of the single certificate in a PEM file owned by this user or root.
  static func certificateFingerprint(_ url: URL) throws -> String {
    let refused = RuntimeError(
      .invalidConfiguration,
      "--server-certificate must be an absolute path to a regular PEM file holding the gateway certificate, owned by this user or root and not writable by others"
    )
    var info = stat()
    guard url.isFileURL, url.path.hasPrefix("/"),
      lstat(GatewayDocument.systemAlias(url.path), &info) == 0,
      info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() || info.st_uid == 0,
      info.st_mode & 0o022 == 0, info.st_size <= 65_536,
      let pem = try? String(contentsOf: url, encoding: .utf8)
    else { throw refused }
    let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
    guard blocks.count == 1, let block = blocks.first,
      let end = block.range(of: "-----END CERTIFICATE-----"),
      let der = Data(
        base64Encoded: String(block[..<end.lowerBound]), options: .ignoreUnknownCharacters),
      SecCertificateCreateWithData(nil, der as CFData) != nil
    else { throw refused }
    return GatewayDocument.sha256Hex(data: der)
  }

  static func validateAddresses(_ addresses: [String]) throws {
    guard !addresses.isEmpty, addresses.count <= Self.maxAddresses else {
      throw RuntimeError(
        .invalidRequest, "Give 1 to \(Self.maxAddresses) --address values the client can reach")
    }
    guard Set(addresses).count == addresses.count else {
      throw RuntimeError(.invalidRequest, "Each --address may be given once")
    }
    for address in addresses where !isAddress(address) {
      throw RuntimeError(
        .invalidRequest,
        "Invalid --address \(terminalSafe(address)): use HOST:PORT or [IPv6]:PORT, without a scheme"
      )
    }
  }

  /// `host:port` or `[ipv6]:port` with a port from 1 to 65535.
  static func isAddress(_ value: String) -> Bool {
    guard value.utf8.count <= 255, let colon = value.lastIndex(of: ":") else { return false }
    let host = value[..<colon]
    let port = value[value.index(after: colon)...]
    guard !port.isEmpty, port.count <= 5, port.utf8.allSatisfy({ (48...57).contains($0) }),
      let number = Int(port), (1...65_535).contains(number), !host.isEmpty
    else { return false }
    if host.hasPrefix("[") {
      guard host.hasSuffix("]"), host.count > 2 else { return false }
      return host.dropFirst().dropLast().utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) || $0 == 58
      }
    }
    return host.utf8.allSatisfy {
      (48...57).contains($0) || (97...122).contains($0) || (65...90).contains($0)
        || $0 == 46 || $0 == 45
    } && !host.hasPrefix("-") && !host.hasPrefix(".")
  }

  @Sendable static func isRecord(_ record: [String: Any]) -> Bool {
    guard let id = record["id"] as? String, GatewayDocument.isID(id),
      GatewayDocument.isHex64(record["verifier"]),
      let name = record["name"] as? String, GatewayDocument.isName(name)
    else { return false }
    return GatewayDocument.isTimestamp(record["created_at"])
      && GatewayDocument.isTimestamp(record["expires_at"])
      && GatewayDocument.isNullableTimestamp(record["revoked_at"])
      && (record["restricted"] == nil || record["restricted"] as? Bool == false)
      && (record["projects"] == nil || (record["projects"] as? [Any])?.isEmpty == true)
      && (record["type"] == nil || record["type"] as? String == "client")
  }

  @Sendable static func isRedemption(_ record: [String: Any]) -> Bool {
    guard let id = record["id"] as? String, GatewayDocument.isID(id) else { return false }
    return GatewayDocument.isTimestamp(record["redeemed_at"])
      && GatewayDocument.isHex64(record["fingerprint"])
  }

  static func summary(_ record: [String: Any], redemption: [String: Any]?) -> TrustTokenSummary {
    TrustTokenSummary(
      id: record["id"] as? String ?? "", name: record["name"] as? String ?? "",
      createdAt: record["created_at"] as? String ?? "",
      expiresAt: record["expires_at"] as? String ?? "",
      revokedAt: record["revoked_at"] as? String,
      redeemedAt: redemption?["redeemed_at"] as? String,
      redeemedBy: redemption?["fingerprint"] as? String)
  }
}
