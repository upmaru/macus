import CryptoKit
import Darwin
import Foundation
import Security

/// The local Macus server the CLI talks to: the URL and certificate fingerprint the server
/// published in `<state-dir>/server/endpoint.json`, and the local CLI's own bearer credential
/// from `<state-dir>/server/local-cli.token`.
///
/// Discovery only reads. Both files must be owner-private regular files below a safe state
/// directory and its 0700 `server` directory. A missing file means the server has not been set
/// up there: discovery fails with guidance to run `macus start` and never falls back to the
/// private Swift sockets.
public struct GatewayEndpoint: Sendable, Equatable {
  public static let maximumMetadata = 65_536

  public let url: URL
  /// Lowercase hex SHA-256 of the server's leaf certificate (DER).
  public let fingerprint: String
  let token: String

  public static func discover(stateDirectory: URL) throws -> GatewayEndpoint {
    let directory = stateDirectory.standardizedFileURL
    let state = GatewayDocument.systemAlias(directory.path)
    var info = stat()
    guard lstat(state, &info) == 0 else {
      guard errno == ENOENT else {
        throw RuntimeError(.io, "Cannot inspect the state directory \(directory.path)")
      }
      throw RuntimeError(
        .unavailable,
        "No Macus server is set up for \(directory.path). Run macus start; this command does not create state or start services."
      )
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o022 == 0, try GatewayDocument.safeAncestors(state)
    else {
      throw RuntimeError(
        .invalidConfiguration,
        "The state directory and its ancestors must belong to this user or root and not be writable by others"
      )
    }
    let server = URL(fileURLWithPath: state).appendingPathComponent("server")
    guard lstat(server.path, &info) == 0 else {
      guard errno == ENOENT else { throw RuntimeError(.io, "Cannot inspect the gateway directory") }
      throw RuntimeError(
        .unavailable,
        "The Macus server has not been set up in \(directory.path). Run macus start.")
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o777 == 0o700
    else {
      throw RuntimeError(
        .invalidConfiguration, "The gateway directory must be a 0700 directory owned by this user")
    }
    let metadata = try readPrivate(server.appendingPathComponent("endpoint.json"))
    guard let metadata else {
      throw RuntimeError(
        .unavailable,
        "The Macus server has not published its endpoint in \(directory.path)/server. Run macus start."
      )
    }
    let (url, fingerprint) = try parse(metadata)
    guard
      let token = BearerTokenStore.readLocalToken(server.appendingPathComponent("local-cli.token"))
    else {
      throw RuntimeError(
        .unavailable,
        "The local CLI credential \(directory.path)/server/local-cli.token is missing or not owner-private. Run macus start to prepare it."
      )
    }
    return GatewayEndpoint(
      url: url, fingerprint: fingerprint, token: "macus.\(token.id).\(token.secret)")
  }

  static func parse(_ data: Data) throws -> (URL, String) {
    let malformed = RuntimeError(
      .invalidConfiguration,
      "The Macus server endpoint metadata is malformed. Restart the server with macus start.")
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      jsonInt(object["schema_version"]) == 1, let text = jsonString(object["url"]),
      let fingerprint = jsonString(object["certificate_fingerprint"]),
      fingerprint.utf8.count == 64,
      fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let url = baseURL(text)
    else { throw malformed }
    return (url, fingerprint)
  }

  /// `https://HOST:PORT` with no user information, path, query or fragment.
  static func baseURL(_ text: String) -> URL? {
    guard text.utf8.count <= 2_048, let components = URLComponents(string: text),
      components.scheme == "https", let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.path.isEmpty || components.path == "/", components.query == nil,
      components.fragment == nil, (components.port ?? 443) > 0
    else { return nil }
    var base = components
    base.path = ""
    return base.url
  }

  /// The contents of an owner-private (0600) regular file of at most `maximumMetadata` bytes, or
  /// nil when it does not exist. Never follows a link.
  static func readPrivate(_ url: URL) throws -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw RuntimeError(
        .invalidConfiguration, "\(url.lastPathComponent) must be a regular file owned by this user")
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
      info.st_size <= Int64(maximumMetadata)
    else {
      throw RuntimeError(
        .invalidConfiguration,
        "\(url.lastPathComponent) must be an owner-private (0600) file of at most 64 KiB")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw RuntimeError(.io, "Cannot read \(url.lastPathComponent)")
      }
      if count == 0 { break }
      data.append(buffer, count: count)
      guard data.count <= maximumMetadata else {
        throw RuntimeError(.invalidConfiguration, "\(url.lastPathComponent) exceeds 64 KiB")
      }
    }
    return data
  }
}

