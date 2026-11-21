import Foundation

struct IncusExecutableResolution: Sendable, Equatable {
  var executable: String
  var installed: Bool
}

struct IncusSetupResult: Sendable, Equatable {
  var address: String
  var connected: Bool
  var isDefault: Bool
  var executable: String
  var installed: Bool
  var remote: String
  var onPath: Bool
}

enum IncusAvailability: Sendable, Equatable {
  case executable(String)
  case homebrew(String)
  case missing
}

/// Discovery, official Homebrew installation and remote registration for the standard Incus CLI.
///
/// `client setup` and `start` share this service. It does not boot a runtime or install Homebrew.
struct IncusClientService: Sendable {
  var runner: any LocalCommandRunner
  var streams: MacusStreams
  var environment: [String: String]

  func availability(override: String?) throws -> IncusAvailability {
    if let override {
      guard isAbsoluteExecutablePath(override),
        FileManager.default.isExecutableFile(atPath: override)
      else {
        throw RuntimeError(.invalidConfiguration, "--incus must be an executable file")
      }
      return .executable(override)
    }
    if let found = executable(named: "incus", path: environment["PATH"] ?? "") {
      return .executable(found)
    }
    if let brew = brewExecutable(environment: environment) { return .homebrew(brew) }
    return .missing
  }

