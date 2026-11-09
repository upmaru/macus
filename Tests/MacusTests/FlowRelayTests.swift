import Darwin
import Foundation
import Testing

@testable import Macus

// MARK: Frame codec

@Test func flowFramesRoundTripAcrossArbitraryReadBoundaries() throws {
  let payload = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
  let frames: [FlowRelayProtocol.Frame] = [
    .data(payload.prefix(FlowRelayProtocol.maximumPayload)), .credit(1),
    .credit(FlowRelayProtocol.window), .data(Data([0])), .end,
  ]
  let encoded = frames.reduce(into: Data()) { $0.append(FlowRelayProtocol.encode($1)) }
  for split in [1, 2, 4, 5, 6, 4096, encoded.count] {
    var parser = FlowFrameParser()
    var decoded: [FlowRelayProtocol.Frame] = []
    var offset = 0
    while offset < encoded.count {
      let chunk = encoded[offset..<min(offset + split, encoded.count)]
      decoded += try chunk.withUnsafeBytes { try parser.append($0) }
      offset += split
    }
    #expect(decoded == frames)
  }
}

@Test(arguments: [
  [UInt8(9), 0, 0, 0, 0],  // unknown type
  [1, 0, 0, 0, 0],  // empty data
  [1, 0, 1, 0, 1],  // data larger than one frame
  [2, 0, 0, 0, 3, 0, 0, 1],  // credit with a short payload
  [2, 0, 0, 0, 4, 0, 0, 0, 0],  // zero credit
  [2, 0, 0, 0, 4, 0, 4, 0, 1],  // credit beyond the window
  [3, 0, 0, 0, 1],  // end with a payload
]) func malformedFlowFramesAreRejected(bytes: [UInt8]) {
  var parser = FlowFrameParser()
  #expect(throws: FlowProtocolViolation.self) {
    _ = try bytes.withUnsafeBytes { try parser.append($0) }
  }
}

@Test func headerIsValidatedBeforeItsPayloadArrives() {
  var parser = FlowFrameParser()
  // A huge declared length is rejected immediately rather than buffered.
  #expect(throws: FlowProtocolViolation.self) {
    _ = try [UInt8(1), 0xFF, 0xFF, 0xFF, 0xFF].withUnsafeBytes { try parser.append($0) }
  }
}

// MARK: Test peer standing in for the guest bridge

/// Speaks the flow protocol over one socket with blocking I/O on the SocketIO queue.
final class FlowTestPeer: @unchecked Sendable {
  let socket: SocketDescriptor
  private let condition = NSCondition()
  private let writeLock = NSLock()
  private var credit = FlowRelayProtocol.window
  private var received = Data()
  private var endReceived = false
  private var closed = false
  private(set) var creditReceived = 0
  /// Grant credit for received data immediately, as if delivered to Incus.
  let grantsCredit: Bool

  init(_ socket: SocketDescriptor, grantsCredit: Bool = true) {
    self.socket = socket
    self.grantsCredit = grantsCredit
  }

  func write(_ frame: FlowRelayProtocol.Frame) throws {
    try writeRaw(FlowRelayProtocol.encode(frame))
  }
  func writeRaw(_ bytes: Data) throws {
    writeLock.lock()
    defer { writeLock.unlock() }
    try socket.write(bytes)
  }

  /// Reads frames until EOF, recording data and applying credit.
  func runReader() throws {
    var parser = FlowFrameParser()
    while true {
      let chunk: Data
      do { chunk = try socket.read() } catch {
        markClosed()
        return
      }
      if chunk.isEmpty {
        markClosed()
        return
      }
      for frame in try chunk.withUnsafeBytes({ try parser.append($0) }) {
        switch frame {
        case .data(let payload):
          condition.lock()
          received.append(payload)
          condition.broadcast()
          condition.unlock()
          if grantsCredit { try? write(.credit(payload.count)) }
        case .credit(let count):
          condition.lock()
          credit += count
          creditReceived += count
          condition.broadcast()
          condition.unlock()
        case .end:
          condition.lock()
          endReceived = true
          condition.broadcast()
          condition.unlock()
        }
      }
    }
  }

