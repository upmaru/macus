import Darwin
import Foundation

/// Per-connection flow control for the guest vsock hop.
///
/// Virtualization.framework services the whole virtio-vsock device on one serial queue
/// and writes guest bytes into each host descriptor with a blocking write. A host relay
/// that stops reading one guest descriptor therefore stalls every vsock connection.
/// This protocol lets the host drain guest descriptors unconditionally while bounding
/// memory: each direction may have at most `window` unacknowledged payload bytes, and a
/// receiver grants credit only after delivering bytes to its local peer.
public enum FlowRelayProtocol {
  /// The guest Incus relay port. Guests serve only this framed protocol on it.
  public static let port: UInt32 = 8443
  public static let version = 1
  public static let window = 262_144
  public static let maximumPayload = 65_536
  static let headerSize = 5
  /// Owed credit is granted once it reaches this size, or when local output drains.
  static let creditThreshold = window / 4

  public enum Frame: Equatable, Sendable {
    case data(Data)
    case credit(Int)
    case end
  }

  static let dataType: UInt8 = 1
  static let creditType: UInt8 = 2
  static let endType: UInt8 = 3

  public static func encode(_ frame: Frame) -> Data {
    var output = Data()
    switch frame {
    case .data(let payload):
      appendHeader(&output, type: dataType, length: payload.count)
      output.append(payload)
    case .credit(let count):
      appendHeader(&output, type: creditType, length: 4)
      appendUInt32(&output, UInt32(count))
    case .end:
      appendHeader(&output, type: endType, length: 0)
    }
    return output
  }

  static func appendHeader(_ output: inout Data, type: UInt8, length: Int) {
    output.append(type)
    appendUInt32(&output, UInt32(length))
  }

  static func appendUInt32(_ output: inout Data, _ value: UInt32) {
    output.append(contentsOf: [
      UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
    ])
  }
}

struct FlowProtocolViolation: Error, Equatable {
  let reason: String
}

/// Incrementally decodes frames, validating each header before buffering its payload.
struct FlowFrameParser {
  private var buffer = ByteQueue()

  mutating func append(_ bytes: UnsafeRawBufferPointer) throws -> [FlowRelayProtocol.Frame] {
    buffer.append(bytes)
    var frames: [FlowRelayProtocol.Frame] = []
    while buffer.count >= FlowRelayProtocol.headerSize {
      let header = buffer.peek(FlowRelayProtocol.headerSize)
      let type = header[0]
      let length = Self.uint32(header, at: 1)
      switch type {
      case FlowRelayProtocol.dataType:
        guard length >= 1, length <= FlowRelayProtocol.maximumPayload else {
          throw FlowProtocolViolation(reason: "invalid data length")
        }
      case FlowRelayProtocol.creditType:
        guard length == 4 else { throw FlowProtocolViolation(reason: "invalid credit length") }
      case FlowRelayProtocol.endType:
        guard length == 0 else { throw FlowProtocolViolation(reason: "invalid end length") }
      default:
        throw FlowProtocolViolation(reason: "unknown frame type")
      }
      guard buffer.count >= FlowRelayProtocol.headerSize + length else { break }
      buffer.consume(FlowRelayProtocol.headerSize)
      let payload = buffer.take(length)
      switch type {
      case FlowRelayProtocol.dataType:
        frames.append(.data(payload))
      case FlowRelayProtocol.creditType:
        let count = Self.uint32(Array(payload), at: 0)
        guard count >= 1, count <= FlowRelayProtocol.window else {
          throw FlowProtocolViolation(reason: "invalid credit")
        }
        frames.append(.credit(count))
      default:
        frames.append(.end)
      }
    }
    return frames
  }

  private static func uint32(_ bytes: [UInt8], at offset: Int) -> Int {
    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
      | Int(bytes[offset + 3])
  }
}

/// FIFO byte buffer with amortized O(1) consumption.
struct ByteQueue {
  private var storage: [UInt8] = []
  private var head = 0

  var count: Int { storage.count - head }
  var isEmpty: Bool { count == 0 }

  mutating func append(_ bytes: UnsafeRawBufferPointer) {
    storage.append(contentsOf: bytes)
  }
  mutating func append(_ data: Data) {
    storage.append(contentsOf: data)
  }
  func peek(_ length: Int) -> [UInt8] {
    Array(storage[head..<(head + length)])
  }
  mutating func take(_ length: Int) -> Data {
    let data = Data(storage[head..<(head + length)])
    consume(length)
    return data
  }
  mutating func consume(_ length: Int) {
    head += length
    if head == storage.count {
      storage.removeAll(keepingCapacity: true)
      head = 0
    } else if head >= 65_536, head * 2 >= storage.count {
      storage.removeFirst(head)
      head = 0
    }
  }
  /// Writes from the front without blocking until drained, EAGAIN or an error.
  mutating func write(to descriptor: Int32) -> (written: Int, failed: Bool) {
    var total = 0
    while !isEmpty {
      let written = storage.withUnsafeBytes {
        Darwin.write(descriptor, $0.baseAddress!.advanced(by: head), count)
      }
      if written > 0 {
        consume(written)
        total += written
        continue
      }
      if written < 0, errno == EINTR { continue }
      if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { return (total, false) }
      return (total, true)
    }
    return (total, false)
  }
}

