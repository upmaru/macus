import Foundation
import Testing

@testable import Macus

// `macus start` drives creation, boot, progress and live health through the public gateway
// (`FakeServerProbe` relays `/runtime/*` to the scripted private runtime the way the server does).

@Test func stoppedRuntimeBootsThroughTheGatewayWithItsRemainingBudget() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  let script = BootScript(state: pair.state)
  pair.launch.responder = script.respond
  let daemon = try pair.openRuntime()
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  pair.probe.serving = true
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 0, "\(capture.error)")
  let object = try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any]
  #expect(object?["ready"] as? Bool == true)
  #expect(object?["capabilities"] != nil)

  let requests = pair.probe.requests
  #expect(requests.allSatisfy { $0.path.hasPrefix("/runtime/") })
  let starts = requests.filter { $0.method == "POST" }
  #expect(starts.map(\.path) == ["/runtime/start"])
  let budget = try JSONSerialization.jsonObject(with: Data(starts[0].body.utf8)) as? [String: Int]
  #expect(budget?.keys.sorted() == ["remaining_seconds"])
  #expect((1...5).contains(budget?["remaining_seconds"] ?? 0))
  // Live readiness is the guest's health and capabilities, read through the gateway.
  let reads = requests.filter { $0.method == "GET" }.map(\.path)
  #expect(reads.contains("/runtime/health") && reads.contains("/runtime/capabilities"))
  // The private runtime received exactly the one relayed boot.
  #expect(daemon.requests().filter { $0.method != "GET" }.map(\.path) == ["/v1/runtime/start"])
}

@Test func lostGatewayDuringBootIsNotRetriedAndReadinessIsObservedThroughIt() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  // Swift accepts the boot and keeps working through the expected kernel restart while the
  // connection to the server is lost.
  let script = BootScript(state: pair.state, startingReads: 6)
  pair.launch.responder = script.respond
  let daemon = try pair.openRuntime()
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  pair.probe.serving = true
  pair.probe.drop("POST", "/runtime/start", .afterDispatch)
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 0, "\(capture.error)")
  let object = try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any]
  #expect(object?["ready"] as? Bool == true)

  let requests = pair.probe.requests
  #expect(requests.filter { $0.method == "POST" }.count == 1)
  #expect(requests.contains { $0.path == "/runtime/progress" })
  #expect(requests.filter { $0.path == "/runtime/status" }.count > 6)
  #expect(daemon.requests().filter { $0.method != "GET" }.map(\.path) == ["/v1/runtime/start"])
  #expect(script.reads >= 6)
}

@Test func startLostBeforeDispatchIsReportedWithoutRetryOrMutation() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  let script = BootScript(state: pair.state)
  pair.launch.responder = script.respond
  let daemon = try pair.openRuntime()
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  pair.probe.serving = true
  pair.probe.drop("POST", "/runtime/start", .beforeDispatch)
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 1)
  #expect(capture.error.contains("runtime is now stopped"))
  #expect(capture.error.contains("not sent again"))
  #expect(pair.probe.requests.filter { $0.method == "POST" }.count == 1)
  #expect(!daemon.requests().contains { $0.method != "GET" })
  #expect(
    try Data(contentsOf: pair.state.appendingPathComponent("runtime/data.raw"))
      == Data("data".utf8))
}

@Test func stoppedServerJobIsRecoveredAloneWhileTheReadyVMKeepsRunning() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  // Swift owns a ready guest under launchd; only the server job is stopped.
  let daemon = try pair.openRuntime()
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: false))
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 0, "\(capture.error)")
  let object = try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any]
  #expect(object?["ready"] as? Bool == true)
  #expect(object?["service_ownership"] as? String == "launchd")
  #expect(pair.launch.kickstarted == [pair.serverLabel])
  #expect(pair.launch.bootstrapped.isEmpty)
  // Public connectivity was rechecked; nothing started, stopped or recreated the guest.
  #expect(pair.probe.requests.contains { $0.path == "/runtime/status" })
  #expect(pair.probe.requests.allSatisfy { $0.method == "GET" })
  #expect(daemon.requests().allSatisfy { $0.method == "GET" })
}

@Test func interruptDuringGatewayBootReportsTheObservedGuestWithoutStoppingIt() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  let script = BootScript(state: pair.state, startingReads: 1_000)
  pair.launch.responder = script.respond
  let daemon = try pair.openRuntime()
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  pair.probe.serving = true
  pair.probe.drop("POST", "/runtime/start", .interruptAfterDispatch)
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 130)
  #expect(capture.output.isEmpty)
  #expect(capture.error.contains("interrupted"))
  // The observed state comes from the gateway; the guest is left booting.
  #expect(capture.error.contains("Observed runtime state is starting"))
  #expect(capture.error.contains("not force-stopped"))
  #expect(daemon.requests().filter { $0.method != "GET" }.map(\.path) == ["/v1/runtime/start"])
}

/// A private runtime that is stopped until it receives a boot, then reports `starting` (with
/// the expected kernel restart in its progress) for `startingReads` status reads before `ready`.
final class BootScript: @unchecked Sendable {
  private let lock = NSLock()
  private let state: URL
  private var phase = "stopped"
  private var remaining: Int
  private var count = 0

  init(state: URL, startingReads: Int = 0) {
    self.state = state
    remaining = startingReads
  }

  /// Status reads answered while starting.
  var reads: Int { lock.withLock { count } }

  var respond: @Sendable (String, String, Data) -> Data {
    { [self] method, path, body in answer(method, path, body) }
  }

  private func answer(_ method: String, _ path: String, _ body: Data) -> Data {
    let incus = state.appendingPathComponent("incus.sock").path
    switch (method, path) {
    case ("POST", "/v1/runtime/start"):
      let state: String = lock.withLock {
        phase = remaining > 0 ? "starting" : "ready"
        return phase
      }
      return mustJSON(200, statusObject(state: state, incus: incus))
    case ("GET", "/v1/runtime/status"):
      let state: String = lock.withLock {
        if phase == "starting" {
          count += 1
          remaining -= 1
          if remaining <= 0 { phase = "ready" }
          return "starting"
        }
        return phase
      }
      return mustJSON(200, statusObject(state: state, incus: incus))
    case ("GET", "/v1/runtime/progress"):
      let state = lock.withLock { phase }
      if state == "starting" {
        return mustJSON(
          200,
          [
            "api_version": 1, "ready": false, "state": "starting", "phase": "kernel_transition",
            "expected_reboot": true,
          ])
      }
      return mustJSON(200, ["api_version": 1, "ready": state == "ready", "state": state])
    case ("POST", _):
      return mustJSON(500, ["error": ["code": "io", "message": "unexpected mutation"]])
    default:
      return readyRuntime(method: method, path: path, directory: state)
    }
  }
}
