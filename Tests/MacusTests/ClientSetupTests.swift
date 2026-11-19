import Darwin
import Foundation
import Testing

@testable import Macus

@Test func clientSetupEnrollsTheHTTPSServerAndPreservesConfiguration() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeBrew(mode: .install)
  try tools.writeIncus(
    defaultRemote: "other",
    remotes: [
      "local": ["unix://"], "other": ["unix:/tmp/other.sock"],
    ])
  let environment = tools.environment(runtime: runtime)
  let first = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: environment)
  #expect(first.status == 0, "\(first.stderr)")
  #expect(first.stderr.contains("installing official Homebrew formula incus"))
  let body = try jsonObject(first.stdout)
  #expect(body["remote"] as? String == "macus")
  #expect(body["installed"] as? Bool == true)
  #expect(body["connected"] as? Bool == true)
  #expect(body["default"] as? Bool == false)
  #expect((body["incus"] as? String)?.hasSuffix("/prefix/bin/incus") == true)
  #expect(body["address"] as? String == runtime.url)
  let saved = try tools.readState()
  #expect(saved.defaultRemote == "other")
  #expect(saved.remotes["other"] == ["unix:/tmp/other.sock"])
  #expect(saved.remotes["macus"] == [runtime.url])
  #expect(try tools.commands().filter { $0.first == "install" }.count == 1)

  // Standard commands only: the remote was added from a token naming this gateway's certificate
  // and address, bound to the certificate incus presents, which the gateway now trusts.
  let additions = try tools.additions()
  #expect(additions.count == 1)
  let encoded = try #require(additions.first?.last)
  let token = try #require(Data(base64Encoded: encoded))
  let decoded = try #require(try JSONSerialization.jsonObject(with: token) as? [String: Any])
  #expect(decoded["fingerprint"] as? String == runtime.gateway.identity.fingerprint)
  #expect(decoded["addresses"] as? [String] == [runtime.authority])
  #expect(decoded["client_name"] as? String == "incus-remote-macus")
  let records = try runtime.tokens()
  #expect(records.count == 1)
  #expect(records.first?["client_fingerprint"] as? String == FixtureCertificate.client.fingerprint)
  #expect(records.first?["secret"] == nil)
  #expect(
    try runtime.redemptions().map { $0["fingerprint"] as? String }
      == [FixtureCertificate.client.fingerprint])
  #expect(try runtime.trusted() == [FixtureCertificate.client.fingerprint])
  #expect(try tools.incusArguments().contains(["query", "macus:/1.0"]))
  #expect(try tools.incusArguments().last == ["list", "macus:"])
  // Client material stays in the selected INCUS_CONF.
  #expect(
    FileManager.default.fileExists(atPath: tools.conf.appendingPathComponent("client.crt").path))
  #expect(
    FileManager.default.fileExists(
      atPath: tools.conf.appendingPathComponent("servercerts/macus.crt").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: tools.home.path).isEmpty)

  // Setting up the same endpoint again verifies and reuses the remote; only --set-default moves
  // the default.
  let again = try await runMacus(
    [
      "--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup",
      "--set-default",
    ],
    environment: environment)
  #expect(again.status == 0, "\(again.stderr)")
  #expect(try jsonObject(again.stdout)["default"] as? Bool == true)
  #expect(try jsonObject(again.stdout)["address"] as? String == runtime.url)
  #expect(try tools.commands().filter { $0.first == "install" }.count == 1)
  #expect(try tools.additions().count == 1)
  #expect(try runtime.tokens().count == 1)
  #expect(try tools.incusArguments().filter { $0 == ["query", "macus:/1.0"] }.count == 2)
  let switched = try tools.readState()
  #expect(switched.defaultRemote == "macus")
  #expect(switched.remotes["other"] == ["unix:/tmp/other.sock"])
  #expect(switched.remotes["macus"] == [runtime.url])
}

