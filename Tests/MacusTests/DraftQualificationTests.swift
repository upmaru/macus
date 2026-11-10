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

@Test func prebuiltObservationIsRecognized() {
  let observed = GuestObservationParser.parse(
    line: "MACUS_OBSERVATION v1 stage=image state=verified")
  #expect(observed?.stage == "image")
  #expect(observed?.state == "verified")
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
