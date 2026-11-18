# MCP: search and execute

The Macus server serves one MCP endpoint, `/mcp`, on its HTTPS gateway (see
[the server page](server.md) for the address and certificate). It advertises
exactly two tools: `search`, to find an operation, and `execute`, to run
one. Every operation they serve is listed in
[the operation manifest](mcp-operations.md): the Macus runtime operations
(`macus` cassette) and the shared opsmaru_incus Incus operations
(`opsmaru_incus` cassette).

## Connecting

| | |
| --- | --- |
| Endpoint | `POST https://<gateway>/mcp`, MCP Streamable HTTP, protocol `2026-07-28` (stateless). Only that path; `GET` is 405 and longer paths are 404 |
| Credential | `Authorization: Bearer macus.<id>.<secret>` on every request (see [Bearer tokens](server.md#bearer-tokens)). A missing, unknown, expired or revoked token is a 401 with `Bearer error="invalid_token"` before any tool runs |
| Body | At most 1 MiB (413 beyond that) |
| Deadline | 30 seconds per request |
| Connections | The gateway listener accepts at most 1024 connections, shared with `/runtime` and native Incus |
| Revocation | Revoking or expiring a token ends its in-flight requests within 5 seconds |

Issue a token with only the scopes the agent needs:

```bash
macus server token issue --principal agent --scope incus.read --scope runtime.read \
  --expires-in 7d --output /Users/me/agent.token
```

Then configure the MCP client with the endpoint URL, the token as a bearer
`Authorization` header, and the gateway certificate
(`<state-dir>/server/gateway.crt` for the generated identity) as a trusted
certificate authority.

## Scopes decide what an agent sees

A scope both reveals and permits operations. `search` returns only the
operations the token's scopes allow, and `execute` answers `not_found` for
any other, without saying whether it exists.

| Scope | Operations |
| --- | --- |
| `runtime.read` | Runtime status, progress, health, capabilities and configuration |
| `runtime.write` | Create, start, stop, restart and configuration replacement |
| `runtime.delete` | Forced stop and runtime deletion (destructive, confirmed) |
| `incus.read` | Incus inspection: server, projects, instances, images, networks, storage, operations |
| `incus.write` | Instance, state, image and snapshot changes; cancelling an operation |
| `incus.exec` | Running one bounded command in a named instance |
| `incus.delete` | Workload deletion and destructive restore (confirmed) |
| `incus.native.read`, `incus.native.write`, `incus.native.delete`, `incus.native.admin` | opsmaru_incus's one-to-one native Incus operations. Granted only when a token is issued with them by name; no other scope implies them |

Having a scope is necessary but not sufficient: each operation still checks
its own rules when it runs, such as the confirmation value, Macus's project
and image-remote policy, and the runtime's stopped-state preconditions.

## `search`

Finds operations. All arguments are optional.

| Argument | Meaning | Bounds |
| --- | --- | --- |
| `query` | Words to match in operation IDs, summaries, tags, descriptions and input fields; each word is a prefix and all must match. Omit it to list operations | At most 512 characters |
| `cassette` | Only this cassette: `macus` or `opsmaru_incus` | |
| `source` | Only this source: `macus`, `opsmaru_incus` or `opsmaru_incus_native` | |
| `tags` | Only operations carrying every tag | At most 16 |
| `limit` | Results to return | 1 to 20, default 5 |
| `include_schemas` | Include each result's input schema | Default `true` |

The response is `{"results": [...], "truncated": bool}`. Results from both
cassettes are ranked together. Each carries `cassette`, `cassette_version`,
`operation_id`, `source`, `summary`, `description`, `tags`, `scopes`,
`destructive`, `confirmation` (`null` or `{field, description}`), `bounds`
and, unless omitted, `input_schema`. Descriptions longer than 1024
characters are cut (`description_truncated`). The whole response stays
within 64 KiB: input schemas are dropped from the lowest-ranked results
first (`schema_omitted`), then whole results from the end, and `truncated`
says results were dropped.
A bad argument is an `invalid_arguments` error; while the index is still
loading, `not_ready`.

```json
{"name": "search", "arguments": {"query": "instance list", "limit": 3}}
```

## `execute`

Runs one operation found with `search`. All three arguments are required.

| Argument | Meaning |
| --- | --- |
| `cassette` | Copied from the search result |
| `operation_id` | Copied from the search result |
| `input` | A JSON object matching the result's `input_schema`, including its confirmation field when it has one. At most 1 MiB |

```json
{
  "name": "execute",
  "arguments": {
    "cassette": "opsmaru_incus",
    "operation_id": "incus_instance_delete",
    "input": {"name": "c1", "confirm": "c1"}
  }
}
```

A success is `{"cassette", "operation_id", "source", "result"}`, where
`result` is the operation's own output. The input is checked before the
operation runs, and the operation runs at most once.

### Errors and `dispatched`

Every error says whether the operation ran:

| Error | `dispatched` | Meaning |
| --- | --- | --- |
| `not_found` | false | Unknown cassette or operation, or one your scopes hide |
| `not_ready` | false | The operation index, or this cassette's first import, is still loading. Try again shortly |
| `no_executor` | false | No runner for the operation's source |
| `invalid_input` | false | `input` is not an object within 1 MiB or doesn't match the schema; up to 16 failing JSON pointers in `details` |
| `confirmation_required` | false | The confirmation field is missing or empty |
| `operation_error` (in place of `error`) | true | The operation's own error, such as a wrong confirmation value, a policy refusal or a native Incus error with its code |
| `dispatch_failed` | true | The runner failed while running |
| `invalid_output` | true | The operation ran but its result did not match its schema; known identity fields are in `details` |

Errors with `dispatched: true` are returned as MCP tool errors and may have
taken effect. Check the state with a read operation before trying again;
Macus never retries a mutation itself.

### Long-running work

Operations are synchronous with bounded waits; there are no MCP tasks or
task handles.

- An Incus mutation returns its native `operation_id` with `status`
  `completed`, `running`, `failed` or `uncertain`. Poll a `running` one with
  `incus_operation_get` or `incus_operation_wait`, and cancel it with
  `incus_operation_cancel`.
- A runtime start, stop or restart waits up to 25 seconds. A slower one
  reports `status: "uncertain"` and keeps going; poll
  `macus_runtime_progress` or `macus_runtime_status`.
- `incus_instance_exec` runs one noninteractive command with a 30-second
  default (300 at most) timeout, at most 64 KiB of `stdin` given as a
  string, and 64 KiB of captured output per stream. Longer output is counted
  and marked truncated; a command still running at its timeout is killed.

### Readiness

The operation index is gateway readiness, separate from the VM. It is
loaded at server start: the bundled, SHA-256-pinned `opsmaru_incus`
cassette is imported and the `macus` cassette is built from the runtime
document. Until a cassette is committed, calls naming it answer
`not_ready`; a cassette that failed to install is reported with repair
guidance while the other keeps serving. Startup never downloads a cassette.

## Not provided

These are absent by design:

- Per-operation MCP tools. The catalogue grows without changing the tool
  list.
- MCP tasks, notifications and subscriptions; MCP resources, resource
  templates and prompts; completions. These methods answer "method not
  found".
- A stdio transport or any second MCP endpoint or listener.
- Interactive or terminal exec, console attachment and streamed stdin.
  Use a standard Incus client against the native gateway for those.
- A host shell, arbitrary HTTP requests, or a way to choose another
  backend, socket, owner or cluster target from tool input.
