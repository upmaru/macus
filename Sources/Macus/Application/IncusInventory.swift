import Darwin
import Foundation

/// Names Incus lists in one project: instances, default-pool volumes, managed networks and
/// profiles. Names only; nothing here reads or changes a workload.
public struct IncusProjectInventory: Codable, Sendable, Equatable {
  public var name: String
  public var instances: [String]
  /// `type/name`, such as `custom/backups` or `container/web`. Image volumes are left out:
  /// Incus expires cached images on its own schedule, which is not a loss.
  public var volumes: [String]
  /// Managed networks only; unmanaged entries are the guest's own interfaces.
  public var networks: [String]
  public var profiles: [String]
}

public struct IncusInventory: Codable, Sendable, Equatable {
  public var schemaVersion = 1
  /// Sorted by name.
  public var projects: [IncusProjectInventory]

  public init(projects: [IncusProjectInventory]) {
    self.projects = projects.sorted { $0.name < $1.name }
  }

  /// Every name in `earlier` that this inventory lacks, as `kind name (project p)`. New names
  /// are allowed.
  func missing(from earlier: IncusInventory) -> [String] {
    var result: [String] = []
    let now = Dictionary(projects.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    for project in earlier.projects {
      guard let current = now[project.name] else {
        result.append("project \(project.name)")
        continue
      }
      let kinds: [(String, [String], [String])] = [
        ("instance", project.instances, current.instances),
        ("volume", project.volumes, current.volumes),
        ("network", project.networks, current.networks),
        ("profile", project.profiles, current.profiles),
      ]
      for (kind, before, after) in kinds {
        let present = Set(after)
        for name in before where !present.contains(name) {
          result.append("\(kind) \(name) (project \(project.name))")
        }
      }
    }
    return result
  }
}

/// What the upgrade result says about the comparison.
public struct UpgradeInventoryOutcome: Codable, Sendable, Equatable {
  /// False when the previous guest could not be queried.
  public var compared: Bool
  public var skippedReason: String?
  /// The inventory of the upgraded runtime, for the user to check.
  public var current: IncusInventory
}

/// One Incus API read, returning the response's `metadata`.
protocol IncusQuerying: Sendable {
  func get(_ path: String) async throws -> Data
}

/// Reads the inventory through a guest stream opener. Production reads Incus over an
/// internal relay stream; tests substitute their own source.
protocol IncusInventorySource: Sendable {
  func read(open: @escaping @Sendable () async throws -> GuestStream) async throws
    -> IncusInventory
}

struct RelayInventorySource: IncusInventorySource {
  var timeout = 30
  func read(open: @escaping @Sendable () async throws -> GuestStream) async throws
    -> IncusInventory
  {
    try await IncusInventoryReader.read(RelayIncusQuery(open: open, timeout: timeout))
  }
}

enum IncusInventoryReader {
  /// The pool bootstrap creates on `tama-data/workloads`.
  static let pool = "default"

  static func read(_ query: any IncusQuerying) async throws -> IncusInventory {
    let projectURLs = try decodeURLs(try await query.get("/1.0/projects"))
    var projects: [IncusProjectInventory] = []
    for url in projectURLs {
      let name = try lastName(url, prefix: "/1.0/projects")
      let scope = "project=\(queryEscape(name))"
      let instances = try decodeURLs(try await query.get("/1.0/instances?\(scope)"))
        .map { try lastName($0, prefix: "/1.0/instances") }
      let volumes = try decodeURLs(
        try await query.get("/1.0/storage-pools/\(pool)/volumes?\(scope)")
      )
      .map { try lastName($0, prefix: "/1.0/storage-pools/\(pool)/volumes") }
      .filter { !$0.hasPrefix("image/") }
      let networks = try JSON.decoder().decode(
        [NetworkEntry].self, from: try await query.get("/1.0/networks?\(scope)&recursion=1")
      )
      .filter(\.managed).map(\.name)
      let profiles = try decodeURLs(try await query.get("/1.0/profiles?\(scope)"))
        .map { try lastName($0, prefix: "/1.0/profiles") }
      projects.append(
        IncusProjectInventory(
          name: name, instances: instances.sorted(), volumes: volumes.sorted(),
          networks: networks.sorted(), profiles: profiles.sorted()))
    }
    return IncusInventory(projects: projects)
  }

  private struct NetworkEntry: Decodable {
    let name: String
    let managed: Bool
  }

  private static func decodeURLs(_ data: Data) throws -> [String] {
    try JSON.decoder().decode([String].self, from: data)
  }

  /// The path below `prefix`, without its query, each component percent-decoded.
  static func lastName(_ url: String, prefix: String) throws -> String {
    let path = url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard path.hasPrefix(prefix + "/") else {
      throw RuntimeError(.io, "Unexpected Incus URL \(url)")
    }
    let components = path.dropFirst(prefix.count + 1).split(
      separator: "/", omittingEmptySubsequences: false)
    let decoded = try components.map { component -> String in
      guard !component.isEmpty, let value = String(component).removingPercentEncoding else {
        throw RuntimeError(.io, "Unexpected Incus URL \(url)")
      }
      return value
    }
    return decoded.joined(separator: "/")
  }

  static func queryEscape(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}

/// Incus requests over an internal relay stream: a socket pair whose far end the
/// flow-controlled relay joins to the guest, exactly as it joins an `incus.sock` client.
/// It works while the relay is closed to clients.
struct RelayIncusQuery: IncusQuerying {
  let open: @Sendable () async throws -> GuestStream
  let timeout: Int

  func get(_ path: String) async throws -> Data {
    let stream = try await open()
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      stream.socket.shutdown()
      await stream.release()
      throw RuntimeError(.io, "Cannot create the internal Incus stream")
    }
    let local: SocketDescriptor
    let relaySide: SocketDescriptor
    do {
      local = try SocketDescriptor(pair[0])
      relaySide = try SocketDescriptor(pair[1])
    } catch {
      Darwin.close(pair[0])
      Darwin.close(pair[1])
      stream.socket.shutdown()
      await stream.release()
      throw error
    }
    let relay = Task { await FlowControlledRelay.relay(client: relaySide, guest: stream.socket) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    let result: Result<LocalHTTPResponse, any Error>
    do {
      try local.setNonblocking()
      result = .success(
        try await SocketIO.run {
          try UnixHTTPClient.exchange(on: local, method: "GET", path: path, deadline: deadline)
        })
    } catch {
      result = .failure(error)
    }
    local.shutdown()
    relay.cancel()
    await relay.value
    await stream.release()
    let response = try result.get()
    guard response.status == 200 else {
      throw RuntimeError(.unavailable, "Incus answered \(response.status) for \(path)")
    }
    guard
      let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let metadata = object["metadata"]
    else { throw RuntimeError(.io, "Incus returned no metadata for \(path)") }
    return try JSONSerialization.data(withJSONObject: metadata, options: [.fragmentsAllowed])
  }
}
