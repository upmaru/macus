# Spec Delta

## ADDED Requirements

### Requirement: Incus crash evidence

The appliance SHALL keep incusd's log and its stdout/stderr, including Go runtime panics, in persistent guest log files without changing Alpine's `incusd` init script. When incusd is found crashed or stopped during boot, the guest SHALL copy a bounded tail of those files, and the start of the last crash dump, to the serial console, prefixed so that no copied line is parsed as a provisioning observation. A boot that recovers from such a crash SHALL also record that it recovered.

#### Scenario: incusd panics during boot

- **WHEN** incusd exits during boot after writing a panic to stderr
- **THEN** the panic stays in the guest stderr log, and its first lines and a bounded tail appear on the serial console before any restart or failure observation

#### Scenario: Copied log looks like an observation

- **WHEN** a copied incusd log line contains observation text
- **THEN** it is copied with a prefix and the host does not treat it as an observation

### Requirement: Bounded Incus boot recovery

Guest boot SHALL restart a crashed or exited incusd at most a fixed number of times per boot, shared by bootstrap and the bridge start, without adding a supervisor to incusd or changing its stop behaviour. A running but not yet ready incusd MUST NOT be restarted. When restarts are exhausted, the guest SHALL leave the dead daemon marked stopped so shutdown can proceed to storage, and SHALL emit `MACUS_OBSERVATION v1 stage=failed code=incus_crashed` on that boot, whether or not it is a provisioning boot, and withhold bridge readiness. When a running incusd stays unready past the readiness bound, it SHALL emit `stage=failed code=incus_not_ready`. Normal boots SHALL also emit the Incus stage observation.

#### Scenario: Transient crash

- **WHEN** incusd crashes once at boot and starts normally on restart
- **THEN** the guard restarts it once, the bridge starts, and readiness proceeds without host action

#### Scenario: Persistent crash

- **WHEN** incusd crashes on every launch during one boot
- **THEN** the guest stops after the restart limit, emits the `incus_crashed` failure observation once per invoking step, and does not start the bridge

#### Scenario: Clean shutdown

- **WHEN** incusd is stopped through its normal OpenRC stop or system shutdown
- **THEN** nothing restarts it

#### Scenario: Readiness check fails while incusd runs

- **WHEN** incusd is running and ready but the storage readiness check fails
- **THEN** the guard reports that failure without restarting incusd