extension GatewayEndpoint: CustomStringConvertible {
  /// Never includes the credential.
  public var description: String { "GatewayEndpoint(\(url.absoluteString))" }
}

/// One request to the public `/runtime` API of the local Macus server.
public protocol GatewayTransport: Sendable {
  func request(
    _ endpoint: GatewayEndpoint, method: String, path: String, body: Data, timeout: Int
  ) async throws -> LocalHTTPResponse
}

/// HTTPS to the local Macus server with the published certificate pinned.
///
/// The server must present exactly the leaf certificate whose SHA-256 the endpoint metadata
/// records, over TLS 1.3; system trust, proxies, cookies, caches and redirects are not used. One
/// deadline covers connecting, sending and the whole response, and the body is limited to
/// 16 MiB. A failure is reported, never retried, and never answered from a private socket.
public struct HTTPSGatewayClient: GatewayTransport {
  public static let maximumResponseBody = 16 * 1024 * 1024
  static let methods: Set<String> = ["GET", "POST", "PUT", "DELETE"]
  static let cannotConnect = "Cannot connect to the Macus server"

  /// Whether a request failed before any connection to the server was made, so it never ran.
  static func neverConnected(_ error: any Error) -> Bool {
    guard let error = error as? RuntimeError else { return false }
    return error.code == .unavailable && error.message.hasPrefix(cannotConnect)
  }

  /// Whether a gateway answer says the runtime service never received the request: the
  /// credential was refused, or the gateway reports it `not_dispatched`.
  static func notDispatched(_ response: LocalHTTPResponse) -> Bool {
    if response.status == 401 { return true }
    guard !(200...299).contains(response.status),
      let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let error = object["error"] as? [String: Any]
    else { return false }
    return error["outcome"] as? String == "not_dispatched"
  }

  public init() {}

