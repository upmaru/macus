import Darwin
import Foundation
import Testing

@testable import Macus

// Task 8.2: the same two per-state jobs, com.upmaru.macus (Swift) and com.upmaru.macus.server
// (the Elixir release), each validated from launchctl's actual program, arguments and selected
// state, with matched isolated suffixes and no third (Opsmaru or other) job.

@Test func launchctlEnvironmentBlockIsReadLiterally() throws {
  let text = """
    gui/501/com.upmaru.macus.server = {
    \tstate = running
    \tprogram = /opt/homebrew/opt/macus/libexec/macus/bin/macus
    \targuments = {
    \t\t/opt/homebrew/opt/macus/libexec/macus/bin/macus
    \t\tstart
    \t}

    \tinherited environment = {
    \t\tMACUS_STATE_DIR => /inherited
    \t}

    \tdefault environment = {
    \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
    \t}

    \tenvironment = {
    \t\tOSLogRateLimit => 64
    \t\tMACUS_STATE_DIR => /tmp/a b\u{20}
    \t\tMACUS_SERVE => 1
    \t\tXPC_SERVICE_NAME => com.upmaru.macus.server
    \t}
    }
    """
  let job = try LaunchJobParser.parse(text: text, label: "com.upmaru.macus.server")
  #expect(job.programArguments.last == "start")
  // Only the job's own block; launchctl indentation removed, the trailing space kept.
  #expect(job.environment["MACUS_STATE_DIR"] == "/tmp/a b ")
  #expect(job.environment["PATH"] == nil)
  #expect(job.environment["XPC_SERVICE_NAME"] == "com.upmaru.macus.server")

  let duplicated = text.replacingOccurrences(
    of: "\t\tMACUS_SERVE => 1", with: "\t\tMACUS_SERVE => 1\n\t\tMACUS_SERVE => 0")
  #expect(throws: RuntimeError.self) {
    _ = try LaunchJobParser.parse(text: duplicated, label: "com.upmaru.macus.server")
  }
  let malformed = text.replacingOccurrences(of: "MACUS_SERVE => 1", with: "MACUS_SERVE = 1")
  #expect(throws: RuntimeError.self) {
    _ = try LaunchJobParser.parse(text: malformed, label: "com.upmaru.macus.server")
  }

  // Expected variables must match; another selected state never does.
  let expected = LaunchAgentPlan.environment(
    stateDirectory: URL(fileURLWithPath: "/tmp/a b "), role: .server)
  #expect(!LaunchAgentPlan.environmentMatches(job.environment, expected: expected))
  var serving = job.environment
  serving["RELEASE_DISTRIBUTION"] = "none"
  #expect(LaunchAgentPlan.environmentMatches(serving, expected: expected))
  serving["TIM_STATE_DIR"] = "/elsewhere"
  #expect(!LaunchAgentPlan.environmentMatches(serving, expected: expected))
  #expect(!LaunchAgentPlan.environmentMatches(["MACUS_STATE_DIR": "/x"], expected: nil))
}

@Test func servicePairLabelsAndPlistsFollowTheState() {
  let home = URL(fileURLWithPath: "/Users/someone")
  let agents = home.appendingPathComponent("Library/LaunchAgents")
  let standard = home.appendingPathComponent(".tama/incus-mac")
  #expect(LaunchAgentPlan.label(stateDirectory: standard, home: home) == "com.upmaru.macus")
  #expect(
    LaunchAgentPlan.label(stateDirectory: standard, home: home, role: .server)
      == "com.upmaru.macus.server")
  #expect(
    LaunchAgentPlan.plistURL(
      stateDirectory: standard, home: home, launchAgents: agents, role: .server
    ).path
      == agents.appendingPathComponent("com.upmaru.macus.server.plist").path)

  let isolated = URL(fileURLWithPath: "/tmp/macus-isolated")
  let runtime = LaunchAgentPlan.label(stateDirectory: isolated, home: home)
  let server = LaunchAgentPlan.label(stateDirectory: isolated, home: home, role: .server)
  let suffix = String(runtime.dropFirst("com.upmaru.macus.".count))
  #expect(suffix.count == 12)
  #expect(server == "com.upmaru.macus.server.\(suffix)")
  for role in [ServiceRole.runtime, .server] {
    // Isolated plists live in the state, never where launchd loads them at login.
    #expect(
      LaunchAgentPlan.plistURL(
        stateDirectory: isolated, home: home, launchAgents: agents, role: role
      ).deletingLastPathComponent().path == isolated.appendingPathComponent("launchd").path)
  }
  let other = LaunchAgentPlan.label(
    stateDirectory: URL(fileURLWithPath: "/tmp/macus-other"), home: home, role: .server)
  #expect(other != server)
  #expect(
    LaunchAgentPlan.arguments(
      executable: "/p/libexec/macus/bin/macus", stateDirectory: isolated, role: .server)
      == ["/p/libexec/macus/bin/macus", "start"])
}