  private func markClosed() {
    condition.lock()
    closed = true
    condition.broadcast()
    condition.unlock()
  }

  /// Sends `data` respecting the window, then END.
  func send(_ data: Data, end: Bool = true) throws {
    var offset = 0
    while offset < data.count {
      condition.lock()
      while credit == 0 && !closed { condition.wait() }
      let available = credit
      let isClosed = closed
      condition.unlock()
      guard !isClosed else { throw RuntimeError(.io, "peer closed") }
      let size = min(available, FlowRelayProtocol.maximumPayload, data.count - offset)
      condition.lock()
      credit -= size
      condition.unlock()
      try write(.data(data[offset..<(offset + size)]))
      offset += size
    }
    if end { try write(.end) }
  }

  func waitForEnd(seconds: Double = 5) -> Data? {
    let deadline = Date().addingTimeInterval(seconds)
    condition.lock()
    defer { condition.unlock() }
    while !endReceived {
      guard condition.wait(until: deadline) else { return nil }
    }
    return received
  }

  func waitUntilClosed(seconds: Double = 5) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    condition.lock()
    defer { condition.unlock() }
    while !closed {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
  }

  var availableCredit: Int {
    condition.lock()
    defer { condition.unlock() }
    return credit
  }
}

func readAll(_ socket: SocketDescriptor) throws -> Data {
  var received = Data()
  while true {
    let chunk = try socket.read()
    if chunk.isEmpty { return received }
    received.append(chunk)
  }
}

func unreadBytes(_ socket: SocketDescriptor) -> Int {
  // FIONREAD (_IOR('f', 127, int)) is a function-like macro that Swift does not import.
  let fionread: UInt = 0x4004_667F
  var count: Int32 = 0
  return ioctl(socket.rawValue, fionread, &count) == 0 ? Int(count) : -1
}

func setBuffer(_ socket: SocketDescriptor, _ option: Int32, _ size: Int32) {
  var value = size
  _ = setsockopt(socket.rawValue, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size))
}

struct FlowRelayFixture {
  let client: SocketDescriptor
  let guestPeer: FlowTestPeer
  let hostGuest: SocketDescriptor
  let relay: Task<Void, Never>
  let reader: Task<Void, any Error>

  init(
    grantsCredit: Bool = true, configure: (SocketDescriptor, SocketDescriptor) -> Void = { _, _ in }
  )
    throws
  {
    let (client, hostClient) = try socketPair()
    let (hostGuest, guest) = try socketPair()
    client.timeout(seconds: 10)
    guest.timeout(seconds: 10)
    configure(client, hostClient)
    self.client = client
    self.hostGuest = hostGuest
    let peer = FlowTestPeer(guest, grantsCredit: grantsCredit)
    guestPeer = peer
    relay = Task { await FlowControlledRelay.relay(client: hostClient, guest: hostGuest) }
    reader = Task { try await SocketIO.run { try peer.runReader() } }
  }

  func close() {
    client.shutdown()
    guestPeer.socket.shutdown()
    relay.cancel()
  }
}

// MARK: Relay behavior

@Test func flowRelayPreservesBinaryAndHalfCloseBothWays() async throws {
  let fixture = try FlowRelayFixture()
  defer { fixture.close() }
  let request = Data([0, 255, 128, 10, 13, 0, 42])
  let response = Data("response-after-client-half-close".utf8)
  try await SocketIO.run {
    try fixture.client.write(request)
    fixture.client.shutdownWrite()
    #expect(fixture.guestPeer.waitForEnd() == request)
    try fixture.guestPeer.send(response)
    #expect(try readAll(fixture.client) == response)
  }
  await fixture.relay.value
  // Normal completion closes the guest stream only after both ends of stream.
  #expect(fixture.guestPeer.waitUntilClosed())
}

