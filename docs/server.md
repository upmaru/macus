# Macus server: HTTPS, trust and credentials

The Macus server (`server/`) is the one HTTPS gateway in front of the private
Swift runtime. It serves native Incus at `/` and `/1.0`, the runtime API and
the `/mcp` tools. This page covers where it listens, who it trusts and how
credentials are issued, rotated and revoked. All of its state lives in
`<state-dir>/server/` (0700), outside the package and outside the VM disks in
`<state-dir>/runtime/`.

The `macus server` commands described here are owner-local: they change only
files in `<state-dir>/server/`. They never start, restart or stop a service,
contact the runtime or Incus, touch VM disks or print a secret.

## Local HTTPS (the default)

Without configuration the gateway listens on `127.0.0.1:8443` only and
advertises `https://127.0.0.1:8443`. On its first start it generates its own
identity, an ECDSA P-384 certificate for `localhost`, `127.0.0.1` and `::1`,
in `server/gateway.crt` and `server/gateway.key` (0600). It never regenerates
it: once the server has published `server/endpoint.json`, a missing or
half-missing identity stops the server instead of silently replacing the
certificate clients have pinned.

After binding, the server atomically writes `server/endpoint.json` (0600): its
URL, advertised addresses, listen address, certificate and SHA-256
fingerprint, process ID, start time and build identity. It never contains a
key, token or socket path.

`macus start` also prepares the local CLI's own credential once: a
`macus-local-cli` bearer token with the `runtime.read`, `runtime.write` and
`runtime.delete` scopes, written only to `server/local-cli.token` (0600). Its
record in `server/bearer-tokens.json` holds the token's SHA-256 verifier,
never the token. Later starts keep a valid credential unchanged.

Show the current configuration:

```bash
macus server config show
```

## LAN or remote HTTPS

LAN access is never automatic. The gateway never binds `0.0.0.0` or `::`,
inspects no interfaces, and changes no router or firewall setting. To serve
another network, choose one address to bind, the URL clients will use, and a
certificate that names that URL's host:

```bash
macus server config set --bind-address 192.168.1.20 \
  --advertised-url https://macus.example.net:8443 \
  --certificate-file /Users/me/certs/macus.example.net.pem \
  --key-file /Users/me/certs/macus.example.net.key
```

That writes `server/gateway.json` (0600):

```json
{
  "advertised_url": "https://macus.example.net:8443",
  "bind_address": "192.168.1.20",
  "certificate_file": "/Users/me/certs/macus.example.net.pem",
  "key_file": "/Users/me/certs/macus.example.net.key",
  "schema_version": 1
}
```

The rules, checked by `macus server config set` and again by the server when
it starts:

- `--bind-address` is an IP literal; `--port` is 1 to 65535 (default 8443).
- A non-loopback bind needs `--advertised-url`, `https://HOST[:PORT]` with no
  path, query or user information, whose host is not a loopback name.
- The generated identity names loopback only, so a LAN or remote URL needs
  `--certificate-file` and `--key-file`, absolute paths given together. The
  key must be an unencrypted EC or RSA key readable only by you (0600); the
  certificate (optionally followed by its chain) must be yours and writable
  by nobody else. At start the server proves the key belongs to the
  certificate, that the certificate is currently valid and that it names the
  advertised host (DNS name or IP address).

The server reads `gateway.json` only when it starts; `set` and `reset` say so
and restart nothing. `macus server config reset` removes the file, returning
to the loopback defaults at the next start.

A gateway bound to a loopback, private (10/8, 172.16/12, 192.168/16, 100.64/10,
fc00::/7) or link-local address may advertise local addresses and names such
as `macmini`, as native Incus does. A gateway bound to a public address
advertises only public addresses and dotted DNS names.

## Gateway trust, not guest trust

The gateway terminates TLS on macOS, so it alone decides who may use native
Incus. Its trust store is `server/trusted-certificates.json`. The guest's own
Incus trust store, certificates and addresses never grant or describe access:
an anonymous client sees only the gateway's synthetic identity, and a
certificate the guest trusts but the gateway does not is refused before any
guest request.

Enroll a client with a single-use enrollment token:

```bash
macus server trust token issue --name laptop --address macus.example.net:8443 \
  --server-certificate /Users/me/certs/macus.example.net.pem \
  --output /Users/me/laptop.trust-token
```

The token is written only to the new 0600 `--output` file; move it to the
client and redeem it there with the standard client:

```bash
incus remote add macus "$(cat laptop.trust-token)"
```

It expires after one hour by default (at most 30 days) and enrolls one
certificate once. `macus server trust token list` and `revoke ID` administer
unredeemed tokens. Enrolled certificates are managed with the standard
`incus config trust list` and `incus config trust remove` against the gateway.
`--server-certificate` is the gateway certificate clients pin: the operator
certificate, or `<state-dir>/server/gateway.crt` for the generated identity.

## Native Incus

Native Incus clients use the same HTTPS listener as the runtime API and `/mcp`,
at the canonical paths only: `/`, `/1.0` and `/1.0/*`. There is no `/incus`
prefix or other alias, and nothing else listens. Standard clients such as
`incus` connect unmodified, with no patch or Macus plugin. Requests,
WebSockets and raw upgrades reach the guest's `incus.sock` only after the
client certificate is found in gateway trust. Requests keep their method,
path, query, conditional headers, body and status, and errors arrive in
Incus's own shape. Hop-by-hop headers (`Connection` and the headers it names,
`Keep-Alive`, `TE`, `Upgrade`, `Proxy-*`), credentials and forwarding headers
are not passed on.

