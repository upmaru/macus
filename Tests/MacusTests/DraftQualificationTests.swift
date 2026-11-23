import Foundation
import Testing

@testable import Macus

@Test func seedCarriesExactPrebuiltIdentityRecord() throws {
  var entry = ApplianceCatalogEntry.current
  entry.id = "alpine-3.24.2-stable-1"
  let lock = String(repeating: "a", count: 64)
  let manifest = String(repeating: "b", count: 64)
  let identity = PrebuiltImageIdentity(
    channel: "stable", alpineBranch: "v3.24", lockSHA256: lock, manifestSHA256: manifest,
    kernelRelease: "7.1.5-0-stable")
  entry.prebuiltIdentity = identity
  let expected =
    "format=1\nappliance_id=alpine-3.24.2-stable-1\nchannel=stable\nalpine_branch=v3.24\n"
    + "lock_sha256=\(lock)\nmanifest_sha256=\(manifest)\nkernel_release=7.1.5-0-stable\n"
  #expect(identity.record(id: entry.id) == expected)
  let yaml = try SeedPreparation.userData(entry: entry)
  #expect(
    yaml.contains(
      "  - path: /etc/macus-appliance-expected\n    permissions: \"0600\"\n    content: |\n"
        + expected.split(separator: "\n").map { "      \($0)\n" }.joined()))
  #expect(!((try SeedPreparation.userData()).contains("path: /etc/macus-appliance-expected")))
}

@Test func seedCarriesTheGuestRecordForHealth() throws {
  let record =
    "format=1\npayload_revision=\(EmbeddedGuestPayload.revision)\nappliance_id=\(ApplianceCatalogEntry.current.id)\n"
  #expect(SeedPreparation.guestRecord(applianceID: ApplianceCatalogEntry.current.id) == record)
  let yaml = try SeedPreparation.userData(entry: .current)
  #expect(
    yaml.contains(
      "  - path: /etc/macus-guest\n    permissions: \"0600\"\n    content: |\n"
        + record.split(separator: "\n").map { "      \($0)\n" }.joined()))
  // Without a catalog entry the record still names the payload, but no appliance.
  let bare = try SeedPreparation.userData()
  #expect(bare.contains("      payload_revision=\(EmbeddedGuestPayload.revision)\n"))
  #expect(!bare.contains("appliance_id="))
}

@Test func adoptionRecordIsRenderedOnlyForAnUpgradeSeed() throws {
  let adoption = try StorageAdoption(poolGuid: "1234567890123456789", layout: "zfs-v1")
  let block =
    "  - path: /etc/tama-storage/adopt\n    permissions: \"0600\"\n    content: |\n"
    + "      pool_guid=1234567890123456789\n      layout=zfs-v1\n"
  let upgrade = try SeedPreparation.userData(entry: .current, adoption: adoption)
  #expect(upgrade.contains(block))
  // The rest of the upgrade seed is the creation seed.
  #expect(
    upgrade.replacingOccurrences(of: block, with: "")
      == (try SeedPreparation.userData(entry: .current)))
  for creation in [try SeedPreparation.userData(entry: .current), try SeedPreparation.userData()] {
    #expect(!creation.contains("path: \(StorageAdoption.path)"))
    #expect(!creation.contains("pool_guid="))
  }
  let record = StorageIdentityRecord(
    backend: "zfs", poolGuid: "120", layout: "zfs-v1", source: StorageIdentityRecord.healthSource)
  #expect(try StorageAdoption(record).record == "pool_guid=120\nlayout=zfs-v1\n")
}

@Test func adoptionRefusesMalformedIdentity() {
  for guid in ["", "12a", "-1", " 120", String(repeating: "1", count: 21), "١٢٠"] {
    #expect(throws: RuntimeError.self) { try StorageAdoption(poolGuid: guid, layout: "zfs-v1") }
  }
  for layout in ["", "zfs-v2", "zfs-v1\npool_guid=1"] {
    #expect(throws: RuntimeError.self) { try StorageAdoption(poolGuid: "120", layout: layout) }
  }
  let ext4 = StorageIdentityRecord(
    backend: "ext4", poolGuid: "120", layout: "zfs-v1", source: StorageIdentityRecord.healthSource)
  #expect(throws: RuntimeError.self) { try StorageAdoption(ext4) }
}

@Test func creationSeedNeverCarriesAnAdoptionRecord() async throws {
  let cache = URL(fileURLWithPath: "/tmp/macus-adopt-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: cache) }
  _ = try await SeedPreparation.prepare(
    entry: .current, cache: cache, runner: ProcessCommandRunner(), timeout: 30, environment: [:])
  // The ISO stores user data uncompressed, so the rendered paths are visible in its bytes.
  let iso = try Data(contentsOf: cache.appendingPathComponent("seed.iso"))
  #expect(iso.range(of: Data("path: /etc/macus-guest".utf8)) != nil)
  #expect(iso.range(of: Data("path: \(StorageAdoption.path)".utf8)) == nil)
}

@Test func prebuiltObservationIsRecognized() {
  let observed = GuestObservationParser.parse(
    line: "MACUS_OBSERVATION v1 stage=image state=verified")
  #expect(observed?.stage == "image")
  #expect(observed?.state == "verified")
}

@Test func refusedAdoptionObservationKeepsItsCode() {
  let observed = GuestObservationParser.parse(
    line: "MACUS_OBSERVATION v1 stage=failed code=storage_adoption_refused")
  #expect(observed?.stage == "failed")
  #expect(observed?.code == "storage_adoption_refused")
}

#if DEBUG
  @Test func draftLoaderAcceptsFreshSiblingPathsAndRejectsExistingState() throws {
    let root = URL(fileURLWithPath: "/private/tmp/macus-draft-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let client = root.appendingPathComponent("client", isDirectory: true)
    try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    let archive = root.appendingPathComponent("archive")
    try Data().write(to: archive)
    let pins = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Integration/qualification/drafts/alpine-3.24.2-lts-1.json")
    let env = [
      "MACUS_QUALIFICATION_PINS": pins.path,
      "MACUS_QUALIFICATION_ARCHIVE": archive.path,
      "INCUS_CONF": client.path,
    ]
    let loaded = try DraftQualification.load(environment: env, state: state)
    let draft = try #require(loaded)
    #expect(draft.catalog.id == "alpine-3.24.2-lts-1")
    #expect(draft.catalog.prebuiltIdentity?.channel == "lts")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    #expect(throws: RuntimeError.self) {
      try DraftQualification.load(environment: env, state: state)
    }
  }
#endif
