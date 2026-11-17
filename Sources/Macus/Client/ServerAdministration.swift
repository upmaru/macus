import Foundation

/// `macus server token ...` and `macus server trust token ...`: owner-local bearer and enrollment
/// token administration over private gateway state.
///
/// These commands never contact the runtime, Incus or launchd, never touch runtime disks or
/// gateway trust and never print a token. The only secret output is the file an issue command
/// creates at `--output`.
enum ServerAdministration {
  static func issue(
    principal: String, scopes: [String], expiresIn: Int?, output: String, directory: URL,
    json: Bool, streams: MacusStreams, presentation: HumanPresentation, now: Date = Date()
  ) throws {
    let store = BearerTokenStore(stateDirectory: directory)
    let outputURL = URL(fileURLWithPath: output)
    let summary = try store.issue(
      principal: principal, scopes: scopes,
      expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }, output: outputURL,
      now: now)
    if json {
      var object = summary.jsonObject
      object["output"] = outputURL.path
      streams.writeOutput(try jsonText(["token": object]))
    } else {
      presentation.issuedToken(summary, output: outputURL.path, directory: directory)
    }
  }

  static func list(
    directory: URL, json: Bool, streams: MacusStreams, presentation: HumanPresentation,
    now: Date = Date()
  ) throws {
    let tokens = try BearerTokenStore(stateDirectory: directory).list()
    if json {
      streams.writeOutput(try jsonText(["tokens": tokens.map(\.jsonObject)]))
    } else {
      presentation.tokens(tokens, now: now)
    }
  }

  static func revoke(
    id: String, directory: URL, json: Bool, streams: MacusStreams,
    presentation: HumanPresentation
  ) throws {
    let result = try BearerTokenStore(stateDirectory: directory).revoke(id: id)
    if json {
      streams.writeOutput(
        try jsonText(["token": result.record.jsonObject, "already_revoked": result.alreadyRevoked])
      )
    } else {
      presentation.revokedToken(result.record, alreadyRevoked: result.alreadyRevoked)
    }
  }

  static func issueTrustToken(
    name: String, addresses: [String], serverCertificate: String, expiresIn: Int, output: String,
    directory: URL, json: Bool, streams: MacusStreams, presentation: HumanPresentation,
    now: Date = Date()
  ) throws {
    let outputURL = URL(fileURLWithPath: output)
    let summary = try TrustTokenStore(stateDirectory: directory).issue(
      name: name, addresses: addresses,
      serverCertificate: URL(fileURLWithPath: serverCertificate),
      expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)), output: outputURL, now: now)
    if json {
      var object = summary.jsonObject
      object["output"] = outputURL.path
      object["addresses"] = addresses
      streams.writeOutput(try jsonText(["trust_token": object]))
    } else {
      presentation.issuedTrustToken(summary, output: outputURL.path, directory: directory)
    }
  }

  static func listTrustTokens(
    directory: URL, json: Bool, streams: MacusStreams, presentation: HumanPresentation,
    now: Date = Date()
  ) throws {
    let tokens = try TrustTokenStore(stateDirectory: directory).list()
    if json {
      streams.writeOutput(try jsonText(["trust_tokens": tokens.map(\.jsonObject)]))
    } else {
      presentation.trustTokens(tokens, now: now)
    }
  }

  static func revokeTrustToken(
    id: String, directory: URL, json: Bool, streams: MacusStreams,
    presentation: HumanPresentation
  ) throws {
    let result = try TrustTokenStore(stateDirectory: directory).revoke(id: id)
    if json {
      streams.writeOutput(
        try jsonText([
          "trust_token": result.record.jsonObject, "already_revoked": result.alreadyRevoked,
        ]))
    } else {
      presentation.revokedTrustToken(result.record, alreadyRevoked: result.alreadyRevoked)
    }
  }

  /// Parses `--expires-in`: a positive count with an `s`, `m`, `h` or `d` suffix, from one
  /// minute to ten years.
  static func expiry(_ raw: String) -> Int? {
    guard let unit = raw.last, let multiplier = ["s": 1, "m": 60, "h": 3_600, "d": 86_400][unit],
      raw.count > 1, raw.count <= 8, raw.dropLast().utf8.allSatisfy({ (48...57).contains($0) }),
      let count = Int(raw.dropLast())
    else { return nil }
    let seconds = count * multiplier
    return (60...(3_650 * 86_400)).contains(seconds) ? seconds : nil
  }
}

