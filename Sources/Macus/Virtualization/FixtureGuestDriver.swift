import Darwin
import Foundation

/// The guest of an isolated cross-component fixture (`MACUS_FIXTURE_GUEST_DIR`). Starting
/// creates no virtual machine: it only marks the guest running. Each vsock port is the
/// owner-private Unix socket `vsock-<port>.sock` in `directory`, which the fixture serves with
/// the real guest bridge, so health, the flow-controlled relay and every runtime route above
/// this driver are the production code.
public actor FixtureGuestDriver: VirtualMachineDriver {
  public let directory: URL
  private var running = false

  public init(directory: URL) { self.directory = directory }

  public func capabilities() async -> HostCapabilities {
    await MainActor.run { CapabilityDetector.detect() }
  }

  public func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws {
    guard !running else { throw RuntimeError(.conflict, "VM already active") }
    running = true
  }

  public func requestStop() async throws { running = false }
  public func forceStop() async throws { running = false }
  public func isRunning() async -> Bool { running }

  public func openStream(port: UInt32) async throws -> GuestStream {
    guard running else { throw RuntimeError(.unavailable, "Guest socket device is unavailable") }
    let path = directory.appendingPathComponent("vsock-\(port).sock").path
    let socket = try await SocketIO.run { () throws -> SocketDescriptor in
      try validatePrivateUnixSocket(URL(fileURLWithPath: path))
      let descriptor = try SocketDescriptor(Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let bytes = Array(path.utf8) + [0]
      guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw RuntimeError(.invalidConfiguration, "Fixture guest socket path is too long")
      }
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor.rawValue, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard connected == 0 else {
        throw RuntimeError(.unavailable, "Fixture guest port \(port) is not listening")
      }
      return descriptor
    }
    return GuestStream(socket: socket, release: {})
  }

  public func health() async throws -> GuestHealth {
    try await GuestHealthProbe.fetch(try await openStream(port: 8444))
  }
}
