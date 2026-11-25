import Darwin
import Foundation

/// The state volume as an upgrade sees it: free space, clone support and the two ways to copy
/// the data disk. Tests substitute a volume without clone support.
protocol UpgradeVolume: Sendable {
  func availableBytes(at directory: URL) throws -> UInt64
  func supportsCloning(at directory: URL) throws -> Bool
  /// Blocks actually allocated to a file, which a full copy must write.
  func allocatedBytes(of file: URL) throws -> UInt64
  /// `clonefile(2)`: no data is copied, and an unsupported volume fails instead of copying.
  func clone(_ source: URL, to destination: URL) throws
  /// A full copy that keeps holes, for a volume without clone support.
  func copy(_ source: URL, to destination: URL) throws
  /// Puts a file's contents on stable storage (`F_FULLFSYNC`), not only in the drive cache.
  func sync(_ file: URL) throws
}

struct HostVolume: UpgradeVolume {
  func availableBytes(at directory: URL) throws -> UInt64 {
    var info = statfs()
    guard statfs(directory.path, &info) == 0 else {
      throw RuntimeError(.io, "Cannot read free space of \(directory.path)")
    }
    return UInt64(info.f_bavail) * UInt64(info.f_bsize)
  }

  func supportsCloning(at directory: URL) throws -> Bool {
    let values = try directory.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
    return values.volumeSupportsFileCloning == true
  }

  func allocatedBytes(of file: URL) throws -> UInt64 {
    var info = stat()
    guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw RuntimeError(.io, "Cannot inspect \(file.path)")
    }
    return UInt64(info.st_blocks) * 512
  }

  func clone(_ source: URL, to destination: URL) throws {
    guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
      throw RuntimeError(
        .io, "Cannot clone \(source.lastPathComponent): \(String(cString: strerror(errno)))")
    }
  }

  func sync(_ file: URL) throws {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open \(file.lastPathComponent)") }
    defer { close(descriptor) }
    // F_FULLFSYNC can be unsupported (some network volumes); fsync is then the best available.
    guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
      throw RuntimeError(.io, "Cannot sync \(file.lastPathComponent)")
    }
  }

  func copy(_ source: URL, to destination: URL) throws {
    // COPYFILE_DATA_SPARSE keeps the holes of a sparse disk image.
    let sparse = copyfile_flags_t(1) << 27
    guard
      copyfile(
        source.path, destination.path, nil,
        copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL | COPYFILE_NOFOLLOW) | sparse) == 0
    else {
      throw RuntimeError(
        .io, "Cannot copy \(source.lastPathComponent): \(String(cString: strerror(errno)))")
    }
  }
}
