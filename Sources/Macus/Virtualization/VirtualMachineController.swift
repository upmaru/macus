import Darwin
import Foundation
import Virtualization
import os

@MainActor
public final class VirtualMachineController: NSObject, VirtualMachineDriver,
  @MainActor VZVirtualMachineDelegate
{
  private var machine: VZVirtualMachine?
  private var activity: (any NSObjectProtocol)?
  private var connections: [UUID: VZVirtioSocketConnection] = [:]
  private let logger = Logger(subsystem: "com.upmaru.macus", category: "virtualization")
  public override init() { super.init() }
  public func capabilities() async -> HostCapabilities { CapabilityDetector.detect() }
  public func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws {
    guard machine == nil || machine?.state == .stopped || machine?.state == .error else {
      throw RuntimeError(.conflict, "VM already active")
    }
    // Release the previous VM before reopening its EFI store. Virtualization.framework
    // drops that file lock asynchronously, and validating too soon reports an invalid
    // boot loader even though the existing store is intact. Do not recreate it.
    closeConnections()
    machine = nil
    let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while true {
      try Task.checkCancellation()
      do {
        let vm = try autoreleasepool {
          try VZVirtualMachine(
            configuration: VirtualMachineConfiguration.make(configuration, paths: paths))
        }
        vm.delegate = self
        machine = vm
        endActivity()
        activity = ProcessInfo.processInfo.beginActivity(
          options: .userInitiatedAllowingIdleSystemSleep,
          reason: "Run user-requested Incus host VM")
        do {
          try await vm.start()
          return
        } catch {
          endActivity()
          machine = nil
          throw error
        }
      } catch {
        guard Self.efiStoreStillAttached(error), ContinuousClock.now < releaseDeadline else {
          throw error
        }
        try await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  private static func efiStoreStillAttached(_ error: Error) -> Bool {
    error.localizedDescription.localizedCaseInsensitiveContains("boot loader is invalid")
  }
  public func requestStop() async throws {
    guard let machine, machine.canRequestStop else {
      throw RuntimeError(.unavailable, "Guest cannot accept graceful shutdown")
    }
    try machine.requestStop()
  }
  public func forceStop() async throws {
    for connection in connections.values {
      _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
    }
    connections.removeAll()
    guard let machine, machine.canStop else { return }
    try await machine.stop()
    self.machine = nil
    endActivity()
  }
  public func isRunning() async -> Bool {
    guard let machine else { return false }
    return machine.state != .stopped && machine.state != .error
  }
  public func openStream(port: UInt32) async throws -> GuestStream {
    guard let device = machine?.socketDevices.first as? VZVirtioSocketDevice,
      machine?.state == .running
    else {
      throw RuntimeError(.unavailable, "Guest socket device is unavailable")
    }
    let attempt = GuestConnectionAttempt()
    return try await attempt.wait { [self] attempt in
      device.connect(toPort: port) { [self] result in
        // VZ invokes this completion on the VM's queue, which is the main queue.
        MainActor.assumeIsolated {
          guard attempt.isPending else {
            // VZ has no cancel-connect API. Discard a connection delivered after
            // our deadline/cancellation instead of retaining or exposing it.
            if case .success(let connection) = result {
              _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
            }
            return
          }
          do {
            let connection = try result.get()
            let descriptor = try SocketDescriptor(dup(connection.fileDescriptor))
            let id = UUID()
            self.connections[id] = connection
            let stream = GuestStream(socket: descriptor) { [weak self] in
              await self?.releaseConnection(id)
            }
            attempt.finish(.success(stream))
          } catch {
            if case .success(let connection) = result {
              _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
            }
            attempt.finish(.failure(error))
          }
        }
      }
    }
  }
  private func releaseConnection(_ id: UUID) { connections.removeValue(forKey: id) }
  public func health() async throws -> GuestHealth {
    try await GuestHealthProbe.fetch(try await openStream(port: 8444))
  }
  public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    guard machine === virtualMachine else { return }
    closeConnections()
    machine = nil
    logger.info("Guest stopped")
  }
  public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    guard machine === virtualMachine else { return }
    closeConnections()
    machine = nil
    logger.error("Guest failed: \(error.localizedDescription, privacy: .public)")
  }
  private func endActivity() {
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
  }
  private func closeConnections() {
    endActivity()
    for connection in connections.values {
      _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
    }
    connections.removeAll()
  }
}