@Test func homebrewOptPathsAreStableForBothExecutables() throws {
  let root = URL(fileURLWithPath: "/private/tmp/macus-brew-\(UUID().uuidString.prefix(8))")
  defer { try? FileManager.default.removeItem(at: root) }
  let keg = root.appendingPathComponent("Cellar/macus/1.2.3")
  let swift = try makeExecutable(keg.appendingPathComponent("bin/macus"))
  let launcher = try makeExecutable(keg.appendingPathComponent("libexec/macus/bin/macus"))
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("opt"), withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    atPath: root.appendingPathComponent("opt/macus").path, withDestinationPath: keg.path)

  let stable = ServiceExecutable.stablePath(for: swift.path)
  #expect(stable == root.appendingPathComponent("opt/macus/bin/macus").path)
  let stableLauncher = ServerRelease.launcher(forServiceExecutable: stable)
  #expect(stableLauncher == root.appendingPathComponent("opt/macus/libexec/macus/bin/macus").path)
  // launchctl may report the keg path behind the opt link; another keg is a conflict.
  #expect(ServiceExecutable.matches(reported: launcher.path, expected: stableLauncher))
  #expect(
    !ServiceExecutable.matches(
      reported: root.appendingPathComponent("Cellar/macus/1.0.0/libexec/macus/bin/macus").path,
      expected: stableLauncher))
  // A source install keeps its physical paths.
  #expect(ServiceExecutable.stablePath(for: "/usr/local/bin/macus") == "/usr/local/bin/macus")
  #expect(
    ServerRelease.launcher(forServiceExecutable: "/usr/local/bin/macus")
      == "/usr/local/libexec/macus/bin/macus")
}

@Test func absentPairIsBootstrappedRuntimeFirstWithIsolatedJobsAndLogs() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 0, "\(capture.error)")

  #expect(
    pair.launch.bootstrapped.map(\.lastPathComponent) == [
      "\(pair.runtimeLabel).plist", "\(pair.serverLabel).plist",
    ])
  for plist in pair.launch.bootstrapped {
    #expect(
      plist.deletingLastPathComponent().path == pair.state.appendingPathComponent("launchd").path)
  }
  // The default agents directory is never written for an isolated state.
  #expect(!FileManager.default.fileExists(atPath: pair.agents.path))

  let server = try plistObject(pair.launch.bootstrapped[1])
  #expect(server["Label"] as? String == pair.serverLabel)
  #expect(server["ProgramArguments"] as? [String] == [pair.launcher, "start"])
  #expect(
    server["EnvironmentVariables"] as? [String: String] == [
      "MACUS_STATE_DIR": pair.state.path, "MACUS_SERVE": "1", "RELEASE_DISTRIBUTION": "none",
      "MACUS_EXPECTED_REVISION": String(repeating: "ab", count: 20),
    ])
  #expect(
    server["StandardErrorPath"] as? String
      == pair.state.appendingPathComponent("logs/server.err.log").path)
  let runtime = try plistObject(pair.launch.bootstrapped[0])
  #expect(runtime["EnvironmentVariables"] == nil)
  #expect(
    runtime["StandardErrorPath"] as? String
      == pair.state.appendingPathComponent("logs/service.err.log").path)
  // Exactly the Macus pair: no Opsmaru or other job.
  for plist in pair.launch.bootstrapped {
    let label = try plistObject(plist)["Label"] as? String ?? ""
    #expect(LaunchAgentPlan.isMacusLabel(label) && !label.contains("opsmaru"))
  }
  #expect(pair.launch.kickstarted.isEmpty)

  // A second start reuses both registered jobs.
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  #expect(await pair.start() == 0)
  #expect(pair.launch.bootstrapped.count == 2)
  #expect(pair.launch.kickstarted.isEmpty)
}

