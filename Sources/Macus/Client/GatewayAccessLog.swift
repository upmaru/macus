import Darwin
import Foundation

/// `macus server logs`: reads the server's owner-private gateway access log,
/// `<state-dir>/logs/gateway-access.log`, and its rotated archives directly.
///
/// The server's OTP `logger_std_h` handler names archives `gateway-access.log.0` (newest) to
/// `gateway-access.log.4` (oldest) and rotates by renaming, so a reader holding the old file
/// open can finish it before moving to the new one. Reading contacts neither the server nor the
/// runtime, starts nothing and writes nothing.
struct GatewayAccessLog: Sendable {
  static let fileName = "gateway-access.log"
  static let defaultLines = 50
  static let maxLines = 100_000
  static let followInterval: Duration = .milliseconds(250)

  let stateDirectory: URL

  init(stateDirectory: URL) {
    self.stateDirectory = stateDirectory.standardizedFileURL
  }

  var logsDirectory: URL { stateDirectory.appendingPathComponent("logs", isDirectory: true) }
  var file: URL { logsDirectory.appendingPathComponent(Self.fileName) }

  // MARK: Ownership

  /// Whether there is a log directory to read. Throws `invalid_configuration` when the state
  /// directory, `logs` or an existing log file is not owner-private.
  func validate() throws -> Bool {
    let state = GatewayDocument.systemAlias(stateDirectory.path)
    var info = stat()
    guard lstat(state, &info) == 0 else {
      guard errno == ENOENT else { throw unsafe("Cannot inspect the state directory") }
      return false
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o022 == 0,
      try GatewayDocument.safeAncestors(state)
    else {
      throw unsafe(
        "The state directory and its ancestors must belong to this user or root and not be writable by others"
      )
    }
    guard lstat(GatewayDocument.systemAlias(logsDirectory.path), &info) == 0 else {
      guard errno == ENOENT else { throw unsafe("Cannot inspect the log directory") }
      return false
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
    else { throw unsafe("The log directory must be a 0700 directory owned by this user") }
    return true
  }

  private func unsafe(_ message: String) -> RuntimeError {
    RuntimeError(.invalidConfiguration, message + "; nothing was read")
  }

  /// Checks one log file without following links: absent is `false`.
  func validateFile(_ url: URL) throws -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      guard errno == ENOENT else { throw unsafe("Cannot inspect \(url.lastPathComponent)") }
      return false
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o022 == 0
    else {
      throw unsafe("\(url.lastPathComponent) must be a regular file owned by this user")
    }
    return true
  }

  /// The archives present, oldest first (`gateway-access.log.4` before `.0`).
  func archives() throws -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: logsDirectory.path)) ?? []
    let prefix = Self.fileName + "."
    let numbers = names.compactMap { name -> Int? in
      guard name.hasPrefix(prefix) else { return nil }
      let suffix = name.dropFirst(prefix.count)
      guard !suffix.isEmpty, suffix.count <= 4, suffix.utf8.allSatisfy({ (48...57).contains($0) })
      else { return nil }
      return Int(suffix)
    }
    return numbers.sorted(by: >).map { logsDirectory.appendingPathComponent(prefix + String($0)) }
  }

  // MARK: Reading

  /// The last `count` complete lines across the archives and the current file, oldest first.
  /// A trailing line without its newline is still being written and is left for later.
  func recentLines(_ count: Int) throws -> [String] {
    guard try validate() else { return [] }
    var collected: [String] = []
    if try validateFile(file) {
      collected = Array(Self.completeLines(try Self.read(file)).lines.suffix(count))
    }
    for url in try archives().reversed() {
      guard collected.count < count else { break }
      guard try validateFile(url) else { continue }
      let lines = Self.completeLines(try Self.read(url)).lines
      collected = Array(lines.suffix(count - collected.count)) + collected
    }
    return collected
  }

  static func read(_ url: URL) throws -> Data {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      return try handle.readToEnd() ?? Data()
    } catch {
      throw RuntimeError(.io, "Cannot read \(url.lastPathComponent)")
    }
  }

  /// Splits on newlines; the bytes after the last newline are returned as the remainder.
  static func completeLines(_ data: Data) -> (lines: [String], remainder: Data) {
    var lines: [String] = []
    var start = data.startIndex
    for index in data.indices where data[index] == 0x0A {
      if index > start { lines.append(String(decoding: data[start..<index], as: UTF8.self)) }
      start = data.index(after: index)
    }
    return (lines, Data(data[start...]))
  }

  // MARK: Following

  /// Prints the last `count` lines, then new complete lines until the task is cancelled, and
  /// throws `FollowInterrupted`. Files are told apart by device and inode, not by name: the
  /// current file is opened once and held, a rotation (a rename) is read to its end, and every
  /// archive not read before is read before the new current file. So a rotation while the
  /// initial lines are gathered prints nothing twice, and several rotations between two polls
  /// skip nothing that is still on disk.
  func follow(
    lines count: Int, emit: @Sendable ([String]) -> Void, interval: Duration = followInterval
  ) async throws -> Never {
    var reader = FollowReader(log: self)
    let current = try reader.start()
    emit(try reader.recentLines(count, current: current))
    while true {
      do { try await Task.sleep(for: interval) } catch { throw FollowInterrupted() }
      if Task.isCancelled { throw FollowInterrupted() }
      let lines = try reader.poll()
      if !lines.isEmpty { emit(lines) }
    }
  }

  // MARK: Presentation

  /// One human row per stored line; malformed lines are skipped and counted.
  static func rows(_ lines: [String]) -> (rows: [String], malformed: Int) {
    var rows: [String] = []
    var malformed = 0
    for line in lines {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        jsonInt(object["v"]) == 1
      else {
        malformed += 1
        continue
      }
      if let dropped = jsonInt(object["dropped_before"]), dropped > 0 {
        rows.append("… \(dropped) earlier record\(dropped == 1 ? "" : "s") dropped")
      }
      rows.append(row(object))
    }
    return (rows, malformed)
  }

  static func row(_ object: [String: Any]) -> String {
    let time = jsonString(object["time"]) ?? "-"
    let status = jsonInt(object["status"]).map(String.init) ?? "-"
    let method = jsonString(object["method"]) ?? "-"
    let path = jsonString(object["path"]) ?? "-"
    var fields = [time, caller(object), status, "\(method) \(path)"]
    let outcome = jsonString(object["outcome"]) ?? "-"
    if outcome != "ok" {
      fields.append(
        [outcome, jsonString(object["reason"])].compactMap { $0 }.joined(separator: " "))
    }
    fields.append(jsonInt(object["duration_ms"]).map { "\($0)ms" } ?? "-")
    fields.append(
      "in \(bytes(jsonInt(object["request_bytes"]))) out \(bytes(jsonInt(object["response_bytes"])))"
    )
    return terminalSafe(fields.joined(separator: "  "))
  }

  /// The certificate prefix of a trusted caller, or how the request was admitted.
  static func caller(_ object: [String: Any]) -> String {
    switch jsonString(object["admitted_as"]) {
    case "caller":
      return jsonString(object["certificate"]).map { String($0.prefix(12)) } ?? "caller"
    case "anonymous": return "anonymous"
    case "operation_peer": return "operation-peer"
    case "image_peer": return "image-peer"
    case nil: return "refused"
    case let other?: return other
    }
  }

  static func bytes(_ value: Int?) -> String {
    guard let value else { return "-" }
    if value < 1024 { return "\(value)B" }
    let units = ["KiB", "MiB", "GiB", "TiB"]
    var amount = Double(value) / 1024
    var unit = 0
    while amount >= 1024, unit < units.count - 1 {
      amount /= 1024
      unit += 1
    }
    return String(format: "%.1f%@", amount, units[unit])
  }
}

