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

## Bearer tokens

`/mcp` takes scoped bearer tokens instead of client certificates; the
`runtime.*` scopes are for the public runtime API:

```bash
macus server token issue --principal laptop --scope incus.read --scope runtime.read \
  --expires-in 30d --output /Users/me/laptop.token
```

Scopes are `incus.read`, `incus.write`, `incus.exec`, `incus.delete`,
`runtime.read`, `runtime.write` and `runtime.delete`; native Incus scopes are
never issued, and `macus-local-cli` is reserved. Tokens are
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
