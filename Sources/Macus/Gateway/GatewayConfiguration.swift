import Darwin
import Foundation

/// The owner's gateway listener configuration, `<state-dir>/server/gateway.json`, as the Macus
/// server reads it (`Macus.Gateway.Config`). Every field is optional; without the file the server
/// listens on `127.0.0.1:8443` with its generated loopback identity.
public struct GatewayConfiguration: Sendable, Equatable {
  public static let defaultBindAddress = "127.0.0.1"
  public static let defaultPort = 8_443
  static let fields: Set<String> = [
    "schema_version", "bind_address", "port", "advertised_url", "certificate_file", "key_file",
  ]

  public var bindAddress: String?
  public var port: Int?
  public var advertisedURL: String?
  public var certificateFile: String?
  public var keyFile: String?

  public init(
    bindAddress: String? = nil, port: Int? = nil, advertisedURL: String? = nil,
    certificateFile: String? = nil, keyFile: String? = nil
  ) {
    self.bindAddress = bindAddress
    self.port = port
    self.advertisedURL = advertisedURL
    self.certificateFile = certificateFile
    self.keyFile = keyFile
  }

  /// The address and port the server binds.
  public var effectiveBindAddress: String { bindAddress ?? Self.defaultBindAddress }
  public var effectivePort: Int { port ?? Self.defaultPort }

  /// What clients connect to: the advertised URL, or the loopback bind address.
  public var effectiveURL: String {
    if let advertisedURL { return advertisedURL }
    let host = effectiveBindAddress
    return "https://\(host.contains(":") ? "[\(host)]" : host):\(effectivePort)"
  }

  /// Whether the server uses its generated loopback identity.
  public var usesDefaultIdentity: Bool { certificateFile == nil && keyFile == nil }

  var document: [String: Any] {
    var object: [String: Any] = ["schema_version": 1]
    if let bindAddress { object["bind_address"] = bindAddress }
    if let port { object["port"] = port }
    if let advertisedURL { object["advertised_url"] = advertisedURL }
    if let certificateFile { object["certificate_file"] = certificateFile }
    if let keyFile { object["key_file"] = keyFile }
    return object
  }

  var jsonObject: [String: Any] {
    [
      "bind_address": effectiveBindAddress, "port": effectivePort, "url": effectiveURL,
      "certificate_file": certificateFile ?? NSNull(), "key_file": keyFile ?? NSNull(),
      "default_identity": usesDefaultIdentity,
    ]
  }

  // MARK: Validation (mirroring Macus.Gateway.Config)

  /// Checks the configuration the way the server does at start: an IP literal bind address that
  /// is never `0.0.0.0` or `::`, a port from 1 to 65535, an `https://HOST[:PORT]` advertised URL
  /// that a non-loopback bind requires and whose host is then not a loopback name, and absolute
  /// certificate and key paths given together.
  public func validate() throws {
    let bind = effectiveBindAddress
    guard let ip = Self.parseIP(bind) else {
      throw RuntimeError(.invalidRequest, "--bind-address must be an IPv4 or IPv6 address literal")
    }
    if Self.isUnspecified(ip) {
      throw RuntimeError(
        .invalidRequest,
        "The gateway never binds every interface (0.0.0.0 or ::); choose one address")
    }
    guard Self.isUsable(ip) else {
      throw RuntimeError(.invalidRequest, "--bind-address cannot be multicast or broadcast")
    }
    guard (1...65_535).contains(effectivePort) else {
      throw RuntimeError(.invalidRequest, "--port must be from 1 to 65535")
    }
    let loopback = Self.isLoopback(ip)
    if let advertisedURL {
      guard let host = Self.advertisedHost(advertisedURL) else {
        throw RuntimeError(
          .invalidRequest,
          "--advertised-url must be https://HOST[:PORT] with no path, query or user information")
      }
      if !loopback, Self.isLoopbackName(host) {
        throw RuntimeError(
          .invalidRequest,
          "A non-loopback --bind-address needs an --advertised-url clients elsewhere can reach")
      }
    } else if !loopback {
      throw RuntimeError(
        .invalidRequest,
        "A non-loopback --bind-address needs --advertised-url, the URL clients connect to")
    }
    switch (certificateFile, keyFile) {
    case (nil, nil): break
    case (let certificate?, let key?):
      guard Self.isAbsolute(certificate) else {
        throw RuntimeError(.invalidRequest, "--certificate-file requires an absolute path")
      }
      guard Self.isAbsolute(key) else {
        throw RuntimeError(.invalidRequest, "--key-file requires an absolute path")
      }
    default:
      throw RuntimeError(.invalidRequest, "--certificate-file and --key-file are given together")
    }
  }