@Test func stoppedServerJobAloneIsKickstartedBesideAForegroundDaemon() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  // A foreground Swift daemon serves the state; only the server job is registered, stopped.
  let daemon = try pair.openRuntime()
  pair.launch.register(pair.serverJob(loaded: false))
  #expect(await pair.start() == 0)
  #expect(pair.launch.kickstarted == [pair.serverLabel])
  #expect(pair.launch.bootstrapped.isEmpty)
  // Recovering the server never stopped, restarted or mutated the runtime.
  #expect(!daemon.requests().contains { $0.method != "GET" })

  // Registered and running: waited for, never kickstarted again.
  pair.launch.register(pair.serverJob(loaded: true))
  #expect(await pair.start() == 0)
  #expect(pair.launch.kickstarted == [pair.serverLabel])
}

@Test func foregroundServerAndDaemonAreReusedWithoutAnyJob() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  _ = try pair.openRuntime()
  pair.probe.serving = true
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 0)
  #expect(pair.launch.bootstrapped.isEmpty)
  #expect(pair.launch.kickstarted.isEmpty)
  #expect(Set(pair.launch.printed) == [pair.runtimeLabel, pair.serverLabel])
  #expect(capture.output.contains("foreground"))
}

@Test func serverJobForAnotherProgramOrStateIsRejectedBeforeActivation() async throws {
  let cases: [(String, @Sendable (inout LaunchJob) -> Void)] = [
    ("actual program", { $0.executable = "/elsewhere/libexec/macus/bin/macus" }),
    ("selected state", { $0.environment["MACUS_STATE_DIR"]! += "-other" }),
    ("legacy state variable", { $0.environment["TIM_STATE_DIR"] = "/elsewhere" }),
    ("serve flag", { $0.environment["MACUS_SERVE"] = nil }),
    ("arguments", { $0.programArguments = [$0.executable, "daemon"] }),
  ]
  for (name, change) in cases {
    let pair = try PairFixture()
    defer { pair.remove() }
    let disk = try Data(contentsOf: pair.state.appendingPathComponent("runtime/data.raw"))
    var registered = pair.serverJob(loaded: true)
    change(&registered)
    pair.launch.register(registered)
    let capture = StartCapture()
    #expect(await pair.start(capture: capture) == 1, "\(name)")
    #expect(capture.error.contains("conflict"), "\(name): \(capture.error)")
    // Neither job is created or started: the Swift job is not activated first.
    #expect(pair.launch.bootstrapped.isEmpty, "\(name)")
    #expect(pair.launch.kickstarted.isEmpty, "\(name)")
    #expect(try Data(contentsOf: pair.state.appendingPathComponent("runtime/data.raw")) == disk)
  }
}

@Test func missingOrIncompleteReleaseFailsBeforeAnyJobStarts() async throws {
  for damage in ["launcher", "erts"] {
    let pair = try PairFixture()
    defer { pair.remove() }
    let release = pair.prefix.appendingPathComponent("libexec/macus")
    switch damage {
    case "launcher":
      try FileManager.default.removeItem(at: release.appendingPathComponent("bin/macus"))
    default: try FileManager.default.removeItem(at: release.appendingPathComponent("erts-15.2"))
    }
    let capture = StartCapture()
    #expect(await pair.start(capture: capture) == 1)
    #expect(capture.error.contains("invalid_configuration"), "\(damage): \(capture.error)")
    #expect(
      capture.error.contains(damage == "launcher" ? "not installed" : "bundled ERTS"),
      "\(damage): \(capture.error)")
    #expect(pair.launch.bootstrapped.isEmpty)
    #expect(pair.launch.kickstarted.isEmpty)
  }
}

