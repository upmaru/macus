import Darwin
import Foundation

/// Homebrew owns a stable opt link; source installations retain their physical executable path.
enum ServiceExecutable {
  static func stablePath(for physicalPath: String) -> String {
    let binary = URL(fileURLWithPath: physicalPath)
    guard binary.lastPathComponent == "macus",
      binary.deletingLastPathComponent().lastPathComponent == "bin"
    else { return physicalPath }
    return homebrewStablePath(for: physicalPath) ?? physicalPath
  }

  /// `<homebrew>/Cellar/macus/<version>/<rest>` maps to `<homebrew>/opt/macus/<rest>` only when
  /// that opt path currently resolves to exactly this file.
  static func homebrewStablePath(for physicalPath: String) -> String? {
    // Not standardizedFileURL: for an existing file it rewrites /private/tmp to /tmp.
    let components = URL(fileURLWithPath: physicalPath).pathComponents
    guard let cellar = components.lastIndex(of: "Cellar"), cellar + 3 < components.count,
      components[cellar + 1] == "macus", !components[cellar + 2].isEmpty
    else { return nil }
    let prefix = NSString.path(withComponents: Array(components[..<cellar]))
    let rest = Array(components[(cellar + 3)...])
    let stable = URL(fileURLWithPath: prefix).appendingPathComponent("opt/macus")
      .appendingPathComponent(NSString.path(withComponents: rest))
    guard FileManager.default.isExecutableFile(atPath: stable.path),
      let resolved = canonical(stable.path), resolved == canonical(physicalPath)
    else { return nil }
    return stable.path
  }

  static func matches(reported: String, expected: String) -> Bool {
    if reported == expected { return true }
    guard let physical = canonical(expected) else { return false }
    // Only a verified Homebrew opt path may have an alternate physical representation.
    // An arbitrary symlink or an old keg registration remains a conflict.
    guard expected != physical, let mapped = homebrewStablePath(for: physical),
      sameOptPath(mapped, expected)
    else { return false }
    return canonical(reported) == physical
  }

  /// Both name `<prefix>/opt/macus/<rest>` with the same rest and the same resolved prefix (so
  /// `/var` and `/private/var` agree), without following the opt link itself.
  private static func sameOptPath(_ first: String, _ second: String) -> Bool {
    func split(_ path: String) -> (prefix: String, rest: [String])? {
      let components = URL(fileURLWithPath: path).pathComponents
      guard let opt = components.lastIndex(of: "opt"), opt + 1 < components.count,
        components[opt + 1] == "macus"
      else { return nil }
      return (
        NSString.path(withComponents: Array(components[...opt])), Array(components[(opt + 1)...])
      )
    }
    guard let a = split(first), let b = split(second), a.rest == b.rest,
      let prefix = canonical(a.prefix)
    else { return false }
    return prefix == canonical(b.prefix)
  }

  /// The fully resolved path (every link, including `/tmp` → `/private/tmp`).
  static func canonical(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

/// The Elixir release installed beside the Swift executable:
/// `<prefix>/bin/macus` and `<prefix>/libexec/macus/{bin/macus,releases,erts-*}`. Deriving the
/// launcher from the stable Swift path keeps both jobs on the same Homebrew opt link.
enum ServerRelease {
  static func launcher(forServiceExecutable executable: String) -> String {
    URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("libexec/macus/bin/macus").path
  }

  /// The launcher and the ERTS it runs must both live inside the installed release, so the job
  /// never depends on a host Erlang or Elixir. Completeness and build identity are checked by the
  /// startup preflight.
  static func requireInstalled(launcher: String) throws {
    let root = URL(fileURLWithPath: launcher).deletingLastPathComponent()
      .deletingLastPathComponent()
    var info = stat()
    guard stat(launcher, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      access(launcher, X_OK) == 0
    else { throw missing(root) }
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: root.path),
      names.contains("releases")
    else { throw missing(root) }
    let erts = names.filter { $0.hasPrefix("erts-") }
    guard erts.count == 1,
      FileManager.default.isExecutableFile(
        atPath: root.appendingPathComponent(erts[0]).appendingPathComponent("bin/erl").path)
    else {
      throw RuntimeError(
        .invalidConfiguration,
        "The Macus server release at \(root.path) does not contain exactly one bundled ERTS. Reinstall the complete Macus package; macus start does not use a host Erlang."
      )
    }
  }

  private static func missing(_ root: URL) -> RuntimeError {
    RuntimeError(
      .invalidConfiguration,
      "The Macus server release is not installed at \(root.path). Install the complete Macus package; macus start does not fetch a server payload."
    )
  }
}