  enum IP: Equatable {
    case v4([UInt8])
    case v6([UInt8])
  }

  static func parseIP(_ text: String) -> IP? {
    var v4 = in_addr()
    if inet_pton(AF_INET, text, &v4) == 1 {
      return .v4(withUnsafeBytes(of: &v4) { Array($0) })
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, text, &v6) == 1 {
      return .v6(withUnsafeBytes(of: &v6) { Array($0) })
    }
    return nil
  }

  static func isUnspecified(_ ip: IP) -> Bool {
    switch ip {
    case .v4(let bytes), .v6(let bytes): bytes.allSatisfy { $0 == 0 }
    }
  }

  static func isUsable(_ ip: IP) -> Bool {
    switch ip {
    case .v4(let bytes): bytes[0] < 224 && bytes != [255, 255, 255, 255]
    case .v6(let bytes): bytes[0] != 0xFF
    }
  }

  static func isLoopback(_ ip: IP) -> Bool {
    switch ip {
    case .v4(let bytes): bytes[0] == 127
    case .v6(let bytes): bytes == Array(repeating: 0, count: 15) + [1]
    }
  }

  static func isLoopbackName(_ host: String) -> Bool {
    if let ip = parseIP(host) { return isLoopback(ip) }
    let lower = host.lowercased()
    return lower == "localhost" || lower.hasSuffix(".localhost")
  }

  /// The host of a valid advertised URL, or nil.
  static func advertisedHost(_ url: String) -> String? {
    guard url.utf8.count <= 2_048, url.hasPrefix("https://"),
      let components = URLComponents(string: url), components.scheme == "https",
      components.user == nil, components.password == nil, components.path.isEmpty,
      components.query == nil, components.fragment == nil,
      var host = components.host, !host.isEmpty
    else { return nil }
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if let port = components.port, !(1...65_535).contains(port) { return nil }
    if let ip = parseIP(host) { return isUnspecified(ip) ? nil : host }
    guard host.utf8.count <= 253, let first = host.utf8.first, let last = host.utf8.last,
      isAlphanumeric(first), isAlphanumeric(last),
      host.utf8.allSatisfy({ isAlphanumeric($0) || $0 == 0x2E || $0 == 0x2D })
    else { return nil }
    return host
  }

  private static func isAlphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }

  static func isAbsolute(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.utf8.contains(0) && !path.contains("\n")
  }
}

/// Owner-local administration of `<state-dir>/server/gateway.json`.
///
/// Changes hold an exclusive lock and replace the file atomically as a 0600 file in the 0700
/// gateway directory; `show` creates nothing. The running server reads the file only when it
/// starts, so nothing here restarts, activates or contacts a service.
public struct GatewayConfigurationStore: Sendable {
  static let maxBytes = 65_536

  public let stateDirectory: URL
  let document: GatewayDocument

  public init(stateDirectory: URL) {
    self.stateDirectory = stateDirectory.standardizedFileURL
    document = GatewayDocument(
      stateDirectory: self.stateDirectory, name: "gateway", label: "gateway configuration",
      collection: "", maxRecords: 0, isRecord: { _ in false })
  }

  public var file: URL { document.file }

  /// The stored configuration, or the defaults when there is none. Creates nothing.
  public func show() throws -> (configuration: GatewayConfiguration, stored: Bool) {
    try document.requireStateDirectory()
    guard case .present = try document.gatewayDirectoryState(),
      let configuration = try load()
    else { return (GatewayConfiguration(), false) }
    return (configuration, true)
  }

