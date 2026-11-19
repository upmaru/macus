import Foundation

struct StartupDependencies: Sendable {
  var transport: any LocalHTTPTransport
  var runner: any LocalCommandRunner
  var downloader: any ApplianceDownloader
  var launchControl: any LaunchControl
  /// Recognizes a serving Macus server only through its authenticated, pinned gateway.
  var server: any ServerProbe = GatewayServerProbe()
  /// The public `/runtime` API every lifecycle, progress and health request uses.
  var gateway: any GatewayTransport = HTTPSGatewayClient()
  /// This executable's package version and source revision, paired with the server release.
  var build: BuildIdentity = .current
  var capabilities: @Sendable () async -> HostCapabilities
  var hasEntitlement: @Sendable () -> Bool
  var executablePath: @Sendable () -> String
  var now: @Sendable () -> ContinuousClock.Instant
  var homeDirectory: URL
  var launchAgentsDirectory: URL
  var uid: uid_t
  var catalog: ApplianceCatalogEntry
  var sink: any StartupProgressSink
}

struct StartupCoordinator {
  var dependencies: StartupDependencies

  func run(_ request: StartupRequest) async throws -> StartupResult {
    let budget = StartupBudget(seconds: request.timeout, now: dependencies.now())
    let context = StartContext(
      request: request, budget: budget, dependencies: dependencies, operationID: request.operationID
    )
    return try await context.run()
  }
}

private final class StartContext: @unchecked Sendable {
  var request: StartupRequest
  var budget: StartupBudget
  var dependencies: StartupDependencies
  var operationID: String
  var serviceOwnership = "launchd"
  var serviceLabel: String?
  var serverOwnership = "launchd"
  var serverLabel: String?
  /// What the preflight found for the server job: its validated registration, or whether a
  /// server already serves this state outside launchd.
  var serverRegistration: LaunchJob?
  var serverForeground = false
  var startDispatched = false
  var currentStage: StartupStage = .preflight

  init(
    request: StartupRequest, budget: StartupBudget, dependencies: StartupDependencies,
    operationID: String
  ) {
    self.request = request
    self.budget = budget
    self.dependencies = dependencies
    self.operationID = operationID
  }

  func run() async throws -> StartupResult {
    do {
      try await preflight()
      let paths = RuntimePaths(directory: request.stateDirectory)
      try paths.prepare()
      let lock = try BootstrapLock(directory: paths.directory)
      defer { lock.release() }
      // The local CLI's own server credential, prepared once and never printed.
      try BearerTokenStore(stateDirectory: paths.directory).prepareLocalCredential()
      serviceLabel = LaunchAgentPlan.label(
        stateDirectory: paths.directory, home: dependencies.homeDirectory)
      serverLabel = LaunchAgentPlan.label(
        stateDirectory: paths.directory, home: dependencies.homeDirectory, role: .server)
      try await rejectLegacy(paths)
      // Before any download, job activation or guest request.
      try await preflightServer(paths)
      let kind = try BootstrapStore.existingRuntime(paths.directory)
      let manifest: URL
      if kind == .absent {
        manifest = try await prepareAbsent(paths)
      } else {
        emit(.acquisition, .skipped, detail: "existing runtime")
        emit(.verification, .skipped)
        emit(.preparation, .skipped)
        emit(.runtimeCreation, .skipped)
        guard let loaded = try loadManifest(paths) else {
          throw RuntimeError(.io, "Existing runtime is missing its appliance manifest path")
        }
        manifest = loaded
        _ = manifest
      }
      let ownership = try await ensureService(paths)
      if kind == .absent { try await createRuntime(paths, manifest: try publishedManifest(paths)) }
      let capabilities = try await bootAndWait(paths)
      let client = try await configureClient(paths)
      emit(.clientSetup, .complete)
      return StartupResult(
        ready: true, connected: true, stateDirectory: paths.directory.path, remote: request.remote,
        incus: client.executable, installed: client.installed,
        serviceOwnership: ownership.ownership, serviceLabel: ownership.label,
        capabilities: capabilities, nextCommands: client.commands, pathGuidance: client.guidance,
        observedState: "ready")
    } catch is CancellationError {
      throw StartupInterrupted(message: await interruptedMessage())
    } catch let error as StartupInterrupted {
      throw error
    } catch {
      let failed = error as? RuntimeError ?? RuntimeError(.io, error.localizedDescription)
      emit(currentStage, .failed, detail: failed.message, code: failed.code.rawValue)
      throw failed
    }
  }