  func resolve(
    override: String?, timeout: Int, deadline: ContinuousClock.Instant? = nil
  ) async throws -> IncusExecutableResolution {
    switch try availability(override: override) {
    case .executable(let path):
      return IncusExecutableResolution(executable: path, installed: false)
    case .missing:
      throw RuntimeError(
        .unavailable,
        "Incus CLI was not found on PATH and Homebrew is not installed. Install Homebrew from https://brew.sh, then rerun macus client setup. macus does not install Homebrew."
      )
    case .homebrew(let brew):
      if let existing = try await installedIncus(brew: brew, timeout: timeout, deadline: deadline) {
        try finishWithin(deadline)
        return IncusExecutableResolution(executable: existing, installed: false)
      }
      streams.writeError(
        "macus: Incus CLI not found; installing official Homebrew formula incus\n")
      var brewEnvironment = environment
      if brewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] == nil {
        brewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      }
      let install = try await run(
        executable: brew, arguments: ["install", "incus"], environment: brewEnvironment,
        timeout: timeout, deadline: deadline)
      if !install.stderr.isEmpty {
        let progress = String(decoding: install.stderr, as: UTF8.self)
        // Preserve deliberate line boundaries, escaping every untrusted line separately.
        let bounded = String(progress.prefix(4_000))
        streams.writeError("Homebrew installation details:\n")
        for line in bounded.split(separator: "\n", omittingEmptySubsequences: false)
        where !line.isEmpty {
          streams.writeError("  " + terminalSafe(String(line)) + "\n")
        }
      }
      guard install.status == 0 else {
        throw RuntimeError(.io, "Homebrew install of incus failed")
      }
      guard
        let installed = try await installedIncus(brew: brew, timeout: timeout, deadline: deadline)
      else {
        throw RuntimeError(
          .unavailable, "Homebrew installed incus but the executable was not found under its prefix"
        )
      }
      try finishWithin(deadline)
      return IncusExecutableResolution(executable: installed, installed: true)
    }
  }

  func setup(
    remote: String, setDefault: Bool, incusOverride: String?, directory: URL, timeout: Int,
    gateway: any GatewayTransport
  ) async throws -> IncusSetupResult {
    if let incusOverride {
      guard isAbsoluteExecutablePath(incusOverride),
        FileManager.default.isExecutableFile(atPath: incusOverride)
      else {
        throw RuntimeError(.invalidConfiguration, "--incus must be an executable file")
      }
    }
    // Readiness comes from the public server, never from the private runtime socket. The pinned
    // request also proves the discovered endpoint's identity before anything is registered.
    try await readyRuntimeStatus(
      directory: directory, timeout: timeout, gateway: gateway, command: "client setup")
    let endpoint = try GatewayEndpoint.discover(stateDirectory: directory)
    return try await register(
      remote: remote, setDefault: setDefault, incusOverride: incusOverride, endpoint: endpoint,
      stateDirectory: directory, timeout: timeout, deadline: nil)
  }

  /// Registers `remote` for the server's public HTTPS endpoint with standard Incus commands and
  /// enrolls the client's certificate in gateway trust. Does not boot the runtime.
  ///
  /// An existing remote is never changed: one naming this endpoint is verified and reused, and
  /// any other (a legacy `unix:` registration included) is a conflict. A new remote is added from
  /// a single-use enrollment token bound to the certificate `incus` will present, or, when the
  /// gateway already trusts that certificate, by URL with the pinned server fingerprint answering
  /// the certificate prompt. Either way `incus` checks the server certificate before it sends
  /// anything. Afterwards `/1.0` must report the client trusted with the endpoint's certificate,
  /// and `incus list` must work. The default remote changes only with `setDefault`.
  ///
  /// A nil deadline preserves client setup's per-command timeout. Start passes one shared deadline.
  func register(
    remote: String, setDefault: Bool, incusOverride: String?, endpoint: GatewayEndpoint,
    stateDirectory: URL, timeout: Int, deadline: ContinuousClock.Instant? = nil
  ) async throws -> IncusSetupResult {
    guard let server = RemoteServer(endpoint.url) else {
      throw RuntimeError(.invalidConfiguration, "The server endpoint is not an HTTPS address")
    }
    let resolved = try await resolve(override: incusOverride, timeout: timeout, deadline: deadline)
    let incus = resolved.executable
    let previousDefault = try await incusDefault(incus, timeout: timeout, deadline: deadline)
    let remotes = try await incusRemotes(incus, timeout: timeout, deadline: deadline)
    let existed = remotes[remote] != nil
    if let existing = remotes[remote] {
      if let conflict = remoteConflict(remote, existing, server: server) { throw conflict }
    } else {
      try await enroll(
        incus, remote: remote, server: server, endpoint: endpoint,
        stateDirectory: stateDirectory, timeout: timeout, deadline: deadline)
    }
    var selectedDefault = previousDefault
    if setDefault {
      try await requireSuccess(
        executable: incus, arguments: ["remote", "switch", remote],
        timeout: timeout, deadline: deadline, failure: "incus remote switch failed")
      selectedDefault = remote
    } else if let previousDefault {
      let current = try await incusDefault(incus, timeout: timeout, deadline: deadline)
      if current != previousDefault {
        try await requireSuccess(
          executable: incus, arguments: ["remote", "switch", previousDefault],
          timeout: timeout, deadline: deadline,
          failure: "Cannot restore the previous default remote")
      }
      selectedDefault = previousDefault
    }
    try await verifyServer(
      incus, remote: remote, endpoint: endpoint, existed: existed, timeout: timeout,
      deadline: deadline)
    try await requireSuccess(
      executable: incus, arguments: ["list", "\(remote):"], timeout: timeout,
      deadline: deadline, failure: "incus list could not use the registered remote")
    try finishWithin(deadline)
    return IncusSetupResult(
      address: server.address, connected: true, isDefault: selectedDefault == remote,
      executable: incus, installed: resolved.installed, remote: remote,
      onPath: pathContains(URL(fileURLWithPath: incus).deletingLastPathComponent())
    )
  }

  /// The conflict an existing `remote` would cause for the server at `url`, if any. Reads only.
  func existingRemoteConflict(
    executable: String, remote: String, url: String, timeout: Int,
    deadline: ContinuousClock.Instant? = nil
  ) async throws -> RuntimeError? {
    guard let server = RemoteServer(url) else { return nil }
    let remotes = try await incusRemotes(executable, timeout: timeout, deadline: deadline)
    guard let existing = remotes[remote] else { return nil }
    return remoteConflict(remote, existing, server: server)
  }

  private func remoteConflict(_ remote: String, _ addresses: [String], server: RemoteServer)
    -> RuntimeError?
  {
    if let legacy = addresses.first(where: { $0.hasPrefix("unix:") }) {
      return RuntimeError(
        .conflict,
        "Remote \(remote) is a direct-socket registration (\(terminalSafe(legacy))) from an earlier macus. macus does not change it: keep it and choose another name with --remote, or remove it yourself with incus remote remove \(remote) and rerun."
      )
    }
    guard addresses.contains(where: { RemoteServer($0) == server }) else {
      return RuntimeError(
        .conflict,
        "Remote \(remote) already points at a different address. macus does not overwrite it; choose another name with --remote."
      )
    }
    return nil
  }

  private func enroll(
    _ incus: String, remote: String, server: RemoteServer, endpoint: GatewayEndpoint,
    stateDirectory: URL, timeout: Int, deadline: ContinuousClock.Instant?
  ) async throws {
    // The certificate incus presents for a new remote; incus creates it when there is none.
    let certificate = try await requireSuccess(
      executable: incus, arguments: ["remote", "get-client-certificate"], timeout: timeout,
      deadline: deadline, failure: "incus could not report its client certificate")
    guard
      let client = pemCertificateFingerprint(String(decoding: certificate.stdout, as: UTF8.self))
    else { throw RuntimeError(.io, "incus reported a malformed client certificate") }
    if try GatewayTrust(stateDirectory: stateDirectory).trusts(client) {
      try await requireSuccess(
        executable: incus, arguments: ["remote", "add", remote, server.address],
        input: Data((endpoint.fingerprint + "\n").utf8), timeout: timeout, deadline: deadline,
        failure: "incus remote add failed")
      return
    }
    let tokens = TrustTokenStore(stateDirectory: stateDirectory)
    let issued = try tokens.issueBound(
      name: "incus-remote-\(remote)", addresses: [server.authority],
      serverFingerprint: endpoint.fingerprint, clientFingerprint: client,
      expiresAt: Date().addingTimeInterval(TimeInterval(Self.enrollmentLifetime)))
    do {
      try await requireSuccess(
        executable: incus, arguments: ["remote", "add", remote, issued.token], timeout: timeout,
        deadline: deadline, failure: "incus remote add failed")
    } catch {
      // An unredeemed token is useless to anyone else, but is not left valid either.
      _ = try? tokens.revoke(id: issued.summary.id)
      throw error
    }
  }

  /// How long a client-setup enrollment token stays valid.
  static let enrollmentLifetime = 300

  private func verifyServer(
    _ incus: String, remote: String, endpoint: GatewayEndpoint, existed: Bool, timeout: Int,
    deadline: ContinuousClock.Instant?
  ) async throws {
    let guidance =
      existed
      ? " Remote \(remote) was left unchanged; if it belongs to an earlier server identity, remove it with incus remote remove \(remote) and rerun."
      : ""
    let result = try await run(
      executable: incus, arguments: ["query", "\(remote):/1.0"], environment: environment,
      input: Data(), timeout: timeout, deadline: deadline)
    guard result.status == 0 else {
      throw RuntimeError(
        .unavailable,
        "incus could not verify the server behind remote \(remote)\(detail(result)).\(guidance)")
    }
    guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
      let environment = object["environment"] as? [String: Any],
      let certificate = environment["certificate"] as? String
    else { throw RuntimeError(.io, "incus query returned a malformed server description") }
    guard pemCertificateFingerprint(certificate) == endpoint.fingerprint else {
      throw RuntimeError(
        .conflict,
        "Remote \(remote) reached a server whose certificate is not this state's gateway certificate.\(guidance)"
      )
    }
    guard object["auth"] as? String == "trusted" else {
      throw RuntimeError(
        .unavailable,
        "The server does not trust the client certificate of remote \(remote).\(guidance)")
    }
  }

  private func installedIncus(
    brew: String, timeout: Int, deadline: ContinuousClock.Instant?
  ) async throws -> String? {
    for arguments in [["--prefix"], ["--prefix", "incus"]] {
      let result = try await run(
        executable: brew, arguments: arguments, environment: environment, timeout: timeout,
        deadline: deadline)
      guard result.status == 0,
        let prefix = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines), isAbsoluteExecutablePath(prefix)
      else { continue }
      let candidate = URL(fileURLWithPath: prefix).appendingPathComponent("bin/incus").path
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  private func incusRemotes(
    _ executable: String, timeout: Int, deadline: ContinuousClock.Instant?
  ) async throws -> [String: [String]] {
    let result = try await requireSuccess(
      executable: executable, arguments: ["remote", "list", "--format", "json"], timeout: timeout,
      deadline: deadline, failure: "incus remote list failed")
    guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
    else {
      throw RuntimeError(.io, "incus remote list returned malformed JSON")
    }
    var remotes: [String: [String]] = [:]
    for (name, value) in object {
      let info = value as? [String: Any]
      remotes[name] = info?["Addrs"] as? [String] ?? []
    }
    return remotes
  }

  private func incusDefault(
    _ executable: String, timeout: Int, deadline: ContinuousClock.Instant?
  ) async throws -> String? {
    let result = try await run(
      executable: executable, arguments: ["remote", "get-default"], environment: environment,
      input: Data(), timeout: timeout, deadline: deadline)
    guard result.status == 0,
      let text = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines), !text.isEmpty
    else {
      throw RuntimeError(
        .io, "Cannot read the existing Incus default remote; configuration was not changed")
    }
    return text
  }

  /// Runs an incus command, by default with an empty standard input so a prompt ends instead of
  /// waiting on the terminal.
  @discardableResult
  private func requireSuccess(
    executable: String, arguments: [String], input: Data = Data(), timeout: Int,
    deadline: ContinuousClock.Instant?, failure: String
  ) async throws -> LocalCommandResult {
    let result = try await run(
      executable: executable, arguments: arguments, environment: environment, input: input,
      timeout: timeout, deadline: deadline)
    guard result.status == 0 else { throw RuntimeError(.io, "\(failure)\(detail(result))") }
    return result
  }

  private func detail(_ result: LocalCommandResult) -> String {
    let text = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return text.isEmpty ? "" : ": \(terminalSafe(String(text.prefix(500))))"
  }

  private func run(
    executable: String, arguments: [String], environment: [String: String], input: Data? = nil,
    timeout: Int, deadline: ContinuousClock.Instant?
  ) async throws -> LocalCommandResult {
    let limit = try childTimeout(timeout, deadline: deadline)
    return try await runner.run(
      executable: executable, arguments: arguments, environment: environment, timeout: limit,
      input: input)
  }

  /// Whole seconds still inside the original deadline. Nil keeps each client-setup command on its
  /// own timeout. A partial second is not rounded up into a new second.
  private func childTimeout(_ fallback: Int, deadline: ContinuousClock.Instant?) throws -> Int {
    guard let deadline else { return fallback }
    try Task.checkCancellation()
    let now = ContinuousClock.now
    guard now < deadline else { throw RuntimeError(.timeout, "Startup deadline exceeded") }
    let whole = now.duration(to: deadline).components.seconds
    guard whole >= 1 else { throw RuntimeError(.timeout, "Startup deadline exceeded") }
    return min(fallback, Int(whole))
  }

  private func finishWithin(_ deadline: ContinuousClock.Instant?) throws {
    if let deadline, ContinuousClock.now >= deadline {
      throw RuntimeError(.timeout, "Startup deadline exceeded")
    }
  }

  private func pathContains(_ directory: URL) -> Bool {
    let path = environment["PATH"] ?? ""
    return path.split(separator: ":").contains { candidate in
      URL(fileURLWithPath: String(candidate)).standardizedFileURL.path
        == directory.standardizedFileURL.path
    }
  }
}

