import Foundation
import Testing

@testable import Macus

// `macus start` reports both services and the public endpoint, keeps its JSON, progress and
// error contracts, and says truthfully what a failed or interrupted start left in place: only the
// established service pair.

/// The keys a successful `start --json` has always had here (`path_guidance` because the fixture
/// client is not on PATH).
private let establishedKeys: Set<String> = [
  "capabilities", "connected", "incus", "installed", "next_commands", "path_guidance", "ready",
  "remote", "service_label", "service_ownership", "state_directory",
]

private func publishedURL(_ pair: PairFixture) throws -> String {
  let data = try Data(contentsOf: pair.state.appendingPathComponent("server/endpoint.json"))
  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  return try #require(object?["url"] as? String)
}

private func errorObject(_ text: String) throws -> [String: Any] {
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  #expect(Set(object.keys) == ["error"])
  let error = try #require(object["error"] as? [String: Any])
  #expect(Set(error.keys) == ["code", "message"])
  return error
}

@Test func startReportsBothServicesAndTheEndpointWithoutChangingItsContract() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  // Neither job exists: start bootstraps the pair.
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 0, "\(capture.error)")
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any])
  #expect(
    Set(object.keys)
      == establishedKeys.union(["server_endpoint", "server_label", "server_ownership"]))
  // The established fields keep their meaning: the Swift runtime service.
  #expect(object["service_ownership"] as? String == "launchd")
  #expect(object["service_label"] as? String == pair.runtimeLabel)
  #expect(object["ready"] as? Bool == true && object["connected"] as? Bool == true)
  #expect(object["server_ownership"] as? String == "launchd")
  #expect(object["server_label"] as? String == pair.serverLabel)
  let endpoint = try #require(object["server_endpoint"] as? [String: String])
  #expect(
    endpoint == [
      "url": try publishedURL(pair),
      "certificate_fingerprint": FixtureCertificate.server.fingerprint,
    ])
  #expect(capture.error.isEmpty)

  // The human report adds a Server section after the unchanged Service section.
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  let human = StartCapture()
  #expect(await pair.start(capture: human, json: false) == 0, "\(human.error)")
  let report = human.output
  let service = try #require(report.range(of: "\nService\n"))
  let server = try #require(report.range(of: "\nServer\n"))
  #expect(service.upperBound <= server.lowerBound)
  #expect(report[service.upperBound..<server.lowerBound].contains("Label: \(pair.runtimeLabel)"))
  let serverSection = report[server.upperBound...]
  #expect(serverSection.contains("Ownership: Launchd"))
  #expect(serverSection.contains("Label: \(pair.serverLabel)"))
  #expect(serverSection.contains("Endpoint: \(try publishedURL(pair))"))
  #expect(
    pair.launch.bootstrapped.map(\.lastPathComponent).sorted()
      == ["\(pair.runtimeLabel).plist", "\(pair.serverLabel).plist"].sorted())
}

@Test func aForegroundServerIsReportedWithoutALabel() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  _ = try pair.openRuntime()
  pair.launch.register(pair.runtimeJob(loaded: true))
  // A server already serves this state outside launchd.
  pair.probe.serving = true
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 0, "\(capture.error)")
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any])
  #expect(object["server_ownership"] as? String == "foreground")
  #expect(object["server_label"] == nil)
  #expect((object["server_endpoint"] as? [String: String])?["url"] == (try publishedURL(pair)))
  #expect(pair.launch.bootstrapped.isEmpty && pair.launch.kickstarted.isEmpty)
}

@Test func clientFailureAfterReadinessIsAFailureThatNamesWhatStartLeft() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  let daemon = try pair.openRuntime()
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: false))
  pair.environment["MACUS_FIXTURE_LIST_FAIL"] = "1"
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 1)
  // Partial success is not a result: nothing on stdout, the usual error shape on stderr.
  #expect(capture.output.isEmpty)
  let error = try errorObject(capture.error)
  #expect(error["code"] as? String == "io")
  let message = try #require(error["message"] as? String)
  #expect(message.contains("Client setup failed after the runtime became ready"))
  #expect(message.contains("Start left both services in place"))
  #expect(message.contains("launchd job \(pair.runtimeLabel)"))
  #expect(message.contains("launchd job \(pair.serverLabel) at \(try publishedURL(pair))"))
  // Only the server job was recovered; the ready guest was not touched.
  #expect(pair.launch.kickstarted == [pair.serverLabel])
  #expect(pair.launch.bootstrapped.isEmpty)
  #expect(daemon.requests().allSatisfy { $0.method == "GET" })
}

@Test func failedStartProgressMarksOnlyTheFailedStage() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  _ = try pair.openRuntime()
  pair.launch.register(pair.runtimeJob(loaded: true))
  pair.launch.register(pair.serverJob(loaded: true))
  pair.probe.serving = true
  pair.environment["MACUS_FIXTURE_LIST_FAIL"] = "1"
  let capture = StartCapture()
  #expect(await pair.start(capture: capture, json: false, progress: "plain") == 1)
  let lines = capture.error.split(separator: "\n").map(String.init)
  let failed = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("⨯") }
  #expect(failed.count == 1, "\(lines)")
  #expect(failed.first?.contains("Connecting client failed") == true, "\(lines)")
  // The progress row carries the stage's own failure; the final message adds the partial state.
  #expect(failed.first?.contains("Start left both services") == false)
  #expect(capture.error.contains("Start left both services in place"))
  #expect(!capture.error.contains("Macus is ready"))
}

@Test func interruptAfterTheyAreEstablishedLeavesOnlyTheServicePair() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  // Neither job exists and the runtime is stopped: start bootstraps the pair, then boots.
  let script = BootScript(state: pair.state, startingReads: 1_000)
  pair.launch.responder = script.respond
  pair.probe.drop("POST", "/runtime/start", .interruptAfterDispatch)
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 130)
  #expect(capture.output.isEmpty)
  let error = try errorObject(capture.error)
  #expect(error["code"] as? String == "interrupted")
  let message = try #require(error["message"] as? String)
  #expect(message.contains("Observed runtime state is starting"))
  #expect(message.contains("not force-stopped"))
  #expect(message.contains("Start left both services in place"))
  #expect(message.contains(pair.runtimeLabel) && message.contains(pair.serverLabel))
  // Exactly the established pair was activated, once each, and nothing was started afterwards.
  #expect(
    pair.launch.bootstrapped.map(\.lastPathComponent)
      == ["\(pair.runtimeLabel).plist", "\(pair.serverLabel).plist"])
  #expect(pair.launch.kickstarted.isEmpty)
  #expect(
    try FileManager.default.contentsOfDirectory(
      atPath: pair.state.appendingPathComponent("launchd").path
    ).filter { $0.hasSuffix(".plist") }.sorted()
      == ["\(pair.runtimeLabel).plist", "\(pair.serverLabel).plist"].sorted())
}

@Test func failuresBeforeTheServicesServeClaimNothingAboutThem() async throws {
  let pair = try PairFixture()
  defer { pair.remove() }
  // The installed release is incomplete, so the server job cannot be created.
  try FileManager.default.removeItem(at: pair.release.appendingPathComponent("erts-15.2"))
  let capture = StartCapture()
  #expect(await pair.start(capture: capture) == 1)
  let message = try #require(try errorObject(capture.error)["message"] as? String)
  #expect(!message.contains("Start left both services"))
  #expect(pair.launch.bootstrapped.isEmpty)
}
