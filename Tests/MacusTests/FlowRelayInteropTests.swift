import Darwin
import Foundation
import Testing

@testable import Macus

/// Runs the host relay against the real guest bridge flow handler. A `python3`
/// subprocess connects to two Unix listeners standing in for vsock and the Incus socket.
struct BridgeInterop {
  let client: SocketDescriptor
  let hostGuest: SocketDescriptor
  let incus: SocketDescriptor
  let relay: Task<Void, Never>
  let process: Process
  let output: Pipe
  let directory: URL

  static var bridgePath: String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Integration/guest/bridge.py").path
  }

  static let script = """
    import importlib.util, socket, sys
    spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    vsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    vsock.connect(sys.argv[2])
    incus = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    incus.connect(sys.argv[3])
    connection = bridge.FlowConnection(vsock, incus)
    connection.run()
    print("aborted" if connection.aborted else "completed", flush=True)
    """

  init() async throws {
    directory = URL(fileURLWithPath: "/private/tmp/mfl-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let vsockPath = directory.appendingPathComponent("v").path
    let incusPath = directory.appendingPathComponent("i").path
    let vsockListener = try unixListener(vsockPath)
    let incusListener = try unixListener(incusPath)
    process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", Self.script, Self.bridgePath, vsockPath, incusPath]
    output = Pipe()
    process.standardOutput = output
    try process.run()
    hostGuest = try await SocketIO.run { try acceptOne(vsockListener) }
    incus = try await SocketIO.run { try acceptOne(incusListener) }
    let (client, hostClient) = try socketPair()
    client.timeout(seconds: 10)
    incus.timeout(seconds: 10)
    self.client = client
    let guest = hostGuest
    relay = Task { await FlowControlledRelay.relay(client: hostClient, guest: guest) }
  }

  func outcome() async throws -> String {
    let process = self.process
    let output = self.output
    return try await SocketIO.run {
      process.waitUntilExit()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  func close() {
    client.shutdown()
    incus.shutdown()
    relay.cancel()
    if process.isRunning { process.terminate() }
    try? FileManager.default.removeItem(at: directory)
  }
}

func unixListener(_ path: String) throws -> SocketDescriptor {
  let socket = try SocketDescriptor(Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    throw RuntimeError(.io, "Socket path too long")
  }
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: bytes)
  }
  let length = socklen_t(MemoryLayout<sockaddr_un>.size)
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(socket.rawValue, $0, length)
    }
  }
  guard bound == 0, Darwin.listen(socket.rawValue, 1) == 0 else {
    throw RuntimeError(.io, "Unix listener failed (errno \(errno))")
  }
  return socket
}

func acceptOne(_ listener: SocketDescriptor) throws -> SocketDescriptor {
  listener.timeout(seconds: 10)
  return try SocketDescriptor(Darwin.accept(listener.rawValue, nil, nil))
}

@Test func hostRelayInteroperatesWithGuestBridgeBothWays() async throws {
  let interop = try await BridgeInterop()
  defer { interop.close() }
  let forward = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0) })
  let reverse = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
  let client = interop.client
  let incus = interop.incus
  let writeForward = Task {
    try await SocketIO.run {
      try client.write(forward)
      client.shutdownWrite()
    }
  }
  let readForward = Task { try await SocketIO.run { try readAll(incus) } }
  #expect(try await readForward.value == forward)
  let writeReverse = Task {
    try await SocketIO.run {
      try incus.write(reverse)
      incus.shutdownWrite()
    }
  }
  #expect(try await SocketIO.run { try readAll(client) } == reverse)
  try await writeForward.value
  try await writeReverse.value
  await interop.relay.value
  #expect(try await interop.outcome() == "completed")
}

@Test func stalledClientDoesNotLeaveBridgeBytesUnread() async throws {
  let interop = try await BridgeInterop()
  defer { interop.close() }
  setBuffer(interop.client, SO_RCVBUF, 2048)
  let payload = Data((0..<(3 * FlowRelayProtocol.window)).map { UInt8(truncatingIfNeeded: $0 / 5) })
  let incus = interop.incus
  let writer = Task {
    try await SocketIO.run {
      try incus.write(payload)
      incus.shutdownWrite()
    }
  }
  try await Task.sleep(for: .milliseconds(300))
  // The bridge has spent its window and the host keeps the guest stream drained.
  #expect(unreadBytes(interop.hostGuest) == 0)
  let client = interop.client
  let received = try await SocketIO.run { () throws -> Data in
    let data = try readUntil(client, count: payload.count)
    client.shutdownWrite()
    return data
  }
  #expect(received == payload)
  try await writer.value
  await interop.relay.value
  #expect(try await interop.outcome() == "completed")
}

func readUntil(_ socket: SocketDescriptor, count: Int) throws -> Data {
  var received = Data()
  while received.count < count {
    let chunk = try socket.read()
    if chunk.isEmpty { break }
    received.append(chunk)
  }
  return received
}
