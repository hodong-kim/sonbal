# Runtime Lifecycle, Diagnostics, and Failure Contract

## Timeout, cancellation, and shutdown

Execution timeout uses Clair's monotonic deadline, `Process_Tree` termination,
and `Strict_Ownership`. Strict ownership is mandatory for every `run_process`
and `start_process`; Sonbal never silently falls back to PID or process-group
cleanup. If the host cannot establish the required kernel ownership domain, the
execution fails before untrusted payload code runs. Sonbal does not publish a
terminal process state until Clair has completed bounded termination, wait,
output drainage, ownership-domain-empty verification, and required cleanup.

`cancel_process` applies only to server-owned jobs and is an asynchronous,
idempotent cancellation request. Its acknowledgement does not prove settlement;
a terminal `poll_process` result does. Local server shutdown and fatal
dispatcher/runtime failure cancel both synchronous executions and server-owned
jobs. Loss of a synchronous `run_process` or `read_file` response path cancels that
request-owned execution, while loss of the request/connection that created a server-owned job
does not cancel the job. Response loss does not prove that a synchronous
operation was never admitted or that its child produced no side effects.
Clients must not automatically replay mutating work solely because the response
was not observed. All cancellation uses the fixed one-second graceful period
and `Process_Tree` scope.

Cancellation completion does not fabricate a normal process outcome for a
response that can no longer be delivered. Sonbal retains ownership until
binding cleanup succeeds and Clair has verified that the strict execution
domain contains no live workload. Retryable Event Loop integration cleanup uses
bounded retry work and must either settle or make shutdown fail explicitly.

`Strict_Ownership` protects the execution boundary against process-topology
escape such as process-group changes, `setsid`, double fork, daemon-style root
exit, and concurrent fork during cleanup. Its native ownership domain must also
self-settle after abrupt owner-process death: once execution has been published,
loss of the Sonbal/Event Loop owner, including SIGKILL, must not leave an owned
payload, descendant, or native ownership domain behind waiting for consumer
cleanup that can no longer run. This is a backend lifetime guarantee, not a
service-manager substitute. It is not a sandbox claim and does not claim
containment against same-identity code that directly attacks Sonbal, Clair, or
the platform ownership mechanism itself.

## Resource diagnostics

`Sonbal.Diagnostics` is a local, read-only observation surface for long-running
resource analysis. It is not an MCP tool, remote metrics service, leak verdict,
or allocator-control interface.

The stable process-memory snapshot reports only an explicit observation state and
current resident/virtual byte counts. Maintained Linux and FreeBSD backends use
bounded native observation; unsupported or failed observation must be represented
explicitly rather than fabricated as zero. Observation performs no child-process
execution, background sampling, allocator trimming, or runtime mutation.

A single RSS/VmSize value never establishes a memory leak. Leak acceptance
requires repeated workload/idle observations together with structural resource
recovery such as descriptors, threads, children, native ownership domains, and
configured admission/registry counts returning to their expected bounded state.
Security diagnostics remain a separate contract.

For bounded operational diagnosis, `SONBAL_DIAGNOSTIC_TRACE=1` enables local
request/transport and process-job traces. This is a diagnostic control, not
runtime policy: it does not change request admission, process/job lifetime,
retention, polling, cancellation, workspace-token freshness, transport
semantics, or the MCP wire. The trace is disabled by default. Failure to
initialize or emit diagnostics disables or drops diagnostic evidence rather
than changing the primary execution result.

The request scope records monotonic ordering for each ordinary seven-tool request:
request admission, synchronous `run_process` or `read_file` helper execution
start/completion where applicable, bounded response serialization completion, and final transport
handoff or abandonment. Its server-local correlation serial identifies one
request only. `response_ready` means bounded MCP serialization completed inside
Sonbal. `transport_response_handoff` also remains a local boundary: stdio
records it after the complete output frame is written, while the connector path
records it only after `Connector_Host.complete_request` accepts the terminal
response into plugin ownership. Neither event proves that the provider, an AI
service, or a UI received the response.

