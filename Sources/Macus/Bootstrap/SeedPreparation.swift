import Darwin
import Foundation

/// The host-named pool a replacement root may adopt. The guest treats the GUID as a selector
/// and proves ownership itself, but the host still renders only a well-formed record.
struct StorageAdoption: Sendable, Equatable {
  static let path = "/etc/tama-storage/adopt"
  static let supportedLayout = "zfs-v1"

  let poolGuid: String
  let layout: String

  init(poolGuid: String, layout: String) throws {
    guard !poolGuid.isEmpty, poolGuid.utf8.count <= 20,
      poolGuid.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
    else {
      throw RuntimeError(.invalidConfiguration, "Storage adoption needs a numeric pool GUID")
    }
    guard layout == Self.supportedLayout else {
      throw RuntimeError(
        .invalidConfiguration, "Storage adoption does not support layout \(layout)")
    }
    self.poolGuid = poolGuid
    self.layout = layout
  }

  /// The pool this state's record names.
  init(_ record: StorageIdentityRecord) throws {
    guard record.backend == "zfs" else {
      throw RuntimeError(.invalidConfiguration, "Storage adoption needs a ZFS identity")
    }
    try self.init(poolGuid: record.poolGuid, layout: record.layout)
  }

  var record: String { "pool_guid=\(poolGuid)\nlayout=\(layout)\n" }
}

enum SeedPreparation {
  static let entries: [(name: String, destination: String, permissions: String)] = [
    ("bridge.py", "/usr/local/libexec/tama-bridge.py", "0755"),
    ("storage.sh", "/usr/local/libexec/tama-storage.sh", "0755"),
    ("incus-guard.sh", "/usr/local/libexec/tama-incus-guard.sh", "0755"),
    ("bootstrap.sh", "/usr/local/libexec/tama-bootstrap.sh", "0755"),
    ("verify-appliance-image.sh", "/usr/local/libexec/tama-verify-appliance-image.sh", "0755"),
    ("tama-storage.initd", "/etc/init.d/tama-storage", "0755"),
    ("tama-bridge.initd", "/etc/init.d/tama-bridge", "0755"),
    ("tama-bootstrap.initd", "/etc/init.d/tama-bootstrap", "0755"),
  ]

  static let guestRecordPath = "/etc/macus-guest"

  /// Read by the guest bridge and reported in health.
  static func guestRecord(applianceID: String?) -> String {
    var record = "format=1\npayload_revision=\(EmbeddedGuestPayload.revision)\n"
    if let applianceID { record += "appliance_id=\(applianceID)\n" }
    return record
  }

  /// The rendered user data for a seed. Only an upgrade seed passes `adoption`; `prepare`, which
  /// builds the shared creation seed, never does, so a new runtime cannot adopt a pool.
  static func userData(
    entry: ApplianceCatalogEntry? = nil, adoption: StorageAdoption? = nil
  ) throws -> String {
    var text =
      "#cloud-config\noutput: {all: \"| tee -a /var/log/cloud-init-output.log /dev/hvc0\"}\nusers: []\nssh_pwauth: false\ndisable_root: true\nwrite_files:\n"
    for entry in entries {
      let body = try EmbeddedGuestPayload.text(entry.name)
      text +=
        "  - path: \(entry.destination)\n    permissions: \"\(entry.permissions)\"\n    content: |\n"
      text += body.split(separator: "\n", omittingEmptySubsequences: false).map {
        "      \($0)\n"
      }.joined()
    }
    // The payload revision hashes the payload, so it is delivered beside it, not inside it.
    text += "  - path: \(guestRecordPath)\n    permissions: \"0600\"\n    content: |\n"
    text += guestRecord(applianceID: entry?.id).split(separator: "\n").map { "      \($0)\n" }
      .joined()
    if let adoption {
      text += "  - path: \(StorageAdoption.path)\n    permissions: \"0600\"\n    content: |\n"
      text += adoption.record.split(separator: "\n").map { "      \($0)\n" }.joined()
    }
    if let entry, let identity = entry.prebuiltIdentity {
      text += "  - path: /etc/macus-appliance-expected\n    permissions: \"0600\"\n    content: |\n"
      text += identity.record(id: entry.id).split(separator: "\n").map { "      \($0)\n" }.joined()
    }
    text +=
      "bootcmd:\n  - [sh, -c, \"(sleep 20; rc-status default; cat /var/log/tama-storage.log; test ! -f /var/log/tama-bridge.log || cat /var/log/tama-bridge.log) > /dev/hvc0 2>&1 &\"]\n"
    text += "runcmd:\n  - [sh, /usr/local/libexec/tama-bootstrap.sh]\n"
    return text
  }

