# Spec Delta

## MODIFIED Requirements

### Requirement: Future scope

Automatic appliance upgrade, signed/notarized distribution, transparent service exposure, DNS, memory ballooning and sleep migration SHALL remain documented future features. They MUST NOT block the minimal Incus endpoint or introduce workload orchestration. Explicit, user-requested appliance upgrade is provided by the runtime and is not future scope; package installation and upgrade MUST NOT trigger it.

#### Scenario: Scope review

- **WHEN** an agent workload needs orchestration or cloud placement
- **THEN** those operations remain outside this runtime

#### Scenario: Package upgrade

- **WHEN** the package is upgraded and start is run
- **THEN** no appliance upgrade happens unless the user requests it
