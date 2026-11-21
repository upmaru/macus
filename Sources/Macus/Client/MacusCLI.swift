import Foundation

public struct MacusStreams: Sendable {
  public var writeOutput: @Sendable (String) -> Void
  public var writeError: @Sendable (String) -> Void

  public var stdoutIsTTY = false
  public var stderrIsTTY = false

  public static let standard = MacusStreams(
    writeOutput: { text in
      try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    },
    writeError: { text in
      try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    },
    stdoutIsTTY: isatty(STDOUT_FILENO) == 1,
    stderrIsTTY: isatty(STDERR_FILENO) == 1
  )
}

/// Thin local grammar and request orchestration for the `macus` executable.
///
/// Read-only commands never create state, boot the appliance, install software, or mutate Incus.
/// Workload operations belong to the standard incus client.
public enum MacusCLI {
  public static let defaultRemoteName = "macus"
  public static let readOnlyTimeout = 10
  public static let lifecycleTimeout = 650
  public static let startTimeout = 1_800

  public static func run(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    transport: any LocalHTTPTransport = UnixHTTPClient(),
    gateway: any GatewayTransport = HTTPSGatewayClient(),
    streams: MacusStreams = .standard
  ) async -> Int32 {
    await run(
      arguments: arguments, environment: environment, transport: transport, gateway: gateway,
      streams: streams, overrides: StartupOverrides())
  }

  static func run(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    transport: any LocalHTTPTransport = UnixHTTPClient(),
    gateway: any GatewayTransport = HTTPSGatewayClient(),
    streams: MacusStreams = .standard,
    overrides: StartupOverrides
  ) async -> Int32 {
    let json = requestsJSON(arguments)
    do {
      if arguments.isEmpty || arguments == ["--help"] {
        streams.writeOutput(helpText)
        return 0
      }
      if arguments.first == "serve" {
        try await Daemon.run(arguments: arguments, environment: environment, streams: streams)
        return 0
      }
      let invocation = try parse(arguments)
      let directory: URL
      if case .capabilities = invocation.command {
        directory = URL(fileURLWithPath: "/")
      } else {
        directory = try stateDirectory(flag: invocation.stateDirectory, environment: environment)
      }
      let timeout = invocation.timeout ?? defaultTimeout(invocation.command)
      try await execute(
        invocation.command, directory: directory, timeout: timeout, json: invocation.json,
        environment: environment, transport: transport, gateway: gateway,
        runner: ProcessCommandRunner(), streams: streams, overrides: overrides)
      return 0
    } catch let error as UsageError {
      emit(
        RuntimeError(.invalidRequest, error.message), json: json, streams: streams,
        environment: environment)
      return 2
    } catch let error as StartupInterrupted {
      emitInterrupted(
        error, json: json, streams: streams, environment: environment,
        commands: recoveryCommands(arguments: arguments, environment: environment))
      return 130
    } catch is ReportedDiagnosis {
      return 1
    } catch let error as RuntimeError {
      emit(
        error, json: json, streams: streams, environment: environment,
        commands: recoveryCommands(arguments: arguments, environment: environment))
      return arguments.first == "serve" && error.code == .invalidRequest ? 2 : 1
    } catch {
      emit(
        RuntimeError(.io, error.localizedDescription), json: json, streams: streams,
        environment: environment)
      return 1
    }
  }

