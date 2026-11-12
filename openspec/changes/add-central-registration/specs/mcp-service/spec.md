# Spec Delta

## Purpose

Keeps centrally delegated operations on Macus bound to the registered target and isolated from local callers.

## ADDED Requirements

### Requirement: Local and delegated target identity

Local tools SHALL use only Macus's configured target, permitting omitted target ID locally and rejecting a different target. Central calls SHALL carry the exact enrolled target/generation and a distinct delegated owner binding. Remote execution SHALL retain shared schemas and Macus lifecycle/destructive-input policy.

#### Scenario: Delegated lifecycle safety

- **WHEN** central requests a Macus share configuration change while the VM is running
- **THEN** the same stopped-runtime prerequisite applies and the connector does not restart the VM implicitly

### Requirement: Central receipt recovery

Connected dispatch SHALL commit stable dispatch ID/input digest/owner/target binding in the existing shared journal before acknowledgement. Duplicate matching dispatch SHALL return its receipt; conflicting input SHALL fail. Local and delegated tasks SHALL remain isolated, with native uncertainty preserved through reconnect.

#### Scenario: Duplicate central dispatch

- **WHEN** central resends a dispatch whose acknowledgement was lost
- **THEN** Macus returns the recorded receipt/native outcome without starting another mutation or runner