public enum FlowControlledRelay {
  /// Relays `client` (an incus.sock connection) and `guest` (a flow-protocol vsock stream)
  /// until both directions end, either side fails, or the task is cancelled.
  public static func relay(client: SocketDescriptor, guest: SocketDescriptor) async {
    let relay = FlowRelayConnection(client: client, guest: guest)
    await withTaskCancellationHandler {
      await withCheckedContinuation { relay.start($0) }
    } onCancel: {
      relay.cancel()
    }
  }
}

/// Dispatch source with an explicit armed state; sources are created suspended.
private final class ArmableSource {
  let source: any DispatchSourceProtocol
  private(set) var armed = false
  private var cancelled = false
  init(_ source: any DispatchSourceProtocol) { self.source = source }
  func arm() {
    guard !armed, !cancelled else { return }
    armed = true
    source.resume()
  }
  func disarm() {
    guard armed, !cancelled else { return }
    armed = false
    source.suspend()
  }
  func cancel() {
    guard !cancelled else { return }
    cancelled = true
    source.cancel()
    // A suspended source never runs its cancellation handler.
    if !armed {
      armed = true
      source.resume()
    }
  }
}

/// All mutable state is confined to `queue`. Guest-bound output holds at most one data
/// frame plus control frames; client-bound output is bounded by the receive window.
private final class FlowRelayConnection: @unchecked Sendable {
  let queue = DispatchQueue(label: "com.upmaru.macus.flow-relay")
  let client: SocketDescriptor
  let guest: SocketDescriptor
  var continuation: CheckedContinuation<Void, Never>?
  var finished = false

  var clientReader: ArmableSource?
  var clientWriter: ArmableSource?
  var guestReader: ArmableSource?
  var guestWriter: ArmableSource?

  var parser = FlowFrameParser()
  var toClient = ByteQueue()
  var toGuest = ByteQueue()
  var readBuffer = [UInt8](repeating: 0, count: FlowRelayProtocol.maximumPayload)

  /// Payload bytes we may still send to the guest.
  var sendCredit = FlowRelayProtocol.window
  /// Bytes written to the client that the guest has not yet been credited for.
  var owedCredit = 0
  var endQueued = false
  /// Guest-bound bytes that must still be written before our END frame is delivered.
  var endBytesPending: Int?
  var endDelivered = false
  var endReceived = false
  var clientWriteShut = false
  var guestWritesFailed = false

  init(client: SocketDescriptor, guest: SocketDescriptor) {
    self.client = client
    self.guest = guest
  }

  func start(_ continuation: CheckedContinuation<Void, Never>) {
    queue.async {
      guard !self.finished else {
        continuation.resume()
        return
      }
      self.continuation = continuation
      do {
        try self.client.setNonblocking()
        try self.guest.setNonblocking()
      } catch {
        self.finish()
        return
      }
      self.clientReader = self.makeSource(.clientRead)
      self.clientWriter = self.makeSource(.clientWrite)
      self.guestReader = self.makeSource(.guestRead)
      self.guestWriter = self.makeSource(.guestWrite)
      // The guest descriptor is always drained; only teardown cancels this source.
      self.guestReader?.arm()
      self.updateClientReader()
    }
  }

  func cancel() { queue.async { self.finish() } }

  private enum SourceKind { case clientRead, clientWrite, guestRead, guestWrite }

  private func makeSource(_ kind: SourceKind) -> ArmableSource {
    let socket: SocketDescriptor
    let source: any DispatchSourceProtocol
    switch kind {
    case .clientRead, .clientWrite: socket = client
    case .guestRead, .guestWrite: socket = guest
    }
    switch kind {
    case .clientRead, .guestRead:
      source = DispatchSource.makeReadSource(fileDescriptor: socket.rawValue, queue: queue)
    case .clientWrite, .guestWrite:
      source = DispatchSource.makeWriteSource(fileDescriptor: socket.rawValue, queue: queue)
    }
    source.setEventHandler { [weak self] in self?.handle(kind) }
    source.setCancelHandler { withExtendedLifetime(socket) {} }
    return ArmableSource(source)
  }

  private func handle(_ kind: SourceKind) {
    guard !finished else { return }
    switch kind {
    case .clientRead: readClient()
    case .clientWrite: flushClient()
    case .guestRead: readGuest()
    case .guestWrite: flushGuest()
    }
  }

