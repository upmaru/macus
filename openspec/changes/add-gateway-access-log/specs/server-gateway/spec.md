# Spec Delta

## ADDED Requirements

### Requirement: Native exchange access record

While serving, the Macus server SHALL append one record to an owner-private access log under the selected state directory for every native Incus exchange that reaches its gateway, including relayed HTTP requests, locally served discovery and trust, WebSocket and raw upgrades, and requests it refuses. Each record SHALL be written after the exchange has ended and SHALL state when it ended, the protocol, method, path, native project and target selection, operation, peer address, the fingerprint of any presented client certificate, how the request was admitted, the status sent, the outcome, a reason when it did not complete, its duration and the bytes moved in each direction. Requests to `/runtime` and `/mcp` are not part of this record.

#### Scenario: Relayed request

- **WHEN** a trusted client lists instances through the gateway
- **THEN** one record names the method, path, client certificate fingerprint, status 200, outcome `ok` and the response bytes

#### Scenario: Refused request

- **WHEN** a client whose certificate is not in gateway trust requests a native resource
- **THEN** one record names the presented certificate fingerprint, status 403 and the reason, and states that nothing was sent to the guest

#### Scenario: Raw upgrade

- **WHEN** a client opens an SFTP upgrade and later closes it
- **THEN** one record is written when the tunnel closes, with its duration and the bytes moved

#### Scenario: Revoked stream

- **WHEN** an exec WebSocket is ended because its certificate was removed from gateway trust
- **THEN** one record reports the stream's lifetime and the revocation as its reason

### Requirement: Access record redaction

The access log MUST NOT contain bearer or enrollment tokens, `authorization` values, query strings, operation or image secrets, request or response headers and bodies, WebSocket frames, private keys or certificate bodies. The server SHALL write only the documented fields and SHALL ignore any other value the shared library supplies.

#### Scenario: Migration peer

- **WHEN** an Incus server opens an operation WebSocket with its secret in the query
- **THEN** the record names the operation and that the request was admitted as an operation peer, and contains neither the query nor the secret

#### Scenario: Unknown library field

- **WHEN** a newer shared library adds a metadata value to its exchange event
- **THEN** the value does not appear in the access log

### Requirement: Bounded non-blocking access log

The access log SHALL rotate by size and keep a fixed number of archives, so its total size is bounded. Its files SHALL be readable and writable only by the owner, inside an owner-private directory. Recording MUST NOT delay, fail or change any exchange: under overload or a write failure records SHALL be dropped and the drop counted and marked in the log. A log directory that is unsafe or cannot be written SHALL disable the access log with a reported error and MUST NOT stop the gateway from serving.

#### Scenario: Rotation

- **WHEN** the access log reaches its size limit
- **THEN** it is rotated, the oldest archive beyond the retained count is removed and new records continue in a fresh owner-private file

#### Scenario: Stalled disk

- **WHEN** writes to the access log stall while requests continue
- **THEN** relayed requests complete with unchanged responses and timing bounds, records are dropped, and the next record written states how many were dropped

#### Scenario: Unsafe log directory

- **WHEN** the log directory is writable by another user at startup
- **THEN** the server reports the access log as disabled, writes no record there and serves the gateway as before