  /// Resolves the flag, Macus environment, legacy environment, then the existing default.
  /// This does not create, chmod or stat the directory.
  public static func stateDirectory(flag: String?, environment: [String: String]) throws -> URL {
    if let flag {
      guard isAbsolute(flag) else {
        throw RuntimeError(.invalidRequest, "--state-dir requires an absolute path")
      }
      return URL(fileURLWithPath: flag, isDirectory: true)
    }
    let key = environment["MACUS_STATE_DIR"] != nil ? "MACUS_STATE_DIR" : "TIM_STATE_DIR"
    if let env = environment[key] {
      guard isAbsolute(env) else {
        throw RuntimeError(.invalidConfiguration, "\(key) must be an absolute path")
      }
      return URL(fileURLWithPath: env, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(
      ".tama/incus-mac", isDirectory: true)
  }

  public static var helpText: String {
    """
    macus — native macOS Incus host

    Usage: macus [--state-dir ABSOLUTE_PATH] [--json] [--timeout SECONDS] <command>

    Startup:
      start [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH] [--progress auto|plain|none]
        Prepare the appliance, wait for readiness and connect the Incus client.

    Inspection:
      runtime status    Observe the outer runtime.
      doctor            Diagnose live runtime, host and guest health.
      capabilities      Report host support; add --json for machine output.

    Lifecycle:
      runtime start     Boot an existing appliance.
      runtime stop [--force]
      runtime restart
      serve [--state-dir ABSOLUTE_PATH]    Own the daemon in this terminal.

    Client:
      client setup [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH]

    Server administration (owner-local; never starts services or touches VM disks):
      server config show              Show the gateway listener configuration.
      server config set [--bind-address IP] [--port PORT] [--advertised-url URL]
                        [--certificate-file ABSOLUTE_PATH --key-file ABSOLUTE_PATH]
        Change STATE/server/gateway.json; the server reads it when it next starts.
      server config reset             Return to loopback 127.0.0.1:8443 defaults.
      server token issue --principal NAME --scope SCOPE [--scope SCOPE ...]
                         [--expires-in DURATION] --output ABSOLUTE_PATH
        Issue a scoped bearer token into a new 0600 file. The token is never printed.
      server token list               List tokens without secrets or verifiers.
      server token revoke ID          Refuse a token from the server's next request.
      server trust token issue --name NAME --address HOST:PORT [--address HOST:PORT ...]
                         --server-certificate ABSOLUTE_PATH [--expires-in DURATION]
                         --output ABSOLUTE_PATH
        Issue a single-use enrollment token for `incus remote add` into a new 0600 file.
        It expires after 1 hour by default and at most 30 days. It is never printed.
      server trust token list         List enrollment tokens and their redemption.
      server trust token revoke ID    Refuse an unredeemed enrollment token.

    Common examples:
      macus start
      macus runtime status
      macus doctor --json
      macus capabilities --json
      macus --state-dir /tmp/macus-demo start --progress plain
      macus client setup --remote macus
      macus server config set --bind-address 192.168.1.20 \\
        --advertised-url https://macus.example.net:8443 \\
        --certificate-file ~/certs/macus.pem --key-file ~/certs/macus.key
      macus server token issue --principal laptop --scope incus.read --output ~/macus.token
      macus server trust token issue --name laptop --address macus.example.net:8443 \\
        --server-certificate ~/gateway.crt --output ~/laptop.trust-token

    Options:
      --json            Machine results on stdout, errors on stderr.
      --progress auto|plain|none    Startup progress on stderr.
      --state-dir ABSOLUTE_PATH    Select existing or isolated state.
      --timeout SECONDS           Set a bounded deadline.

    start is the high-level first-use command. It prepares the pinned appliance,
    activates the per-user runtime and server jobs when needed, creates an absent
    runtime, waits for live Incus readiness, and registers the standard incus client.
    It does not install Homebrew or require sudo. serve, runtime, doctor and client setup remain
    explicit lower-level commands and do not download an appliance or activate a service.

    The outer runtime is the Apple VZ appliance. runtime commands and doctor use
    the Macus server's pinned HTTPS endpoint and never install software or boot implicitly.
    Workload operations belong to the standard incus client. client setup registers
    that client with the server's HTTPS endpoint and enrolls its certificate. The default
    remote name is \(defaultRemoteName). Existing remotes are never changed, and
    --set-default is required to change the selected default.
    If incus is not on PATH, setup installs the official Homebrew formula incus
    when Homebrew is already installed. It does not install Homebrew.

    serve runs the foreground daemon; capabilities reports host support without booting.
    Serve flags follow serve. Other commands accept global flags around the command.
    State directory: --state-dir, then MACUS_STATE_DIR, then legacy TIM_STATE_DIR,
    then ~/.tama/incus-mac. The existing default preserves appliance data.
    Selecting a state directory does not create it. Invalid flags fail before
    networking or installation. Timeout is \(readOnlyTimeout) seconds for read-only
    requests and \(lifecycleTimeout) seconds for runtime start, stop, restart and
    client setup (1...3600). macus start defaults to \(startTimeout) seconds, still within
    1...3600, and uses one deadline across download, boot, the expected kernel restart and
    client setup. A restart or Homebrew install may need a larger value.
    Bearer scopes: incus.read, incus.write, incus.exec, incus.delete, runtime.read,
    runtime.write and runtime.delete, plus incus.native.read, incus.native.write,
    incus.native.delete and incus.native.admin for the native client operations, which no
    other scope implies and which are granted only when named. DURATION is a
    count with s, m, h or d (1 minute to 3650 days); without it a token does not expire.
    Tokens live in STATE/server/bearer-tokens.json as SHA-256 verifiers. macus start
    prepares the local CLI's own runtime token once in STATE/server/local-cli.token;
    revoke its macus-local-cli record to rotate it at the next start. The gateway never
    binds 0.0.0.0 or ::, and a non-loopback --bind-address needs --advertised-url and a
    certificate naming that host.
    --progress auto animates only on an interactive terminal; plain and JSON avoid cursor
    escapes. --progress none suppresses progress. Exit status is 0 on success, 1 on
    operational failure, 2 on invalid arguments and 130 when start is interrupted.

    """
  }
}

private struct ReportedDiagnosis: Error {}

private struct UsageError: Error {
  let message: String
}

private enum Command {
  case capabilities
  case runtimeStatus
  case runtimeStart
  case runtimeStop(force: Bool)
  case runtimeRestart
  case doctor
  case clientSetup(remote: String, setDefault: Bool, incus: String?)
  case start(remote: String, setDefault: Bool, incus: String?, progress: ProgressSelection)
  case serverConfigShow
  case serverConfigSet(GatewayConfigurationChange)
  case serverConfigReset
  case serverTokenIssue(principal: String, scopes: [String], expiresIn: Int?, output: String)
  case serverTokenList
  case serverTokenRevoke(id: String)
  case serverTrustTokenIssue(
    name: String, addresses: [String], serverCertificate: String, expiresIn: Int, output: String)
  case serverTrustTokenList
  case serverTrustTokenRevoke(id: String)
}

private struct Invocation {
  var stateDirectory: String?
  var json: Bool
  var timeout: Int?
  var command: Command
}

private func requestsJSON(_ arguments: [String]) -> Bool {
  var index = 0
  while index < arguments.count {
    let token = arguments[index]
    if token == "--json" { return true }
    if token == "--timeout" || token == "--state-dir" || token == "--remote"
      || token == "--incus" || token == "--progress" || token == "--principal"
      || token == "--scope" || token == "--expires-in" || token == "--output"
      || token == "--name" || token == "--address" || token == "--server-certificate"
      || token == "--bind-address" || token == "--port" || token == "--advertised-url"
      || token == "--certificate-file" || token == "--key-file"
    {
      index += 2
      continue
    }
    index += 1
  }
  return false
}

private func isAbsolute(_ path: String) -> Bool {
  path.hasPrefix("/") && !path.utf8.contains(0) && !path.contains("\n") && !path.contains("\r")
}

private func defaultTimeout(_ command: Command) -> Int {
  switch command {
  case .runtimeStart, .runtimeStop, .runtimeRestart, .clientSetup: MacusCLI.lifecycleTimeout
  case .start: MacusCLI.startTimeout
  case .capabilities, .runtimeStatus, .doctor, .serverConfigShow, .serverConfigSet,
    .serverConfigReset, .serverTokenIssue, .serverTokenList, .serverTokenRevoke,
    .serverTrustTokenIssue, .serverTrustTokenList, .serverTrustTokenRevoke:
    MacusCLI.readOnlyTimeout
  }
}

private func parse(_ arguments: [String]) throws -> Invocation {
  var index = 0
  var json = false
  var timeout: Int?
  var stateDirectory: String?
  var force = false
  var setDefault = false
  var remote: String?
  var incusOverride: String?
  var progress: String?
  var principal: String?
  var scopes: [String] = []
  var expiresIn: Int?
  var output: String?
  var name: String?
  var addresses: [String] = []
  var serverCertificate: String?
  var gateway = GatewayConfigurationChange()
  var positionals: [String] = []
  func value(for flag: String) throws -> String {
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
      throw UsageError(message: "\(flag) requires a value")
    }
    index += 1
    return arguments[index]
  }
  while index < arguments.count {
    let token = arguments[index]
    switch token {
    case "--json":
      guard !json else { throw UsageError(message: "Duplicate --json") }
      json = true
    case "--timeout":
      guard timeout == nil else { throw UsageError(message: "Duplicate --timeout") }
      let raw = try value(for: "--timeout")
      guard raw.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(raw),
        (1...3600).contains(parsed)
      else { throw UsageError(message: "--timeout must be an integer from 1 to 3600") }
      timeout = parsed
    case "--state-dir":
      guard stateDirectory == nil else { throw UsageError(message: "Duplicate --state-dir") }
      let raw = try value(for: "--state-dir")
      guard isAbsolute(raw) else {
        throw UsageError(message: "--state-dir requires an absolute path")
      }
      stateDirectory = raw
    case "--force":
      guard !force else { throw UsageError(message: "Duplicate --force") }
      force = true
    case "--set-default":
      guard !setDefault else { throw UsageError(message: "Duplicate --set-default") }
      setDefault = true
    case "--remote":
      guard remote == nil else { throw UsageError(message: "Duplicate --remote") }
      let raw = try value(for: "--remote")
      try validateRemoteName(raw)
      remote = raw
    case "--incus":
      guard incusOverride == nil else { throw UsageError(message: "Duplicate --incus") }
      let raw = try value(for: "--incus")
      guard isAbsolute(raw) else {
        throw UsageError(message: "--incus requires an absolute path")
      }
      incusOverride = raw
    case "--progress":
      guard progress == nil else { throw UsageError(message: "Duplicate --progress") }
      let raw = try value(for: "--progress")
      guard ProgressSelection(rawValue: raw) != nil else {
        throw UsageError(message: "--progress must be auto, plain or none")
      }
      progress = raw
    case "--principal":
      guard principal == nil else { throw UsageError(message: "Duplicate --principal") }
      principal = try value(for: "--principal")
    case "--scope":
      scopes.append(try value(for: "--scope"))
    case "--expires-in":
      guard expiresIn == nil else { throw UsageError(message: "Duplicate --expires-in") }
      guard let parsed = ServerAdministration.expiry(try value(for: "--expires-in")) else {
        throw UsageError(
          message: "--expires-in must be a count with s, m, h or d, from 1 minute to 3650 days")
      }
      expiresIn = parsed
    case "--output":
      guard output == nil else { throw UsageError(message: "Duplicate --output") }
      let raw = try value(for: "--output")
      guard isAbsolute(raw) else { throw UsageError(message: "--output requires an absolute path") }
      output = raw
    case "--name":
      guard name == nil else { throw UsageError(message: "Duplicate --name") }
      name = try value(for: "--name")
    case "--address":
      addresses.append(try value(for: "--address"))
    case "--server-certificate":
      guard serverCertificate == nil else {
        throw UsageError(message: "Duplicate --server-certificate")
      }
      let raw = try value(for: "--server-certificate")
      guard isAbsolute(raw) else {
        throw UsageError(message: "--server-certificate requires an absolute path")
      }
      serverCertificate = raw
    case "--bind-address":
      guard gateway.bindAddress == nil else {
        throw UsageError(message: "Duplicate --bind-address")
      }
      gateway.bindAddress = try value(for: "--bind-address")
    case "--port":
      guard gateway.port == nil else { throw UsageError(message: "Duplicate --port") }
      let raw = try value(for: "--port")
      guard raw.utf8.count <= 5, raw.utf8.allSatisfy({ (48...57).contains($0) }),
        let parsed = Int(raw), (1...65_535).contains(parsed)
      else { throw UsageError(message: "--port must be an integer from 1 to 65535") }
      gateway.port = parsed
    case "--advertised-url":
      guard gateway.advertisedURL == nil else {
        throw UsageError(message: "Duplicate --advertised-url")
      }
      gateway.advertisedURL = try value(for: "--advertised-url")
    case "--certificate-file":
      guard gateway.certificateFile == nil else {
        throw UsageError(message: "Duplicate --certificate-file")
      }
      let raw = try value(for: "--certificate-file")
      guard isAbsolute(raw) else {
        throw UsageError(message: "--certificate-file requires an absolute path")
      }
      gateway.certificateFile = raw
    case "--key-file":
      guard gateway.keyFile == nil else { throw UsageError(message: "Duplicate --key-file") }
      let raw = try value(for: "--key-file")
      guard isAbsolute(raw) else {
        throw UsageError(message: "--key-file requires an absolute path")
      }
      gateway.keyFile = raw
    default:
      if token.hasPrefix("-") { throw UsageError(message: "Unknown flag \(token)") }
      positionals.append(token)
    }
    index += 1
  }
  let command: Command
  if positionals == ["capabilities"] {
    guard stateDirectory == nil, timeout == nil else {
      throw UsageError(message: "capabilities accepts only --json")
    }
    command = .capabilities
  } else if positionals == ["runtime", "status"] {
    command = .runtimeStatus
  } else if positionals == ["runtime", "start"] {
    command = .runtimeStart
  } else if positionals == ["runtime", "stop"] {
    command = .runtimeStop(force: force)
  } else if positionals == ["runtime", "restart"] {
    command = .runtimeRestart
  } else if positionals == ["doctor"] {
    command = .doctor
  } else if positionals == ["client", "setup"] {
    command = .clientSetup(
      remote: remote ?? MacusCLI.defaultRemoteName, setDefault: setDefault, incus: incusOverride)
  } else if positionals == ["start"] {
    command = .start(
      remote: remote ?? MacusCLI.defaultRemoteName, setDefault: setDefault, incus: incusOverride,
      progress: ProgressSelection(rawValue: progress ?? "auto") ?? .auto)
  } else if positionals == ["server", "config", "show"] {
    command = .serverConfigShow
  } else if positionals == ["server", "config", "set"] {
    guard !gateway.isEmpty else {
      throw UsageError(
        message:
          "server config set requires --bind-address, --port, --advertised-url or --certificate-file with --key-file"
      )
    }
    guard (gateway.certificateFile == nil) == (gateway.keyFile == nil) else {
      throw UsageError(message: "--certificate-file and --key-file are given together")
    }
    command = .serverConfigSet(gateway)
  } else if positionals == ["server", "config", "reset"] {
    command = .serverConfigReset
  } else if positionals == ["server", "token", "issue"] {
    guard let principal else {
      throw UsageError(message: "server token issue requires --principal")
    }
    guard let output else {
      throw UsageError(
        message: "server token issue requires --output, a new private file for the token")
    }
    guard !scopes.isEmpty else {
      throw UsageError(message: "server token issue requires at least one --scope")
    }
    command = .serverTokenIssue(
      principal: principal, scopes: scopes, expiresIn: expiresIn, output: output)
  } else if positionals == ["server", "token", "list"] {
    command = .serverTokenList
  } else if positionals.count == 4, positionals.prefix(3) == ["server", "token", "revoke"] {
    command = .serverTokenRevoke(id: positionals[3])
  } else if positionals == ["server", "trust", "token", "issue"] {
    guard let name else {
      throw UsageError(message: "server trust token issue requires --name")
    }
    guard !addresses.isEmpty else {
      throw UsageError(
        message: "server trust token issue requires --address, a HOST:PORT the client can reach")
    }
    guard let serverCertificate else {
      throw UsageError(
        message: "server trust token issue requires --server-certificate, the gateway certificate")
    }
    guard let output else {
      throw UsageError(
        message: "server trust token issue requires --output, a new private file for the token")
    }
    command = .serverTrustTokenIssue(
      name: name, addresses: addresses, serverCertificate: serverCertificate,
      expiresIn: expiresIn ?? TrustTokenStore.defaultLifetime, output: output)
  } else if positionals == ["server", "trust", "token", "list"] {
    command = .serverTrustTokenList
  } else if positionals.count == 5, positionals.prefix(4) == ["server", "trust", "token", "revoke"]
  {
    command = .serverTrustTokenRevoke(id: positionals[4])
  } else if positionals == ["list"] || positionals.first == "show" {
    throw UsageError(
      message:
        "Unknown command. Workload operations belong to the standard incus client. Run macus --help"
    )
  } else {
    throw UsageError(
      message:
        "Unknown command. Workload operations belong to the standard incus client. Run macus --help"
    )
  }
  if force, case .runtimeStop = command {
  } else if force {
    throw UsageError(message: "--force is only valid with runtime stop")
  }
  if remote != nil || setDefault || incusOverride != nil {
    switch command {
    case .clientSetup, .start: break
    default:
      throw UsageError(
        message: "--remote, --set-default and --incus are only valid with start and client setup")
    }
  }
  if progress != nil {
    if case .start = command {
    } else {
      throw UsageError(message: "--progress is only valid with start")
    }
  }
  if principal != nil || !scopes.isEmpty {
    if case .serverTokenIssue = command {
    } else {
      throw UsageError(message: "--principal and --scope are only valid with server token issue")
    }
  }
  if name != nil || !addresses.isEmpty || serverCertificate != nil {
    if case .serverTrustTokenIssue = command {
    } else {
      throw UsageError(
        message:
          "--name, --address and --server-certificate are only valid with server trust token issue"
      )
    }
  }
  if !gateway.isEmpty {
    if case .serverConfigSet = command {
    } else {
      throw UsageError(
        message:
          "--bind-address, --port, --advertised-url, --certificate-file and --key-file are only valid with server config set"
      )
    }
  }
  if expiresIn != nil || output != nil {
    switch command {
    case .serverTokenIssue, .serverTrustTokenIssue: break
    default:
      throw UsageError(
        message:
          "--expires-in and --output are only valid with server token issue and server trust token issue"
      )
    }
  }
  switch command {
  case .serverConfigShow, .serverConfigSet, .serverConfigReset, .serverTokenIssue,
    .serverTokenList, .serverTokenRevoke, .serverTrustTokenIssue, .serverTrustTokenList,
    .serverTrustTokenRevoke:
    // Local administration has no request deadline to bound.
    guard timeout == nil else {
      throw UsageError(message: "server commands do not accept --timeout")
    }
  default: break
  }
  return Invocation(
    stateDirectory: stateDirectory, json: json, timeout: timeout, command: command)
}

private func execute(
  _ command: Command, directory: URL, timeout: Int, json: Bool, environment: [String: String],
  transport: any LocalHTTPTransport, gateway: any GatewayTransport,
  runner: any LocalCommandRunner, streams: MacusStreams, overrides: StartupOverrides
) async throws {
  let presentation = HumanPresentation(streams: streams, environment: environment)
  switch command {
  case .capabilities:
    let capabilities: HostCapabilities
    if let detect = overrides.capabilities {
      capabilities = await detect()
    } else {
      capabilities = await MainActor.run { CapabilityDetector.detect() }
    }
    let data = try JSON.encoder().encode(capabilities)
    if json {
      streams.writeOutput(String(decoding: data, as: UTF8.self) + "\n")
    } else {
      presentation.capabilities(try jsonObject(data))
    }
  case .runtimeStatus:
    let response = try await gatewayRequest(
      "GET", "/runtime/status", directory: directory, timeout: timeout, transport: gateway)
    if json {
      streams.writeOutput(try jsonText(jsonObject(response.body)))
    } else {
      presentation.runtime(try jsonObject(response.body), directory: directory)
    }
  case .runtimeStart:
    let response = try await gatewayRequest(
      "POST", "/runtime/start", directory: directory, timeout: timeout, transport: gateway)
    if json {
      streams.writeOutput(try jsonText(jsonObject(response.body)))
    } else {
      presentation.runtime(try jsonObject(response.body), directory: directory)
    }
  case .runtimeStop(let force):
    // The public API asks for an explicit confirmation of a forced stop.
    let body: [String: Any] = force ? ["force": true, "confirm": "force-stop"] : ["force": false]
    let response = try await gatewayRequest(
      "POST", "/runtime/stop", try jsonData(body), directory: directory, timeout: timeout,
      transport: gateway)
    if json {
      streams.writeOutput(try jsonText(jsonObject(response.body)))
    } else {
      presentation.runtime(try jsonObject(response.body), directory: directory)
    }
  case .runtimeRestart:
    let response = try await gatewayRequest(
      "POST", "/runtime/restart", directory: directory, timeout: timeout, transport: gateway)
    if json {
      streams.writeOutput(try jsonText(jsonObject(response.body)))
    } else {
      presentation.runtime(try jsonObject(response.body), directory: directory)
    }
  case .clientSetup(let remote, let setDefault, let incus):
    let result = try await IncusClientService(
      runner: overrides.runner ?? runner, streams: streams, environment: environment
    ).setup(
      remote: remote, setDefault: setDefault, incusOverride: incus, directory: directory,
      timeout: timeout, gateway: gateway)
    let object = clientResultObject(result)
    if json { streams.writeOutput(try jsonText(object)) } else { presentation.client(result) }
  case .doctor:
    try await doctor(
      directory: directory, timeout: timeout, json: json, gateway: gateway, streams: streams,
      presentation: presentation)
  case .start(let remote, let setDefault, let incus, let progress):
    try await runStart(
      directory: directory, remote: remote, setDefault: setDefault, incusOverride: incus,
      progress: progress, timeout: timeout, json: json, environment: environment,
      transport: transport, gateway: gateway, runner: runner, streams: streams,
      overrides: overrides)
  case .serverConfigShow:
    try ServerAdministration.showConfiguration(
      directory: directory, json: json, streams: streams, presentation: presentation)
  case .serverConfigSet(let change):
    try ServerAdministration.setConfiguration(
      change, directory: directory, json: json, streams: streams, presentation: presentation)
  case .serverConfigReset:
    try ServerAdministration.resetConfiguration(
      directory: directory, json: json, streams: streams, presentation: presentation)
  case .serverTokenIssue(let principal, let scopes, let expiresIn, let output):
    try ServerAdministration.issue(
      principal: principal, scopes: scopes, expiresIn: expiresIn, output: output,
      directory: directory, json: json, streams: streams, presentation: presentation)
  case .serverTokenList:
    try ServerAdministration.list(
      directory: directory, json: json, streams: streams, presentation: presentation)
  case .serverTokenRevoke(let id):
    try ServerAdministration.revoke(
      id: id, directory: directory, json: json, streams: streams, presentation: presentation)
  case .serverTrustTokenIssue(
    let name, let addresses, let serverCertificate, let expiresIn, let output):
    try ServerAdministration.issueTrustToken(
      name: name, addresses: addresses, serverCertificate: serverCertificate,
      expiresIn: expiresIn, output: output, directory: directory, json: json, streams: streams,
      presentation: presentation)
  case .serverTrustTokenList:
    try ServerAdministration.listTrustTokens(
      directory: directory, json: json, streams: streams, presentation: presentation)
  case .serverTrustTokenRevoke(let id):
    try ServerAdministration.revokeTrustToken(
      id: id, directory: directory, json: json, streams: streams, presentation: presentation)
  }
}

private func clientResultObject(_ result: IncusSetupResult) -> [String: Any] {
  [
    "address": result.address,
    "connected": result.connected,
    "default": result.isDefault,
    "incus": result.executable,
    "installed": result.installed,
    "remote": result.remote,
  ]
}

private func validateRemoteName(_ name: String) throws {
  guard let first = name.utf8.first, (1...63).contains(name.utf8.count),
    isASCIIAlphanumeric(first),
    name.utf8.dropFirst().allSatisfy({ isRemoteByte($0) }),
    name != ".", name != ".."
  else { throw UsageError(message: "--remote must be a single name without path characters") }
}

private func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
  (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
}

private func isRemoteByte(_ byte: UInt8) -> Bool {
  isASCIIAlphanumeric(byte) || byte == 45 || byte == 46 || byte == 95
}

private func doctor(
  directory: URL, timeout: Int, json: Bool, gateway: any GatewayTransport,
  streams: MacusStreams,
  presentation: HumanPresentation
) async throws {
  let statusResponse = try await gatewayRequest(
    "GET", "/runtime/status", directory: directory, timeout: timeout, transport: gateway)
  let status = try jsonObject(statusResponse.body)
  var capabilities: [String: Any]?
  var health: [String: Any]?
  var observations: [String: String] = [:]
  do {
    let response = try await gatewayRequest(
      "GET", "/runtime/capabilities", directory: directory, timeout: timeout, transport: gateway)
    capabilities = try jsonObject(response.body)
  } catch {
    observations["host"] = (error as? RuntimeError)?.message ?? error.localizedDescription
  }
  do {
    let response = try await gatewayRequest(
      "GET", "/runtime/health", directory: directory, timeout: timeout, transport: gateway)
    health = try jsonObject(response.body)
  } catch {
    observations["guest"] = (error as? RuntimeError)?.message ?? error.localizedDescription
  }
  let report: [String: Any] = [
    "capabilities": capabilities ?? NSNull(),
    "health": health ?? NSNull(),
    "status": status,
  ]
  if json {
    streams.writeOutput(try jsonText(report))
  } else {
    presentation.doctor(
      status: status, capabilities: capabilities, health: health,
      directory: directory,
      error: readinessError(status: status, capabilities: capabilities, health: health),
      observations: observations)
  }
  if let error = readinessError(status: status, capabilities: capabilities, health: health) {
    if !json { throw ReportedDiagnosis() }
    throw error
  }
}

private func readinessError(
  status: [String: Any], capabilities: [String: Any]?, health: [String: Any]?
) -> RuntimeError? {
  let state = jsonString(status["state"]) ?? "unknown"
  if jsonInt(status["api_version"]) != 1 {
    return RuntimeError(
      .invalidConfiguration,
      "Incompatible runtime API version. This macus client supports API version 1.")
  }
  if state != "ready" {
    return RuntimeError(
      .unavailable,
      "Runtime is \(state) and not ready. macus doctor does not start or repair the VM; run macus runtime start to boot it."
    )
  }
  if jsonBool(capabilities?["supported"]) != true {
    return RuntimeError(
      .unavailable,
      "Host virtualization is not supported. macus doctor does not change host configuration."
    )
  }
  if jsonInt(health?["protocol_version"]) != 1 {
    return RuntimeError(
      .unavailable,
      "Guest health protocol is unavailable or incompatible. macus doctor does not repair the guest."
    )
  }
  return nil
}

func responseFailure(status: Int, body: Data) -> RuntimeError {
  if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
    let error = object["error"] as? [String: Any], let code = jsonString(error["code"]),
    let message = jsonString(error["message"]), let parsed = RuntimeError.Code(rawValue: code)
  {
    return RuntimeError(parsed, message)
  }
  let incus = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
    .flatMap { jsonString($0["error"]) }
  let message = incus ?? "Local API request failed with HTTP \(status)"
  return RuntimeError(code(for: status), message)
}

private func code(for status: Int) -> RuntimeError.Code {
  switch status {
  case 400: .invalidRequest
  case 404: .notFound
  case 409: .conflict
  case 408, 504: .timeout
  case 503: .unavailable
  default: .io
  }
}

func emitInterrupted(
  _ error: StartupInterrupted, json: Bool, streams: MacusStreams,
  environment: [String: String] = [:], commands: [String] = []
) {
  if json,
    let text = try? jsonText(["error": ["code": "interrupted", "message": error.message]])
  {
    streams.writeError(text)
    return
  }
  HumanPresentation(streams: streams, environment: environment, error: true).failure(
    error.message, code: "interrupted", commands: commands)
}

private func emit(
  _ error: RuntimeError, json: Bool, streams: MacusStreams,
  environment: [String: String], commands: [String] = []
) {
  if json,
    let text = try? jsonText(["error": ["code": error.code.rawValue, "message": error.message]])
  {
    streams.writeError(text)
    return
  }
  HumanPresentation(streams: streams, environment: environment, error: true).failure(
    error.message, code: error.code.rawValue,
    commands: error.code == .invalidRequest ? ["macus --help"] : commands)
}

private func recoveryCommands(arguments: [String], environment: [String: String]) -> [String] {
  guard let invocation = try? parse(arguments),
    let directory = try? MacusCLI.stateDirectory(
      flag: invocation.stateDirectory, environment: environment)
  else { return [] }
  if case .start = invocation.command {
    return [
      shellCommand(["macus", "--state-dir", directory.path, "runtime", "status"]),
      shellCommand(["macus", "--state-dir", directory.path, "runtime", "stop"]),
    ]
  }
  return []
}

func terminalSafe(_ value: String) -> String {
  var output = ""
  for scalar in value.unicodeScalars {
    if scalar.properties.generalCategory == .control || scalar.value == 127
      || (0x2028...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    {
      output += String(format: "\\u{%04X}", scalar.value)
    } else {
      output.unicodeScalars.append(scalar)
    }
  }
  return output
}

func jsonObject(_ data: Data) throws -> [String: Any] {
  do {
    let value = try JSONSerialization.jsonObject(with: data)
    guard let object = value as? [String: Any] else {
      throw RuntimeError(.io, "Malformed JSON object")
    }
    return object
  } catch let error as RuntimeError {
    throw error
  } catch {
    throw RuntimeError(.io, "Malformed JSON response")
  }
}

private func jsonData(_ object: [String: Any]) throws -> Data {
  do { return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) } catch {
    throw RuntimeError(.io, "Cannot encode JSON request")
  }
}

func jsonText(_ value: Any) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  guard var text = String(data: data, encoding: .utf8) else {
    throw RuntimeError(.io, "Cannot encode JSON output")
  }
  if !text.hasSuffix("\n") { text.append("\n") }
  return text
}

func jsonString(_ value: Any?) -> String? { value as? String }

func jsonInt(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber, !isJSONBool(number) else { return nil }
  return number.intValue
}

func jsonBool(_ value: Any?) -> Bool? {
  guard let number = value as? NSNumber, isJSONBool(number) else { return nil }
  return number.boolValue
}

private func isJSONBool(_ number: NSNumber) -> Bool {
  CFGetTypeID(number) == CFBooleanGetTypeID()
}
