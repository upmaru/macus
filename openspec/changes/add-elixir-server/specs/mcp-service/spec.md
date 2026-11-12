# Spec Delta

## Purpose

Exposes shared `:opsmaru_incus` Incus operations and Macus runtime operations to agents through one authenticated MCP endpoint that advertises exactly two tools, `search` and `execute`, with synchronous execution and macOS runtime safety.

## ADDED Requirements

### Requirement: Maintained MCP protocol integration

Macus SHALL expose one /mcp endpoint through the maintained protocol implementation. The shared library MUST NOT start another endpoint, listener or process, and tama-dex MUST NOT start another endpoint or listener; its index process runs under the Macus supervisor. Unsupported protocol/transport features MUST NOT be advertised, and authentication SHALL precede tool discovery and execution.

#### Scenario: Unsupported protocol

- **WHEN** a client requests a protocol version or feature unsupported by the pinned dependency
- **THEN** the server returns the dependency's bounded protocol failure rather than inventing compatibility

### Requirement: Two-tool search and execute surface

The /mcp endpoint SHALL advertise exactly two tools: `search`, which finds operations across all indexed cassettes with an optional cassette filter, and `execute`, which runs one operation addressed by cassette and operation ID with its input. Individual operations SHALL NOT be advertised as separate MCP tools. Macus SHALL own both tool modules, taking their definitions from `Tama.Dex.MCP.search_tool/0` and `Tama.Dex.MCP.execute_tool/0` and delegating to `Tama.Dex.MCP.handle_search/3` and `Tama.Dex.MCP.handle_execute/4`. Indexing and query matching SHALL be delegated to tama-dex; Macus SHALL NOT implement its own search engine. `search` SHALL return each operation's cassette, cassette version, operation ID, description, input/output schemas, scopes, confirmation rule and bounds taken from the indexed documents.

#### Scenario: Tool discovery

- **WHEN** an authenticated caller lists tools at the Macus endpoint
- **THEN** only `search` and `execute` are returned, regardless of how many operations the catalogue holds

#### Scenario: Operation lookup

- **WHEN** an authorized caller searches for an operation such as listing instances
- **THEN** the result names matching operations with the schemas and confirmation rules needed to call `execute`

### Requirement: Cassette-namespaced operation sources

Macus SHALL keep one tama-dex index holding two cassettes, each a namespace of `tama-operations/1` operations. The `opsmaru_incus` cassette SHALL be installed from the shared library's bundled release cassette. The local `macus` cassette SHALL hold the Macus-built runtime document. Operations SHALL be addressed by cassette and operation ID, so an operation ID needs to be unique only within its cassette. Each source SHALL be executed by its registered executor: `Opsmaru.Incus.Operations.run/3` for `opsmaru_incus` and the Macus runtime executor for `macus`. Shared operations SHALL be indexed as published, without renaming or schema changes. Loading into an imported cassette's name SHALL fail, as SHALL importing over the local cassette's name. Operations the shared library does not export SHALL NOT be indexed or executable.

#### Scenario: Same operation ID in two cassettes

- **WHEN** the `macus` and `opsmaru_incus` cassettes each declare an operation with the same ID
- **THEN** both load, and `execute` runs whichever one the call's cassette names

#### Scenario: Cassette name conflict

- **WHEN** Macus loads its runtime document into the `opsmaru_incus` cassette name
- **THEN** the load fails with a cassette conflict and the imported cassette is unchanged

#### Scenario: Native source without an executor

- **WHEN** the imported `opsmaru_incus` cassette includes its `opsmaru_incus_native` source and Macus registers no native executor
- **THEN** Macus refuses to issue `incus.native.*` scopes, so no caller can discover or execute a native operation

#### Scenario: Shared cassette upgrade

- **WHEN** a newer bundled `opsmaru_incus` cassette that drops an operation is imported
- **THEN** the whole cassette is replaced atomically, the dropped operation is no longer executable and the `macus` cassette is untouched

### Requirement: Index storage and readiness

Macus SHALL supervise the tama-dex index at `<state-dir>/server/tama-dex.sqlite3` with mode 0600, as derived data that is recreated when deleted or when its schema version does not match. At server start Macus SHALL import the bundled `opsmaru_incus` cassette pinned by SHA-256 and load its `macus` cassette without blocking VM startup. It SHALL report each cassette's status as gateway readiness, separate from VM readiness. Startup MUST NOT download a cassette. While a cassette is on its first import, describing or executing its operations SHALL return `not_ready` without dispatching.

#### Scenario: Index still importing

- **WHEN** an `execute` call names the `opsmaru_incus` cassette while its first import is still running
- **THEN** the tool returns `not_ready` with `dispatched: false`, the committed `macus` cassette keeps serving and the VM's startup and readiness are unaffected

#### Scenario: Bundled cassette fails its pin

