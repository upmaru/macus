import CryptoKit
import Foundation

@testable import Macus

/// A PEM certificate and its lowercase SHA-256 fingerprint.
struct FixtureCertificate: Sendable {
  let pem: String
  let fingerprint: String

  init(der: Data) {
    let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    pem = "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
  }

  /// The gateway certificate `FakeServerProbe` publishes and the fake incus client reports.
  static let server = generate("gateway")
  /// The client certificate the fake incus client presents.
  static let client = generate("incus-client")
  /// Another certificate, for a server that is not this state's gateway.
  static let other = generate("elsewhere")

  private static func generate(_ name: String) -> FixtureCertificate {
    let directory = URL(
      fileURLWithPath: "/private/tmp/macus-cert-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = [
      "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
      "-keyout", directory.appendingPathComponent("key.pem").path,
      "-out", directory.appendingPathComponent("cert.der").path, "-outform", "DER",
      "-days", "2", "-subj", "/CN=\(name)",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "openssl could not create \(name)")
    return FixtureCertificate(
      der: try! Data(contentsOf: directory.appendingPathComponent("cert.der")))
  }
}

/// The `--timeout` for start and client setup tests that expect to succeed. Each run spawns the
/// fake incus client several times, which CI runners do several times slower than a local Mac;
/// a 5-second budget has expired there. Deadline behaviour has its own tests with short,
/// explicit budgets.
let successDeadline = "30"