@Test func foreignOrStaleRegistrationsTargetingTheStateAreConflicts() async throws {
  // A non-Macus job (an Opsmaru one included) selecting the state through its environment.
  let pair = try PairFixture()
  defer { pair.remove() }
  try FileManager.default.createDirectory(at: pair.agents, withIntermediateDirectories: true)
  let foreign = pair.agents.appendingPathComponent("com.upmaru.opsmaru.incus.plist")
  try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": "com.upmaru.opsmaru.incus", "ProgramArguments": ["/usr/bin/true"],
      "EnvironmentVariables": ["MACUS_STATE_DIR": pair.state.path],
    ], format: .xml, options: 0
  ).write(to: foreign)
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 1)
  #expect(capture.error.contains("com.upmaru.opsmaru.incus"))
  #expect(pair.launch.bootstrapped.isEmpty)
  #expect(FileManager.default.fileExists(atPath: foreign.path))

  // A stale server plist at the chosen path naming another state is preserved, not replaced.
  let stale = try PairFixture()
  defer { stale.remove() }
  let plist = LaunchAgentPlan.plistURL(
    stateDirectory: stale.state, home: stale.tools.root, launchAgents: stale.agents, role: .server)
  try FileManager.default.createDirectory(
    at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
  let bytes = try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": stale.serverLabel, "ProgramArguments": [stale.launcher, "start"],
      "EnvironmentVariables": ["MACUS_STATE_DIR": "/tmp/another", "MACUS_SERVE": "1"],
    ], format: .xml, options: 0)
  try bytes.write(to: plist)
  let refused = StartCapture()
  #expect(await stale.start(capture: refused) == 1)
  #expect(refused.error.contains("will not replace"))
  #expect(try Data(contentsOf: plist) == bytes)
  #expect(stale.launch.bootstrapped.isEmpty)
}

// Task 8.3: the startup preflight pairs the release with this executable, checks its bundled
// opsmaru_incus and the selected TLS configuration, before any download, job or guest request.

@Test func swiftBuildIdentityIsReadFromItsEmbeddedInfoPlist() {
  let revision = String(repeating: "0f", count: 20)
  #expect(
    BuildIdentity.read(["MacusVersion": "0.1.0", "MacusSourceRevision": revision])
      == BuildIdentity(version: "0.1.0", revision: revision))
  #expect(BuildIdentity.read(nil) == BuildIdentity(version: nil, revision: nil))
  for bad in ["HEAD", revision.uppercased(), String(revision.dropLast()), revision + "0"] {
    #expect(BuildIdentity.read(["MacusSourceRevision": bad]).revision == nil, "\(bad)")
  }
  #expect(BuildIdentity.isRevision(String(repeating: "a", count: 64)))
  #expect(BuildIdentity.read(["MacusVersion": "0.1 beta"]).version == nil)
}

