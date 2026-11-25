import Foundation

/// `macus runtime upgrade` and `macus runtime upgrade --rollback`.
enum RuntimeUpgradeAction: Sendable, Equatable {
  case upgrade(dryRun: Bool)
  case rollback(id: String?, discardData: Bool)
}

private struct SilentProgressSink: StartupProgressSink {
  func emit(_ event: StartupProgressEvent) {}
}

/// Upgrade and rollback first activate the runtime and server jobs without booting, as start
/// does, so a state start refused can still be repaired. Everything after that goes through
/// the public API; the client only downloads the appliance and stages it inside the state.
/// It never runs a package manager or changes the installed package.
func runRuntimeUpgrade(
  _ action: RuntimeUpgradeAction, directory: URL, timeout: Int, json: Bool,
  environment: [String: String], transport: any LocalHTTPTransport,
  gateway: any GatewayTransport, runner: any LocalCommandRunner, streams: MacusStreams,
  overrides: StartupOverrides
) async throws {
  let launchctl = try FixtureSeam.path(
    FixtureSeam.launchctlVariable, environment: environment, stateDirectory: directory,
    kind: .executable)
  // The daemon plans against the appliance this executable ships, so the client stages the
  // same one, never a draft qualification catalog.
  let dependencies = startupDependencies(
    environment: environment, transport: transport, gateway: gateway, runner: runner,
    overrides: overrides, launchctl: launchctl, downloader: nil, catalog: nil,
    sink: SilentProgressSink())
  let budget = StartupBudget(seconds: timeout, now: dependencies.now())
  let purpose: String
  switch action {
  case .upgrade(let dryRun): purpose = dryRun ? "the upgrade dry run" : "the upgrade"
  case .rollback: purpose = "the rollback"
  }
  let request = StartupRequest(
    stateDirectory: directory, remote: MacusCLI.defaultRemoteName, setDefault: false,
    incusOverride: nil, timeout: timeout, environment: environment)
  let services = try await StartupCoordinator(dependencies: dependencies).activate(
    request, purpose: purpose)
  defer { services.release() }
  let presentation = HumanPresentation(streams: streams, environment: environment)
  let session = UpgradeSession(
    directory: directory, budget: budget, dependencies: dependencies, json: json,
    environment: environment, streams: streams, presentation: presentation)
  switch action {
  case .upgrade(let dryRun): try await session.upgrade(dryRun: dryRun, paths: services.paths)
  case .rollback(let id, let discardData): try await session.rollback(id: id, discard: discardData)
  }
}

private struct UpgradeSession {
  let directory: URL
  let budget: StartupBudget
  let dependencies: StartupDependencies
  let json: Bool
  let environment: [String: String]
  let streams: MacusStreams
  let presentation: HumanPresentation

  func upgrade(dryRun: Bool, paths: RuntimePaths) async throws {
    let planned = try await request("POST", "/runtime/upgrade/plan")
    let plan = try JSON.decoder().decode(UpgradePlan.self, from: planned.body)
    let planObject = try jsonObject(planned.body)
    let entry = dependencies.catalog
    try Self.requireThisPackage(plan, entry: entry, payload: EmbeddedGuestPayload.revision)
    if plan.current {
      if json {
        streams.writeOutput(try jsonText(["upgraded": false, "plan": planObject]))
      } else {
        presentation.heading("Macus runtime upgrade")
        presentation.text(
          "  This runtime already runs the installed appliance \(terminalSafe(plan.toCatalogId)) and guest payload. Nothing was changed.\n"
        )
      }
      return
    }
    if dryRun {
      if json {
        streams.writeOutput(
          try jsonText(["dry_run": true, "upgraded": false, "plan": planObject]))
      } else {
        presentation.upgradePlan(plan)
        presentation.text(
          "\n  Dry run: nothing was downloaded, staged or stopped. Run macus runtime upgrade to upgrade.\n"
        )
      }
      return
    }
    // Shown before anything is downloaded or stopped.
    if !json { presentation.upgradePlan(plan) }
    if !json { presentation.text("\nDownloading and verifying \(terminalSafe(entry.id))…\n") }
    let cache = try await ApplianceAcquisition(downloader: dependencies.downloader).materialize(
      entry: entry, directory: directory, budget: budget, now: dependencies.now
    ) { _, _ in }
    if !json { presentation.text("Staging the new root and upgrade seed…\n") }
    let stagingID = try await UpgradeStaging.stage(
      plan: plan, cache: cache, entry: entry, paths: paths, runner: dependencies.runner,
      timeout: try budget.remainingSeconds(at: dependencies.now()), environment: environment)
    if !json {
      presentation.text(
        "Stopping the runtime and booting \(terminalSafe(entry.id)); every workload restarts…\n")
    }
    let upgraded = try await dispatch(stagingID: stagingID, paths: paths)
    let result = try jsonObject(upgraded.body)
    if json {
      streams.writeOutput(try jsonText(["upgraded": true, "plan": planObject, "result": result]))
    } else {
      presentation.upgradeResult(result, directory: directory)
    }
  }

