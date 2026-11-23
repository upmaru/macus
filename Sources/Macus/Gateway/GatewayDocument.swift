import CryptoKit
import Darwin
import Foundation

/// One owner-private JSON store in `<state-dir>/server`, shaped
/// `{"schema_version": 1, "<collection>": [record, ...]}`, with the checks the Macus server applies
/// to the same files (`Macus.PrivatePath`).
///
/// The gateway directory is 0700 and the store a 0600 regular file owned by this user, below
/// ancestors only this user or root can write. Reads are bounded and reject the whole store when
/// any record is malformed or duplicated. Changes hold an exclusive lock, keep every other record
/// and unknown field and replace the store atomically. Nothing here touches runtime disks, Incus
/// or services.
struct GatewayDocument: Sendable {
  static let maxBytes = 1_048_576
  static let schemaVersion = 1

  let stateDirectory: URL
  /// The file name without `.json`, also naming the lock and temporary files.
  let name: String
  /// How messages name the store, such as "bearer token store".
  let label: String
  let collection: String
  let maxRecords: Int
  let isRecord: @Sendable ([String: Any]) -> Bool
  /// The field that identifies a record, unique within the store.
  var idKey = "id"

  var gatewayDirectory: URL {
    stateDirectory.appendingPathComponent("server", isDirectory: true)
  }
  var file: URL { gatewayDirectory.appendingPathComponent("\(name).json") }
  var lockFile: URL { gatewayDirectory.appendingPathComponent("\(name).lock") }

  enum DirectoryState { case absent, present }

  // MARK: Reading