  public func request(
    _ endpoint: GatewayEndpoint, method: String, path: String, body: Data = Data(), timeout: Int
  ) async throws -> LocalHTTPResponse {
    guard Self.methods.contains(method), path == "/runtime" || path.hasPrefix("/runtime/"),
      !path.utf8.contains(where: { $0 < 33 || $0 == 127 || $0 == 35 || $0 == 63 }),
      (1...3600).contains(timeout), body.count <= 1_048_576,
      let url = URL(string: endpoint.url.absoluteString + path)
    else { throw RuntimeError(.invalidRequest, "Invalid Macus server request") }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = TimeInterval(timeout)
    request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if !body.isEmpty {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
    configuration.timeoutIntervalForRequest = TimeInterval(timeout)
    configuration.timeoutIntervalForResource = TimeInterval(timeout)
    configuration.waitsForConnectivity = false
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.httpMaximumConnectionsPerHost = 1

    let exchange = PinnedExchange(
      fingerprint: endpoint.fingerprint, server: endpoint.url.absoluteString,
      limit: Self.maximumResponseBody)
    let session = URLSession(configuration: configuration, delegate: exchange, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return try await exchange.run(session.dataTask(with: request), timeout: timeout)
  }

  /// Lowercase hex SHA-256 of a certificate's DER bytes.
  static func fingerprint(_ certificate: SecCertificate) -> String {
    SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
      .map { String(format: "%02x", $0) }.joined()
  }
}

private final class PinnedExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let fingerprint: String
  private let server: String
  private let limit: Int
  private let lock = NSLock()
  private var continuation: CheckedContinuation<LocalHTTPResponse, any Error>?
  private var task: URLSessionTask?
  private var status = 0
  private var data = Data()
  private var failure: RuntimeError?

  init(fingerprint: String, server: String, limit: Int) {
    self.fingerprint = fingerprint
    self.server = server
    self.limit = limit
  }

  func run(_ task: URLSessionDataTask, timeout: Int) async throws -> LocalHTTPResponse {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          self.continuation = continuation
          self.task = task
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in
          self?.fail(
            RuntimeError(
              .timeout, "The Macus server at \(self?.server ?? "") did not answer in \(timeout)s"))
        }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  /// Records the first failure and stops the exchange.
  private func fail(_ error: RuntimeError) {
    let task: URLSessionTask? = lock.withLock {
      if failure == nil { failure = error }
      return self.task
    }
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
      Void
  ) {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      guard let trust = challenge.protectionSpace.serverTrust,
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
        let leaf = chain.first, HTTPSGatewayClient.fingerprint(leaf) == fingerprint
      else {
        fail(
          RuntimeError(
            .unavailable,
            "The server at \(server) did not present the certificate recorded in endpoint.json. Nothing was sent."
          ))
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    case NSURLAuthenticationMethodClientCertificate:
      // The gateway accepts but never needs a client certificate on /runtime.
      completionHandler(.performDefaultHandling, nil)
    default:
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      fail(RuntimeError(.io, "The Macus server sent a non-HTTP response"))
      completionHandler(.cancel)
      return
    }
    if http.expectedContentLength > Int64(limit) {
      fail(RuntimeError(.io, "The Macus server response exceeds 16 MiB"))
      completionHandler(.cancel)
      return
    }
    lock.withLock { status = http.statusCode }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let exceeded = lock.withLock {
      self.data.append(data)
      return self.data.count > limit
    }
    if exceeded { fail(RuntimeError(.io, "The Macus server response exceeds 16 MiB")) }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let (continuation, failure, status, data) = lock.withLock {
      let continuation = self.continuation
      self.continuation = nil
      return (continuation, self.failure, self.status, self.data)
    }
    guard let continuation else { return }
    if let failure {
      continuation.resume(throwing: failure)
    } else if let error {
      continuation.resume(throwing: map(error))
    } else if (300...399).contains(status) {
      continuation.resume(
        throwing: RuntimeError(.io, "The Macus server answered with a redirect, which is refused"))
    } else {
      continuation.resume(returning: LocalHTTPResponse(status: status, body: data))
    }
  }

  private func map(_ error: any Error) -> any Error {
    guard let error = error as? URLError else {
      return RuntimeError(.io, error.localizedDescription)
    }
    switch error.code {
    case .cancelled:
      return CancellationError()
    case .timedOut:
      return RuntimeError(.timeout, "The Macus server at \(server) did not answer in time")
    case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed,
      .secureConnectionFailed:
      return RuntimeError(
        .unavailable,
        "\(HTTPSGatewayClient.cannotConnect) at \(server). Run macus start; this command does not fall back to the private runtime socket."
      )
    case .networkConnectionLost:
      return RuntimeError(
        .unavailable,
        "The connection to the Macus server at \(server) was lost before it answered, so the request may have run. Check macus status before retrying."
      )
    default:
      return RuntimeError(.io, "Macus server request failed: \(error.localizedDescription)")
    }
  }
}

/// Sends one `/runtime` request and turns a non-2xx answer into its `RuntimeError`.
func gatewayRequest(
  _ method: String, _ path: String, _ body: Data = Data(), directory: URL, timeout: Int,
  transport: any GatewayTransport
) async throws -> LocalHTTPResponse {
  let endpoint = try GatewayEndpoint.discover(stateDirectory: directory)
  return try requireGatewaySuccess(
    try await transport.request(endpoint, method: method, path: path, body: body, timeout: timeout))
}

/// A 2xx gateway answer, or the `RuntimeError` its body describes.
func requireGatewaySuccess(_ response: LocalHTTPResponse) throws -> LocalHTTPResponse {
  guard (200...299).contains(response.status) else {
    if response.status == 401 {
      throw RuntimeError(
        .unavailable,
        "The Macus server refused the local CLI credential. Run macus start to prepare a new one.")
    }
    throw responseFailure(status: response.status, body: response.body)
  }
  return response
}

/// Whether the Macus server for a state is serving. Only an authenticated `/runtime/status`
/// answered over the pinned published identity counts: a port that merely accepts connections, or
/// an endpoint record left by an earlier process, does not.
protocol ServerProbe: Sendable {
  func serving(stateDirectory: URL, timeout: Int) async throws -> Bool
}

struct GatewayServerProbe: ServerProbe {
  var transport: any GatewayTransport = HTTPSGatewayClient()

  func serving(stateDirectory: URL, timeout: Int) async throws -> Bool {
    do {
      _ = try await gatewayRequest(
        "GET", "/runtime/status", directory: stateDirectory, timeout: max(1, timeout),
        transport: transport)
      return true
    } catch let error as RuntimeError where error.code == .invalidConfiguration {
      // Unsafe endpoint or credential files are never worked around.
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return false
    }
  }
}