func brewExecutable(environment: [String: String]) -> String? {
  if let found = executable(named: "brew", path: environment["PATH"] ?? "") { return found }
  guard environment["MACUS_BREW_FALLBACK"] != "0" else { return nil }
  for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

func executable(named name: String, path: String) -> String? {
  for directory in path.split(separator: ":") where !directory.isEmpty {
    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

/// An Incus HTTPS remote address reduced to what identifies the server: lowercase host and port
/// (8443, the Incus default, when absent).
struct RemoteServer: Sendable, Equatable {
  let host: String
  let port: Int

  init?(_ url: URL) { self.init(url.absoluteString) }

  init?(_ address: String) {
    guard let components = URLComponents(string: address), components.scheme == "https",
      let host = components.host?.lowercased(), !host.isEmpty, components.user == nil,
      components.password == nil, components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else { return nil }
    let port = components.port ?? 8_443
    guard (1...65_535).contains(port) else { return nil }
    self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
    self.port = port
  }

  /// `host:port`, bracketing an IPv6 host, as an enrollment token lists it.
  var authority: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }
  /// The address registered with `incus remote add`.
  var address: String { "https://\(authority)" }
}

func isAbsoluteExecutablePath(_ path: String) -> Bool {
  path.hasPrefix("/") && !path.utf8.contains(0) && !path.contains("\n") && !path.contains("\r")
}

struct ReadyRuntimeStatus {
  let apiVersion: Int
  let state: String
}

/// The runtime status from the public server, which must report a ready runtime.
@discardableResult
func readyRuntimeStatus(
  directory: URL, timeout: Int, gateway: any GatewayTransport, command: String
) async throws -> ReadyRuntimeStatus {
  let response = try await gatewayRequest(
    "GET", "/runtime/status", directory: directory, timeout: timeout, transport: gateway)
  let object = try jsonObject(response.body)
  guard let api = jsonInt(object["api_version"]), let state = jsonString(object["state"]) else {
    throw RuntimeError(.io, "Malformed runtime status")
  }
  guard api == 1 else {
    throw RuntimeError(
      .invalidConfiguration,
      "Incompatible runtime API version \(api); this macus client supports version 1")
  }
  guard state == "ready", jsonBool(object["runtime_ready"]) != false else {
    throw RuntimeError(
      .unavailable,
      "Runtime is \(state), not ready. macus \(command) does not start the appliance; run macus runtime start"
    )
  }
  return ReadyRuntimeStatus(apiVersion: api, state: state)
}
