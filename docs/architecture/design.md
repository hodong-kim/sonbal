# Sonbal Design

This file routes the stable Sonbal product contract. Read only the specialist
document that owns the subsystem being changed; read multiple documents when a
change actually crosses those boundaries.

## Product scope and trust boundary

[`design/overview-and-trust.md`](design/overview-and-trust.md)

Owns product scope, host authority, hardened deployment topology, runtime
configuration, and the distinction between Sonbal policy and OS/deployment
authority.

## Connector and transport architecture

[`design/connectors.md`](design/connectors.md)

Owns the in-process connector ABI and lifecycle, connector request transport,
OpenAI connector boundary, event-loop integration, and connector admission.

## MCP and execution contract

[`design/mcp-and-execution.md`](design/mcp-and-execution.md)

Owns workspace-token freshness, the exact ordinary tool surface, process and
`read_file` input/result contracts, shared capacity, bounded retention, exact
response bounds, and tool annotations.

## Runtime lifecycle, diagnostics, and failure

[`design/runtime-and-failure.md`](design/runtime-and-failure.md)

Owns timeout/cancellation/shutdown semantics, resource diagnostics, failure
mapping policy, and security/reliability invariants shared across tools.

## Related contracts

Deployment-specific credential and service hardening belongs in
[`deployment-security.md`](deployment-security.md). Engineering tradeoffs and
minimum sufficient design belong in
[`engineering-principles.md`](engineering-principles.md).

Stable observable behavior belongs in this architecture tree. Current
implementation status, candidate identities, acceptance evidence, and resume
points belong in [`../roadmaps/README.md`](../roadmaps/README.md).