  /// Applies `change` to the stored configuration (or the defaults), validates the result and
  /// writes it. The certificate and key must already exist as this user's regular files, the
  /// key readable by nobody else; the server checks that they match and name the advertised host
  /// when it starts.
  public func update(_ change: (inout GatewayConfiguration) -> Void) throws -> GatewayConfiguration
  {
    try document.requireStateDirectory()
    // Refuse an invalid change before creating anything; it is checked again under the lock.
    if case .absent = try document.gatewayDirectoryState() {
      var preview = GatewayConfiguration()
      change(&preview)
      try Self.check(preview)
    }
    try document.prepareGatewayDirectory()
    return try document.withLock {
      var configuration = try load() ?? GatewayConfiguration()
      change(&configuration)
      try Self.check(configuration)
      guard
        var data = try? JSONSerialization.data(
          withJSONObject: configuration.document, options: [.sortedKeys, .withoutEscapingSlashes])
      else { throw RuntimeError(.io, "Cannot encode the gateway configuration") }
      data.append(0x0A)
      try document.replace(with: data)
      return configuration
    }
  }

  /// Removes the stored configuration, returning the server to its loopback defaults at its next
  /// start. Reports whether a file was removed.
  public func reset() throws -> Bool {
    try document.requireStateDirectory()
    guard case .present = try document.gatewayDirectoryState() else { return false }
    return try document.withLock {
      guard try load() != nil else { return false }
      guard unlink(file.path) == 0 else {
        throw RuntimeError(.io, "Cannot remove the gateway configuration")
      }
      try GatewayDocument.syncDirectory(document.gatewayDirectory)
      return true
    }
  }

  /// Reads and validates `gateway.json`; nil when absent. An unsafe, oversized, malformed or
  /// invalid file is refused and left unchanged, as the server would refuse it.
  func load() throws -> GatewayConfiguration? {
    var info = stat()
    if lstat(file.path, &info) != 0 {
      guard errno == ENOENT else { throw preserved("Cannot inspect the gateway configuration") }
      return nil
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o777 == 0o600, info.st_size <= Self.maxBytes
    else {
      throw preserved(
        "The gateway configuration must be a 0600 regular file owned by this user, at most 64 KiB")
    }
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw preserved("Cannot open the gateway configuration") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard let data = try? handle.read(upToCount: Self.maxBytes + 1), data.count <= Self.maxBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw preserved("The gateway configuration is not a JSON object") }
    guard Set(object.keys).isSubset(of: GatewayConfiguration.fields),
      jsonInt(object["schema_version"]) == 1
    else { throw preserved("The gateway configuration has unknown fields or schema") }
    func string(_ key: String) throws -> String? {
      guard let value = object[key] else { return nil }
      guard let text = value as? String else {
        throw preserved("The gateway configuration field \(key) is invalid")
      }
      return text
    }
    var port: Int?
    if let raw = object["port"] {
      guard let value = jsonInt(raw) else {
        throw preserved("The gateway configuration field port is invalid")
      }
      port = value
    }
    let configuration = GatewayConfiguration(
      bindAddress: try string("bind_address"), port: port,
      advertisedURL: try string("advertised_url"),
      certificateFile: try string("certificate_file"), keyFile: try string("key_file"))
    do {
      try configuration.validate()
    } catch let error as RuntimeError {
      throw preserved("The stored gateway configuration is invalid: \(error.message)")
    }
    return configuration
  }

  static func check(_ configuration: GatewayConfiguration) throws {
    try configuration.validate()
    if let certificate = configuration.certificateFile, let key = configuration.keyFile {
      try checkIdentityFile(certificate, flag: "--certificate-file", privateKey: false)
      try checkIdentityFile(key, flag: "--key-file", privateKey: true)
    }
  }

  static func checkIdentityFile(_ path: String, flag: String, privateKey: Bool) throws {
    var info = stat()
    guard lstat(GatewayDocument.systemAlias(path), &info) == 0,
      info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid()
    else {
      throw RuntimeError(
        .invalidConfiguration, "\(flag) must name an existing regular file owned by this user")
    }
    if privateKey, info.st_mode & 0o077 != 0 {
      throw RuntimeError(.invalidConfiguration, "\(flag) must be readable only by this user (0600)")
    }
    if !privateKey, info.st_mode & 0o022 != 0 {
      throw RuntimeError(.invalidConfiguration, "\(flag) must not be writable by others")
    }
  }

  private func preserved(_ message: String) -> RuntimeError {
    RuntimeError(.invalidConfiguration, message + "; the file was preserved")
  }
}