@Test func flowRelayTransfersLargeStreamsBothWaysWithinTheWindow() async throws {
  let fixture = try FlowRelayFixture { client, host in
    for socket in [client, host] {
      setBuffer(socket, SO_SNDBUF, 2048)
      setBuffer(socket, SO_RCVBUF, 2048)
    }
  }
  defer { fixture.close() }
  let forward = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0) })
  let reverse = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
  let peer = fixture.guestPeer
  let client = fixture.client
  let sendReverse = Task { try await SocketIO.run { try peer.send(reverse) } }
  let writeForward = Task {
    try await SocketIO.run {
      try client.write(forward)
      client.shutdownWrite()
    }
  }
  let readReverse = Task { try await SocketIO.run { try readAll(client) } }
  #expect(try await readReverse.value == reverse)
  try await writeForward.value
  try await sendReverse.value
  let forwarded = try await SocketIO.run { peer.waitForEnd(seconds: 10) }
  #expect(forwarded == forward)
  await fixture.relay.value
}

@Test func stalledClientDrainsGuestUpToOneWindowWithoutCredit() async throws {
  let fixture = try FlowRelayFixture { client, host in
    setBuffer(client, SO_RCVBUF, 2048)
    setBuffer(host, SO_SNDBUF, 2048)
  }
  defer { fixture.close() }
  let payload = Data((0..<(3 * FlowRelayProtocol.window)).map { UInt8(truncatingIfNeeded: $0 / 3) })
  let peer = fixture.guestPeer
  let sender = Task { try await SocketIO.run { try peer.send(payload) } }
  // The guest exhausts its window while the client reads nothing.
  try await waitUntil { peer.availableCredit == 0 }
  try await Task.sleep(for: .milliseconds(200))
  #expect(peer.availableCredit == 0)
  #expect(peer.creditReceived < FlowRelayProtocol.creditThreshold)
  // The relay never leaves guest bytes unread, unlike a raw relay applying backpressure.
  #expect(unreadBytes(fixture.hostGuest) == 0)
  let client = fixture.client
  let received = try await SocketIO.run { try readAll(client) }
  #expect(received == payload)
  try await sender.value
}

@Test func windowViolationAbortsOnlyThatRelay() async throws {
  let fixture = try FlowRelayFixture { client, host in
    setBuffer(client, SO_RCVBUF, 2048)
    setBuffer(host, SO_SNDBUF, 2048)
  }
  defer { fixture.close() }
  let peer = fixture.guestPeer
  try await SocketIO.run {
    for _ in 0..<(FlowRelayProtocol.window / FlowRelayProtocol.maximumPayload) {
      try peer.write(.data(Data(repeating: 1, count: FlowRelayProtocol.maximumPayload)))
    }
    try peer.write(.data(Data([2])))
  }
  await fixture.relay.value
  #expect(peer.waitUntilClosed())
}

@Test(arguments: [
  FlowRelayProtocol.encode(.end) + FlowRelayProtocol.encode(.data(Data([1]))),
  Data([9, 0, 0, 0, 0]),
  FlowRelayProtocol.encode(.end) + FlowRelayProtocol.encode(.end),
]) func protocolViolationsAbortTheRelay(bytes: Data) async throws {
  let fixture = try FlowRelayFixture()
  defer { fixture.close() }
  let peer = fixture.guestPeer
  try await SocketIO.run { try peer.writeRaw(bytes) }
  await fixture.relay.value
  #expect(peer.waitUntilClosed())
}

@Test func excessCreditAbortsTheRelay() async throws {
  let fixture = try FlowRelayFixture()
  defer { fixture.close() }
  let peer = fixture.guestPeer
  try await SocketIO.run { try peer.write(.credit(1)) }
  await fixture.relay.value
  #expect(peer.waitUntilClosed())
}

