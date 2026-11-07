import Foundation

public struct GuestStream: Sendable {
  public let socket: SocketDescriptor
  public let release: @Sendable () async -> Void
  public init(socket: SocketDescriptor, release: @escaping @Sendable () async -> Void) {
    self.socket = socket
    self.release = release
  }
}

/// How bytes cross the vsock hop for one incus.sock connection.
public enum IncusRelayMode: Sendable, Equatable {
  /// Unframed bytes on guest port 8443, used by appliances without the flow relay.
  case raw
  /// Flow-controlled frames on ``FlowRelayProtocol/port``.
  case flowControlled
}

public struct IncusStream: Sendable {
  public let stream: GuestStream
  public let mode: IncusRelayMode
}

public protocol VirtualMachineDriver: Sendable {
  func capabilities() async -> HostCapabilities
  func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws
  func requestStop() async throws
  func forceStop() async throws
  func isRunning() async -> Bool
  func openStream(port: UInt32) async throws -> GuestStream
  func health() async throws -> GuestHealth
}
