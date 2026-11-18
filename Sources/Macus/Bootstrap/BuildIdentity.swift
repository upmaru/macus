import Foundation

/// This executable's Macus package version and immutable source revision. Packaged builds embed
/// them in the executable's Info.plist (`__TEXT,__info_plist`) as `MacusVersion` and
/// `MacusSourceRevision`; a plain `swift build` records none, and such a build cannot be paired
/// with a server release.
struct BuildIdentity: Sendable, Equatable {
  var version: String?
  var revision: String?

  static let current = read(Bundle.main.infoDictionary)

  static func read(_ info: [String: Any]?) -> BuildIdentity {
    let version = info?["MacusVersion"] as? String
    let revision = info?["MacusSourceRevision"] as? String
    return BuildIdentity(
      version: version.flatMap { isVersion($0) ? $0 : nil },
      revision: revision.flatMap { isRevision($0) ? $0 : nil })
  }

  /// 40 or 64 lowercase hex, as the server's `Macus.Build` requires.
  static func isRevision(_ value: String) -> Bool {
    (value.utf8.count == 40 || value.utf8.count == 64)
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func isVersion(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || Array(".-+_".utf8).contains($0)
      }
  }
}