/// `--follow` ended by an interrupt; the command exits 130 without an error message.
struct FollowInterrupted: Error, Sendable {}

/// A file's identity across renames.
struct LogFileIdentity: Hashable, Sendable {
  let device: dev_t
  let inode: ino_t

  init(_ info: stat) {
    device = info.st_dev
    inode = info.st_ino
  }
}

/// Tracks the open log file across rotation and truncation, and which files it has already
/// accounted for, so that a renamed file is neither read twice nor passed over.
struct FollowReader {
  let log: GatewayAccessLog
  var handle: FileHandle?
  var identity: LogFileIdentity?
  var remainder = Data()
  /// Files whose records were already printed, or that predate the lines asked for.
  var known: Set<LogFileIdentity> = []

  init(log: GatewayAccessLog) { self.log = log }

  /// Opens the current file and returns its complete lines; `nil` when there is none yet.
  mutating func start() throws -> [String]? {
    guard try log.validate(), try open() else { return nil }
    return readAvailable()
  }

  /// The last `count` lines: `current`, the held file's lines, preceded by as many archive
  /// lines as needed, newest archive first. The held file is skipped if a rotation has already
  /// renamed it into the archives, and every archive present now counts as accounted for.
  mutating func recentLines(_ count: Int, current: [String]?) throws -> [String] {
    guard try log.validate() else { return [] }
    var collected = Array((current ?? []).suffix(count))
    for url in try log.archives().reversed() {
      guard let archive = try openArchive(url) else { continue }
      defer { try? archive.handle.close() }
      guard known.insert(archive.identity).inserted, collected.count < count else { continue }
      let lines = GatewayAccessLog.completeLines(Self.readToEnd(archive.handle)).lines
      collected = Array(lines.suffix(count - collected.count)) + collected
    }
    return collected
  }