extension HumanPresentation {
  func issuedToken(_ token: BearerTokenSummary, output: String, directory: URL) {
    heading("Bearer token issued")
    tokenFields(token)
    field("Token file", output)
    text("  The token was written only to the token file (mode 0600) and is not shown again.\n")
    next([
      shellCommand([
        "macus", "--state-dir", directory.path, "server", "token", "revoke", token.id,
      ])
    ])
  }

  func revokedToken(_ token: BearerTokenSummary, alreadyRevoked: Bool) {
    heading(alreadyRevoked ? "Bearer token was already revoked" : "Bearer token revoked")
    tokenFields(token)
    text("  The Macus server refuses this token from its next request.\n")
  }

  func tokens(_ tokens: [BearerTokenSummary], now: Date) {
    heading("Bearer tokens")
    if tokens.isEmpty {
      text("  No bearer tokens are stored.\n")
      return
    }
    for token in tokens {
      heading("\n" + token.id)
      field("Principal", token.principal)
      field("Scopes", token.scopes.joined(separator: " "))
      field("Status", status(token, now: now))
      field("Created", token.createdAt)
    }
  }

  private func tokenFields(_ token: BearerTokenSummary) {
    heading("\nToken")
    field("ID", token.id)
    field("Principal", token.principal)
    field("Scopes", token.scopes.joined(separator: " "))
    field("Expires", token.expiresAt ?? "Never")
    if let revoked = token.revokedAt { field("Revoked", revoked) }
  }

  private func status(_ token: BearerTokenSummary, now: Date) -> String {
    if let revoked = token.revokedAt { return "Revoked \(revoked)" }
    guard let expires = token.expiresAt else { return "Active, no expiry" }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: expires), date <= now { return "Expired \(expires)" }
    return "Active until \(expires)"
  }

  func issuedTrustToken(_ token: TrustTokenSummary, output: String, directory: URL) {
    heading("Trust token issued")
    trustTokenFields(token)
    field("Token file", output)
    text("  The token was written only to the token file (mode 0600) and is not shown again.\n")
    text("  It enrolls one client certificate once, as an unrestricted gateway client.\n")
    text("  On the client, pass the token from the file to: incus remote add REMOTE TOKEN\n")
    next([
      shellCommand([
        "macus", "--state-dir", directory.path, "server", "trust", "token", "revoke", token.id,
      ])
    ])
  }

  func revokedTrustToken(_ token: TrustTokenSummary, alreadyRevoked: Bool) {
    heading(alreadyRevoked ? "Trust token was already revoked" : "Trust token revoked")
    trustTokenFields(token)
    if token.redeemedAt != nil {
      text(
        "  This token was already redeemed; remove its certificate with incus config trust remove.\n"
      )
    } else {
      text("  The Macus server refuses this token from its next enrollment.\n")
    }
  }

  func trustTokens(_ tokens: [TrustTokenSummary], now: Date) {
    heading("Trust tokens")
    if tokens.isEmpty {
      text("  No trust tokens are stored.\n")
      return
    }
    for token in tokens {
      heading("\n" + token.id)
      field("Name", token.name)
      field("Status", trustStatus(token, now: now))
      field("Created", token.createdAt)
    }
  }

  private func trustTokenFields(_ token: TrustTokenSummary) {
    heading("\nToken")
    field("ID", token.id)
    field("Name", token.name)
    field("Expires", token.expiresAt)
    if let revoked = token.revokedAt { field("Revoked", revoked) }
    if let redeemed = token.redeemedAt { field("Redeemed", redeemed) }
  }

  private func trustStatus(_ token: TrustTokenSummary, now: Date) -> String {
    if let redeemed = token.redeemedAt {
      return "Redeemed \(redeemed) by \(token.redeemedBy ?? "unknown")"
    }
    if let revoked = token.revokedAt { return "Revoked \(revoked)" }
    if let date = GatewayDocument.date(token.expiresAt), date <= now {
      return "Expired \(token.expiresAt)"
    }
    return "Active until \(token.expiresAt)"
  }
}
