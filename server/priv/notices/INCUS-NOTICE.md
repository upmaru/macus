# Incus reference attribution

Macus's Incus verification fixtures derive from the official
[lxc/incus](https://github.com/lxc/incus) source at commit
`13f3992766142d5087fff2e362cd2e1a75294fe8` (v7.0.1): the native wire cases in
`test/fixtures/incus/wire.json` and the reference driver in `test/reference`,
which builds against that module. Incus is licensed under Apache-2.0; its
unmodified `COPYING` is included here as `incus-APACHE-2.0.txt`. Upstream has no
separate NOTICE file at this revision. The original source and contributor
history remain available at that commit.

The reference pin, declaration inventory and inventory generator that Macus
first produced moved to the shared `:opsmaru_incus` package with these notices
(its `priv/incus/transfer.json` records the hashes); Macus reads them from the
locked dependency. No upstream implementation is installed as a runtime
sidecar, and no inventory establishes parity.