  private func preflight() async throws {
    emit(.preflight, .active)
    try BootstrapStore.validateState(request.stateDirectory)
    let host = await dependencies.capabilities()
    guard host.supported else {
      throw RuntimeError(
        .unavailable,
        "Apple virtualization is unavailable on this host. macus start will not download or create a runtime."
      )
    }
    guard dependencies.hasEntitlement() else {
      throw RuntimeError(
        .unavailable,
        "The macus executable is missing the virtualization entitlement. Install the entitled binary before macus start."
      )
    }
    let client = IncusClientService(
      runner: dependencies.runner,
      streams: MacusStreams(writeOutput: { _ in }, writeError: { _ in }),
      environment: request.environment)
    switch try client.availability(override: request.incusOverride) {
    case .missing:
      throw RuntimeError(
        .unavailable,
        "Incus CLI was not found on PATH and Homebrew is not installed. Install Homebrew from https://brew.sh, then rerun macus start. macus does not install Homebrew or use sudo."
      )
    case .executable(let path):
      // The server publishes its endpoint only once it runs; until then its configured URL is
      // the address the remote will name.
      let url =
        (try? GatewayEndpoint.discover(stateDirectory: request.stateDirectory).url.absoluteString)
        ?? (try? GatewayConfigurationStore(stateDirectory: request.stateDirectory).show())?
        .configuration.effectiveURL ?? GatewayConfiguration().effectiveURL
      if let conflict = try await client.existingRemoteConflict(
        executable: path, remote: request.remote, url: url, timeout: request.timeout,
        deadline: budget.deadline)
      {
        throw RuntimeError(
          .conflict, "\(conflict.message) Existing remotes and runtime data were preserved.")
      }
    case .homebrew:
      break
    }
    emit(.preflight, .complete)
  }

  private func prepareAbsent(_ paths: RuntimePaths) async throws -> URL {
    emit(.acquisition, .active)
    let acquisition = ApplianceAcquisition(downloader: dependencies.downloader)
    let cache = try await acquisition.materialize(
      entry: dependencies.catalog, directory: paths.directory, budget: budget, now: dependencies.now
    ) { completed, total in
      self.emit(.acquisition, .active, completed: completed, total: total)
    }
    emit(.acquisition, .complete, detail: "verified")
    emit(.verification, .complete)
    emit(.preparation, .active)
    let timeout = try budget.remainingSeconds(at: dependencies.now())
    let manifest = try await SeedPreparation.prepare(
      entry: dependencies.catalog, cache: cache, runner: dependencies.runner, timeout: timeout,
      environment: request.environment)
    let journal = BootstrapJournal(
      catalogID: dependencies.catalog.id, payloadRevision: EmbeddedGuestPayload.revision,
      archiveSHA512: dependencies.catalog.archiveSHA512, rawSHA256: dependencies.catalog.rawSHA256,
      acquired: true, prepared: true)
    try BootstrapStore.saveJournal(journal, directory: paths.directory)
    _ = journal
    emit(.preparation, .complete)
    return manifest
  }