The process-job scope records job start, accepted child launch, poll,
cancellation, terminal observation/publication, retained-terminal eviction, and
response-ready boundaries. Its correlation serial remains stable for the
retained job lifecycle so later poll/cancel requests can be related to the same
server-owned job without logging the bearer job identifier. Request-scope and
job-scope correlations are intentionally scoped identifiers and are not
interchangeable, bearer identifiers, session identities, or authority.

Each scope owns a fixed 256-event overwrite ring, so request volume and repeated
polling cannot create unbounded Sonbal-owned history. When enabled, the same
events are emitted through `Clair.Log.Native_Diagnostic` with the explicit scope,
event kind, bounded outcome or tool kind as applicable, ordinal, correlation,
and elapsed monotonic seconds. Command arguments, workspace tokens, job
identifiers/secrets, cursors, provider credentials, environment contents, and
process output are excluded. This bounded trace is a diagnostic substrate only;
the planned general logging contract may later define additional structured
fields and connector-supplied correlation such as `cmd_request_id`.

## Failure policy

Malformed or unsupported MCP requests are request-local failures and receive
bounded protocol errors when a response ID is available. Notifications do not
receive responses. A complete oversized frame is likewise request-local: Sonbal
boundedly discards it through its newline delimiter, records a diagnostic, resets
the decoder, and continues serving later frames without fabricating a response
for the uncorrelatable oversized request.

Transport loss or corruption that prevents further protocol exchange is
process-fatal. This includes stdin read failure, peer EOF with a truncated frame,
stdout loss, and unrecoverable Event Loop integration failure. These paths stop
new admission and settle owned work before process exit.

Operational failure diagnostics are outside MCP stdio. Sonbal writes them through
`Clair.Log` with `Native_Diagnostic` only: POSIX targets use `syslog()` with the
Clair `LOG_USER` facility and Windows uses `OutputDebugStringW`. Sonbal does not
mirror these diagnostics to standard error. The `--security-check` report remains
functional command output rather than logging. Diagnostic delivery is best-effort
and must not replace or alter the primary failure path.

Internal invariant failure moves the dispatcher to a stopping state. The server
then stops accepting new work, cancels and settles owned process executions,
releases Event Loop resources, settles owned process executions, restores
process-level I/O/signal state, and returns failure.

No retry loop is unbounded. No request may allocate an unbounded response,
process backlog, or queue.

## Security and reliability invariants

The implementation shall preserve these invariants:

1. Every process creation presents a current workspace token before process
   admission or native process-resource creation.
2. A fenced or stale workspace generation cannot create new work.
3. Publishing a replacement workspace token does not cancel already admitted work;
   accepted work remains governed by its existing execution lifecycle.
4. Synchronous process executions, `read_file` helpers, and server-owned jobs
   share one bounded admission ceiling and never create a hidden execution queue.
5. Transport or connector request identity is never treated as an implicit
   application session or workspace owner.
6. Only the documented tool surface is advertised or dispatchable; unknown
   tool names fail closed, and no application-session or terminal/PTY tool
   surface exists.
7. Process execution never uses an implicit shell, PTY, or terminal fallback;
   executable and arguments remain separate through the process layer.
8. Process output is byte-exact within retained limits and explicitly marked
   when truncated.
9. `read_file` opens the workspace root using identity captured at token rotation,
   refuses root replacement or symlink traversal, and uses descriptor-relative
   no-follow traversal below that verified root. Its helper is the same executable
   image captured at server startup rather than a later pathname lookup.
10. Timeout, cancellation, or shutdown does not publish settlement while
   owned descendant cleanup remains unresolved.
11. Input, output, job/workspace registries, queues, retries, callback work, and
    concurrency remain bounded.
12. Shutdown restores modified process state and does not knowingly abandon an
    owned live resource.
13. Process children do not inherit ambient parent environment state; the
    product-owned environment remains fixed and bounded unless a future explicit
    capability changes this contract.