/// Writes a fake standard `incus` client to `path`. It keeps remotes in the JSON file named by
/// `MACUS_FIXTURE_STATE` (`{"default", "remotes": {name: [address]}, "trusted": [fingerprint]}`)
/// and its client certificate and server certificates under `INCUS_CONF`, and logs each argument
/// list to `MACUS_FIXTURE_LOG` when set.
///
/// It also plays the gateway: `MACUS_FIXTURE_SERVER_CERT` is the gateway certificate (PEM file).
/// With `MACUS_FIXTURE_GATEWAY` naming a Macus state directory, enrollment redeems tokens from that
/// state's `server/trust-tokens.json` as the server does (bound tokens refused unconsumed for any
/// other certificate, redemptions recorded) and trust is that state's
/// `server/trusted-certificates.json`; otherwise trust is the `trusted` list. `remote add NAME URL`
/// answers the certificate prompt from standard input as incus does.
/// `MACUS_FIXTURE_QUERY_CERT` makes `/1.0` report another certificate, and
/// `MACUS_FIXTURE_LIST_FAIL=1` makes `incus list` fail.
///
/// The interpreter runs with `-B`: Apple's `/usr/bin/python3` otherwise caches bytecode under
/// `$HOME/Library/Caches/com.apple.python`, which would write into a test's isolated `HOME` on any
/// machine that does not already set `PYTHONDONTWRITEBYTECODE`.
func writeFakeIncus(to path: String) throws {
  let script = #"""
    #!/usr/bin/python3 -B
    import base64, hashlib, json, os, sys
    args = sys.argv[1:]
    if os.environ.get("MACUS_FIXTURE_LOG"):
        with open(os.environ["MACUS_FIXTURE_LOG"], "a") as handle:
            handle.write(json.dumps(args) + "\n")
    state_path = os.environ["MACUS_FIXTURE_STATE"]
    with open(state_path) as handle:
        state = json.load(handle)
    state.setdefault("trusted", [])
    conf = os.environ.get("INCUS_CONF") or os.path.join(os.environ["HOME"], ".config", "incus")
    gateway = os.environ.get("MACUS_FIXTURE_GATEWAY")

    def fail(message, code=1):
        print(message, file=sys.stderr)
        sys.exit(code)

    def read(path):
        with open(path) as handle:
            return handle.read()

    def fingerprint(pem):
        body = pem.split("-----BEGIN CERTIFICATE-----")[1].split("-----END CERTIFICATE-----")[0]
        return hashlib.sha256(base64.b64decode("".join(body.split()))).hexdigest()

    def save():
        with open(state_path, "w") as handle:
            json.dump(state, handle)

    def private_write(path, document):
        descriptor = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(document, handle)
        os.rename(path + ".tmp", path)

    def document(name, key):
        path = os.path.join(gateway, "server", name)
        if not os.path.exists(path):
            return []
        return json.loads(read(path))[key]

    def trusted(value):
        if gateway:
            return any(entry["fingerprint"] == value for entry in document("trusted-certificates.json", "certificates"))
        return value in state["trusted"]

    def trust(value, name):
        if trusted(value):
            return
        if gateway:
            entries = document("trusted-certificates.json", "certificates")
            entries.append({"fingerprint": value, "name": name, "type": "client"})
            private_write(os.path.join(gateway, "server", "trusted-certificates.json"), {"schema_version": 1, "certificates": entries})
        else:
            state["trusted"].append(value)

    def client_pem():
        path = os.path.join(conf, "client.crt")
        if not os.path.exists(path):
            os.makedirs(conf, exist_ok=True)
            with open(path, "w") as handle:
                handle.write(read(os.environ["MACUS_FIXTURE_CLIENT_CERT"]))
        return read(path)

    def server_pem():
        return read(os.environ["MACUS_FIXTURE_SERVER_CERT"])

    def store_server_certificate(name):
        os.makedirs(os.path.join(conf, "servercerts"), exist_ok=True)
        with open(os.path.join(conf, "servercerts", name + ".crt"), "w") as handle:
            handle.write(server_pem())

    def reachable(name):
        if name not in state["remotes"]:
            fail("Remote %s doesn't exist" % name)
        address = state["remotes"][name][0]
        if not address.startswith("https://"):
            return address
        stored = os.path.join(conf, "servercerts", name + ".crt")
        if not os.path.exists(stored) or fingerprint(read(stored)) != fingerprint(server_pem()):
            fail("x509: certificate signed by unknown authority")
        return address

    def redeem(token):
        tokens = document("trust-tokens.json", "tokens")
        redemptions = document("trust-token-redemptions.json", "redemptions")
        verifier = hashlib.sha256(token["secret"].encode()).hexdigest()
        matches = [record for record in tokens if record["verifier"] == verifier and record["revoked_at"] is None]
        if len(matches) != 1 or any(entry["id"] == matches[0]["id"] for entry in redemptions):
            fail("Failed to create certificate: forbidden")
        record = matches[0]
        presented = fingerprint(client_pem())
        if record.get("client_fingerprint", presented) != presented:
            fail("Failed to create certificate: forbidden")
        redemptions.append({"id": record["id"], "redeemed_at": "2026-11-19T00:00:00Z", "fingerprint": presented})
        private_write(os.path.join(gateway, "server", "trust-token-redemptions.json"), {"schema_version": 1, "redemptions": redemptions})
        trust(presented, record["name"])

    if args == ["remote", "list", "--format", "json"]:
        print(json.dumps({name: {"Addrs": addrs, "Protocol": "incus"} for name, addrs in state["remotes"].items()}))
    elif args == ["remote", "get-default"]:
        if os.environ.get("MACUS_FIXTURE_DEFAULT_FAIL") == "1":
            sys.exit(1)
        print(state["default"])
    elif len(args) == 3 and args[:2] == ["remote", "switch"]:
        if args[2] not in state["remotes"] and args[2] != "local":
            fail("Remote %s doesn't exist" % args[2])
        state["default"] = args[2]
    elif args == ["remote", "get-client-certificate"]:
        sys.stdout.write(client_pem())
    elif len(args) == 4 and args[:2] == ["remote", "add"]:
        name, target = args[2], args[3]
        if name in state["remotes"]:
            fail("Remote %s exists as <%s>" % (name, state["remotes"][name][0]))
        presented = fingerprint(client_pem())
        if target.startswith("https://"):
            print("Certificate fingerprint: %s" % fingerprint(server_pem()))
            answer = sys.stdin.readline().strip()
            if answer != fingerprint(server_pem()):
                fail("Please type 'y', 'n' or the fingerprint:")
            store_server_certificate(name)
            if not trusted(presented):
                if not sys.stdin.readline():
                    fail("EOF")
            state["remotes"][name] = [target]
        else:
            token = json.loads(base64.b64decode(target))
            if token["fingerprint"] != fingerprint(server_pem()):
                fail("Certificate fingerprint mismatch between certificate token and server")
            if gateway:
                redeem(token)
            else:
                trust(presented, token["client_name"])
            store_server_certificate(name)
            state["remotes"][name] = ["https://" + token["addresses"][0]]
    elif len(args) == 2 and args[0] == "query" and args[1].endswith(":/1.0"):
        name = args[1][:-len(":/1.0")]
        if not reachable(name).startswith("https://"):
            fail("unix remotes are not served here")
        certificate = server_pem()
        if os.environ.get("MACUS_FIXTURE_QUERY_CERT"):
            certificate = read(os.environ["MACUS_FIXTURE_QUERY_CERT"])
        auth = "trusted" if trusted(fingerprint(client_pem())) else "untrusted"
        print(json.dumps({"api_version": "1.0", "auth": auth, "environment": {"certificate": certificate}}))
    elif len(args) == 2 and args[0] == "list" and args[1].endswith(":"):
        name = args[1][:-1]
        if os.environ.get("MACUS_FIXTURE_LIST_FAIL") == "1":
            fail("Error: connection reset by peer")
        if reachable(name).startswith("https://") and not trusted(fingerprint(client_pem())):
            fail("not authorized")
    else:
        fail("unexpected %s" % args, 2)
    save()
    """#
  try script.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

/// Writes the fixture certificates into `directory` and returns the environment the fake incus
/// client needs to find them.
func fakeIncusCertificates(in directory: URL, query: FixtureCertificate? = nil) throws -> [String:
  String]
{
  let server = directory.appendingPathComponent("gateway.crt")
  let client = directory.appendingPathComponent("fixture-client.crt")
  try FixtureCertificate.server.pem.write(to: server, atomically: true, encoding: .utf8)
  try FixtureCertificate.client.pem.write(to: client, atomically: true, encoding: .utf8)
  var environment = [
    "MACUS_FIXTURE_SERVER_CERT": server.path, "MACUS_FIXTURE_CLIENT_CERT": client.path,
  ]
  if let query {
    let other = directory.appendingPathComponent("query.crt")
    try query.pem.write(to: other, atomically: true, encoding: .utf8)
    environment["MACUS_FIXTURE_QUERY_CERT"] = other.path
  }
  return environment
}