@Test func guestCloseBeforeEndOfStreamAbortsTheClient() async throws {
  let fixture = try FlowRelayFixture()
  defer { fixture.close() }
  let peer = fixture.guestPeer
  let client = fixture.client
  try await SocketIO.run {
    try peer.send(Data("partial".utf8), end: false)
    peer.socket.shutdown()
  }
  await fixture.relay.value
  let received = try await SocketIO.run { (try? readAll(client)) ?? Data() }
  #expect(received.count <= 7)
}

@Test func flowRelayCanBeCancelled() async throws {
  let fixture = try FlowRelayFixture()
  defer { fixture.close() }
  try await Task.sleep(for: .milliseconds(50))
  fixture.relay.cancel()
  await fixture.relay.value
  #expect(fixture.guestPeer.waitUntilClosed())
}

func waitUntil(seconds: Double = 5, _ condition: @Sendable () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("Condition not reached before deadline")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

// MARK: Guest bridge compatibility

actor StreamFakeVM: VirtualMachineDriver {
  var flowRelayVersion: Int?
  var ports: [UInt32] = []
  var running = false
  init(flowRelayVersion: Int?) { self.flowRelayVersion = flowRelayVersion }
  func setFlowRelayVersion(_ version: Int?) { flowRelayVersion = version }
  func capabilities() async -> HostCapabilities {
    HostCapabilities(supported: true, nestedVirtualization: true)
  }
  func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws {
    running = true
  }
  func requestStop() async throws { running = false }
  func forceStop() async throws { running = false }
  func isRunning() async -> Bool { running }
  func openStream(port: UInt32) async throws -> GuestStream {
    ports.append(port)
    let (local, _) = try socketPair()
    return GuestStream(socket: local) {}
  }
  func health() async throws -> GuestHealth {
    GuestHealth(
      incusVersion: "test", apiExtensions: [], kvm: true, flowRelayVersion: flowRelayVersion)
  }
}

@Test func incusStreamsUseTheFlowRelayPort() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = StreamFakeVM(flowRelayVersion: FlowRelayProtocol.version)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  #expect(try await service.start().state == .ready)
  _ = try await service.openIncusStream()
  #expect(FlowRelayProtocol.port == 8443)
  #expect(await driver.ports == [8443])
}

@Test(arguments: [Int?.none, Int?.some(2)])
func startRefusesGuestBridgesWithoutTheFlowRelay(version: Int?) async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = StreamFakeVM(flowRelayVersion: version)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  await #expect(throws: RuntimeError.self) { try await service.start() }
  let status = await service.status()
  #expect(status.state == .failed)
  #expect(status.lastError == RuntimeService.legacyGuestBridge)
  await #expect(throws: RuntimeError.self) { try await service.openIncusStream() }
  #expect(await driver.ports.isEmpty)
}

@Test func readyRuntimeFailsWhenHealthLosesTheFlowRelay() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = StreamFakeVM(flowRelayVersion: FlowRelayProtocol.version)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  #expect(try await service.start().state == .ready)
  await driver.setFlowRelayVersion(nil)
  let status = await service.status()
  #expect(status.state == .failed)
  #expect(status.lastError == RuntimeService.legacyGuestBridge)
}

@Test func guestHealthDecodesWithAndWithoutFlowRelay() throws {
  let legacy = Data(
    #"{"protocol_version":1,"incus_version":"7.0.1","api_extensions":[],"kvm":true}"#.utf8)
  let current = Data(
    #"{"protocol_version":1,"incus_version":"7.0.1","api_extensions":[],"kvm":true,"flow_relay_version":1}"#
      .utf8)
  #expect(try JSON.decoder().decode(GuestHealth.self, from: legacy).flowRelayVersion == nil)
  #expect(try JSON.decoder().decode(GuestHealth.self, from: current).flowRelayVersion == 1)
}