@Test func unpairedReleaseOrPayloadFailsBeforeAnyFetchJobOrGuestRequest() async throws {
  let other = String(repeating: "cd", count: 20)
  let damages: [(String, String, (PairFixture) throws -> Void)] = [
    ("revision", "this macus is", { try $0.writeManifest(revision: other) }),
    ("version", "this macus is", { try $0.writeManifest(version: "0.2.0") }),
    ("unrecorded build", "records no package version", { $0.build = BuildIdentity() }),
    (
      "missing manifest", "has no macus-build.json",
      {
        try FileManager.default.removeItem(
          at: $0.release.appendingPathComponent(ServerRelease.manifestName))
      }
    ),
    (
      "malformed manifest", "malformed",
      {
        try Data("{}".utf8).write(
          to: $0.release.appendingPathComponent(ServerRelease.manifestName))
      }
    ),
    (
      "writable manifest", "unsafe",
      { chmod($0.release.appendingPathComponent(ServerRelease.manifestName).path, 0o666) }
    ),
    (
      "missing library", "does not bundle the opsmaru_incus",
      {
        try FileManager.default.removeItem(
          at: $0.release.appendingPathComponent("lib/opsmaru_incus-0.2.3"))
      }
    ),
    ("recorded other library", "opsmaru_incus 0.2.4", { try $0.writeManifest(library: "0.2.4") }),
    (
      "second library", "does not bundle",
      {
        try FileManager.default.createDirectory(
          at: $0.release.appendingPathComponent("lib/opsmaru_incus-0.2.2/ebin"),
          withIntermediateDirectories: true)
      }
    ),
    (
      "application version", "does not bundle",
      {
        try Data(#"{application,opsmaru_incus,[{vsn,"0.2.2"}]}."#.utf8).write(
          to: $0.release.appendingPathComponent("lib/opsmaru_incus-0.2.3/ebin/opsmaru_incus.app"))
      }
    ),
  ]
  for (name, message, damage) in damages {
    // An absent runtime: a passing preflight would go on to download the appliance.
    let pair = try PairFixture(existing: false)
    defer { pair.remove() }
    try damage(pair)
    let capture = StartCapture()
    #expect(await pair.start(capture: capture) == 1, "\(name)")
    #expect(capture.error.contains("invalid_configuration"), "\(name): \(capture.error)")
    #expect(capture.error.contains(message), "\(name): \(capture.error)")
    #expect(pair.downloader.calls == 0, "\(name)")
    #expect(pair.launch.bootstrapped.isEmpty && pair.launch.kickstarted.isEmpty, "\(name)")
    #expect(!pair.launch.runtimeOpened, "\(name)")
    #expect(
      !FileManager.default.fileExists(atPath: pair.state.appendingPathComponent("runtime").path))
  }

  // A registered, stopped server job over a mismatched release is not kickstarted, and a running
  // guest's data is untouched.
  let pair = try PairFixture()
  defer { pair.remove() }
  let disk = try Data(contentsOf: pair.state.appendingPathComponent("runtime/data.raw"))
  pair.launch.register(pair.serverJob(loaded: false))
  try pair.writeManifest(revision: other)
  #expect(await pair.start() == 1)
  #expect(pair.launch.kickstarted.isEmpty && pair.launch.bootstrapped.isEmpty)
  #expect(!pair.launch.runtimeOpened)
  #expect(try Data(contentsOf: pair.state.appendingPathComponent("runtime/data.raw")) == disk)
}

@Test func invalidListenerOrTLSConfigurationFailsPreflight() async throws {
  let cases: [(String, [String: Any])] = [
    ("port", ["schema_version": 1, "port": 0]),
    ("unspecified bind", ["schema_version": 1, "bind_address": "0.0.0.0"]),
    (
      "missing certificate",
      [
        "schema_version": 1, "certificate_file": "/tmp/macus-no-such.crt",
        "key_file": "/tmp/macus-no-such.key",
      ]
    ),
  ]
  for (name, document) in cases {
    let pair = try PairFixture(existing: false)
    defer { pair.remove() }
    let server = pair.state.appendingPathComponent("server")
    try FileManager.default.createDirectory(
      at: server, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = server.appendingPathComponent("gateway.json")
    let bytes = try JSONSerialization.data(withJSONObject: document)
    try writePrivate(bytes, to: file)
    let capture = StartCapture()
    #expect(await pair.start(capture: capture) == 1, "\(name)")
    #expect(capture.error.contains("invalid_configuration"), "\(name): \(capture.error)")
    #expect(pair.downloader.calls == 0, "\(name)")
    #expect(pair.launch.bootstrapped.isEmpty, "\(name)")
    #expect(try Data(contentsOf: file) == bytes, "\(name)")
  }
}

@Test func serverJobFromAnotherPackageRevisionNeedsAnExplicitTransition() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  var old = pair.serverJob(loaded: true)
  old.environment["MACUS_EXPECTED_REVISION"] = String(repeating: "cd", count: 20)
  pair.launch.register(old)
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 1)
  #expect(capture.error.contains("conflict"))
  #expect(capture.error.contains("launchctl bootout"))
  #expect(capture.error.contains(String(repeating: "cd", count: 20)))
  #expect(pair.launch.bootstrapped.isEmpty && pair.launch.kickstarted.isEmpty)
  #expect(!pair.launch.runtimeOpened)
}

@Test func foregroundServerNeedsNoInstalledRelease() async throws {
  // A server already answering on the pinned endpoint is reused; no second listener is started
  // even though no release is installed beside this executable.
  let pair = try PairFixture()
  defer { pair.remove() }
  try FileManager.default.removeItem(at: pair.release)
  _ = try pair.openRuntime()
  pair.probe.serving = true
  #expect(await pair.start() == 0)
  #expect(pair.launch.bootstrapped.isEmpty && pair.launch.kickstarted.isEmpty)
}