  // MARK: Guest → client

  private func readGuest() {
    let count = readBuffer.withUnsafeMutableBytes {
      Darwin.read(guest.rawValue, $0.baseAddress!, $0.count)
    }
    if count > 0 {
      do {
        let frames = try readBuffer.withUnsafeBytes {
          try parser.append(UnsafeRawBufferPointer(rebasing: $0[0..<count]))
        }
        for frame in frames { try apply(frame) }
      } catch {
        finish()
        return
      }
      flushClient()
      flushGuest()
      updateClientReader()
      completeIfDone()
    } else if count == 0 {
      // The guest closes only after both ends of stream; anything earlier is an abort.
      guard endDelivered, endReceived else {
        finish()
        return
      }
      guestReader?.cancel()
      guestWritesFailed = true
      toGuest = ByteQueue()
      completeIfDone()
    } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
      finish()
    }
  }

  private func apply(_ frame: FlowRelayProtocol.Frame) throws {
    switch frame {
    case .data(let payload):
      guard !endReceived else { throw FlowProtocolViolation(reason: "data after end") }
      guard toClient.count + owedCredit + payload.count <= FlowRelayProtocol.window else {
        throw FlowProtocolViolation(reason: "window exceeded")
      }
      toClient.append(payload)
    case .credit(let count):
      guard sendCredit + count <= FlowRelayProtocol.window else {
        throw FlowProtocolViolation(reason: "credit exceeds window")
      }
      sendCredit += count
    case .end:
      guard !endReceived else { throw FlowProtocolViolation(reason: "duplicate end") }
      endReceived = true
    }
  }

  private func flushClient() {
    guard !finished else { return }
    let result = toClient.write(to: client.rawValue)
    guard !result.failed else {
      finish()
      return
    }
    owedCredit += result.written
    if toClient.isEmpty {
      clientWriter?.disarm()
      if endReceived, !clientWriteShut {
        client.shutdownWrite()
        clientWriteShut = true
      }
    } else {
      clientWriter?.arm()
    }
    // The guest no longer needs credit once it has ended its stream.
    if endReceived {
      owedCredit = 0
    } else if owedCredit > 0,
      owedCredit >= FlowRelayProtocol.creditThreshold || toClient.isEmpty
    {
      queueToGuest(.credit(owedCredit))
      owedCredit = 0
    }
    completeIfDone()
  }

  // MARK: Client → guest

  private var canReadClient: Bool {
    !endQueued && sendCredit > 0 && toGuest.count < FlowRelayProtocol.maximumPayload
  }

  private func updateClientReader() {
    if canReadClient { clientReader?.arm() } else { clientReader?.disarm() }
  }

  private func readClient() {
    guard canReadClient else {
      clientReader?.disarm()
      return
    }
    let limit = min(FlowRelayProtocol.maximumPayload, sendCredit)
    let count = readBuffer.withUnsafeMutableBytes {
      Darwin.read(client.rawValue, $0.baseAddress!, limit)
    }
    if count > 0 {
      sendCredit -= count
      queueToGuest(.data(Data(readBuffer[0..<count])))
    } else if count == 0 {
      endQueued = true
      clientReader?.cancel()
      queueToGuest(.end)
    } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
      finish()
      return
    }
    updateClientReader()
  }

  private func queueToGuest(_ frame: FlowRelayProtocol.Frame) {
    guard !guestWritesFailed else { return }
    toGuest.append(FlowRelayProtocol.encode(frame))
    if frame == .end { endBytesPending = toGuest.count }
    flushGuest()
  }

  private func flushGuest() {
    guard !finished, !guestWritesFailed else { return }
    let result = toGuest.write(to: guest.rawValue)
    if let pending = endBytesPending {
      endBytesPending = pending - result.written > 0 ? pending - result.written : nil
      if endBytesPending == nil { endDelivered = true }
    }
    if result.failed {
      // Once our end of stream is delivered only credit can remain, and the guest may
      // already have closed normally; its end of stream then decides the outcome.
      guard endDelivered else {
        finish()
        return
      }
      guestWritesFailed = true
      toGuest = ByteQueue()
      guestWriter?.disarm()
      return
    }
    if toGuest.isEmpty {
      guestWriter?.disarm()
      updateClientReader()
      completeIfDone()
    } else {
      guestWriter?.arm()
    }
  }

  // MARK: Completion

  private func completeIfDone() {
    guard !finished, endDelivered, endReceived, toClient.isEmpty, clientWriteShut else { return }
    finish()
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    for source in [clientReader, clientWriter, guestReader, guestWriter] { source?.cancel() }
    client.shutdown()
    guest.shutdown()
    continuation?.resume()
    continuation = nil
  }
}
