# Proposal

## Why

A standalone Macus is the first milestone (see `add-elixir-server`). Later, an owner should be able to register a Mac's Incus with central Opsmaru so central `/mcp` can operate its instances alongside other registered targets, while the Mac keeps working standalone. This change preserves that planned work, split out of `add-elixir-server` on 2026-10-13 so it no longer gates the standalone milestone.

## What Changes

- Add `macus connect [url]`, `macus connection status` and `macus disconnect` for explicit registration with central Opsmaru.
- Let central operate this Mac's Incus through the shared `:opsmaru_incus` operations, under central identity and Macus-approved projects and operations, without central identity becoming local owner authority.
- Choose the transport: register a reachable Mac as a direct HTTPS Incus target through its existing gateway, and use an outbound connector only for Macs behind NAT (see design).
- Keep local startup, the gateway and local `/mcp` independent of central availability and registration.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `client-cli`: connect, status and disconnect commands.
- `server-gateway`: optional outbound connector and constrained delegated execution.
- `mcp-service`: delegated target identity and receipt recovery for central dispatch.
- `incus-transport`: reuse of the existing bridges for delegated operations.
- `startup-bootstrap`: local startup independent of central.
- `service-delivery`: registration support inside the existing package.

`server-gateway` and `mcp-service` are introduced by `add-elixir-server`; apply this change after it.

## Impact

- Depends on `add-elixir-server` and on central Opsmaru's registry, enrollment and (for NAT) connector work in `upmaru/opsmaru` (`add-compute-substrate`, `add-remote-api-and-oauth`). Not scheduled for the first milestone.
- Durable delegated execution and receipts assume a durable task layer, which is also deferred; revisit when central planning resumes.
- Planning only; no implementation, enrollment or service activation.
