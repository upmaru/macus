import Darwin
import Foundation

struct StartupOverrides: Sendable {
  var capabilities: (@Sendable () async -> HostCapabilities)?
  var hasEntitlement: (@Sendable () -> Bool)?
  var downloader: (any ApplianceDownloader)?
  var launchControl: (any LaunchControl)?
  var server: (any ServerProbe)?
  var gateway: (any GatewayTransport)?
  var build: BuildIdentity?
  var executablePath: (@Sendable () -> String)?
  var now: (@Sendable () -> ContinuousClock.Instant)?
  var homeDirectory: URL?
  var launchAgentsDirectory: URL?
  var catalog: ApplianceCatalogEntry?
  var stderrIsTTY: Bool?
  var terminalWidth: (@Sendable () -> Int?)?
  var term: String?
  var installSignals = true
  var uid: uid_t?
  var runner: (any LocalCommandRunner)?
}

/// What start and the commands that activate its services run against: the real host, or
/// the overrides tests and fixtures supply.
func startupDependencies(
  environment: [String: String], transport: any LocalHTTPTransport,
  gateway: any GatewayTransport, runner: any LocalCommandRunner, overrides: StartupOverrides,
  launchctl: URL?, downloader: (any ApplianceDownloader)?, catalog: ApplianceCatalogEntry?,
  sink: any StartupProgressSink
) -> StartupDependencies {
  let home = overrides.homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  return StartupDependencies(
    transport: transport,
    runner: overrides.runner ?? runner,
    downloader: overrides.downloader ?? downloader ?? URLSessionApplianceDownloader(),
    launchControl: overrides.launchControl
      ?? ProcessLaunchControl(
        runner: runner, environment: environment, uid: overrides.uid ?? getuid(),
        executable: launchctl?.path ?? "/bin/launchctl"),
    server: overrides.server ?? GatewayServerProbe(transport: overrides.gateway ?? gateway),
    gateway: overrides.gateway ?? gateway,
    build: overrides.build ?? .current,
    capabilities: overrides.capabilities ?? { await MainActor.run { CapabilityDetector.detect() } },
    hasEntitlement: overrides.hasEntitlement ?? { currentProcessHasVirtualizationEntitlement() },
    executablePath: overrides.executablePath
      ?? { ServiceExecutable.stablePath(for: currentExecutablePath()) },
    now: overrides.now ?? { ContinuousClock.now },
    homeDirectory: home,
    launchAgentsDirectory: overrides.launchAgentsDirectory
      ?? home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
    uid: overrides.uid ?? getuid(),
    catalog: overrides.catalog ?? catalog ?? .current,
    sink: sink)
}

func runStart(
  directory: URL, remote: String, setDefault: Bool, incusOverride: String?,
  progress: ProgressSelection,
  timeout: Int, json: Bool, environment: [String: String], transport: any LocalHTTPTransport,
  gateway: any GatewayTransport = HTTPSGatewayClient(), runner: any LocalCommandRunner,
  streams: MacusStreams, overrides: StartupOverrides
) async throws {
  // A launchctl stand-in is refused before qualification, state or any launchd job is touched.
  let fixtureLaunchctl = try FixtureSeam.path(
    FixtureSeam.launchctlVariable, environment: environment, stateDirectory: directory,
    kind: .executable)
  let draft = try DraftQualification.load(environment: environment, state: directory)
  let rendering = ProgressRenderer.resolve(
    selection: progress, stderrIsTTY: overrides.stderrIsTTY ?? streams.stderrIsTTY,
    term: overrides.term ?? environment["TERM"], json: json)
  var progressEnvironment = environment
  if let term = overrides.term { progressEnvironment["TERM"] = term }
  if json { progressEnvironment["NO_COLOR"] = "1" }
  let terminal = MacusTerminal(
    descriptor: STDERR_FILENO, isTTY: rendering == .animated,
    environment: progressEnvironment, width: overrides.terminalWidth, write: streams.writeError)
  let sink = TerminalProgressSink(
    rendering: rendering, environment: progressEnvironment,
    stderrIsTTY: overrides.stderrIsTTY ?? streams.stderrIsTTY,
    width: { terminal.size()?.columns }, write: streams.writeError)
  sink.startRefreshing()
  defer { sink.cleanup() }
  let dependencies = startupDependencies(
    environment: environment, transport: transport, gateway: gateway, runner: runner,
    overrides: overrides, launchctl: fixtureLaunchctl,
    downloader: draft?.downloader, catalog: draft?.catalog, sink: sink)
  let request = StartupRequest(
    stateDirectory: directory, remote: remote, setDefault: setDefault, incusOverride: incusOverride,
    timeout: timeout, environment: environment)
  let task = Task { try await StartupCoordinator(dependencies: dependencies).run(request) }
  let signals = overrides.installSignals ? SignalCancellation(task: task) : nil
  defer { signals?.cancel() }
  let result: StartupResult
  do {
    result = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  } catch {
    await sink.finish()
    throw error
  }
  await sink.finish(ready: result.ready, connected: result.connected)
  if json {
    streams.writeOutput(try jsonText(resultObject(result)))
  } else {
    HumanPresentation(streams: streams, environment: environment).startup(result)
  }
}

