import Foundation
import Security

/// Read-only view of the gateway's client-certificate trust store,
/// `<state-dir>/server/trusted-certificates.json`, which only the Macus server writes
/// (`Macus.Proxy.Trust`). `macus client setup` reads it to choose how to register a client whose
/// certificate the gateway may already trust. Nothing here creates or changes trust.
struct GatewayTrust: Sendable {
  static let maxEntries = 1_024

  let document: GatewayDocument

  init(stateDirectory: URL) {
    document = GatewayDocument(
      stateDirectory: stateDirectory.standardizedFileURL, name: "trusted-certificates",
      label: "gateway trust store", collection: "certificates", maxRecords: Self.maxEntries,
      isRecord: { GatewayDocument.isHex64($0["fingerprint"]) }, idKey: "fingerprint")
  }

  /// Whether the gateway trusts the certificate with SHA-256 `fingerprint`. An absent store
  /// trusts nothing; an unsafe or malformed one is refused, as the server refuses it.
  func trusts(_ fingerprint: String) throws -> Bool {
    try document.existingRecords().contains { $0["fingerprint"] as? String == fingerprint }
  }
}

/// The lowercase hex SHA-256 of the DER certificate in `pem`, which must hold exactly one valid
/// certificate.
func pemCertificateFingerprint(_ pem: String) -> String? {
  let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
  guard blocks.count == 1, let block = blocks.first,
    let end = block.range(of: "-----END CERTIFICATE-----"),
    let der = Data(
      base64Encoded: String(block[..<end.lowerBound]), options: .ignoreUnknownCharacters),
    SecCertificateCreateWithData(nil, der as CFData) != nil
  else { return nil }
  return GatewayDocument.sha256Hex(data: der)
}
