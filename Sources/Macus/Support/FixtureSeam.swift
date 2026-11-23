import Darwin
import Foundation

/// Opt-in seams for isolated cross-component fixture checks without a VM (design §8,
/// service-delivery "Isolated cross-component fixture seams"). Each is refused unless the
/// state directory and the fixture path resolve beneath `/private/tmp`, belong to the current
/// user, are not group- or world-writable and contain no symbolic link of their own.
enum FixtureSeam {
  /// `macus serve` uses a fixture guest whose vsock ports are Unix sockets in this directory.
  static let guestVariable = "MACUS_FIXTURE_GUEST_DIR"
  /// `macus start` runs this executable in place of `/bin/launchctl`, with the same arguments.
  static let launchctlVariable = "MACUS_FIXTURE_LAUNCHCTL"

  private static let root = "/private/tmp/"

  enum Kind { case directory, executable }

  /// The isolated path `variable` names, or nil when it is unset. Throws, naming the variable,
  /// before the caller touches any state, socket or launchd job.
  static func path(
    _ variable: String, environment: [String: String], stateDirectory: URL, kind: Kind
  ) throws -> URL? {
    guard let value = environment[variable] else { return nil }
    func refuse(_ reason: String) -> RuntimeError {
      RuntimeError(
        .invalidConfiguration,
        "\(variable) is refused: \(reason). Fixture seams run only for isolated state beneath /private/tmp."
      )
    }
    let fixture = URL(fileURLWithPath: value)
    for (url, name) in [(stateDirectory, "the state directory"), (fixture, "the fixture path")] {
      if let reason = isolationFailure(url.path) { throw refuse("\(name) \(reason)") }
    }
    var info = stat()
    guard lstat(fixture.path, &info) == 0 else { throw refuse("the fixture path does not exist") }
    switch kind {
    case .directory:
      guard info.st_mode & S_IFMT == S_IFDIR else {
        throw refuse("the fixture path is not a directory")
      }
    case .executable:
      guard info.st_mode & S_IFMT == S_IFREG, access(fixture.path, X_OK) == 0 else {
        throw refuse("the fixture path is not an executable file")
      }
    }
    return fixture
  }

  /// Why `path` is not an isolated fixture location, or nil when it is. The system's own
  /// `/tmp -> private/tmp` link is the one symbolic link followed (as for state paths, and
  /// because standardized state paths drop `/private`); any other link is refused.
  static func isolationFailure(_ path: String) -> String? {
    var path = path
    if path.hasPrefix("/tmp/"),
      (try? FileManager.default.destinationOfSymbolicLink(atPath: "/tmp")) == "private/tmp"
    {
      path = "/private" + path
    }
    guard path.hasPrefix(root), path.count > root.count,
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { return "is not beneath /private/tmp" }
    // /private/tmp itself is the shared sticky directory; everything below it must be ours.
    var current = "/private/tmp"
    for component in path.dropFirst(root.count).split(separator: "/") {
      current += "/" + component
      var info = stat()
      guard lstat(current, &info) == 0 else { return "does not exist" }
      guard info.st_mode & S_IFMT != S_IFLNK else { return "contains a symbolic link" }
      guard info.st_uid == getuid() else { return "is not owned by the current user" }
      guard info.st_mode & 0o022 == 0 else { return "is writable by group or others" }
    }
    return nil
  }
}