| Native path | Through the gateway |
| --- | --- |
| HTTP requests under `/1.0` | Relayed and streamed, including binary uploads and chunked downloads |
| WebSockets (`/1.0/events`, operation channels) | Data and Incus JSON control frames relayed both ways; ping/pong answered locally on each side; close codes and reasons preserved |
| `GET /1.0/instances/NAME/sftp` and `/nbd`, `GET /1.0/storage-pools/POOL/volumes/TYPE/NAME/sftp` and `/nbd` | HTTP/1.1 `Upgrade` switched to a byte tunnel only after the guest itself accepts it; bytes sent along with the handshake, binary traffic and half-close are preserved |

The gateway's identity differs from the guest's in four places:

- Anonymous `GET /` and `GET /1.0` are answered by the gateway itself and
  never reach the guest.
- An authenticated `GET /1.0` reports the gateway's certificate and
  advertised addresses instead of the guest's. Its `api_extensions` are
  limited to those both the guest and the gateway support.
- `/1.0/certificates` manages gateway trust and redeems enrollment tokens. It
  never touches the guest's own trust store.
- If `incus.sock` can't be reached, native requests fail with
  `502 Backend is unavailable`, while `/runtime/status` stays readable (see
  [the API](api.md)).

Native streams have fixed limits:

| Limit | Value | When it is reached |
| --- | --- | --- |
| Concurrent native exchanges | 64 | The next native request is a `503 Gateway is at capacity`. `/runtime` and `/mcp` are not counted. A finished, failed or disconnected exchange frees its slot |
| Idle stream | 60 seconds without bytes in either direction | The exchange is closed |
| Exchange lifetime | 1 hour | The exchange is closed, even if still active |
| Body per stream | 1 GiB, read 64 KiB at a time | The request or response fails |
| Revocation and expiry | 5 seconds | Open exchanges for a removed or expired certificate close |

A slow reader holds the guest back rather than making the gateway buffer.
A transfer or interactive session that runs past an hour is closed at that
limit.

## Bearer tokens

`/mcp` takes scoped bearer tokens instead of client certificates; the
`runtime.*` scopes are for the public runtime API:

```bash
macus server token issue --principal laptop --scope incus.read --scope runtime.read \
  --expires-in 30d --output /Users/me/laptop.token
```

Scopes are `incus.read`, `incus.write`, `incus.exec`, `incus.delete`,
`runtime.read`, `runtime.write` and `runtime.delete`, plus the native Incus
scopes `incus.native.read`, `incus.native.write`, `incus.native.delete` and
`incus.native.admin`. `macus-local-cli` is reserved.

The `incus.*` scopes reach the shared composite Incus operations. The
`incus.native.*` scopes reach opsmaru_incus's one-to-one native operations
and are granted only when you name them: no other scope implies them, and
without one a native operation is neither listed by `search` nor run by
`execute`. `incus.native.admin` includes the guest's own certificate and
cluster operations. Those edit the trust store inside the guest, which never
grants access through the gateway (see
[Gateway trust, not guest trust](#gateway-trust-not-guest-trust)).

```bash
macus server token issue --principal ops --scope incus.native.read \
  --expires-in 1d --output /Users/me/ops.token
```

Tokens are
`macus.<id>.<secret>`; the store keeps the secret's SHA-256 verifier only, and
`macus server token list` shows neither.

## Rotation and revocation

| Credential | Rotate | Revoke | Takes effect |
| --- | --- | --- | --- |
| Bearer token | Issue a new token, move clients to it, revoke the old one | `macus server token revoke ID` | Next request; open `/mcp` streams close within 5 seconds |
| Local CLI token | Revoke its `macus-local-cli` record; the next `macus start` issues a new one | `macus server token revoke ID` | As above |
| Client certificate | Enroll the new certificate, then remove the old one | `incus config trust remove` | Next request; active native exchanges end within 5 seconds |
| Enrollment token | Issue another | `macus server trust token revoke ID` | Next enrollment |
| Gateway certificate | See below | — | At the next server start |

Expiry is enforced the same way: an expired token or certificate is refused
on its next request and its open streams close within the same 5-second bound
(`Macus.Auth.Streams` for bearer streams, the shared gateway's
`recheck_interval` for native exchanges).

To rotate an operator gateway certificate, point the configuration at the new
files with `macus server config set --certificate-file ... --key-file ...` and
restart the server. Clients that pinned the old certificate must pin the new
one, for example by removing the remote and enrolling again with a new token.
The generated identity is replaced only deliberately: stop the server, remove
`server/gateway.crt`, `server/gateway.key` and `server/endpoint.json`, and
start it again; every client must then pin the new certificate.

## Diagnostics

No `macus server` command prints a token or verifier, in human or JSON output.
Secrets exist only in the files an issue command creates and in
`server/local-cli.token`. The server's logs omit credentials: they record each
request's method, path (without its query string) and status, never
authorization headers or bodies, and any logged parameter whose name contains
`token`, `secret`, `password` or `key` appears as `[FILTERED]`.
When sharing diagnostics, include `endpoint.json` and `gateway.json` freely,
but never the token files, `gateway.key` or an operator key.
