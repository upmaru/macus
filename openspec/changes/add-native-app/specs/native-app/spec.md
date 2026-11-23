# Spec Delta

## ADDED Requirements

### Requirement: Optional client application

Macus SHALL provide an optional native macOS application for macOS 15 and later on Apple Silicon. The application SHALL be a client only: it MUST NOT use Virtualization.framework, own or supervise the VM, register or control launchd jobs, or be required to install, start or operate the runtime. Launching, quitting or removing the application MUST NOT change runtime, service, credential or workload state.

#### Scenario: Quit while running

- **WHEN** the application is quit while the runtime is ready and instances are running
- **THEN** the runtime, the server and the instances continue unchanged

#### Scenario: Headless use

- **WHEN** the application has never been built or installed
- **THEN** every `macus` command and standard Incus client works as before

### Requirement: Gateway-only connection

The application SHALL reach the runtime and Incus only through the selected state's published HTTPS gateway, with the published certificate pinned and the same state ownership checks as the CLI. It MUST NOT open the private runtime or Incus Unix sockets, run the `macus` or `incus` executables or any host VM command, or create or repair state. It SHALL serve only state directories of the current user on the local Mac.

#### Scenario: Server not set up

- **WHEN** the selected state directory has no published endpoint
- **THEN** the application reports that Macus is not set up there and names `macus start`, without creating state or starting a service

#### Scenario: Certificate mismatch

- **WHEN** the server presents a certificate other than the published one
- **THEN** the connection is refused and no credential is sent

### Requirement: Application gateway identity

The application SHALL use its own client certificate and owner-private key for native Incus requests, distinct from any other client's. It SHALL enroll that certificate in gateway trust only after an explicit owner action in the application, using a single-use enrollment token bound to its certificate, and SHALL revoke a token it could not redeem. Before enrollment, and after its certificate is removed from trust, it SHALL make no native Incus request other than the enrollment itself and MUST NOT re-enroll without a new owner action.

#### Scenario: First connection

- **WHEN** the owner chooses to connect the application to workloads
- **THEN** its certificate is added to gateway trust exactly once and instance data becomes available

#### Scenario: Not yet connected

- **WHEN** the application is opened and the owner has not connected it
- **THEN** runtime state and the access log are shown and gateway trust is unchanged

#### Scenario: Revoked

- **WHEN** the owner removes the application's certificate from gateway trust while it is open
- **THEN** instance views stop, the application reports that it is no longer trusted and it does not enroll again by itself

### Requirement: Runtime overview

The application SHALL show the runtime's state, uptime, Incus version, resources, public endpoint and failure reason as reported by the gateway's runtime status. It SHALL distinguish an unreachable server from a reachable server whose runtime is absent, stopped, booting or failed.

#### Scenario: Runtime failed

- **WHEN** the server is reachable and the runtime reports a failure
- **THEN** the overview shows the failed state and its reason

#### Scenario: Server stopped

- **WHEN** the server cannot be reached
- **THEN** the overview says the server is not running and does not present stale runtime state as current

### Requirement: Instance list

When connected, the application SHALL list containers and virtual machines across projects with their name, project, type, status, image, addresses and resource use, read from native Incus routes. It SHALL keep the list current from the native events stream and SHALL fall back to bounded polling when the stream is unavailable.

#### Scenario: Instance started elsewhere

- **WHEN** an instance is started with a standard Incus client while the list is visible
- **THEN** the list shows it as running without a manual refresh

#### Scenario: Events stream lost

- **WHEN** the events stream ends
- **THEN** the list continues to update by polling and the stream is retried with bounded backoff

### Requirement: Instance process and agent inspection

For a running instance the application SHALL show its processes, read with a fixed non-interactive native exec whose output and duration are bounded. Processes matching the owner's list of agent programs SHALL be shown as agents with their command, working directory, age and resource use. Inspection SHALL run only while its view is visible, MUST NOT pass owner-entered text to the instance, and MUST NOT signal or modify a process. When processes cannot be read, the application SHALL say why.

#### Scenario: Agent running

- **WHEN** the owner opens the processes of an instance in which a listed agent program is running
- **THEN** that process is shown as an agent with its working directory and age, and its child processes are shown under it

#### Scenario: Virtual machine without agent

- **WHEN** the instance is a virtual machine whose Incus agent is not running
- **THEN** the view reports that processes are unavailable and why

#### Scenario: View closed

- **WHEN** the owner leaves the processes view
- **THEN** no further exec is started for that instance

### Requirement: Instance terminal

The application SHALL let the owner open an interactive shell in a running instance over the native exec streams, with terminal resizing. A session SHALL start only on an explicit owner action, end when its view closes, and the number of concurrent sessions SHALL be bounded.

#### Scenario: Open shell

- **WHEN** the owner opens a shell in a running container
- **THEN** an interactive terminal is attached and resizing the view resizes the remote terminal

#### Scenario: Session limit

- **WHEN** the owner requests a shell beyond the session limit
- **THEN** the request is refused with an explanation and existing sessions continue

### Requirement: Access log view

The application SHALL show the selected state's gateway access records, newest last, and follow new records across rotation. It SHALL read the owner-private log files directly after the same ownership validation as the CLI, without contacting the server, and SHALL offer filtering by path, caller, outcome and protocol. Memory used for records SHALL be bounded. Records of a newer schema version SHALL be shown from the fields the application knows.

#### Scenario: Server stopped

- **WHEN** the access log is opened while the server is not running
- **THEN** the recorded exchanges are shown

#### Scenario: Live record

- **WHEN** a client uses the gateway while the access log is visible
- **THEN** its record appears when the exchange ends

#### Scenario: Unsafe log directory

- **WHEN** the log directory is not owned by the user or is writable by others
- **THEN** the view reports the problem and shows no records

### Requirement: Read-only boundary

Apart from the owner's own input to an instance terminal and the application's own enrollment, the application MUST NOT create, start, stop, delete or configure instances or other Incus resources, transfer files, or start, stop, restart, reset, upgrade or reconfigure the runtime or gateway, and MUST NOT issue or revoke credentials for other clients.

#### Scenario: No workload controls

- **WHEN** the owner views a stopped instance
- **THEN** the application offers no control to start it and names the standard Incus client for workload operations

### Requirement: Application acceptance

Unit tests SHALL cover the application's non-UI logic without a running server or VM. Acceptance of the application on real hardware SHALL be opt-in, SHALL use only isolated state directories, and SHALL be recorded apart from unit test success.

#### Scenario: Unit tests only

- **WHEN** only unit tests have passed
- **THEN** the application's hardware acceptance remains incomplete