@Test func foregroundServerIsRecheckedAfterTheRuntimeRecovers() async throws {
  // A foreground server answers 503 while Swift is down, so the preflight finds nothing serving.
  // Once the Swift job is kickstarted the same server serves again; start reuses it instead of
  // bootstrapping a competing launchd server that could not bind the occupied port.
  let pair = try PairFixture()
  defer { pair.remove() }
  pair.launch.register(pair.runtimeJob(loaded: false))
  pair.launch.servesWithRuntime = true
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 0, "\(capture.error)")
  #expect(pair.launch.kickstarted == [pair.runtimeLabel])
  #expect(pair.launch.bootstrapped.isEmpty)
  let object =
    try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any]
  #expect(object?["server_ownership"] as? String == "foreground")
  #expect(object?["service_ownership"] as? String == "launchd")
}

// MARK: - Fixtures

/// An existing isolated runtime, an installed fake package (`<prefix>/bin/macus` and its release
/// under `libexec/macus`), and a launchd stand-in that serves each job when it is started.
final class PairFixture: @unchecked Sendable {
  let tools: StartTools
  let state: URL
  let prefix: URL
  let agents: URL
  let executable: String
  let launcher: String
  let runtimeLabel: String
  let serverLabel: String
  let probe = FakeServerProbe(serving: false, publishes: true)
  let launch: PairLaunch
  var build = BuildIdentity(version: "0.1.0", revision: String(repeating: "ab", count: 20))
  var release: URL { prefix.appendingPathComponent("libexec/macus") }

  let downloader = RecordingDownloader()