@Test func anAlreadyTrustedClientIsRegisteredByURLWithThePinnedFingerprint() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeIncus(defaultRemote: "local", remotes: ["local": ["unix://"]])
  try tools.publishOnPath()
  let environment = tools.environment(runtime: runtime)
  let first = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: environment)
  #expect(first.status == 0, "\(first.stderr)")
  // The same incus client under another name: its certificate is already trusted, so no token
  // is issued and incus answers its certificate prompt with the gateway's pinned fingerprint.
  let second = try await runMacus(
    [
      "--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup",
      "--remote", "desk",
    ],
    environment: environment)
  #expect(second.status == 0, "\(second.stderr)")
  #expect(try jsonObject(second.stdout)["remote"] as? String == "desk")
  #expect(try tools.additions().last == ["remote", "add", "desk", runtime.url])
  #expect(try runtime.tokens().count == 1)
  #expect(try runtime.trusted() == [FixtureCertificate.client.fingerprint])
  let saved = try tools.readState()
  #expect(saved.remotes["desk"] == [runtime.url])
  #expect(saved.remotes["macus"] == [runtime.url])
  #expect(saved.defaultRemote == "local")
}

@Test func legacyAndForeignRemotesAreConflictsThatChangeNothing() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeBrew(mode: .install)
  try tools.writeIncus(
    defaultRemote: "local",
    remotes: [
      "local": ["unix://"], "macus": ["unix:/tmp/elsewhere.sock"],
      "desk": ["https://192.0.2.4:8443"],
    ])
  try tools.publishOnPath()
  let legacy = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: tools.environment(runtime: runtime))
  #expect(legacy.status == 1)
  #expect(legacy.stdout.isEmpty)
  let error = try #require(jsonObject(legacy.stderr)["error"] as? [String: Any])
  #expect(error["code"] as? String == "conflict")
  let message = try #require(error["message"] as? String)
  #expect(message.contains("direct-socket registration"))
  #expect(message.contains("incus remote remove macus"))
  #expect(message.contains("--remote"))

  let foreign = try await runMacus(
    [
      "--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup",
      "--remote", "desk", "--set-default",
    ],
    environment: tools.environment(runtime: runtime))
  #expect(foreign.status == 1)
  #expect(foreign.stderr.contains("different address"))

  let saved = try tools.readState()
  #expect(saved.remotes["macus"] == ["unix:/tmp/elsewhere.sock"])
  #expect(saved.remotes["desk"] == ["https://192.0.2.4:8443"])
  #expect(saved.defaultRemote == "local")
  #expect(try tools.commands().filter { $0.first == "install" }.isEmpty)
  #expect(try tools.additions().isEmpty)
  #expect(!(try tools.incusArguments().contains { $0.first == "query" }))
  #expect(try runtime.tokens().isEmpty)
  #expect(try runtime.trusted().isEmpty)
}

@Test func stoppedRuntimeChangesNoClientConfiguration() async throws {
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeBrew(mode: .install)
  let stopped = try ScriptedGateway { _, _, _ in mustJSON(200, publicStatus(state: "stopped")) }
  defer { stopped.stop() }
  let blocked = try await runMacus(
    ["--state-dir", stopped.directory.path, "--timeout", "5", "client", "setup"],
    environment: tools.environment())
  #expect(blocked.status == 1)
  #expect(blocked.stderr.contains("not ready"))
  #expect(tools.logText().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: tools.conf.path))
  #expect(
    !FileManager.default.fileExists(
      atPath: stopped.directory.appendingPathComponent("server/trust-tokens.json").path))
}

@Test func aFailedEnrollmentRevokesItsTokenAndRegistersNothing() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeIncus(defaultRemote: "local", remotes: ["local": ["unix://"]])
  try tools.publishOnPath()
  // incus meets a server whose certificate is not the one the token names.
  var environment = tools.environment(runtime: runtime)
  environment["MACUS_FIXTURE_SERVER_CERT"] = tools.environment()["MACUS_FIXTURE_SERVER_CERT"]
  let result = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: environment)
  #expect(result.status == 1)
  #expect(result.stderr.contains("incus remote add failed"))
  #expect(result.stderr.contains("fingerprint mismatch"))
  let records = try runtime.tokens()
  #expect(records.count == 1)
  #expect(records.first?["revoked_at"] is String)
  #expect(try runtime.redemptions().isEmpty)
  #expect(try runtime.trusted().isEmpty)
  #expect(try tools.readState().remotes["macus"] == nil)
}

