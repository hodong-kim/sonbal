# Architecture-Critical Review Map

This document identifies the starting points for changes that can alter Sonbal's
security or reliability boundary. It is a routing aid, not a second product
specification; stable observable behavior remains authoritative in `design.md`.

## MCP interface and tool contracts

Review transport/protocol handling, tool discovery and schemas, request
validation, response serialization, error mapping, exact bounds, abandonment,
and client compatibility evidence.

## Connector and network boundary

Review connector ABI and lifecycle, local bind/listener exposure, provider
protocol state, authentication/credential handling, reconnect behavior, timeout,
shutdown, and any boundary between generic Sonbal core and connector-specific
networking.

## Execution request lifecycle

Review request-owned synchronous work, bounded server-owned jobs, explicit
workspace-token freshness fencing, shared admission, cancellation, settlement,
and the rule that transport or conversation lifetime does not create implicit
workspace authority.

## Process control and platform backends

Review noninteractive process creation, executable/argument representation,
standard streams, bounded output, timeout, process-tree ownership, descendant
cleanup, platform-neutral observable behavior, backend-specific ownership
mechanisms, and explicit failure where required semantics are unsupported.

## File inspection

Review workspace-root identity capture, descriptor-relative no-follow traversal,
regular-file requirements, positional reads, revision checks, helper-process
ownership, shared admission, fixed bounds, and failure mapping.

## Authorization and authority claims

Review what authorizes execution or file inspection and what Sonbal explicitly
does **not** restrict. Never turn a deployment or contributor policy into an
undocumented product sandbox claim.

## Concurrency and scheduling

Review bounded parallelism, request isolation, admission, queue absence or
presence, cancellation races, fairness, starvation/deadlock risks, slow
consumers, backpressure, and resource-exhaustion behavior.

## Configuration, credentials, and diagnostics

Review configuration precedence/validation, root-only credential state,
descriptor passing, environment minimization, secret redaction, diagnostic
bounds, process/request identifiers, and recovery behavior.

## Review rule

When a task changes one of these areas, inspect its implementation, the directly
applicable architecture document, relevant failure paths, configuration, and
tests before accepting the change. A file, module, backend, or documented idea
does not establish production support without implementation and validation
 evidence.

## Bug-review focus

Unless the user asks for a broader audit, inspect first-party paths and avoid
`third-party/`. Prioritize concrete correctness and security defects such as
execution-authorization bypass, unsafe executable/argument construction, secret
exposure, invalid state transitions, lifetime/ownership errors, missing failure
handling, partial-I/O loss, process/resource leaks, ineffective backpressure,
cancellation/timeout races, unbounded resource growth, unsafe retry behavior,
backend semantic mismatch, and misleading support or isolation claims.
