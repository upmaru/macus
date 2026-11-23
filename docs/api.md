# Local API contract

The bundled `macus` client calls the [public runtime API](#public-runtime-api) over the Macus server's pinned HTTPS endpoint for `runtime`, `doctor`, setup readiness and every lifecycle, progress and health request of `macus start`, reads the control socket only to identify an already-serving daemon while `macus start` activates the services, and registers the standard Incus CLI with the server's HTTPS endpoint. See [the CLI reference](cli.md). It does not add daemon routes or implement workload operations. Behind the server, the Swift daemon serves two owner-only Unix sockets in its state directory, default `~/.tama/incus-mac`. `runtime.sock` controls the outer VM ([private runtime API](#private-runtime-api-v1)). `incus.sock` carries unmodified Incus HTTP, WebSockets, exec, events and streaming operations. They are the server's backend, not a client interface. Possession of either socket grants privileged control of the Linux appliance, so keep them owner-only. The daemon opens no TCP listener and no SSH is used; the server's HTTPS gateway, on loopback by default, is the only listener.

## Public runtime API

The Macus server (see [the Macus server](server.md)) publishes the runtime API over its authenticated HTTPS gateway at `/runtime`, with no version in the path. Each public route maps to one private route below and keeps its methods, errors, conflict rules and budget. Every request needs a Macus bearer token (`Authorization: Bearer macus.<id>.<secret>`) with the route's scope, checked before the body is read or the private socket is used. An unknown path is 404 and a known path with another method is 405 with an `Allow` header, also before any private request.

| Method | Public path | Private route | Scope | Body |
| --- | --- | --- | --- | --- |
| GET | `/runtime/status` | `GET /v1/runtime/status` | `runtime.read` | None |
| GET | `/runtime/capabilities` | `GET /v1/runtime/capabilities` | `runtime.read` | None |
| GET | `/runtime/health` | `GET /v1/runtime/health` | `runtime.read` | None |
| GET | `/runtime/config` | `GET /v1/runtime/config` | `runtime.read` | None |
| GET | `/runtime/progress` | `GET /v1/runtime/progress` | `runtime.read` | None |
| POST | `/runtime/create` | `POST /v1/runtime/create` | `runtime.write` | Complete configuration |
| POST | `/runtime/start` | `POST /v1/runtime/start` | `runtime.write` | Empty, or `{"remaining_seconds":N}` |
| POST | `/runtime/stop` | `POST /v1/runtime/stop` | `runtime.write` | Empty or `{"force":false}` |
| POST | `/runtime/stop` | `POST /v1/runtime/stop` with `{"force":true}` | `runtime.delete` | `{"force":true,"confirm":"force-stop"}` |
| POST | `/runtime/restart` | `POST /v1/runtime/restart` | `runtime.write` | None |
| PUT | `/runtime/config` | `PUT /v1/runtime/config` | `runtime.write` | Complete configuration |
| DELETE | `/runtime` | `DELETE /v1/runtime` with `{"confirm":true}` | `runtime.delete` | `{"confirm":"delete-runtime"}` |

The gateway reads each body itself, at most 1 MiB (413 beyond that); no global parser runs on `/runtime`, `/1.0` or `/mcp`. `create` and `PUT config` need a complete schema 1 configuration object with exactly the fields below (`seed_path` optional, shares with `name`, `path` and optional `read_only`); a missing, unknown or mistyped field is a 400 `invalid_configuration` before dispatch, and the original bytes are forwarded so Swift applies its own range, path and state validation. A start budget is forwarded unchanged and the gateway's deadline covers it. Destructive requests need the confirm tokens shown; anything else is a 400 `confirmation_required` before dispatch.

Swift's responses keep their status and JSON bytes, including the error envelope and 409 conflicts. The one change is that a runtime status object (from status and from mutations that answer with one) loses the private `incus_socket` path and gains the gateway's public endpoint and separate readiness:

```json
{
  "api_version": 1,
  "state": "ready",
  "last_error": null,
  "uptime_seconds": 42,
  "server_ready": true,
  "runtime_ready": true,
  "server_endpoint": {
    "url": "https://127.0.0.1:8443",
    "certificate_fingerprint": "<sha-256 of the gateway certificate>"
  },
  "incus_endpoint": {
    "url": "https://127.0.0.1:8443",
    "certificate_fingerprint": "<sha-256 of the gateway certificate>"
  }
}
```

The gateway answers whether or not the guest is ready: status stays readable and start stays available while the runtime is absent, stopped, starting or failed, and workload requests at `/1.0` fail with the shared gateway's bounded 502 "Backend is unavailable" instead of claiming readiness. When the Swift service itself cannot be reached, status is a 503 `unavailable` error that still carries `"server_ready": true` and `"runtime_ready": false`. Transport failures are 503 `unavailable` or 504 `timeout` with an `outcome` of `not_dispatched`, `read_only` or `unknown`; a request that may have been accepted (`unknown`) is never resent. Revoking the bearer token ends an in-flight request within 5 seconds, but the Swift runtime keeps doing whatever that request started.

```sh
TOKEN="$(cat /Users/me/macus.token)"
curl --cacert "$STATE/server/gateway.crt" -H "Authorization: Bearer $TOKEN" \
  https://127.0.0.1:8443/runtime/status
curl --cacert "$STATE/server/gateway.crt" -H "Authorization: Bearer $TOKEN" \
  -X POST -d '{"remaining_seconds":600}' https://127.0.0.1:8443/runtime/start
```

### Host prerequisites

Macus never changes the runtime implicitly. Directory shares, resources and timeouts are configuration, and `PUT /runtime/config` requires a stopped VM: while it runs, Swift answers 409 `conflict` ("Configuration requires a stopped VM") and the gateway passes that through without stopping, restarting or changing anything. To add a share, stop the runtime, replace the complete configuration with the new share, then start it. Share paths must be existing absolute directories on the host; the guest exposes them under `/mnt/tama-shares/<name>`, and workloads use them only through standard Incus disk devices. Host support (Apple virtualization, nested virtualization) and live Incus evidence are read from `GET /runtime/capabilities`; nothing is provisioned to satisfy them.

## Private runtime API v1

The Swift daemon serves these routes on `runtime.sock`. They are the private backend of the public API above. `macus start` reads `GET /v1/runtime/status` and `GET /v1/runtime/progress` here only to identify a compatible daemon while it activates the service; it creates, boots and checks the runtime through the public API.

| Method | Path | Payload / response |
| --- | --- | --- |
| GET | `/v1/runtime/status` | State, socket path, uptime and optional last error |
| GET | `/v1/runtime/capabilities` | Host support and live Incus/workload evidence |
| GET | `/v1/runtime/health` | Live guest protocol, Incus version/extensions and KVM |
| GET | `/v1/runtime/config` | Complete configuration |
| GET | `/v1/runtime/progress` | Read-only boot snapshot; not live readiness |
| POST | `/v1/runtime/create` | Complete configuration; creates verified writable root and persistent data |
| POST | `/v1/runtime/start` | Empty body, or optional `{"remaining_seconds":N}` |
| POST | `/v1/runtime/stop` | Optional `{"force":false}`; waits for graceful shutdown |
| POST | `/v1/runtime/restart` | No body; graceful stop, then start |
| PUT | `/v1/runtime/config` | Complete replacement; only when stopped |
| DELETE | `/v1/runtime` | `{"confirm":true}`; only when stopped; destroys Incus state |

States: `absent`, `stopped`, `starting`, `ready`, `stopping`, `failed`. Start/create/stop are idempotent when their postcondition is already satisfied. Lifecycle/configuration mutations return 409 during another mutation, except explicit force stop cancels an active boot wait; status remains readable. Initial boot allows 600 seconds by default; clients must use a matching response timeout. Stop never silently forces shutdown on timeout. Deletion leaves the externally supplied source image/seed and logs intact. Confirmed deletion records durable intent before touching owned files; daemon restart completes an interrupted reset. Invalid intent or unconfirmed incomplete state preserves data. A readiness failure may leave the outer VM running; explicitly stop it before recovery. Repeated start rechecks guest health before returning ready.

Progress is readable while start is still running. `ready` is true only after live guest health, never because a serial marker or process launch occurred. `phase` is an allowlisted provisioning observation such as `image`, `storage`, `incus` or `expected_reboot`. Unknown marker versions are ignored. A legacy bootstrap may restart once after the current boot emits `MACUS_OBSERVATION v1 stage=kernel_transition state=expected_reboot` and the guest actually stops. The allowance is durable, is not replenished by a daemon restart, and is not a second start request. Stale serial lines do not authorize a restart. Explicit force stop cancels a pending restart. A current-boot `stage=failed` observation ends start at once with `unavailable`, naming the code and keeping disks and the running guest. For `code=incus_crashed` only, start first shuts the guest down (graceful, forced after `min(shutdown_timeout_seconds, 60)` s) and boots it once more within the same budget, reporting phase `incus_recovery`; a second crash in the same start fails. Once the current boot has reported `storage`, `incus` or `ready`, 300 s with neither health nor new serial output fails start with `timeout`. An empty start body keeps the saved readiness limit. A valid `remaining_seconds` value from 1 to 3600 bounds that boot and the expected restart by the smaller of the budget and the saved limit, without writing configuration. Invalid or unbounded budgets fail before boot.

```json
{
  "api_version": 1,
  "schema_version": 1,
  "state": "starting",
  "ready": false,
  "operation": "start",
  "phase": "packages",
  "elapsed_seconds": 12,
  "expected_reboot": false,
  "detail": null,
  "last_error": null
}
```

JSON uses snake_case. Configuration schema 1 requires every nonoptional field shown below. `seed_path` may be omitted or null; `read_only` defaults to true within a share. Swift initializer defaults and the generated template do not imply omitted-field defaults for configuration JSON; API clients can use the generated `config.json`:

```json
{
  "schema_version": 1,
  "cpu_count": 4,
  "memory_mib": 4096,
  "data_disk_gib": 32,
  "appliance_manifest_path": "/absolute/appliance/manifest.json",
  "seed_path": "/absolute/appliance/seed.iso",
  "nested_virtualization": true,
  "shares": [],
  "readiness_timeout_seconds": 600,
  "shutdown_timeout_seconds": 60
}
```

A share is `{"name":"workspace","path":"/absolute/project","read_only":true}`. Names contain ASCII letters, digits, `_` or `-`, up to 36 bytes; paths must be existing directories. The guest exposes them under `/mnt/tama-shares/<name>`; callers use standard Incus disk devices to pass them to workloads. Shares never appear implicitly.

Resource bounds: 1–64 CPUs (also limited by VZ), 512–262144 MiB RAM (also limited by VZ), 1–16384 GiB data, 1–1800 second readiness and 1–300 second shutdown. Updates cannot change appliance/seed identity or shrink data. Growing the disk preserves bytes. The next boot grows recognized ext4 or expands an owned ZFS vdev; it never shrinks or recreates a pool.

Error envelope: `{"error":{"code":"conflict","message":"A runtime mutation is already in progress"}}`. Codes: `invalid_request`/`invalid_configuration` (400), `not_found` (404), `conflict` (409), `unavailable`/`io` (503), `timeout` (504). Invalid JSON yields 400. Control requests use HTTP/1.0 or 1.1 with one request per connection, at most 16 KiB headers and 1 MiB body. Chunked transfer and duplicate lengths are rejected. Incus traffic has its own stream socket and does not inherit control HTTP restrictions.

## tama-machine integration

On Linux, connect directly to native Incus. On macOS, run `macus start` (or rely on its launchd jobs), then use the server's public endpoint from `server/endpoint.json` and pin its `certificate_fingerprint`. Read capabilities and status, create with the appliance configuration if absent and start, all through the [public runtime API](#public-runtime-api) with a bearer token of the right scopes. Then talk to `incus_endpoint` as an ordinary HTTPS Incus server with a client certificate the gateway trusts. Existing Incus SDKs work unchanged. Do not create a second workload API, and do not connect to the private sockets.

```sh
STATE="$HOME/.tama/incus-mac"
macus server token issue --principal tama --scope runtime.read --scope runtime.write \
  --expires-in 30d --output /Users/me/tama.token
TOKEN="$(cat /Users/me/tama.token)"
curl --cacert "$STATE/server/gateway.crt" -H "Authorization: Bearer $TOKEN" \
  https://127.0.0.1:8443/runtime/status
curl --cacert "$STATE/server/gateway.crt" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @/absolute/appliance/config.json https://127.0.0.1:8443/runtime/create
curl --cacert "$STATE/server/gateway.crt" -H "Authorization: Bearer $TOKEN" \
  -X POST -d '{"remaining_seconds":600}' https://127.0.0.1:8443/runtime/start
```

`--cacert` works for the generated default identity; with an operator certificate, verify the fingerprint from `server/endpoint.json` instead. Register the macOS Incus CLI, which has no implicit local server, with `macus client setup`. It adds an HTTPS remote for the endpoint, enrolls the client certificate with a bound single-use token and changes the default remote only with `--set-default`. Use a dedicated `INCUS_CONF` directory for test clients:

```sh
macus client setup --remote macus --set-default
incus list
```

Another machine enrolls with a token from `macus server trust token issue` and plain `incus remote add` (see [the Macus server](server.md)). A remote that still points at `unix:$STATE/incus.sock` from before the server is reported as a conflict, not changed; remove it with `incus remote remove NAME` or choose another `--remote`.

The runtime performs no instance/image/profile/project/network/storage/remote/transfer translations. Standard Incus artifacts remain portable to remote Incus hosts.