  static func prepare(
    entry: ApplianceCatalogEntry, cache: URL, runner: any LocalCommandRunner,
    timeout: Int, environment: [String: String]
  ) async throws -> URL {
    let stamp = cache.appendingPathComponent("seed-stamp.json")
    let iso = cache.appendingPathComponent("seed.iso")
    let manifest = cache.appendingPathComponent("manifest.json")
    if try seedIsCurrent(stamp: stamp, iso: iso, manifest: manifest, entry: entry) {
      return manifest
    }
    do {
      try await makeISO(
        entry: entry, adoption: nil, directory: cache, runner: runner, timeout: timeout,
        environment: environment)
      try writeManifest(entry: entry, manifest: manifest)
      let stampObject: [String: String] = [
        "payload_revision": EmbeddedGuestPayload.revision, "catalog_id": entry.id,
      ]
      try JSONSerialization.data(withJSONObject: stampObject, options: [.sortedKeys]).write(
        to: stamp, options: .atomic)
      guard chmod(stamp.path, 0o600) == 0 else {
        throw RuntimeError(.io, "Cannot secure seed stamp")
      }
      return manifest
    } catch {
      try? FileManager.default.removeItem(at: iso)
      try? FileManager.default.removeItem(at: stamp)
      throw error
    }
  }

  /// The seed of an upgrade, which names the pool the replacement root adopts. It is written
  /// only into the upgrade's private staging directory, never into the shared appliance
  /// cache, so a later new runtime can never adopt.
  static func prepareUpgradeSeed(
    entry: ApplianceCatalogEntry, adoption: StorageAdoption, directory: URL,
    runner: any LocalCommandRunner, timeout: Int, environment: [String: String]
  ) async throws -> URL {
    let iso = directory.appendingPathComponent("seed.iso")
    do {
      try await makeISO(
        entry: entry, adoption: adoption, directory: directory, runner: runner, timeout: timeout,
        environment: environment)
      return iso
    } catch {
      try? FileManager.default.removeItem(at: iso)
      throw error
    }
  }

  /// Renders the NoCloud files into `directory/seed` and builds `directory/seed.iso` from
  /// them. The working directory is removed either way.
  private static func makeISO(
    entry: ApplianceCatalogEntry, adoption: StorageAdoption?, directory: URL,
    runner: any LocalCommandRunner, timeout: Int, environment: [String: String]
  ) async throws {
    let iso = directory.appendingPathComponent("seed.iso")
    let seed = directory.appendingPathComponent("seed", isDirectory: true)
    if FileManager.default.fileExists(atPath: seed.path) {
      try FileManager.default.removeItem(at: seed)
    }
    try FileManager.default.createDirectory(
      at: seed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: seed) }
    try write(
      "instance-id: \(entry.id)\nlocal-hostname: tama-incus\n",
      seed.appendingPathComponent("meta-data"))
    try write(
      "version: 1\nconfig:\n  - type: physical\n    name: eth0\n    subnets:\n      - type: dhcp\n",
      seed.appendingPathComponent("network-config"))
    try write(
      userData(entry: entry, adoption: adoption), seed.appendingPathComponent("user-data"))
    if FileManager.default.fileExists(atPath: iso.path) {
      try FileManager.default.removeItem(at: iso)
    }
    let result = try await runner.run(
      executable: "/usr/bin/hdiutil",
      arguments: [
        "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", iso.path,
        seed.path,
      ],
      environment: environment, timeout: timeout)
    guard result.status == 0, FileManager.default.fileExists(atPath: iso.path) else {
      throw RuntimeError(.io, "hdiutil could not create the NoCloud seed")
    }
    guard chmod(iso.path, 0o600) == 0 else { throw RuntimeError(.io, "Cannot secure seed") }
  }

  private static func seedIsCurrent(
    stamp: URL, iso: URL, manifest: URL, entry: ApplianceCatalogEntry
  ) throws -> Bool {
    guard FileManager.default.fileExists(atPath: stamp.path),
      FileManager.default.fileExists(atPath: iso.path),
      FileManager.default.fileExists(atPath: manifest.path)
    else { return false }
    try requireOwnedRegular(stamp)
    try requireOwnedRegular(iso)
    try requireOwnedRegular(manifest)
    let object =
      try JSONSerialization.jsonObject(with: Data(contentsOf: stamp)) as? [String: String]
    guard object?["payload_revision"] == EmbeddedGuestPayload.revision,
      object?["catalog_id"] == entry.id
    else { return false }
    let decoded = try JSON.decoder().decode(
      ApplianceManifest.self, from: Data(contentsOf: manifest))
    return decoded.sha256 == entry.rawSHA256 && decoded.id == entry.id
  }

  private static func writeManifest(entry: ApplianceCatalogEntry, manifest: URL) throws {
    let object: [String: Any] = [
      "schema_version": 1,
      "id": entry.id,
      "architecture": "arm64",
      "root_disk": "root.raw",
      "sha256": entry.rawSHA256,
      "vsock_protocol": 1,
      "source": [
        "archive": entry.archiveName,
        "archive_sha512": entry.archiveSHA512,
        "upstream_signing_fingerprint": entry.upstream.signerFingerprint,
        "raw_sha256": entry.rawSHA256,
      ],
    ]
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
      to: manifest, options: .atomic)
    guard chmod(manifest.path, 0o600) == 0 else {
      throw RuntimeError(.io, "Cannot secure appliance manifest")
    }
  }

  private static func write(_ text: String, _ url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
    guard chmod(url.path, 0o600) == 0 else { throw RuntimeError(.io, "Cannot secure seed file") }
  }
}
