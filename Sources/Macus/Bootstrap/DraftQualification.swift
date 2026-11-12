import Foundation

struct PrebuiltImageIdentity: Sendable, Equatable {
  var imageFormat: Int = 1
  let channel: String
  let alpineBranch: String
  let lockSHA256: String
  let manifestSHA256: String
  let kernelRelease: String

  func record(id: String) -> String {
    """
    format=\(imageFormat)
    appliance_id=\(id)
    channel=\(channel)
    alpine_branch=\(alpineBranch)
    lock_sha256=\(lockSHA256)
    manifest_sha256=\(manifestSHA256)
    kernel_release=\(kernelRelease)

    """
  }
}

enum DraftQualification {
  static func load(
    environment: [String: String], state: URL
  ) throws -> (catalog: ApplianceCatalogEntry, downloader: any ApplianceDownloader)? {
    let pinsPath = environment["MACUS_QUALIFICATION_PINS"]
    let archivePath = environment["MACUS_QUALIFICATION_ARCHIVE"]
    guard pinsPath != nil || archivePath != nil else { return nil }
    #if DEBUG
      guard let pinsPath, let archivePath, let clientPath = environment["INCUS_CONF"],
        [pinsPath, archivePath, clientPath].allSatisfy({ $0.hasPrefix("/") })
      else {
        throw RuntimeError(
          .invalidConfiguration,
          "Draft qualification requires absolute pins, archive and INCUS_CONF paths")
      }
      let state = state.standardizedFileURL
      let client = URL(fileURLWithPath: clientPath, isDirectory: true).standardizedFileURL
      let parent = state.deletingLastPathComponent().resolvingSymlinksInPath().path
      try BootstrapStore.validateState(state)
      try BootstrapStore.validateState(client)
      guard parent.hasPrefix("/private/tmp/") || parent.hasPrefix("/tmp/"),
        client.deletingLastPathComponent().resolvingSymlinksInPath().path == parent,
        state.path != client.path, !FileManager.default.fileExists(atPath: state.path),
        try FileManager.default.contentsOfDirectory(atPath: client.path).isEmpty
      else {
        throw RuntimeError(
          .invalidConfiguration,
          "Draft qualification requires fresh state and an empty sibling INCUS_CONF under /private/tmp"
        )
      }
      let pinsURL = URL(fileURLWithPath: pinsPath)
      let archive = URL(fileURLWithPath: archivePath)
      try requireOwnedRegular(pinsURL)
      try requireOwnedRegular(archive)
      guard try fileSize(pinsURL) <= 16_384 else {
        throw RuntimeError(.invalidConfiguration, "Draft qualification pins file is too large")
      }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let pins = try decoder.decode(DraftPins.self, from: Data(contentsOf: pinsURL))
      try pins.validate()
      var entry = ApplianceCatalogEntry.current
      entry.id = pins.applianceId
      entry.archiveName = pins.applianceId + ".raw.tar.gz"
      entry.archiveURL = archive
      entry.archiveSHA512 = pins.archiveSha512
      entry.archiveBytes = pins.archiveBytes
      entry.rawBytes = pins.rawBytes
      entry.rawSHA256 = pins.rawSha256
      entry.build = nil
      entry.qualifiedPackages = [:]
      entry.prebuiltIdentity = PrebuiltImageIdentity(
        channel: pins.channel, alpineBranch: pins.alpineBranch, lockSHA256: pins.lockSha256,
        manifestSHA256: pins.manifestSha256, kernelRelease: pins.kernelRelease)
      return (entry, DraftArchiveReader())
    #else
      throw RuntimeError(
        .invalidConfiguration, "Draft qualification is unavailable in release builds")
    #endif
  }
}

#if DEBUG
  private struct DraftPins: Decodable {
    let applianceId: String
    let channel: String
    let alpineBranch: String
    let archiveBytes: Int64
    let archiveSha512: String
    let rawBytes: Int64
    let rawSha256: String
    let lockSha256: String
    let manifestSha256: String
    let kernelRelease: String

    func validate() throws {
      guard ["lts", "stable"].contains(channel),
        applianceId.wholeMatch(of: /alpine-[0-9]+\.[0-9]+\.[0-9]+-(lts|stable)-[1-9][0-9]*/) != nil,
        applianceId.split(separator: "-").dropLast().last == Substring(channel),
        alpineBranch.wholeMatch(of: /v[0-9]+\.[0-9]+/) != nil,
        kernelRelease.wholeMatch(of: /[0-9][a-zA-Z0-9._+-]+/) != nil,
        kernelRelease.hasSuffix("-" + channel),
        archiveBytes > 0, archiveBytes < 2 * 1024 * 1024 * 1024,
        rawBytes > 0, rawBytes <= 16 * 1024 * 1024 * 1024,
        archiveSha512.wholeMatch(of: /[a-f0-9]{128}/) != nil,
        [rawSha256, lockSha256, manifestSha256].allSatisfy({
          $0.wholeMatch(of: /[a-f0-9]{64}/) != nil
        })
      else { throw RuntimeError(.invalidConfiguration, "Invalid draft qualification pins") }
    }
  }

  private struct DraftArchiveReader: ApplianceDownloader {
    func download(
      url: URL, to destination: URL, maximumBytes: Int64, deadline: ContinuousClock.Instant,
      onBytes: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
      guard url.isFileURL else {
        throw RuntimeError(.invalidConfiguration, "Draft archive must be a local file")
      }
      try requireOwnedRegular(url)
      guard try fileSize(url) == maximumBytes else {
        throw RuntimeError(.invalidConfiguration, "Draft archive size differs from the pins")
      }
      let input = try FileHandle(forReadingFrom: url)
      defer { try? input.close() }
      let output = try FileHandle(forWritingTo: destination)
      defer { try? output.close() }
      var count: Int64 = 0
      while let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
          throw RuntimeError(.timeout, "Draft archive copy exceeded the startup deadline")
        }
        count += Int64(data.count)
        guard count <= maximumBytes else {
          throw RuntimeError(.invalidConfiguration, "Draft archive exceeds the pinned size")
        }
        try output.write(contentsOf: data)
        onBytes(count, maximumBytes)
      }
    }
  }
#endif