  private func ensureService(_ paths: RuntimePaths) async throws -> (
    ownership: String, label: String?
  ) {
    emit(.serviceActivation, .active)
    let label = LaunchAgentPlan.label(
      stateDirectory: paths.directory, home: dependencies.homeDirectory)
    serviceLabel = label
    let server = LaunchAgentPlan.label(
      stateDirectory: paths.directory, home: dependencies.homeDirectory, role: .server)
    serverLabel = server
    try await rejectLegacy(paths)
    let executable = dependencies.executablePath()
    guard isAbsoluteExecutablePath(executable) else {
      throw RuntimeError(.invalidConfiguration, "Service executable path must be absolute")
    }
    let launcher = ServerRelease.launcher(forServiceExecutable: executable)
    // The Swift registration is identified from launchctl before either job is started; the
    // server's was identified and paired by the preflight.
    let runtimeJob = try await dependencies.launchControl.printJob(
      label: label, timeout: try budget.remainingSeconds(at: dependencies.now()))
    if let runtimeJob {
      try validateLoadedJob(
        runtimeJob, label: label,
        arguments: LaunchAgentPlan.arguments(
          executable: executable, stateDirectory: paths.directory),
        environment: nil)
    }
    let serverJob = serverRegistration
    let ownership = try await ensureRuntimeJob(
      paths, label: label, executable: executable, registered: runtimeJob)
    try await ensureServerJob(paths, label: server, launcher: launcher, registered: serverJob)
    emit(.serviceActivation, .complete, detail: activationDetail)
    return ownership
  }

  private var activationDetail: String?

  private func ensureRuntimeJob(
    _ paths: RuntimePaths, label: String, executable: String, registered: LaunchJob?
  ) async throws -> (ownership: String, label: String?) {
    if let loaded = registered {
      if !loaded.loaded {
        try Task.checkCancellation()
        try await dependencies.launchControl.kickstart(
          label: label, timeout: try budget.remainingSeconds(at: dependencies.now()))
      }
      try await waitForEndpoint(paths)
      try Task.checkCancellation()
      guard dependencies.now() < budget.deadline else {
        throw RuntimeError(.timeout, "Startup deadline exceeded")
      }
      serviceOwnership = "launchd"
      activationDetail = loaded.loaded ? "reused" : "kickstarted"
      return ("launchd", label)
    }
    if try await compatibleDaemon(paths) {
      serviceOwnership = "foreground"
      activationDetail = "foreground"
      return ("foreground", nil)
    }
    let plist = try LaunchAgentPlan.write(
      stateDirectory: paths.directory, home: dependencies.homeDirectory,
      launchAgents: dependencies.launchAgentsDirectory, executable: executable)
    try await dependencies.launchControl.bootstrap(
      plist: plist, timeout: try budget.remainingSeconds(at: dependencies.now()))
    try await waitForEndpoint(paths)
    serviceOwnership = "launchd"
    activationDetail = nil
    return ("launchd", label)
  }

  /// The server job is recovered on its own: kickstarting or bootstrapping it never stops,
  /// restarts or recreates the Swift job or the VM.
  private func ensureServerJob(
    _ paths: RuntimePaths, label: String, launcher: String, registered: LaunchJob?
  ) async throws {
    if let registered {
      if !registered.loaded {
        try Task.checkCancellation()
        try await dependencies.launchControl.kickstart(
          label: label, timeout: try budget.remainingSeconds(at: dependencies.now()))
      }
      try await waitForServer(paths)
      serverOwnership = "launchd"
      return
    }
    if serverForeground, try await serverServing(paths) {
      // A server already serves this state's pinned endpoint outside launchd: reuse it.
      serverOwnership = "foreground"
      return
    }
    try ServerRelease.requirePaired(launcher: launcher, build: dependencies.build)
    let plist = try LaunchAgentPlan.write(
      stateDirectory: paths.directory, home: dependencies.homeDirectory,
      launchAgents: dependencies.launchAgentsDirectory, executable: launcher, role: .server,
      revision: dependencies.build.revision)
    try Task.checkCancellation()
    try await dependencies.launchControl.bootstrap(
      plist: plist, timeout: try budget.remainingSeconds(at: dependencies.now()))
    try await waitForServer(paths)
    serverOwnership = "launchd"
  }

