import Darwin
import Foundation
import Testing

@testable import Macus

@Test(arguments: [
  "POST /v1/runtime/start HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0",
  "POST /v1/runtime/start HTTP/1.1\r\nTransfer-Encoding: chunked",
  "POST /v1/runtime/start HTTP/1.1\r\nContent-Length: -1",
  "POST /v1/runtime/start HTTP/1.1\r\nContent-Length: 1048577",
  "POST /v1/runtime/start HTTP/1.1\r\n Content-Length: 0",
]) func ambiguousHTTPRejected(header: String) {
  #expect(throws: RuntimeError.self) { try HTTPRequest.parseHeader(Data(header.utf8)) }
}

@Test func validHTTPFrame() throws {
  let (method, path, size) = try HTTPRequest.parseHeader(
    Data("PUT /v1/runtime/config HTTP/1.1\r\nHost: local\r\nContent-Length: 2".utf8))
  #expect(method == "PUT" && path == "/v1/runtime/config" && size == 2)
}

func socketPair() throws -> (SocketDescriptor, SocketDescriptor) {
  var descriptors: [Int32] = [0, 0]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
    throw RuntimeError(.io, "socketpair failed")
  }
  return try (SocketDescriptor(descriptors[0]), SocketDescriptor(descriptors[1]))
}

@Test @MainActor func unresponsiveGuestConnectionHasDeadline() async throws {
  let attempt = GuestConnectionAttempt()
  let began = ContinuousClock.now
  do {
    _ = try await attempt.wait(timeout: .milliseconds(20)) { _ in }
    Issue.record("An unresponsive connection unexpectedly succeeded")
  } catch let error as RuntimeError {
    #expect(error.code == .timeout)
  }
  #expect(began.duration(to: .now) < .seconds(2))
  #expect(!attempt.isPending)
  #expect(!attempt.finish(.failure(RuntimeError(.unavailable, "Late callback"))))
}

@Test @MainActor func pendingGuestConnectionCanBeCancelled() async throws {
  let attempt = GuestConnectionAttempt()
  var requested = false
  let task = Task { try await attempt.wait(timeout: .seconds(30)) { _ in requested = true } }
  while !requested { await Task.yield() }
  task.cancel()
  switch await task.result {
  case .failure(let error): #expect(error is CancellationError)
  case .success: Issue.record("Cancelled connection unexpectedly succeeded")
  }
  #expect(!attempt.isPending)
}

@Test func idleRelaysDoNotBlockControlWorkersAndCanBeCancelled() async throws {
  var peers: [SocketDescriptor] = []
  var relays: [Task<Void, Never>] = []
  defer {
    for peer in peers { peer.shutdown() }
    for relay in relays { relay.cancel() }
  }
  for _ in 0..<80 {
    let (client, host) = try socketPair()
    let (guest, server) = try socketPair()
    peers.append(contentsOf: [client, server])
    relays.append(Task { await FlowControlledRelay.relay(client: host, guest: guest) })
  }
  try await Task.sleep(for: .milliseconds(100))
  let completed = DispatchSemaphore(value: 0)
  let control = Task { try await SocketIO.run { _ = completed.signal() } }
  let result = await Task.detached { waitForControl(completed) }.value
  // Always release streams before awaiting the probe, so this regression cannot
  // strand the suite when run against the former blocking relay implementation.
  for relay in relays { relay.cancel() }
  for peer in peers { peer.shutdown() }
  for relay in relays { await relay.value }
  try await control.value
  #expect(result)
}

private func waitForControl(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now() + 2) == .success
}