  /// `existing: false` leaves the state without a runtime, so start would acquire an appliance.
  init(existing: Bool = true) throws {
    tools = try StartTools()
    state = URL(fileURLWithPath: "/tmp/macus-pair-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(state.path, 0o700)
    if existing {
      try FileManager.default.createDirectory(
        at: state.appendingPathComponent("runtime"), withIntermediateDirectories: true)
      try Data("root".utf8).write(to: state.appendingPathComponent("runtime/root.raw"))
      try Data("data".utf8).write(to: state.appendingPathComponent("runtime/data.raw"))
      try Data(#"{"appliance_manifest_path":"/tmp/manifest.json"}"#.utf8).write(
        to: state.appendingPathComponent("config.json"))
    }
    prefix = tools.root.appendingPathComponent("prefix")
    executable = try makeExecutable(prefix.appendingPathComponent("bin/macus")).path
    let release = prefix.appendingPathComponent("libexec/macus")
    launcher = try makeExecutable(release.appendingPathComponent("bin/macus")).path
    try FileManager.default.createDirectory(
      at: release.appendingPathComponent("releases/0.1.0"), withIntermediateDirectories: true)
    _ = try makeExecutable(release.appendingPathComponent("erts-15.2/bin/erl"))
    agents = tools.root.appendingPathComponent("LaunchAgents")
    runtimeLabel = LaunchAgentPlan.label(stateDirectory: state, home: tools.root)
    serverLabel = LaunchAgentPlan.label(stateDirectory: state, home: tools.root, role: .server)
    launch = PairLaunch(state: state, probe: probe)
    try writeManifest()
    let app = release.appendingPathComponent("lib/opsmaru_incus-0.2.3/ebin/opsmaru_incus.app")
    try FileManager.default.createDirectory(
      at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{application,opsmaru_incus,[{modules,[]},{vsn,"0.2.3"}]}."#.utf8).write(to: app)
  }

  /// The release's build record, as `Macus.Release.write_manifest/1` writes it.
  func writeManifest(
    version: String = "0.1.0", revision: String = String(repeating: "ab", count: 20),
    library: String = "0.2.3"
  ) throws {
    let object: [String: Any] = [
      "schema_version": 1, "version": version, "revision": revision,
      "opsmaru_incus": ["version": library, "checksum": String(repeating: "c", count: 64)],
    ]
    let file = release.appendingPathComponent(ServerRelease.manifestName)
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    chmod(file.path, 0o644)
  }

  func runtimeJob(loaded: Bool) -> LaunchJob {
    LaunchJob(
      label: runtimeLabel, loaded: loaded, executable: executable,
      programArguments: LaunchAgentPlan.arguments(executable: executable, stateDirectory: state))
  }

  func serverJob(loaded: Bool) -> LaunchJob {
    var environment =
      LaunchAgentPlan.environment(stateDirectory: state, role: .server, revision: build.revision)
      ?? [:]
    environment["XPC_SERVICE_NAME"] = serverLabel
    return LaunchJob(
      label: serverLabel, loaded: loaded, executable: launcher,
      programArguments: [launcher, "start"], environment: environment)
  }

  func openRuntime() throws -> ScriptedSocket {
    try launch.openRuntime()
  }

  /// Extra environment for the fake incus client.
  var environment: [String: String] = [:]

  func start(
    capture: StartCapture = StartCapture(), json: Bool = true, progress: String = "none"
  ) async -> Int32 {
    var overrides = tools.overrides(
      downloader: downloader, launchControl: launch, agents: agents)
    overrides.server = probe
    overrides.gateway = probe
    overrides.build = build
    let executable = self.executable
    overrides.executablePath = { executable }
    return await MacusCLI.run(
      arguments: ["--state-dir", state.path] + (json ? ["--json"] : []) + [
        "--progress", progress, "--timeout", successDeadline, "--incus", tools.incus, "start",
      ],
      environment: tools.environment.merging(environment) { $1 }, streams: capture.streams,
      overrides: overrides)
  }

  func remove() {
    launch.stop()
    tools.remove()
    try? FileManager.default.removeItem(at: state)
  }
}

final class PairLaunch: LaunchControl, @unchecked Sendable {
  private let lock = NSLock()
  private var jobs: [String: LaunchJob] = [:]
  private var bootstraps: [URL] = []
  private var kickstarts: [String] = []
  private var prints: [String] = []
  private var runtime: ScriptedSocket?
  let state: URL
  let probe: FakeServerProbe

  init(state: URL, probe: FakeServerProbe) {
    self.state = state
    self.probe = probe
  }

  var bootstrapped: [URL] { lock.withLock { bootstraps } }
  var kickstarted: [String] { lock.withLock { kickstarts } }
  var printed: [String] { lock.withLock { prints } }
  func register(_ job: LaunchJob) { lock.withLock { jobs[job.label] = job } }

  /// The private runtime's answers; a ready runtime unless a test scripts another.
  var responder: (@Sendable (String, String, Data) -> Data)?

  func openRuntime() throws -> ScriptedSocket {
    if let runtime = lock.withLock({ runtime }) { return runtime }
    let state = self.state
    let scripted = lock.withLock { responder }
    let socket = try ScriptedSocket(name: "runtime.sock", directory: state) { method, path, body in
      scripted?(method, path, body) ?? readyRuntime(method: method, path: path, directory: state)
    }
    lock.withLock { runtime = socket }
    return socket
  }

  func stop() { lock.withLock { runtime }?.stop() }
  var runtimeOpened: Bool { lock.withLock { runtime != nil } }

  func printJob(label: String, timeout: Int) async throws -> LaunchJob? {
    lock.withLock {
      prints.append(label)
      return jobs[label]
    }
  }

  func bootstrap(plist: URL, timeout: Int) async throws {
    lock.withLock { bootstraps.append(plist) }
    try activate(label: (plist.lastPathComponent as NSString).deletingPathExtension)
  }

  func kickstart(label: String, timeout: Int) async throws {
    lock.withLock { kickstarts.append(label) }
    try activate(label: label)
  }

  /// A foreground server outside launchd that serves only while the Swift runtime is up.
  var servesWithRuntime: Bool {
    get { lock.withLock { foregroundServer } }
    set { lock.withLock { foregroundServer = newValue } }
  }
  private var foregroundServer = false

  private func activate(label: String) throws {
    if label.hasPrefix(LaunchAgentPlan.serverLabel) {
      probe.serving = true
    } else {
      _ = try openRuntime()
      if servesWithRuntime { probe.serving = true }
    }
  }

  func plist(at url: URL) throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try plistObject(url)
  }
}

private func plistObject(_ url: URL) throws -> [String: Any] {
  try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    as? [String: Any] ?? [:]
}

private func makeExecutable(_ url: URL) throws -> URL {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
  chmod(url.path, 0o755)
  return url
}