  /// The server half of the startup preflight, inside the bootstrap lock and the one budget:
  /// the selected listener/TLS configuration, the registered server job's identity, and, unless
  /// a server already serves this state outside launchd, the installed release paired with this
  /// executable and its bundled `opsmaru_incus`. Reads only.
  private func preflightServer(_ paths: RuntimePaths) async throws {
    let store = GatewayConfigurationStore(stateDirectory: paths.directory)
    try GatewayConfigurationStore.check(try store.show().configuration)
    let executable = dependencies.executablePath()
    guard isAbsoluteExecutablePath(executable) else {
      throw RuntimeError(.invalidConfiguration, "Service executable path must be absolute")
    }
    let launcher = ServerRelease.launcher(forServiceExecutable: executable)
    let label = LaunchAgentPlan.label(
      stateDirectory: paths.directory, home: dependencies.homeDirectory, role: .server)
    let registered = try await dependencies.launchControl.printJob(
      label: label, timeout: try budget.remainingSeconds(at: dependencies.now()))
    if let registered {
      try validateServerJob(registered, label: label, launcher: launcher, paths: paths)
    } else if try await serverServing(paths) {
      serverForeground = true
      return
    }
    try ServerRelease.requirePaired(launcher: launcher, build: dependencies.build)
    serverRegistration = registered
  }

  private func validateServerJob(
    _ job: LaunchJob, label: String, launcher: String, paths: RuntimePaths
  ) throws {
    let arguments = LaunchAgentPlan.arguments(
      executable: launcher, stateDirectory: paths.directory, role: .server)
    let revision = dependencies.build.revision
    let expected = LaunchAgentPlan.environment(
      stateDirectory: paths.directory, role: .server, revision: revision)
    let recorded = job.environment["MACUS_EXPECTED_REVISION"]
    if recorded != revision,
      ServiceExecutable.matches(reported: job.executable, expected: launcher),
      job.programArguments == arguments,
      LaunchAgentPlan.environmentMatches(
        job.environment,
        expected: LaunchAgentPlan.environment(
          stateDirectory: paths.directory, role: .server, revision: recorded))
    {
      // Our own job, registered by another package revision: an explicit transition.
      throw RuntimeError(
        .conflict,
        "Service \(label) was registered for Macus revision \(recorded ?? "none"), but this macus is \(revision ?? "unrecorded"). Unload it with launchctl bootout gui/\(dependencies.uid)/\(label), remove its plist, and rerun macus start. The runtime and its data were preserved."
      )
    }
    try validateLoadedJob(job, label: label, arguments: arguments, environment: expected)
  }

  private func serverServing(_ paths: RuntimePaths) async throws -> Bool {
    let remaining = try budget.remainingSeconds(at: dependencies.now())
    return try await dependencies.server.serving(
      stateDirectory: paths.directory, timeout: min(remaining, 5))
  }

