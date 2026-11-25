import Darwin
import Foundation

/// The device and inode of a file, recorded so an interrupted rename can be resolved later:
/// a path holds the recorded file, another file, or nothing.
struct FileIdentity: Codable, Sendable, Equatable {
  var device: Int64
  var inode: UInt64

  /// The identity of an owned regular file, or nil when nothing is at the path. Anything
  /// else, such as a symlink or another user's file, is refused.
  static func of(_ url: URL) throws -> FileIdentity? {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      guard errno == ENOENT else {
        throw RuntimeError(.io, "Cannot inspect \(url.path)")
      }
      return nil
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
      throw RuntimeError(.invalidConfiguration, "Expected an owned regular file: \(url.path)")
    }
    return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
  }
}

enum PrivateFile {
  /// Atomic and private: a 0600 temporary file is synced, then renamed over the target. An
  /// existing target must be an owned regular file. With `syncDirectory`, the rename itself is
  /// made durable too.
  static func write(_ data: Data, to file: URL, syncDirectory: Bool = false) throws {
    var info = stat()
    if lstat(file.path, &info) == 0 {
      try requireOwnedRegular(file)
    }
    let directory = file.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(file.lastPathComponent)-\(UUID().uuidString)")
    let descriptor = open(
      temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw RuntimeError(.io, "Cannot write \(file.lastPathComponent)")
    }
    var written = 0
    let complete = data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return data.isEmpty }
      while written < data.count {
        let result = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
        if result < 0 { return false }
        written += result
      }
      return true
    }
    let synced = complete && fsync(descriptor) == 0
    close(descriptor)
    guard synced, rename(temporary.path, file.path) == 0 else {
      _ = unlink(temporary.path)
      throw RuntimeError(.io, "Cannot write \(file.lastPathComponent)")
    }
    if syncDirectory { try sync(directory) }
  }

  /// Makes a directory's entries durable, such as a rename or removal inside it.
  static func sync(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open \(directory.path)") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw RuntimeError(.io, "Cannot sync \(directory.path)") }
  }

  /// Creates a private directory, refusing an existing path of any kind.
  static func makeDirectory(_ url: URL) throws {
    guard mkdir(url.path, 0o700) == 0 else {
      throw RuntimeError(.io, "Cannot create \(url.path)")
    }
    guard chmod(url.path, 0o700) == 0 else { throw RuntimeError(.io, "Cannot secure \(url.path)") }
  }

  /// Whether the path is an owned real directory; nil when absent. Anything else is refused.
  static func isOwnedDirectory(_ url: URL) throws -> Bool {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      guard errno == ENOENT else { throw RuntimeError(.io, "Cannot inspect \(url.path)") }
      return false
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
      throw RuntimeError(.invalidConfiguration, "Expected an owned directory: \(url.path)")
    }
    return true
  }

  /// Renames within the state directory: never a copy, never over an existing file.
  static func move(_ source: URL, to destination: URL) throws {
    guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      throw RuntimeError(
        .io, "Cannot move \(source.lastPathComponent) to \(destination.path): errno \(errno)")
    }
  }
}