  mutating func open() throws -> Bool {
    guard try log.validateFile(log.file) else { return false }
    do {
      let handle = try FileHandle(forReadingFrom: log.file)
      var info = stat()
      guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == getuid()
      else {
        try? handle.close()
        throw RuntimeError(
          .invalidConfiguration, "\(GatewayAccessLog.fileName) changed while opening")
      }
      self.handle = handle
      identity = LogFileIdentity(info)
      known.insert(LogFileIdentity(info))
      remainder = Data()
      return true
    } catch let error as RuntimeError {
      throw error
    } catch {
      throw RuntimeError(.io, "Cannot read \(GatewayAccessLog.fileName)")
    }
  }

  mutating func poll() throws -> [String] {
    var lines: [String] = []
    if handle != nil {
      var info = stat()
      let present = lstat(log.file.path, &info) == 0
      if present, LogFileIdentity(info) == identity {
        if let handle, let offset = try? handle.offset(), UInt64(info.st_size) < offset {
          // Truncated in place: start again from the beginning.
          try? handle.seek(toOffset: 0)
          remainder = Data()
        }
        return readAvailable()
      }
      // Renamed or removed: finish it before anything newer.
      lines += readAvailable()
      try? handle?.close()
      handle = nil
      identity = nil
      remainder = Data()
    }
    guard (try? log.validate()) == true else { return lines }
    // Files rotated into the archives without ever being the held file come first, oldest
    // first. Looking again after opening the current file catches a rotation in between.
    lines += try unreadArchives()
    if try open() {
      lines += try unreadArchives()
      lines += readAvailable()
    }
    return lines
  }

  /// The lines of every archive not accounted for yet, oldest first. Identities of files that
  /// are gone are forgotten, so a reused inode is not mistaken for a file already read.
  private mutating func unreadArchives() throws -> [String] {
    var lines: [String] = []
    var present: Set<LogFileIdentity> = []
    for url in try log.archives() {
      guard let archive = try openArchive(url) else { continue }
      defer { try? archive.handle.close() }
      present.insert(archive.identity)
      guard known.insert(archive.identity).inserted else { continue }
      lines += GatewayAccessLog.completeLines(Self.readToEnd(archive.handle)).lines
    }
    if let identity { present.insert(identity) }
    known.formIntersection(present)
    return lines
  }

  /// Opens one archive and identifies the file actually opened, so a rename between listing
  /// and opening cannot pass one file off as another. `nil` when it is gone.
  private func openArchive(_ url: URL) throws -> (handle: FileHandle, identity: LogFileIdentity)? {
    guard try log.validateFile(url), let handle = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid()
    else {
      try? handle.close()
      return nil
    }
    return (handle, LogFileIdentity(info))
  }

  private static func readToEnd(_ handle: FileHandle) -> Data {
    (try? handle.readToEnd()) ?? Data()
  }

  private mutating func readAvailable() -> [String] {
    guard let handle, let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
    let split = GatewayAccessLog.completeLines(remainder + data)
    remainder = split.remainder
    return split.lines
  }
}

/// Cancels a follow task on SIGINT or SIGTERM.
final class FollowSignals: @unchecked Sendable {
  private var sources: [DispatchSourceSignal] = []

  init(cancel: @escaping @Sendable () -> Void) {
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { cancel() }
      source.resume()
      sources.append(source)
    }
  }

  func cancel() {
    for source in sources { source.cancel() }
    sources.removeAll()
    signal(SIGINT, SIG_DFL)
    signal(SIGTERM, SIG_DFL)
  }
}

extension ServerAdministration {
  /// `macus server logs [--lines N] [--follow] [--json]`.
  static func logs(
    lines count: Int, follow: Bool, json: Bool, directory: URL, streams: MacusStreams,
    installSignals: Bool = true, interval: Duration = GatewayAccessLog.followInterval
  ) async throws {
    let log = GatewayAccessLog(stateDirectory: directory)
    let emit: @Sendable ([String]) -> Void = { lines in
      if json {
        if !lines.isEmpty { streams.writeOutput(lines.joined(separator: "\n") + "\n") }
        return
      }
      let (rows, malformed) = GatewayAccessLog.rows(lines)
      if !rows.isEmpty { streams.writeOutput(rows.joined(separator: "\n") + "\n") }
      if malformed > 0 {
        streams.writeOutput("(\(malformed) malformed line\(malformed == 1 ? "" : "s") skipped)\n")
      }
    }
    guard follow else {
      emit(try log.recentLines(count))
      return
    }
    let task = Task { try await log.follow(lines: count, emit: emit, interval: interval) }
    let signals = installSignals ? FollowSignals(cancel: { task.cancel() }) : nil
    defer { signals?.cancel() }
    try await withTaskCancellationHandler {
      _ = try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
