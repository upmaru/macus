import Foundation

public struct RuntimeRoutes: Sendable {
  public let service: RuntimeService
  public init(service: RuntimeService) { self.service = service }
  public func handle(_ request: HTTPRequest) async -> HTTPResponse {
    struct Stop: Decodable { let force: Bool }
    struct Delete: Decodable { let confirm: Bool }
    struct Upgrade: Decodable { let stagingId: String }
    struct Rollback: Decodable {
      let backupId: String?
      let discardDataSinceUpgrade: Bool?
    }
    struct Prune: Decodable {
      let backupId: String
      let confirm: Bool
    }
    do {
      switch (request.method, request.path) {
      case ("GET", "/v1/runtime/status"): return try HTTPResponse(value: await service.status())
      case ("GET", "/v1/runtime/capabilities"):
        return try HTTPResponse(value: await service.capabilities())
      case ("GET", "/v1/runtime/health"): return try HTTPResponse(value: await service.health())
      case ("GET", "/v1/runtime/config"): return try HTTPResponse(value: await service.config())
      case ("POST", "/v1/runtime/create"):
        return try HTTPResponse(
          value: await service.create(decode(RuntimeConfiguration.self, request.body)))
      case ("PUT", "/v1/runtime/config"):
        return try HTTPResponse(
          value: await service.update(decode(RuntimeConfiguration.self, request.body)))
      case ("GET", "/v1/runtime/progress"):
        return try HTTPResponse(value: await service.progress())
      case ("POST", "/v1/runtime/start"):
        return try HTTPResponse(
          value: await service.start(remainingSeconds: try startBudget(request.body)))
      case ("POST", "/v1/runtime/restart"): return try HTTPResponse(value: await service.restart())
      case ("POST", "/v1/runtime/stop"):
        let force = request.body.isEmpty ? false : try decode(Stop.self, request.body).force
        return try HTTPResponse(value: await service.stop(force: force))
      case ("POST", "/v1/runtime/upgrade/plan"):
        try requireEmpty(request.body)
        return try HTTPResponse(value: await service.upgradePlan())
      case ("POST", "/v1/runtime/upgrade"):
        return try HTTPResponse(
          value: await service.upgrade(
            stagingID: decode(Upgrade.self, request.body).stagingId))
      case ("POST", "/v1/runtime/upgrade/rollback"):
        let rollback =
          request.body.isEmpty
          ? Rollback(backupId: nil, discardDataSinceUpgrade: nil)
          : try decode(Rollback.self, request.body)
        if let id = rollback.backupId { try UpgradeID.validate(id) }
        return try HTTPResponse(
          value: await service.rollback(
            backupID: rollback.backupId,
            discardDataSinceUpgrade: rollback.discardDataSinceUpgrade ?? false))
      case ("GET", "/v1/runtime/backups"):
        return try HTTPResponse(value: BackupList(backups: await service.backups()))
      case ("POST", "/v1/runtime/backups/prune"):
        let prune = try decode(Prune.self, request.body)
        return try HTTPResponse(
          value: await service.pruneBackup(id: prune.backupId, confirm: prune.confirm))
      case ("DELETE", "/v1/runtime"):
        return try HTTPResponse(
          value: await service.delete(confirm: decode(Delete.self, request.body).confirm))
      default: throw RuntimeError(.notFound, "Unknown runtime route")
      }
    } catch { return HTTPResponse.error(error) }
  }
  private func requireEmpty(_ data: Data) throws {
    guard data.isEmpty else { throw RuntimeError(.invalidRequest, "This request takes no body") }
  }
  private func startBudget(_ data: Data) throws -> Int? {
    if data.isEmpty { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RuntimeError(.invalidRequest, "Invalid startup budget")
    }
    guard let value = object["remaining_seconds"] else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      throw RuntimeError(.invalidRequest, "Invalid startup budget")
    }
    let double = number.doubleValue
    guard double.rounded() == double, let seconds = Int(exactly: number.int64Value),
      (1...3_600).contains(seconds)
    else {
      throw RuntimeError(.invalidRequest, "remaining_seconds must be an integer from 1 to 3600")
    }
    return seconds
  }
  private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do { return try JSON.decoder().decode(type, from: data) } catch {
      throw RuntimeError(.invalidRequest, "Invalid JSON payload: \(error.localizedDescription)")
    }
  }
}

/// `GET /v1/runtime/backups`: every backup, oldest first.
public struct BackupList: Codable, Sendable, Equatable {
  public var schemaVersion = 1
  public var backups: [BackupSummary]
}