  func rollback(id: String?, discard: Bool) async throws {
    var object: [String: Any] = [:]
    if let id { object["backup_id"] = id }
    if discard {
      object["discard_data_since_upgrade"] = true
      object["confirm"] = "discard-data"
    }
    let body = object.isEmpty ? Data() : try JSONSerialization.data(withJSONObject: object)
    // The runtime service checks the backup before it stops anything, and a refusal leaves
    // the runtime as it was, so this line promises no stop.
    if !json {
      presentation.text(
        "Checking \(id.map { "backup \(terminalSafe($0))" } ?? "the latest backup"); the runtime is stopped only if it can be restored…\n"
      )
    }
    let response = try await request("POST", "/runtime/upgrade/rollback", body)
    let result = try jsonObject(response.body)
    if json {
      streams.writeOutput(try jsonText(result))
    } else {
      presentation.rollbackResult(result, directory: directory)
    }
  }

  /// A runtime service left running from another package plans with its own appliance and
  /// payload, so its answer, current or not, says nothing about this package's.
  static func requireThisPackage(_ plan: UpgradePlan, entry: ApplianceCatalogEntry, payload: String)
    throws
  {
    guard plan.toCatalogId == entry.id, plan.toPayloadRevision == payload else {
      throw RuntimeError(
        .conflict,
        "The runtime service plans with appliance \(terminalSafe(plan.toCatalogId)) and guest payload \(terminalSafe(plan.toPayloadRevision)), but this macus installs \(entry.id) with guest payload \(payload): it runs from another package. Restart the runtime service from this package (macus runtime stop, then macus runtime upgrade); nothing was changed."
      )
    }
  }

  /// Hands the staged upgrade to the runtime service. The staging is removed when the request
  /// certainly never reached it; once it may have, the runtime service owns it.
  private func dispatch(stagingID: String, paths: RuntimePaths) async throws
    -> LocalHTTPResponse
  {
    var undelivered = true
    defer { if undelivered { UpgradeStaging.discard(stagingID, paths: paths) } }
    let body = try JSONSerialization.data(withJSONObject: ["staging_id": stagingID])
    let endpoint = try GatewayEndpoint.discover(stateDirectory: directory)
    let timeout = try budget.remainingSeconds(at: dependencies.now())
    let response: LocalHTTPResponse
    do {
      response = try await dependencies.gateway.request(
        endpoint, method: "POST", path: "/runtime/upgrade", body: body, timeout: timeout)
    } catch {
      undelivered = HTTPSGatewayClient.neverConnected(error)
      throw error
    }
    undelivered = HTTPSGatewayClient.notDispatched(response)
    return try requireGatewaySuccess(response)
  }

  private func request(_ method: String, _ path: String, _ body: Data = Data()) async throws
    -> LocalHTTPResponse
  {
    try await gatewayRequest(
      method, path, body, directory: directory,
      timeout: try budget.remainingSeconds(at: dependencies.now()),
      transport: dependencies.gateway)
  }
}