func resultObject(_ result: StartupResult) -> [String: Any] {
  var object: [String: Any] = [
    "connected": result.connected,
    "incus": result.incus,
    "installed": result.installed,
    "next_commands": result.nextCommands,
    "ready": result.ready,
    "remote": result.remote,
    "service_ownership": result.serviceOwnership,
    "state_directory": result.stateDirectory,
  ]
  if let label = result.serviceLabel { object["service_label"] = label }
  if let ownership = result.serverOwnership { object["server_ownership"] = ownership }
  if let label = result.serverLabel { object["server_label"] = label }
  if let url = result.serverEndpoint, let fingerprint = result.serverFingerprint {
    object["server_endpoint"] = ["url": url, "certificate_fingerprint": fingerprint]
  }
  if let guidance = result.pathGuidance { object["path_guidance"] = guidance }
  if let upgrade = result.upgradeAvailable { object["upgrade_available"] = upgrade }
  if let capabilities = result.capabilities,
    let data = try? JSON.encoder().encode(capabilities),
    let decoded = try? JSONSerialization.jsonObject(with: data)
  {
    object["capabilities"] = decoded
  }
  return object
}

func currentExecutablePath() -> String {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  var size = UInt32(buffer.count)
  guard _NSGetExecutablePath(&buffer, &size) == 0 else {
    return CommandLine.arguments.first ?? "macus"
  }
  let path = decodeCString(buffer)
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return decodeCString(resolved)
}

private func decodeCString(_ bytes: [CChar]) -> String {
  let end = bytes.firstIndex(of: 0) ?? bytes.count
  return String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func decodeCString(_ pointer: UnsafePointer<CChar>) -> String {
  var length = 0
  while pointer[length] != 0 { length += 1 }
  let bytes = UnsafeBufferPointer(start: pointer, count: length).map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}

func currentProcessHasVirtualizationEntitlement() -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
  process.arguments = ["-d", "--entitlements", ":-", currentExecutablePath()]
  let output = Pipe()
  let error = Pipe()
  process.standardOutput = output
  process.standardError = error
  guard (try? process.run()) != nil else { return false }
  process.waitUntilExit()
  let text =
    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    + String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  return text.contains("com.apple.security.virtualization")
}

private final class SignalCancellation: @unchecked Sendable {
  private var sources: [DispatchSourceSignal] = []
  init(task: Task<StartupResult, Error>) {
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { task.cancel() }
      source.resume()
      sources.append(source)
    }
  }
  func cancel() {
    for source in sources { source.cancel() }
    sources.removeAll()
    signal(SIGINT, SIG_DFL)
    signal(SIGTERM, SIG_DFL)
  }
}
