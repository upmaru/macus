# Spec Delta

## Purpose

Composes the shared `:opsmaru_incus` Incus tools with Macus runtime tools through one authenticated MCP endpoint with synchronous execution, retaining macOS runtime safety.

## ADDED Requirements

### Requirement: Maintained MCP protocol integration

Macus SHALL expose one /mcp endpoint composing shared Incus tools with Macus-owned runtime tools through the maintained protocol implementation. The shared library MUST NOT start another endpoint. Unsupported protocol/transport features MUST NOT be advertised, and authentication SHALL precede discovery and execution.

#### Scenario: Unsupported protocol

- **WHEN** a client requests a protocol version or feature unsupported by the pinned dependency
- **THEN** the server returns the dependency's bounded protocol failure rather than inventing compatibility

### Requirement: Scoped inspection and mutation tools

Macus runtime tools and shared native Incus tools SHALL enforce read, write, exec and destructive scopes during discovery and execution. Shared tool names/schemas/results SHALL match their library contract. Unknown or forbidden tools SHALL fail before backend/provider access; no unrestricted host command tool SHALL exist.

#### Scenario: Read-only identity

- **WHEN** an authenticated identity has only inspection scopes
- **THEN** it can discover and execute authorized inspection tools but cannot discover or execute mutation tools

#### Scenario: Canonical workload mutation

- **WHEN** an authorized tool creates, changes, snapshots or deletes an Incus workload
- **THEN** it delegates to the native Incus client and returns standard operation identity without creating a second workload manager

### Requirement: Explicit destructive inputs

Runtime deletion, workload deletion, destructive restore and forced stop SHALL require explicit destructive input and permission. Runtime deletion SHALL retain the private API's stopped-state and confirmation requirements. Broad deletion based on inferred consent or unvalidated model text MUST NOT occur.

#### Scenario: Missing confirmation

- **WHEN** a deletion tool lacks its required explicit confirmation
- **THEN** validation rejects it before any guest or runtime mutation

### Requirement: Truthful synchronous tool behavior

Shared Incus and Macus runtime tools SHALL execute synchronously within bounded waits and report native operation or runtime identity with completed, running, failed or uncertain status. Callers SHALL be able to poll later state through the operation and runtime status tools. Durable MCP task handles MUST NOT be advertised, and accepted operations MUST NOT be described as completed.

#### Scenario: Long-running creation

- **WHEN** an instance creation is still running when the tool's bounded wait expires
- **THEN** the tool returns the native operation identity as running and the caller can poll it without a durable task handle

#### Scenario: Lost mutation response

- **WHEN** the server cannot determine whether a mutation was accepted before a connection failed
- **THEN** it reports an explicit uncertain outcome with any known operation identity and does not automatically issue the mutation again

### Requirement: Bounded results and execution

Tool inputs, outputs, concurrency and deadlines SHALL have documented bounds. Exec tools SHALL run only inside an explicitly selected Incus instance and bound captured output. Tool errors SHALL preserve useful native codes without revealing credentials, private host files or unrestricted guest logs.

#### Scenario: Output limit reached

- **WHEN** a command produces more output than a tool's declared capture limit
- **THEN** the result identifies truncation or the bounded failure and the server remains responsive to other clients

### Requirement: Protocol and backend acceptance

MCP acceptance SHALL exercise the dependency's applicable conformance fixtures plus Macus tool schemas, scope checks, explicit confirmations and truthful operation results. Mock protocol success SHALL remain distinct from actual runtime and guest workload acceptance.

#### Scenario: Conformance without guest

- **WHEN** MCP fixture tests pass against fake runtime and Incus endpoints
- **THEN** protocol evidence is recorded and hardware-backed mutation acceptance remains incomplete

### Requirement: Shared and host catalogue composition

Macus SHALL register shared tool modules and its runtime extensions in one catalogue. Duplicate tool names SHALL fail construction. No other MCP endpoint or catalogue SHALL be required.

#### Scenario: Combined discovery

- **WHEN** an authorized caller discovers tools at the Macus endpoint
- **THEN** allowed shared Incus and Macus runtime tools appear together behind one authentication boundary

### Requirement: Trusted host and owner binding

Macus SHALL supply the shared tools, through their host binding, with the verified principal, scopes and its configured local Incus connection and context. Caller-selected URLs, forged owner fields and unregistered host providers MUST NOT override trusted configuration.

#### Scenario: Forged backend selection

- **WHEN** a tool request supplies another owner or unregistered backend address
- **THEN** no shared or host operation is dispatched using that forged binding

### Requirement: Host-specific runtime capabilities

Macus SHALL supply its runtime capability and path-prerequisite provider without transferring VM ownership to shared code. Capability inspection SHALL be passive; share changes requiring a stopped VM MUST NOT trigger an implicit restart or claim readiness.

#### Scenario: Unavailable workspace share

- **WHEN** host path inspection discovers a new share would require stopped-runtime configuration
- **THEN** it reports that prerequisite without changing sharing or restarting the VM