/// `macus runtime backups` and `macus runtime backups prune ID`. These need no activation:
/// they are only useful once the services serve the state.
func listBackups(
  directory: URL, timeout: Int, json: Bool, gateway: any GatewayTransport,
  streams: MacusStreams, presentation: HumanPresentation
) async throws {
  let response = try await gatewayRequest(
    "GET", "/runtime/backups", directory: directory, timeout: timeout, transport: gateway)
  let object = try jsonObject(response.body)
  if json {
    streams.writeOutput(try jsonText(object))
  } else {
    presentation.backups(object["backups"] as? [[String: Any]] ?? [], directory: directory)
  }
}

func pruneBackup(
  id: String, confirm: Bool, directory: URL, timeout: Int, json: Bool,
  gateway: any GatewayTransport, streams: MacusStreams, presentation: HumanPresentation
) async throws {
  var object: [String: Any] = ["backup_id": id]
  if confirm { object["confirm"] = "prune-backup" }
  let response = try await gatewayRequest(
    "POST", "/runtime/backups/prune", try JSONSerialization.data(withJSONObject: object),
    directory: directory, timeout: timeout, transport: gateway)
  let result = try jsonObject(response.body)
  if json {
    streams.writeOutput(try jsonText(result))
  } else {
    presentation.prune(result)
  }
}

extension HumanPresentation {
  func upgradePlan(_ plan: UpgradePlan) {
    heading("Macus runtime upgrade")
    field("From", describe(plan.fromCatalogId, payload: plan.fromPayloadRevision))
    field("To", describe(plan.toCatalogId, payload: plan.toPayloadRevision))
    let incus =
      "Incus \(plan.recordedIncusPackage ?? "unknown") to \(plan.targetIncusPackage ?? "unknown")"
    switch plan.upgradeClass {
    case .reversible?: field("Class", "Reversible (\(incus))")
    case .migrating?: field("Class", "Migrating (\(incus))")
    case nil: field("Class", "None")
    }
    if let storage = plan.storage {
      field("Pool", "\(storage.poolGuid) (\(storage.layout), from \(storage.source))")
    }
    field("Copies", copies(plan))
    field(
      "Space",
      "\(humanBytes(Int64(clamping: plan.requiredFreeBytes))) needed, \(humanBytes(Int64(clamping: plan.availableBytes))) free; keeping the backup can grow to \(humanBytes(Int64(clamping: plan.backupWorstCaseBytes)))"
    )
    field(
      "Restart",
      "The runtime is stopped and boots the new appliance, so every workload restarts.")
  }

  private func describe(_ catalog: String?, payload: String?) -> String {
    let payload = payload.map { String($0.prefix(12)) } ?? "unknown"
    return "\(catalog ?? "unknown appliance") (guest payload \(payload))"
  }

  private func copies(_ plan: UpgradePlan) -> String {
    let kept =
      "The previous root disk, firmware store, seed and configuration are kept as a backup."
    switch plan.dataCopy {
    case UpgradePlan.cloneCopy:
      return
        "\(kept) The data disk is cloned into it first, because Incus will migrate its database."
    case UpgradePlan.fullCopy:
      return
        "\(kept) The data disk is copied in full into it first (this volume cannot clone), because Incus will migrate its database."
    default:
      return "\(kept) The data disk stays in place."
    }
  }

  func upgradeResult(_ result: [String: Any], directory: URL) {
    heading(
      "\nUpgraded to \(terminalSafe(jsonString(result["to_catalog_id"]) ?? "the new appliance"))")
    field("Backup", jsonString(result["backup_id"]))
    field("Pool", jsonString(result["pool_guid"]))
    let inventory = result["inventory"] as? [String: Any]
    if inventory?["compared"] as? Bool == true {
      field("Verification", "Ready, pool imported, and Incus lists everything it listed before")
    } else {
      field(
        "Verification",
        "Ready and pool imported. \(jsonString(inventory?["skipped_reason"]) ?? "The Incus inventory was not compared.") Check the inventory below."
      )
    }
    if let current = inventory?["current"] as? [String: Any] {
      for project in current["projects"] as? [[String: Any]] ?? [] {
        let counts = ["instances", "volumes", "networks", "profiles"].map {
          "\((project[$0] as? [Any])?.count ?? 0) \($0)"
        }
        field("Project \(jsonString(project["name"]) ?? "?")", counts.joined(separator: ", "))
      }
    }
    if let status = result["status"] as? [String: Any] {
      runtimeFields(status, directory: directory)
    }
    next([
      shellCommand(["macus", "--state-dir", directory.path, "runtime", "backups"]),
      shellCommand(["macus", "--state-dir", directory.path, "runtime", "upgrade", "--rollback"]),
    ])
  }