  /// Reads and validates the store; `nil` when it does not exist.
  func load() throws -> [String: Any]? {
    var info = stat()
    if lstat(file.path, &info) != 0 {
      guard errno == ENOENT else { throw preserved("Cannot inspect the \(label)") }
      return nil
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o777 == 0o600
    else { throw preserved("The \(label) must be a 0600 regular file owned by this user") }
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw preserved("Cannot open the \(label)") }
    defer { close(descriptor) }
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_size <= Self.maxBytes
    else { throw preserved("The \(label) exceeds \(Self.maxBytes) bytes") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      guard count >= 0 else { throw RuntimeError(.io, "Cannot read the \(label)") }
      if count == 0 { break }
      data.append(contentsOf: buffer[0..<count])
      guard data.count <= Self.maxBytes else {
        throw preserved("The \(label) exceeds \(Self.maxBytes) bytes")
      }
    }
    guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw preserved("The \(label) is not a JSON object")
    }
    _ = try records(document)
    return document
  }

  /// The validated records, in order. Any malformed or duplicated record rejects the whole store,
  /// as the server does.
  func records(_ document: [String: Any]) throws -> [[String: Any]] {
    guard jsonInt(document["schema_version"]) == Self.schemaVersion,
      let raw = document[collection] as? [Any]
    else { throw preserved("The \(label) has an unsupported schema") }
    guard raw.count <= maxRecords else {
      throw preserved("The \(label) holds more than \(maxRecords) records")
    }
    var ids = Set<String>()
    var records: [[String: Any]] = []
    for entry in raw {
      guard let record = entry as? [String: Any], isRecord(record),
        let id = record[idKey] as? String, ids.insert(id).inserted
      else { throw preserved("The \(label) has a malformed or duplicate record") }
      records.append(record)
    }
    return records
  }

  /// The records of an existing store, or none when the gateway directory or store is absent.
  /// Never creates anything.
  func existingRecords() throws -> [[String: Any]] {
    try requireStateDirectory()
    guard case .present = try gatewayDirectoryState(), let document = try load() else {
      return []
    }
    return try records(document)
  }

  // MARK: Writing

  /// An empty document for a store that does not exist yet.
  var empty: [String: Any] { ["schema_version": Self.schemaVersion, collection: [Any]()] }

  func encode(_ document: [String: Any]) throws -> Data {
    guard
      var data = try? JSONSerialization.data(
        withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
    else { throw RuntimeError(.io, "Cannot encode the \(label)") }
    data.append(0x0A)
    guard data.count <= Self.maxBytes else {
      throw RuntimeError(
        .conflict, "The \(label) would exceed \(Self.maxBytes) bytes; revoke and prune first")
    }
    return data
  }

  func replace(with data: Data) throws {
    let temporary = gatewayDirectory.appendingPathComponent(
      ".\(name).\(Self.randomHex(bytes: 8)).tmp")
    try Self.writeExclusive(data, to: temporary)
    guard rename(temporary.path, file.path) == 0 else {
      unlink(temporary.path)
      throw RuntimeError(.io, "Cannot replace the \(label)")
    }
    try Self.syncDirectory(gatewayDirectory)
  }

  /// Runs `body` holding the store's exclusive lock, waiting at most five seconds for it.
  func withLock<T>(_ body: () throws -> T) throws -> T {
    let descriptor = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw preserved("Cannot open the \(label) lock") }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), fchmod(descriptor, 0o600) == 0
    else { throw preserved("The \(label) lock must be a regular file owned by this user") }
    let deadline = ContinuousClock.now + .seconds(5)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else {
        throw RuntimeError(.conflict, "Another macus command is changing the \(label)")
      }
      usleep(20_000)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  // MARK: Path checks (mirroring the server's Macus.PrivatePath)

  func requireStateDirectory() throws {
    let path = Self.systemAlias(stateDirectory.path)
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT {
        throw RuntimeError(
          .notFound,
          "State directory does not exist: \(stateDirectory.path). macus server does not create it; run macus start first"
        )
      }
      throw preserved("Cannot inspect the state directory")
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o022 == 0, try Self.safeAncestors(path)
    else {
      throw preserved(
        "The state directory and its ancestors must belong to this user or root and not be writable by others"
      )
    }
  }

  func gatewayDirectoryState() throws -> DirectoryState {
    var info = stat()
    guard lstat(Self.systemAlias(gatewayDirectory.path), &info) == 0 else {
      guard errno == ENOENT else { throw preserved("Cannot inspect the gateway directory") }
      return .absent
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o777 == 0o700
    else { throw preserved("The gateway directory must be a 0700 directory owned by this user") }
    return .present
  }

  func prepareGatewayDirectory() throws {
    if case .present = try gatewayDirectoryState() { return }
    guard mkdir(gatewayDirectory.path, 0o700) == 0 || errno == EEXIST else {
      throw RuntimeError(.io, "Cannot create the gateway directory")
    }
    var info = stat()
    guard lstat(gatewayDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), chmod(gatewayDirectory.path, 0o700) == 0
    else { throw preserved("The gateway directory must be a 0700 directory owned by this user") }
    try Self.syncDirectory(stateDirectory)
  }

  private func preserved(_ message: String) -> RuntimeError {
    RuntimeError(.invalidConfiguration, message + "; the store was preserved")
  }

  /// Every ancestor up to `/` is a directory owned by this user or root and not writable by
  /// group or others, except root-owned sticky directories such as `/private/tmp`.
  static func safeAncestors(_ path: String) throws -> Bool {
    var current = URL(fileURLWithPath: path).deletingLastPathComponent().path
    while true {
      var info = stat()
      guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
      let owner = info.st_uid
      let stickySystem = owner == 0 && info.st_mode & S_ISVTX != 0
      guard owner == 0 || owner == getuid(), info.st_mode & 0o022 == 0 || stickySystem else {
        return false
      }
      if current == "/" { return true }
      current = URL(fileURLWithPath: current).deletingLastPathComponent().path
    }
  }

  /// Rewrites Darwin's `/var` and `/tmp` links to their `/private` destinations.
  static func systemAlias(_ path: String) -> String {
    for alias in ["/var", "/tmp"] where path.hasPrefix(alias + "/") {
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: alias)) == "private" + alias {
        return "/private" + path
      }
    }
    return path
  }

  /// The destination must be a new absolute path in a directory owned by this user, below
  /// ancestors only this user or root can write.
  static func validateOutput(_ output: URL) throws {
    let path = output.path
    guard output.isFileURL, path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\n") else {
      throw RuntimeError(.invalidRequest, "--output requires an absolute file path")
    }
    let parent = systemAlias(output.deletingLastPathComponent().path)
    var info = stat()
    guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o022 == 0,
      try safeAncestors(parent)
    else {
      throw RuntimeError(
        .invalidConfiguration,
        "The --output directory must exist, belong to this user and not be writable by others")
    }
  }

  // MARK: Files

  /// Creates `url` exclusively (never following or replacing anything) as 0600 and syncs it.
  static func writeExclusive(_ data: Data, to url: URL) throws {
    let descriptor = open(
      url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw RuntimeError(.conflict, "Refusing to replace an existing file: \(url.path)")
      }
      throw RuntimeError(.io, "Cannot create \(url.path)")
    }
    var written = 0
    let ok =
      fchmod(descriptor, 0o600) == 0
      && data.withUnsafeBytes { bytes in
        while written < bytes.count {
          let count = write(descriptor, bytes.baseAddress! + written, bytes.count - written)
          if count < 0 {
            if errno == EINTR { continue }
            return false
          }
          written += count
        }
        return true
      } && fsync(descriptor) == 0
    close(descriptor)
    guard ok else {
      unlink(url.path)
      throw RuntimeError(.io, "Cannot write \(url.path)")
    }
  }

  static func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open \(url.path) for sync") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw RuntimeError(.io, "Cannot sync \(url.path)") }
  }

  // MARK: Values

  /// Lowercase hex SHA-256, the verifier both stores keep instead of a secret.
  static func sha256Hex(_ text: String) -> String { sha256Hex(data: Data(text.utf8)) }

  static func sha256Hex(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    arc4random_buf(&bytes, count)
    return bytes
  }

  static func randomHex(bytes: Int) -> String {
    randomBytes(bytes).map { String(format: "%02x", $0) }.joined()
  }

  static func randomBase64URL(bytes: Int) -> String {
    Data(randomBytes(bytes)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(
      from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
  }

  static func date(_ value: Any?) -> Date? {
    guard let text = value as? String, text.hasSuffix("Z") || text.hasSuffix("+00:00") else {
      return nil
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return ISO8601DateFormatter().date(from: text) ?? fractional.date(from: text)
  }

  static func isTimestamp(_ value: Any?) -> Bool { date(value) != nil }

  static func isNullableTimestamp(_ value: Any?) -> Bool {
    value == nil || value is NSNull || isTimestamp(value)
  }

  static func isID(_ value: String) -> Bool {
    value.utf8.count == 16 && value.utf8.allSatisfy(isLowerHex)
  }

  static func isHex64(_ value: Any?) -> Bool {
    guard let text = value as? String else { return false }
    return text.utf8.count == 64 && text.utf8.allSatisfy(isLowerHex)
  }

  /// 1-128 characters: letters, digits, '.', '_', '@' or '-', starting with a letter or digit.
  /// The server applies the same rule (`Macus.Auth.Token.principal?/1`).
  static func isName(_ value: String) -> Bool {
    guard let first = value.utf8.first, (1...128).contains(value.utf8.count),
      isAlphanumeric(first)
    else { return false }
    return value.utf8.dropFirst().allSatisfy {
      isAlphanumeric($0) || [46, 95, 64, 45].contains($0)
    }
  }

  private static func isLowerHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }

  private static func isAlphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }
}