@Test func anExistingRemoteMustStillVerifyTheServerAndItsTrust() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeIncus(defaultRemote: "local", remotes: ["local": ["unix://"]])
  try tools.publishOnPath()
  let environment = tools.environment(runtime: runtime)
  let first = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: environment)
  #expect(first.status == 0, "\(first.stderr)")

  // The server at that address presents another certificate.
  var impostor = environment
  impostor["MACUS_FIXTURE_QUERY_CERT"] =
    tools.environment(runtime: runtime, query: .other)["MACUS_FIXTURE_QUERY_CERT"]
  let mismatch = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: impostor)
  #expect(mismatch.status == 1)
  #expect(mismatch.stderr.contains("\"conflict\""))
  #expect(mismatch.stderr.contains("not this state's gateway certificate"))
  #expect(mismatch.stderr.contains("incus remote remove macus"))

  // The owner removed the client's gateway trust.
  try runtime.distrustAll()
  let untrusted = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: environment)
  #expect(untrusted.status == 1)
  #expect(untrusted.stderr.contains("does not trust the client certificate"))
  #expect(try tools.additions().count == 1)
  #expect(try runtime.tokens().count == 1)
  #expect(try tools.readState().remotes["macus"] == [runtime.url])
}

@Test func missingHomebrewIsGuidanceAndBrewFailureDoesNotRegister() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let missing = try ToolFixture()
  defer { missing.remove() }
  let absent = try await runMacus(
    ["--state-dir", runtime.directory, "--timeout", "5", "client", "setup"],
    environment: missing.environment(includeBrew: false, runtime: runtime))
  #expect(absent.status == 1)
  #expect(absent.stderr.contains("https://brew.sh"))
  #expect(absent.stderr.contains("does not install Homebrew"))

  let failing = try ToolFixture()
  defer { failing.remove() }
  try failing.writeBrew(mode: .fail)
  try failing.writeIncus(defaultRemote: "local", remotes: ["local": ["unix://"]])
  let failed = try await runMacus(
    ["--state-dir", runtime.directory, "--timeout", "5", "client", "setup"],
    environment: failing.environment(runtime: runtime))
  #expect(failed.status == 1)
  #expect(failed.stderr.contains("Homebrew install of incus failed"))
  #expect(try failing.incusArguments().isEmpty)
}

@Test func brewInstallTimeoutReapsTheChild() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeBrew(mode: .sleep)
  let started = ContinuousClock.now
  let result = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "1", "client", "setup"],
    environment: tools.environment(runtime: runtime))
  #expect(result.status == 1)
  #expect(result.stderr.contains("\"timeout\""))
  #expect(started.duration(to: .now) < .milliseconds(2_500))
  let pidLine = try #require(
    tools.logText().split(separator: "\n").first { $0.hasPrefix("brew-pid:") })
  let pid = try #require(pid_t(pidLine.dropFirst("brew-pid:".count)))
  #expect(kill(pid, 0) == -1)
  #expect(errno == ESRCH)
  #expect(try tools.commands().contains(["install", "incus"]))
}

@Test func explicitIncusOverrideSkipsPathAndHomebrew() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let decoy = try ToolFixture()
  defer { decoy.remove() }
  try decoy.writeBrew(mode: .fail)
  let selected = try ToolFixture()
  defer { selected.remove() }
  try selected.writeIncus(defaultRemote: "local", remotes: ["local": ["unix://"]])
  var environment = selected.environment(includeBrew: false, runtime: runtime)
  environment["PATH"] = "\(decoy.bin.path):/usr/bin:/bin"
  let result = try await runMacus(
    [
      "--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup", "--incus",
      selected.incusPath, "--remote", "desk",
    ], environment: environment)
  #expect(result.status == 0, "\(result.stderr)")
  #expect(try jsonObject(result.stdout)["remote"] as? String == "desk")
  #expect(try jsonObject(result.stdout)["installed"] as? Bool == false)
  #expect(try decoy.commands().isEmpty)
  #expect(try selected.incusArguments().contains(["list", "desk:"]))
}