- **WHEN** the bundled `opsmaru_incus` cassette does not match the SHA-256 pin recorded in build metadata
- **THEN** nothing is imported, previous entries stay, that cassette's readiness is reported as failed with repair guidance and the cassette is not rebuilt silently

#### Scenario: Index file deleted

- **WHEN** the index file is missing at server start
- **THEN** Macus recreates it from the bundled cassette and its own document without fetching anything

### Requirement: Scoped search and execution

Search results SHALL include only operations the caller's verified scopes permit, and `execute` SHALL treat an unknown cassette, or an operation hidden by those scopes, as not found. `execute` SHALL enforce the named operation's own scopes even though one tool fronts every operation. Shared operations SHALL run through `Opsmaru.Incus.Operations.run/3` with the caller's verified scopes, and the Macus runtime executor SHALL apply the same check. Unknown or forbidden operations SHALL fail before backend/provider access; no unrestricted host command operation SHALL exist.

#### Scenario: Read-only identity

- **WHEN** an authenticated identity has only inspection scopes
- **THEN** `search` returns only inspection operations and `execute` refuses a mutation operation before any backend request

#### Scenario: Canonical workload mutation

- **WHEN** an authorized `execute` call creates, changes, snapshots or deletes an Incus workload
- **THEN** it delegates to the native Incus client and returns standard operation identity without creating a second workload manager

### Requirement: Explicit destructive inputs

Runtime deletion, workload deletion, destructive restore and forced stop SHALL require explicit destructive input and permission. Shared destructive operations SHALL require `confirm` to repeat the affected resource exactly, as defined by the library. Runtime deletion SHALL retain the private API's stopped-state and confirmation requirements. Broad deletion based on inferred consent or unvalidated model text MUST NOT occur.

#### Scenario: Missing confirmation

- **WHEN** an `execute` call for a deletion operation lacks its required explicit confirmation
- **THEN** validation rejects it before any guest or runtime mutation

### Requirement: Truthful synchronous tool behavior

`execute` SHALL run shared Incus and Macus runtime operations synchronously within bounded waits and report native operation or runtime identity with completed, running, failed or uncertain status. Callers SHALL be able to poll later state by executing the operation and runtime status operations. Durable MCP task handles MUST NOT be advertised, and accepted operations MUST NOT be described as completed. Errors SHALL state whether the operation was dispatched. A dispatched failure or invalid result SHALL keep the operation's declared identity fields and SHALL NOT be retried automatically.

#### Scenario: Long-running creation

- **WHEN** an instance creation is still running when its bounded wait expires
- **THEN** `execute` returns the native operation identity as running and the caller can poll it without a durable task handle

#### Scenario: Lost mutation response

- **WHEN** the server cannot determine whether a mutation was accepted before a connection failed
- **THEN** it reports an explicit uncertain outcome with any known operation identity and does not automatically issue the mutation again

### Requirement: Bounded results and execution

`search` and `execute` inputs, outputs, concurrency and deadlines SHALL have documented bounds; shared operations retain the library's per-operation bounds. Exec operations SHALL run only inside an explicitly selected Incus instance and bound captured output. Errors SHALL preserve useful native codes without revealing credentials, private host files or unrestricted guest logs.

#### Scenario: Output limit reached

- **WHEN** a command produces more output than an operation's declared capture limit
- **THEN** the result identifies truncation or the bounded failure and the server remains responsive to other clients

### Requirement: Protocol and backend acceptance

MCP acceptance SHALL exercise the dependency's applicable conformance fixtures, the two-tool surface, search result filtering, operation schemas, scope checks, explicit confirmations and truthful operation results. Mock protocol success SHALL remain distinct from actual runtime and guest workload acceptance.

#### Scenario: Conformance without guest

- **WHEN** MCP fixture tests pass against fake runtime and Incus endpoints
- **THEN** protocol evidence is recorded and hardware-backed mutation acceptance remains incomplete

### Requirement: Trusted host and owner binding

Macus SHALL implement the shared library's operation host contract with the verified principal, scopes and its configured local Incus connection and context. Caller-selected URLs, sockets, forged owner fields and unregistered host providers MUST NOT override trusted configuration.

#### Scenario: Forged backend selection

- **WHEN** an `execute` call supplies another owner or unregistered backend address
- **THEN** no shared or host operation is dispatched using that forged binding

### Requirement: Host-specific runtime capabilities

Macus SHALL supply its runtime capability and path-prerequisite provider without transferring VM ownership to shared code. Capability inspection SHALL be passive; share changes requiring a stopped VM MUST NOT trigger an implicit restart or claim readiness.

#### Scenario: Unavailable workspace share

- **WHEN** host path inspection discovers a new share would require stopped-runtime configuration
- **THEN** it reports that prerequisite without changing sharing or restarting the VM
