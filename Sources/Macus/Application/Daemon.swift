import Darwin
import Foundation
import os

@MainActor
public enum Daemon {
  public static func run(
    arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
    streams: MacusStreams = .standard
  ) async throws {
    if arguments.isEmpty || arguments == ["--help"] {
      streams.writeOutput(MacusCLI.helpText)
      return
    }
    let directory = try stateDirectory(arguments: arguments, environment: environment)
    // A fixture guest is refused before the state lock, sockets or any state are touched.
    let fixtureGuest = try FixtureSeam.path(
      FixtureSeam.guestVariable, environment: environment, stateDirectory: directory,
      kind: .directory)
    let paths = RuntimePaths(directory: directory)
    let lock = try StateLock(paths: paths)
    let driver: any VirtualMachineDriver =
      if let fixtureGuest { FixtureGuestDriver(directory: fixtureGuest) } else {
        VirtualMachineController()
      }
    let service = try RuntimeService(driver: driver, store: StateStore(paths: paths))
    let server = try APIServer(service: service, paths: paths)
    let logger = Logger(subsystem: "com.upmaru.macus", category: "daemon")
    let presentation = HumanPresentation(streams: streams, environment: environment)
    presentation.heading("Macus is listening")
    presentation.field("Control socket", paths.controlSocket.path)
    if let fixtureGuest {
      presentation.field("Fixture guest", "\(fixtureGuest.path) (no virtual machine)")
      logger.notice("Fixture guest, no virtual machine: \(fixtureGuest.path, privacy: .public)")
    }
    presentation.text("  This terminal owns the foreground daemon. Closing it stops the daemon.\n")
    logger.info("Control API: \(paths.controlSocket.path, privacy: .public)")
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let sources = [SIGTERM, SIGINT].map { number in
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { continuation.yield(()) }
      source.resume()
      return source
    }
    for await _ in stream {
      do { _ = try await service.stop() } catch {
        logger.error("Graceful termination failed: \(error.localizedDescription, privacy: .public)")
        // Keep serving if an operation is active, allowing a later shutdown signal.
        if (error as? RuntimeError)?.code == .conflict { continue }
        _ = try? await service.stop(force: true)
      }
      break
    }
    server.stop()
    continuation.finish()
    for source in sources { source.cancel() }
    withExtendedLifetime(lock) {}
  }

  public nonisolated static func stateDirectory(
    arguments: [String], environment: [String: String]
  ) throws -> URL {
    guard arguments.first == "serve",
      arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--state-dir")
    else { throw RuntimeError(.invalidRequest, "Use macus --help for supported serve arguments") }
    return try MacusCLI.stateDirectory(
      flag: arguments.count == 3 ? arguments[2] : nil, environment: environment)
  }
}