@Test func unreadableIncusDefaultFailsBeforeRegistration() async throws {
  let runtime = try readyRuntime()
  defer { runtime.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeIncus(defaultRemote: "other", remotes: ["other": ["unix:/tmp/other.sock"]])
  try tools.publishOnPath()
  var environment = tools.environment(includeBrew: false, runtime: runtime)
  environment["PATH"] = "\(tools.bin.path):/usr/bin:/bin"
  environment["MACUS_FIXTURE_DEFAULT_FAIL"] = "1"
  let result = try await runMacus(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: environment)
  #expect(result.status == 1)
  #expect(result.stderr.contains("Cannot read the existing Incus default"))
  #expect(try tools.incusArguments() == [["remote", "get-default"]])
  #expect(try tools.readState().defaultRemote == "other")
  #expect(try tools.readState().remotes["macus"] == nil)
  #expect(try runtime.tokens().isEmpty)
}

/// A ready runtime behind the public server, whose HTTPS endpoint client setup registers.
private struct ReadyRuntime {
  var gateway: ScriptedGateway
  var directory: String { gateway.directory.path }
  var state: URL { gateway.directory }
  var url: String { gateway.url }
  var authority: String { String(gateway.url.dropFirst("https://".count)) }
  var certificate: FixtureCertificate { FixtureCertificate(der: gateway.identity.certificate) }
  func stop() { gateway.stop() }

  func tokens() throws -> [[String: Any]] { try records("trust-tokens.json", "tokens") }
  func redemptions() throws -> [[String: Any]] {
    try records("trust-token-redemptions.json", "redemptions")
  }
  func trusted() throws -> [String] {
    try records("trusted-certificates.json", "certificates").compactMap {
      $0["fingerprint"] as? String
    }
  }
  func distrustAll() throws {
    try writePrivate(
      Data(#"{"schema_version":1,"certificates":[]}"#.utf8),
      to: state.appendingPathComponent("server/trusted-certificates.json"))
  }

  private func records(_ name: String, _ key: String) throws -> [[String: Any]] {
    let file = state.appendingPathComponent("server/\(name)")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    return object?[key] as? [[String: Any]] ?? []
  }
}

private func readyRuntime() throws -> ReadyRuntime {
  ReadyRuntime(
    gateway: try ScriptedGateway { _, _, _ in mustJSON(200, publicStatus(state: "ready")) })
}

private enum BrewMode { case install, fail, sleep }

private struct ToolFixture {
  let root: URL
  let bin: URL
  let prefix: URL
  let log: URL
  let state: URL
  let conf: URL
  let home: URL
  let incusPath: String

  init() throws {
    root = URL(fileURLWithPath: "/tmp/tims\(UUID().uuidString.prefix(8))", isDirectory: true)
    bin = root.appendingPathComponent("bin", isDirectory: true)
    prefix = root.appendingPathComponent("prefix", isDirectory: true)
    log = root.appendingPathComponent("commands.log")
    state = root.appendingPathComponent("incus-state.json")
    conf = root.appendingPathComponent("incus-conf", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true)
    incusPath = root.appendingPathComponent("incus-template").path
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: Data())
  }

  /// The environment for `macus`, with an isolated `INCUS_CONF` and `HOME`, playing the gateway
  /// of `runtime` (or of the fixture certificate when there is none).
  func environment(
    includeBrew: Bool = true, runtime: ReadyRuntime? = nil, query: FixtureCertificate? = nil
  ) -> [String: String] {
    var path = "/usr/bin:/bin"
    if includeBrew {
      path = "\(bin.path):" + path
    }
    var environment = [
      "PATH": path, "MACUS_BREW_FALLBACK": "0", "MACUS_FIXTURE_LOG": log.path,
      "MACUS_FIXTURE_STATE": state.path, "MACUS_FIXTURE_PREFIX": prefix.path,
      "MACUS_FIXTURE_INCUS": incusPath, "INCUS_CONF": conf.path, "HOME": home.path,
    ]
    environment.merge((try? fakeIncusCertificates(in: root, query: query)) ?? [:]) { $1 }
    if let runtime {
      let server = root.appendingPathComponent("gateway.crt")
      try? runtime.certificate.pem.write(to: server, atomically: true, encoding: .utf8)
      environment["MACUS_FIXTURE_SERVER_CERT"] = server.path
      environment["MACUS_FIXTURE_GATEWAY"] = runtime.directory
    }
    return environment
  }

  func writeBrew(mode: BrewMode) throws {
    let script: String
    switch mode {
    case .install:
      script = """
        #!/bin/sh
        printf '%s\\n' \"$*\" >> \"$MACUS_FIXTURE_LOG\"
        if [ \"$1\" = \"--prefix\" ]; then
          printf '%s\\n' \"$MACUS_FIXTURE_PREFIX\"
          exit 0
        fi
        if [ \"$1\" = \"install\" ] && [ \"$2\" = \"incus\" ]; then
          mkdir -p \"$MACUS_FIXTURE_PREFIX/bin\"
          cp \"$MACUS_FIXTURE_INCUS\" \"$MACUS_FIXTURE_PREFIX/bin/incus\"
          chmod 755 \"$MACUS_FIXTURE_PREFIX/bin/incus\"
          echo installed >&2
          exit 0
        fi
        echo unexpected >&2
        exit 2
        """
    case .fail:
      script = """
        #!/bin/sh
        printf '%s\\n' \"$*\" >> \"$MACUS_FIXTURE_LOG\"
        echo formula unavailable >&2
        exit 1
        """
    case .sleep:
      script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$MACUS_FIXTURE_LOG"
        if [ "$1" = "--prefix" ]; then
          printf '%s\\n' "$MACUS_FIXTURE_PREFIX"
          exit 0
        fi
        printf 'brew-pid:%s\\n' "$$" >> "$MACUS_FIXTURE_LOG"
        exec /bin/sleep 5
        """
    }
    try writeExecutable(bin.appendingPathComponent("brew"), script)
  }

  func writeIncus(defaultRemote: String, remotes: [String: [String]]) throws {
    let initial: [String: Any] = ["default": defaultRemote, "remotes": remotes]
    try JSONSerialization.data(withJSONObject: initial).write(to: state)
    try writeFakeIncus(to: incusPath)
  }

  func publishOnPath() throws {
    let destination = bin.appendingPathComponent("incus")
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: URL(fileURLWithPath: incusPath), to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: destination.path)
  }

  func commands() throws -> [[String]] {
    logText().split(separator: "\n").compactMap { line in
      let text = String(line)
      guard text.hasPrefix("[") || text.hasPrefix("install") || text.hasPrefix("--prefix") else {
        return text.isEmpty ? nil : [text]
      }
      if text.hasPrefix("[") {
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]
      }
      return text.split(separator: " ").map(String.init)
    }
  }

  func incusArguments() throws -> [[String]] {
    try commands().filter { ["remote", "list", "query"].contains($0.first ?? "") }
  }

  /// The `remote add` argument lists.
  func additions() throws -> [[String]] {
    try incusArguments().filter { $0.prefix(2) == ["remote", "add"] }
  }

  func readState() throws -> (defaultRemote: String, remotes: [String: [String]]) {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any]
    let remotes = object?["remotes"] as? [String: [String]] ?? [:]
    return (object?["default"] as? String ?? "", remotes)
  }

  func logText() -> String {
    (try? String(contentsOf: log, encoding: .utf8)) ?? ""
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  private func writeExecutable(_ url: URL, _ contents: String) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
}

private func jsonObject(_ text: String) throws -> [String: Any] {
  let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
  return value as? [String: Any] ?? [:]
}