  private func waitForServer(_ paths: RuntimePaths) async throws {
    while dependencies.now() < budget.deadline {
      try Task.checkCancellation()
      if try await serverServing(paths) { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RuntimeError(
      .timeout,
      "The Macus server did not answer on its published endpoint before the deadline. The runtime and its data were preserved."
    )
  }

  private func createRuntime(_ paths: RuntimePaths, manifest: URL) async throws {
    emit(.runtimeCreation, .active)
    let host = await dependencies.capabilities()
    var configuration = RuntimeConfiguration(
      applianceManifestPath: manifest.path,
      seedPath: manifest.deletingLastPathComponent().appendingPathComponent("seed.iso").path)
    configuration.nestedVirtualization = host.nestedVirtualization
    configuration.readinessTimeoutSeconds = 1_800
    configuration.shares = []
    let body = try JSON.encoder().encode(configuration)
    _ = try requireGatewaySuccess(
      try await gateway("POST", "/runtime/create", body, paths: paths))
    emit(.runtimeCreation, .complete)
  }

  private func bootAndWait(_ paths: RuntimePaths) async throws -> RuntimeCapabilities {
    emit(.provisioning, .active)
    let status = try await statusObject(paths)
    if jsonString(status["state"]) == "ready" {
      let capabilities = try await liveCapabilities(paths)
      emit(.provisioning, .skipped, detail: "already ready")
      emit(.readiness, .complete)
      return capabilities
    }
    if jsonString(status["state"]) == "starting" {
      throw RuntimeError(
        .conflict,
        "A runtime mutation is already in progress. Retry after it finishes; disks were preserved."
      )
    }
    emit(.readiness, .active)
    startDispatched = true
    let remaining = try budget.remainingSeconds(at: dependencies.now())
    let body = try JSONSerialization.data(withJSONObject: ["remaining_seconds": remaining])
    let poll = Task { await pollProgress(paths) }
    defer { poll.cancel() }
    let endpoint = try GatewayEndpoint.discover(stateDirectory: paths.directory)
    let response: LocalHTTPResponse
    do {
      response = try await dependencies.gateway.request(
        endpoint, method: "POST", path: "/runtime/start", body: body,
        timeout: try budget.remainingSeconds(at: dependencies.now()))
    } catch let error as RuntimeError where error.code == .unavailable || error.code == .io {
      // The connection to the server was lost, so Swift may have accepted the boot. It is never
      // sent again: the guest keeps booting (expected reboot included) and readiness is
      // observed through the gateway once it answers again.
      try await awaitReadyAfterLostStart(paths)
      let capabilities = try await liveCapabilities(paths)
      emit(.provisioning, .complete)
      emit(.readiness, .complete)
      return capabilities
    }
    _ = try requireGatewaySuccess(response)
    let capabilities = try await liveCapabilities(paths)
    emit(.provisioning, .complete)
    emit(.readiness, .complete)
    return capabilities
  }

  private func configureClient(_ paths: RuntimePaths) async throws -> (
    executable: String, installed: Bool, commands: [String], guidance: String?
  ) {
    emit(.clientSetup, .active)
    let status = try await statusObject(paths)
    guard jsonString(status["state"]) == "ready" else {
      throw RuntimeError(
        .unavailable,
        "Runtime is not ready. Client setup was not started and runtime data was preserved."
      )
    }
    let service = IncusClientService(
      runner: dependencies.runner,
      streams: MacusStreams(
        writeOutput: { _ in },
        writeError: { text in
          self.dependencies.sink.diagnostic(text)
        }),
      environment: request.environment)
    do {
      let endpoint = try GatewayEndpoint.discover(stateDirectory: paths.directory)
      let result = try await service.register(
        remote: request.remote, setDefault: request.setDefault,
        incusOverride: request.incusOverride, endpoint: endpoint,
        stateDirectory: paths.directory, timeout: request.timeout, deadline: budget.deadline)
      let directory = URL(fileURLWithPath: result.executable).deletingLastPathComponent().path
      let guidance =
        result.onPath
        ? nil
        : "incus is not on PATH. Use \(result.executable) or add \(directory) to PATH. macus does not edit shell profiles."
      let command =
        result.onPath
        ? shellCommand(["incus", "list", request.remote + ":"])
        : shellCommand([result.executable, "list", request.remote + ":"])
      return (result.executable, result.installed, [command], guidance)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let runtime = error as? RuntimeError ?? RuntimeError(.io, error.localizedDescription)
      throw RuntimeError(
        runtime.code,
        "\(runtime.message) Client setup failed after the runtime became ready; retry macus start without recreating disks."
      )
    }
  }

  private func compatibleDaemon(_ paths: RuntimePaths) async throws -> Bool {
    guard FileManager.default.fileExists(atPath: paths.controlSocket.path) else { return false }
    let status: LocalHTTPResponse
    do {
      status = try await privateProbe("GET", "/v1/runtime/status", Data(), paths: paths)
    } catch let error as RuntimeError where error.code == .invalidConfiguration {
      throw RuntimeError(
        .invalidConfiguration,
        "The control endpoint is unsafe or owned by another user. macus start will not replace it."
      )
    } catch {
      return false
    }
    guard (200...299).contains(status.status) else { return false }
    let progress = try await privateProbe("GET", "/v1/runtime/progress", Data(), paths: paths)
    if progress.status == 404 {
      throw RuntimeError(
        .invalidConfiguration,
        "An incompatible daemon is serving this state. Stop that daemon and rerun macus start with the current executable. macus will not replace it."
      )
    }
    guard (200...299).contains(progress.status) else {
      throw responseFailure(status: progress.status, body: progress.body)
    }
    return true
  }

  private func validateLoadedJob(
    _ job: LaunchJob, label: String, arguments expected: [String],
    environment: [String: String]?
  ) throws {
    guard !job.programArguments.isEmpty else {
      throw RuntimeError(
        .invalidConfiguration,
        "launchctl did not report an unambiguous executable and state for \(label). macus start will not start or replace that service."
      )
    }
    guard let executable = expected.first,
      ServiceExecutable.matches(reported: job.executable, expected: executable),
      job.programArguments == expected,
      LaunchAgentPlan.environmentMatches(job.environment, expected: environment)
    else {
      throw RuntimeError(
        .conflict,
        "Service \(label) already points at a different executable or state. Stop its runtime, unload the owned job and explicitly remove its old plist before retrying macus start. macus start will not replace that plist."
      )
    }
  }

  private func rejectLegacy(_ paths: RuntimePaths) async throws {
    let executable = dependencies.executablePath()
    let label = LaunchAgentPlan.label(
      stateDirectory: paths.directory, home: dependencies.homeDirectory)
    let chosen = LaunchAgentPlan.plistURL(
      stateDirectory: paths.directory, home: dependencies.homeDirectory,
      launchAgents: dependencies.launchAgentsDirectory)
    try LaunchAgentPlan.refuseConflictingDestination(
      chosen, label: label,
      arguments: LaunchAgentPlan.arguments(executable: executable, stateDirectory: paths.directory))
    let launcher = ServerRelease.launcher(forServiceExecutable: executable)
    let serverLabel = LaunchAgentPlan.label(
      stateDirectory: paths.directory, home: dependencies.homeDirectory, role: .server)
    let serverExpected = LaunchAgentPlan.arguments(
      executable: launcher, stateDirectory: paths.directory, role: .server)
    let serverEnvironment = LaunchAgentPlan.environment(
      stateDirectory: paths.directory, role: .server, revision: dependencies.build.revision)
    try LaunchAgentPlan.refuseConflictingDestination(
      LaunchAgentPlan.plistURL(
        stateDirectory: paths.directory, home: dependencies.homeDirectory,
        launchAgents: dependencies.launchAgentsDirectory, role: .server),
      label: serverLabel, arguments: serverExpected, environment: serverEnvironment)
    let directories = [
      dependencies.launchAgentsDirectory,
      paths.directory.appendingPathComponent("launchd", isDirectory: true),
    ]
    for directory in directories {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
        continue
      }
      for name in names where name.hasSuffix(".plist") {
        let url = directory.appendingPathComponent(name)
        guard let object = try dependencies.launchControl.plist(at: url),
          LaunchAgentPlan.targets(plist: object, stateDirectory: paths.directory)
        else { continue }
        let arguments = object["ProgramArguments"] as? [String] ?? []
        let variables = object["EnvironmentVariables"] as? [String: String]
        let label = (name as NSString).deletingPathExtension
        let legacy = LegacyService.labels.contains(label) || label.hasPrefix("com.kritama.")
        if legacy {
          throw RuntimeError(
            .conflict,
            "Legacy service \(label) targets this state. Unload it explicitly and remove its plist before macus start. Data was preserved and no second daemon was created."
          )
        }
        // Only the two Macus jobs may target a state; anything else (an Opsmaru or other
        // foreign job included) is a conflict, never a third service.
        guard LaunchAgentPlan.isMacusLabel(label) else {
          throw RuntimeError(
            .conflict,
            "Service \(label) already targets this state. macus start will not replace it or start a second daemon."
          )
        }
        let matches: Bool
        if label == serviceLabel {
          matches =
            arguments
            == LaunchAgentPlan.arguments(
              executable: executable, stateDirectory: paths.directory) && variables == nil
        } else if label == serverLabel {
          matches = arguments == serverExpected && variables == serverEnvironment
        } else {
          matches = true
        }
        if !matches {
          throw RuntimeError(
            .conflict,
            "Service \(label) points at a different executable or state. macus start will not replace that plist."
          )
        }
      }
    }
  }

  private func waitForEndpoint(_ paths: RuntimePaths) async throws {
    let deadline = budget.deadline
    while dependencies.now() < deadline {
      try Task.checkCancellation()
      if FileManager.default.fileExists(atPath: paths.controlSocket.path),
        (try? await compatibleDaemon(paths)) == true
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RuntimeError(
      .timeout, "The background service did not open its control endpoint before the deadline")
  }

  /// After the start request's connection was lost: waits, within the budget, for the gateway to
  /// report the runtime ready. A gateway that is restarting or a Swift service it cannot reach yet
  /// is waited for; a runtime that is no longer starting is reported, and the boot is not retried.
  private func awaitReadyAfterLostStart(_ paths: RuntimePaths) async throws {
    emit(.provisioning, .active, detail: "reconnecting to the Macus server")
    while dependencies.now() < budget.deadline {
      try Task.checkCancellation()
      let response: LocalHTTPResponse
      do {
        response = try await gateway("GET", "/runtime/status", timeout: 5, paths: paths)
      } catch let error as RuntimeError where error.code == .invalidConfiguration {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try await Task.sleep(for: .milliseconds(250))
        continue
      }
      if (200...299).contains(response.status), let object = try? jsonObject(response.body) {
        switch jsonString(object["state"]) {
        case "ready":
          return
        case "starting":
          break
        case let state:
          throw RuntimeError(
            .unavailable,
            "The connection to the Macus server was lost while the runtime was starting, and the runtime is now \(state ?? "unknown"). The boot was not sent again; rerun macus start. Disks and logs were preserved."
          )
        }
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw RuntimeError(
      .timeout,
      "The runtime did not become ready through the Macus server before the deadline. The guest was not force-stopped; disks and logs were preserved."
    )
  }

  private func pollProgress(_ paths: RuntimePaths) async {
    while !Task.isCancelled {
      if let response = try? await gateway("GET", "/runtime/progress", timeout: 5, paths: paths),
        (200...299).contains(response.status),
        let object = try? jsonObject(response.body)
      {
        let phase = jsonString(object["phase"])
        let reboot = jsonBool(object["expected_reboot"]) == true
        emit(.provisioning, .active, detail: phase, reboot: reboot)
        if jsonBool(object["ready"]) == true {
          break
        }
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func liveCapabilities(_ paths: RuntimePaths) async throws -> RuntimeCapabilities {
    let health = try requireGatewaySuccess(
      try await gateway("GET", "/runtime/health", paths: paths))
    let decoded = try JSON.decoder().decode(GuestHealth.self, from: health.body)
    guard decoded.protocolVersion == 1 else {
      throw RuntimeError(
        .unavailable, "Guest health protocol is not live. Progress markers are not readiness.")
    }
    let capabilities = try requireGatewaySuccess(
      try await gateway("GET", "/runtime/capabilities", paths: paths))
    return try JSON.decoder().decode(RuntimeCapabilities.self, from: capabilities.body)
  }

  private func statusObject(_ paths: RuntimePaths) async throws -> [String: Any] {
    let response = try requireGatewaySuccess(
      try await gateway("GET", "/runtime/status", paths: paths))
    return try jsonObject(response.body)
  }

  /// One public `/runtime` request within the remaining budget (at most `timeout` seconds). The
  /// endpoint is discovered first, so missing or unsafe server files fail as themselves.
  private func gateway(
    _ method: String, _ path: String, _ body: Data = Data(), timeout: Int? = nil,
    paths: RuntimePaths
  ) async throws -> LocalHTTPResponse {
    let endpoint = try GatewayEndpoint.discover(stateDirectory: paths.directory)
    let remaining = try budget.remainingSeconds(at: dependencies.now())
    return try await dependencies.gateway.request(
      endpoint, method: method, path: path, body: body,
      timeout: min(remaining, timeout ?? remaining))
  }

  /// Identifies the private Swift service while activating it (a compatible daemon already
  /// serving this state, launchd-owned or foreground). This is bootstrap mechanics only: every
  /// lifecycle, progress and health request goes through the public gateway.
  private func privateProbe(_ method: String, _ path: String, _ body: Data, paths: RuntimePaths)
    async throws
    -> LocalHTTPResponse
  {
    let timeout = try budget.remainingSeconds(at: dependencies.now())
    return try await dependencies.transport.request(
      socket: paths.controlSocket, method: method, path: path, body: body, timeout: timeout)
  }

  private func publishedManifest(_ paths: RuntimePaths) throws -> URL {
    paths.directory.appendingPathComponent("appliance-cache", isDirectory: true)
      .appendingPathComponent(dependencies.catalog.id, isDirectory: true)
      .appendingPathComponent("manifest.json")
  }

  private func loadManifest(_ paths: RuntimePaths) throws -> URL? {
    guard FileManager.default.fileExists(atPath: paths.config.path) else { return nil }
    let object =
      try JSONSerialization.jsonObject(with: Data(contentsOf: paths.config)) as? [String: Any]
    guard let path = object?["appliance_manifest_path"] as? String else { return nil }
    return URL(fileURLWithPath: path)
  }

  private func interruptedMessage() async -> String {
    let paths = RuntimePaths(directory: request.stateDirectory)
    var observed: String?
    if let endpoint = try? GatewayEndpoint.discover(stateDirectory: paths.directory),
      let response = try? await dependencies.gateway.request(
        endpoint, method: "GET", path: "/runtime/status", body: Data(), timeout: 2),
      (200...299).contains(response.status),
      let object = try? jsonObject(response.body)
    {
      observed = jsonString(object["state"])
    }
    if startDispatched {
      let state = observed ?? "unknown"
      return
        "Start interrupted. Observed runtime state is \(state). The guest was not force-stopped; run macus runtime stop if you need to stop it. Disks and logs were preserved."
    }
    return
      "Start interrupted before a daemon-owned boot was dispatched. No guest was force-stopped. Disks and logs were preserved."
  }

  private func emit(
    _ stage: StartupStage, _ state: StartupStageState, completed: Int64? = nil, total: Int64? = nil,
    detail: String? = nil, reboot: Bool = false, code: String? = nil
  ) {
    dependencies.sink.emit(
      event(
        stage, state, completed: completed, total: total, detail: detail, reboot: reboot, code: code
      )
    )
  }

  private func event(
    _ stage: StartupStage, _ state: StartupStageState, completed: Int64? = nil, total: Int64? = nil,
    detail: String? = nil, reboot: Bool = false, code: String? = nil
  ) -> StartupProgressEvent {
    currentStage = stage
    let elapsed = max(0, Int(budget.started.duration(to: dependencies.now()).components.seconds))
    return StartupProgressEvent(
      operationID: operationID, stage: stage, state: state, elapsedSeconds: elapsed,
      completedBytes: completed, totalBytes: total, detail: detail, errorCode: code,
      expectedReboot: reboot)
  }
}