  func rollbackResult(_ result: [String: Any], directory: URL) {
    heading("\nRestored backup \(terminalSafe(jsonString(result["restored_backup_id"]) ?? "?"))")
    switch jsonString(result["restore_data"]) {
    case "own"?:
      field(
        "Data disk",
        "Restored from this backup's copy of \(jsonString(result["data_copy_created_at"]) ?? "an unknown time")"
      )
    case "later"?:
      field(
        "Data disk",
        "Restored from backup \(jsonString(result["data_from"]) ?? "?")'s copy of \(jsonString(result["data_copy_created_at"]) ?? "an unknown time")"
      )
    default: field("Data disk", "Kept; only the root was restored")
    }
    field("Incus package", jsonString(result["root_incus_package"]) ?? "unknown")
    field("Replaced state", "Kept as backup \(jsonString(result["safety_backup_id"]) ?? "?")")
    if let status = result["status"] as? [String: Any] {
      runtimeFields(status, directory: directory)
    }
    next([shellCommand(["macus", "--state-dir", directory.path, "runtime", "start"])])
  }

  func backups(_ backups: [[String: Any]], directory: URL) {
    heading("Macus runtime backups")
    if backups.isEmpty {
      text("  No backups.\n")
      return
    }
    for backup in backups {
      heading("\n\(terminalSafe(jsonString(backup["id"]) ?? "?"))")
      field("Created", jsonString(backup["created_at"]) ?? "unknown")
      var operation = jsonString(backup["operation"]) ?? "upgrade"
      if let upgradeClass = jsonString(backup["upgrade_class"]) {
        operation += " (\(upgradeClass))"
      }
      field("Operation", operation)
      field("Source appliance", jsonString(backup["from_catalog_id"]) ?? "unknown")
      field("Incus package", jsonString(backup["root_incus_package"]) ?? "unknown")
      field("Data disk copy", backup["data_copy"] as? Bool == true ? "Yes" : "No")
      field("Size", humanBytes(Int64(clamping: jsonInt(backup["allocated_bytes"]) ?? 0)))
      field("Restorable", restorable(backup))
      if let breaks = backup["prune_breaks"] as? [String], !breaks.isEmpty {
        field("Pruning it breaks", breaks.joined(separator: ", "))
      }
    }
    next([
      shellCommand([
        "macus", "--state-dir", directory.path, "runtime", "upgrade", "--rollback", "ID",
      ])
    ])
  }

  private func restorable(_ backup: [String: Any]) -> String {
    guard backup["restorable"] as? Bool == true else {
      let status = jsonString(backup["status"]) ?? "unavailable"
      return "No (\(jsonString(backup["refusal"]) ?? status))"
    }
    switch jsonString(backup["restore_data"]) {
    case "own"?, "later"?:
      return
        "Yes, with a data disk copy; discards data written since \(jsonString(backup["discards_data_since"]) ?? "that copy") (needs --discard-data-since-upgrade)"
    default: return "Yes, root only; the data disk is kept"
    }
  }

  func prune(_ result: [String: Any]) {
    heading("Removed backup \(terminalSafe(jsonString(result["removed"]) ?? "?"))")
    field("Freed up to", humanBytes(Int64(clamping: jsonInt(result["allocated_bytes"]) ?? 0)))
    if let lost = result["no_longer_restorable"] as? [String], !lost.isEmpty {
      field("No longer restorable", lost.joined(separator: ", "))
    }
  }
}
