# Connector and Transport Architecture

## MCP transport and scheduling

Sonbal retains a bounded stdin/stdout transport for direct integration and
local workflows. Native AI-service operation uses the in-process connector
service: the connector owns provider networking and framing while
`Connector_Server` hands complete bounded MCP JSON requests to the same core
used by stdio. Protocol parsing, request admission, execution, response
serialization, and shutdown remain bounded in both paths.

### Connector plugin ABI v1

The current source defines the native in-process connector ABI v1 in
`Sonbal.Connector_ABI`. This ABI is the implemented native connector module
boundary. The product executable loads the OpenAI connector through the explicit
`--connector openai` selection.

The ABI is deliberately smaller than a provider protocol. A connector owns
provider authentication, networking, framing, reconnect behavior, and bounded
provider-side queues. The Sonbal host owns MCP/tool semantics, workspace and
process state, process admission, execution, cancellation, and cleanup. The ABI
carries only complete MCP JSON requests and responses plus lifecycle signals;
OpenAI tunnel request IDs, shard tokens, HTTP details, or another provider's
protocol state do not become generic Sonbal core state.

ABI v1 uses C-convention fixed-width records and function pointers. The Ada
definition in Sonbal.Connector_ABI is mirrored by the source/development C
header include/sonbal_connector_abi.h; dynamic C fixture loading verifies their
record sizes and calling convention together. A plugin exports the data symbol
sonbal_connector_descriptor_v1. Before initialization,
the host requires the exact ABI magic 0x534f4e42414c4331, ABI version 1,
descriptor size, a known connector kind, and all required entry points. The
initial supported connector identity is OpenAI. A mismatch fails closed before
plugin-owned provider work starts.

Initialization receives only these host-owned bounds and startup inputs:

- the exact ABI version and initialization-record byte size;
- maximum connector request tokens concurrently active across the ABI;
- maximum complete MCP request bytes;
- maximum complete MCP response bytes;
- one optional read-only provider-configuration descriptor; and
- one optional read-only startup credential descriptor.

The configuration and credential descriptors are borrowed only during
connector initialization. An invalid descriptor means that startup input is
absent. Provider-specific configuration syntax is opaque to the core and is
parsed only by the connector. The connector may copy bounded configuration and
credential bytes into connector-owned state but does not retain or close either
descriptor. The host closes both descriptors on every post-initialization path
and does not admit requests before closure. Production startup enables
Clair.Process.disable_current_process_inspection before connector credential
consumption; failure is fatal. Credential bytes never become process arguments,
child environment, generic core state, MCP data, or generic diagnostics.

A successful initialization publishes an opaque connector instance and one
connector-owned nonblocking wakeup descriptor. The host borrows that descriptor
until connector finalization and registers it with the Clair Event Loop before
calling the connector start operation. The connector does not call Sonbal Ada
entry points from provider-owned worker threads. Instead it publishes bounded
work in connector-owned state and signals the wakeup descriptor. This keeps MCP
dispatch and process-runtime state on the Sonbal Event Loop owner thread.

The initialization field `maximum_active_requests` bounds request tokens
concurrently handed from the connector to the host and not yet completed or
abandoned. It does not size provider-side prefetch storage. A connector may own
a separate bounded provider queue when its transport requires one, but that
queue is transport buffering only: it must have its own fixed bound, must not
become host execution admission, and must not allow more than
`maximum_active_requests` live request tokens to cross the ABI at once.

The host drains connector events through caller-owned buffers until
STATUS_WOULD_BLOCK. The connector owns wakeup-readiness draining: before that
WOULD_BLOCK return it clears or consumes readiness for the observed drain, and
a later transition to available work makes the descriptor readable again. This
handshake must be race-safe with provider workers so an event cannot be lost
between the final dequeue and readiness clearing. An EVENT_REQUEST contains one
complete MCP JSON request, a nonzero connector-scoped request token, and at most
256 bytes of optional non-authority diagnostic correlation.
The diagnostic value may be truncated explicitly and must never be used as
session identity, workspace authority, request authorization, or a routing
secret. EVENT_REQUEST_ABANDONED reports that the provider response path for a
live token no longer exists. That event is the connector cancellation boundary:
request-owned synchronous work is cancelled through normal Sonbal ownership
rules, while already accepted server-owned jobs retain their independent
lifetime.

Response bytes remain host-owned. complete_request accepts either one complete
MCP JSON response or zero bytes for an MCP notification. STATUS_WOULD_BLOCK
consumes neither the request token nor the response bytes; the host retains the
identical bounded response and retries only after connector progress is
signalled. STATUS_OK consumes that live request token. No allocator ownership
crosses the plugin boundary.

Shutdown is finite and explicit. begin_shutdown stops new provider ingress and
starts connector settlement without blocking the Event Loop owner. The
connector publishes EVENT_SHUTDOWN_COMPLETE only after every live request token
has been completed or explicitly abandoned. A started connector may be
finalized only after that event; an initialized connector that never started
may be finalized during rollback. Only after connector finalization and Event
Loop source removal may the host close the dynamic-library handle. Hot reload,
in-place ABI replacement, and unloading code with live callbacks or requests are
not v1 capabilities.

Connector status values distinguish success, would-block, caller/state errors,
startup failure, bounded resource exhaustion, and internal failure. Provider-
specific diagnostics remain connector-owned and use the normal secret-redacted
diagnostic boundary rather than extending the ABI with provider-specific error
objects.

### Connector host lifecycle

Sonbal.Connector_Host owns the lifecycle boundary around ABI v1 and is used by
the production connector service. The host accepts exactly one absolute trusted
plugin path from its caller, opens it through
Clair.Dynamic_Library, resolves sonbal_connector_descriptor_v1, and validates
the full recognized descriptor before invoking plugin code.

Only the currently recognized OpenAI connector kind is accepted.
A missing symbol, mismatched ABI, or invalid descriptor is rejected before
current-process inspection policy is changed or connector code is initialized.

After descriptor validation, the host enables
Clair.Process.disable_current_process_inspection before connector startup
configuration or credential input can be consumed. Startup descriptors are
host-owned cleanup obligations for the duration of initialize: both success and
rollback paths close them, while the plugin only borrows them synchronously.
Two valid startup roles must not alias the same descriptor.

A successful plugin initialize publishes one connector instance and nonblocking
wakeup descriptor. The host registers that descriptor with the Clair Event Loop
before start. A start failure leaves the ABI-defined initialized-not-started
state and can therefore finalize directly. Event Loop watch-registration
failure removes any partial watch, finalizes plugin state, and closes the
library in that order.

Final shutdown ordering is similarly strict: the started connector first
publishes shutdown completion through its wakeup path, the host removes the
Event Loop watch, plugin finalization consumes the instance and wakeup
descriptor, and only then may the dynamic-library handle close. If plugin
an ABI violation leaves cleanup ownership ambiguous, the host enters a failed
quarantine and retains the library rather than unloading live code. An ordinary
plugin-finalize failure keeps instance/library ownership and remains retryable as
required by ABI v1. A native library-close failure likewise retains the handle
for process-level settlement; Clair does not promise that immediate close retry
is safe.

The lifecycle integration uses real C shared libraries rather than only mocked
Ada calls. Cross-platform coverage exercises matching Ada/C ABI sizes,
missing-symbol and bad-ABI rejection, plugin initialization failure, invalid
wakeup-descriptor rollback, Event Loop watch-registration failure, start
rollback, fail-closed finalization failure, clean shutdown, and repeated
load/start/shutdown/unload cycles. The registration-failure case reserves a
valid nonblocking descriptor in the same Event Loop before connector
initialization, so the connector's duplicate wakeup registration fails through
the portable public EEXIST contract. Backend-native partial-registration and
rollback fault semantics remain owned and native-tested by Clair rather than
being recreated with a Sonbal-private backend seam.

### Connector request transport

Sonbal.Connector_Server is the transport adapter around the lifecycle host and
the existing Sonbal.MCP.Request_Core. It does not duplicate MCP
dispatch, workspace-token, process-admission, or process-ownership semantics.

The server allocates exactly execution.max_work_slots + 1 request slots at
initialization. Each non-free slot owns one connector request token, one
bounded dispatcher result, and one request-owned Process_Execution operation.
The extra slot matches the common stdio/connector control-capacity rule and
does not create a second execution-admission queue.

Connector wakeups are handled only on the Clair Event Loop owner thread.
Sonbal first drains connector events to STATUS_WOULD_BLOCK and only then retries
responses retained by connector backpressure. This ordering is required because
the same wakeup may announce EVENT_REQUEST_ABANDONED rather than response
capacity; retrying a retained response before consuming abandonment could offer
bytes for a token whose provider path has already disappeared.

EVENT_REQUEST bytes are passed unchanged to the existing Request_Core. Immediate
responses and notifications are offered back through complete_request.
STATUS_WOULD_BLOCK retains the identical bounded result and token for a later
progress wakeup. A successful completion records the ordinary Request_Core
transport-handoff boundary and frees the slot.

EVENT_REQUEST_ABANDONED retires provider response ownership before any response
retry. A ready response is marked transport-abandoned and discarded. An active
request-owned synchronous run_process is cancelled through the existing strict
Process_Execution ownership path; its eventual completion is consumed locally
and marked transport-abandoned. Server-owned jobs created by start_process are
not attached to the connector request slot and therefore preserve their
independent lifetime contract.

Shutdown is deliberately staged. Connector ingress is stopped first while the
Request_Core dispatcher remains Running. Existing request-owned work is then
cancelled or completed and all connector request tokens are settled. Only after
all connector request slots are free does Connector_Server call
Request_Core.stop, because switching the dispatcher to Stopping before a
cancelled run_process completion would make that completion invalid. The
connector may publish EVENT_SHUTDOWN_COMPLETE only after its own live token set
is empty. Server settlement requires both connector shutdown completion and an
idle Request_Core, including independently owned jobs.

Finalization is retryable by stage. Connector_Host finalization happens before
local request-operation and Request_Core finalization, and Connector_Server
records successful host finalization so a later local cleanup failure does not
reload or refinalize the plugin. Conversely, a retryable plugin-finalize failure
leaves host/plugin ownership intact and a later Connector_Server.finalize call
retries that same cleanup before touching local core storage.

The Linux dynamic fake-plugin acceptance covers ordinary request/response,
zero-byte notification completion, response WOULD_BLOCK retry, provider
abandonment racing a retained response, abandonment of an active run_process,
preservation of a server-owned start_process job after its connector request
finishes, server shutdown while request-owned work is active, and retry after
an initial plugin-finalize failure. Provider networking and OpenAI protocol
behavior remain outside this connector-server layer.

### OpenAI connector foundation

The OpenAI implementation is a provider-owned C shared library in
`connectors/openai`. It exports the frozen `CONNECTOR_OPENAI` ABI descriptor. The
ordinary product build produces this shared library together with `sonbal`, and
the main executable recognizes the explicit product selection
`--connector openai`.

Connector initialization consumes only the ABI startup inputs. A bounded local
JSON configuration currently supplies the opaque tunnel id plus poll limit and
poll timeout request hints. The dedicated credential descriptor is read into a
fixed connector-owned buffer, trailing CR/LF is removed, whitespace-bearing or
empty credentials are rejected, and the buffer is explicitly zeroed before the
connector instance is released. The connector creates and owns its nonblocking
wakeup pipe only after both startup inputs validate.

The OpenAI wire decoder is allocation-free with caller-bounded input and command
storage. It follows the current official OpenAI tunnel protocol and OpenAPI
contract verified on September 30, 2026:

- request ids, shard tokens, and tunnel ids remain opaque;
- `created_at` is required metadata but is never used to derive a local
  response deadline;
- a missing channel defaults to `main`;
- an omitted `command_type` may use the OpenAPI JSON-RPC default only when a
  top-level JSON-RPC object is present;
- explicit `session_termination` and unknown future command types are kept
  distinct from JSON-RPC dispatch;
- raw JSON-RPC objects and raw multi-valued header objects are preserved without
  provider-to-core reinterpretation;
- `response_timeout` accepts only one non-negative integer plus `ns`, `us`,
  `ms`, `s`, `m`, or `h`; absent/null values have no deadline, malformed or
  wrong-type values fail open to legacy no-deadline behavior, and valid `0s`
  preserves immediate-expiry semantics; and
- poll limit remains only a provider request hint. It never becomes a Sonbal
  execution-capacity authority.

The connector now also contains a bounded synchronous HTTPS primitive backed by
libcurl. Production requests are restricted to `https://api.openai.com` and
canonical plural `/v1/tunnels/{tunnel_id}/poll` and `/response` paths. Tunnel
ids are percent-encoded as opaque path segments. Poll and response requests send
bearer authentication, stable client name/version metadata, `Accept:
application/json`, and the currently implemented tunnel wire protocol version.
The connector does not advertise optional client capabilities it has not
implemented.

The HTTP primitive accepts `200` and `204` without assigning provider
semantics to other status codes, bounds response bodies in caller-owned storage,
records a monotonic receipt timestamp when response headers complete, supports
cross-thread cancellation through libcurl's progress callback, and validates
the original command shard token before placing it only in
`X-Tunnel-Shard-Token` on response delivery. Hidden proxy environment
variables are deliberately disabled until proxy support has an explicit bounded
configuration contract. Test builds alone admit loopback HTTP so the complete
wire shape can be exercised without production network access.

The OpenAI connector has a bounded transport lifecycle in both the ordinary
product library and the dedicated loopback test build. The product library uses
only `https://api.openai.com`; test builds alone may replace the base URL with a
loopback endpoint. The diagnostic tunnel client-name header is `sonbal` rather than the former
test-only `sonbal-test` value. Product activation no
longer has a compile-time `start` failure gate.

The transport owns one finite HTTP worker and one finite deadline monitor, a
fixed provider-command buffer, the libcurl client, wakeup signalling, retries,
response deadlines, and shutdown.
Provider buffering and Sonbal execution admission are separate capacities. The
transport keeps a twenty-command provider queue plus resident overflow
headroom equal to the ABI active-request envelope. `next_event` publishes a
queued JSON-RPC command only while that active envelope has capacity. The
configured poll hint remains valid through 25, but each actual poll requests at
most the twenty free provider-queue positions. If a successful response still
contains more commands than requested, bounded excess commands are retained in
the overflow headroom and promoted as queue positions open rather than being
dropped. Poll response storage is sized from the complete resident envelope
(active-request headroom plus provider queue), not from the requested poll
hint. A batch larger than that hard resident bound fails closed as a whole
instead of being partially accepted. The poll hint never becomes a second
Sonbal execution-admission authority.

One HTTP worker serializes poll and response delivery. It starts the next long
poll only after every resident command from the current batch has reached
terminal settlement. This is intentionally conservative: starting another long
poll on the same worker while an MCP request is active could delay that
request's response POST behind the poll wait. Future throughput work may split
poll and response-delivery execution or use a multiplexed HTTP engine, but that
is not required for the current protocol-correct bounded lifecycle.

Deadline progress is independent of that HTTP worker. One transport-owned
monitor waits on the nearest monotonic deadline under the transport mutex and a
dedicated monotonic condition variable that is not shared with HTTP-worker or
retry waits; it does not create per-request timers, workers, or queues. Startup
does not launch provider HTTP work until that monitor has acknowledged readiness.
`POSTING` remains HTTP-worker-owned while libcurl uses the slot outside the
lock, and response posting enforces its own remaining deadline. Public
completion and event-publication boundaries also recheck monotonic expiry so
scheduler delay cannot make a post-deadline completion valid or publish stale
queued work.

Valid `response_timeout` values become monotonic deadlines relative to the
successful poll response's header-receipt timestamp. Immediate expiry is
preserved, queued expiry is discarded locally, active expiry emits
`REQUEST_ABANDONED` exactly once, and a late completion cannot consume a pending
abandonment. Terminal response posting never retries past the remaining
deadline. Malformed or absent timeouts retain the documented legacy no-deadline
behavior.

The worker treats transient poll failures, HTTP 429, and server 5xx responses as
retryable. Terminal response delivery retries transport failure and HTTP
408/429/502/503/504 with bounded exponential backoff plus jitter; valid
`Retry-After` hints for 429/503 become a bounded minimum delay. HTTP 404 on a
response POST is terminal rather than retryable. Retry waits are interruptible
by shutdown and, for command responses, by response deadline.

JSON-RPC terminal responses preserve opaque request/shard correlation and are
posted as `jsonrpc_response`. JSON-RPC notifications that produce no terminal
MCP response are acknowledged as `notify_ack`. `session_termination` remains a
provider-local control command and is acknowledged as
`session_termination_response` with HTTP-semantic response code 204, without
entering Sonbal MCP dispatch. Unknown provider commands remain provider-local.

Shutdown atomically marks the transport stopping, cancels an active libcurl
operation, wakes retry/HTTP/deadline waits, converts live MCP tokens to bounded
abandonment events, and emits `SHUTDOWN_COMPLETE` only after both transport
threads exit and token settlement completes. The connector wakeup bridge
re-signals when additional events remain ready so draining the nonblocking pipe
cannot lose progress.

OpenAI connector validation uses several layers. The production shared library
proves bounded startup descriptor consumption and configuration/credential
rejection.
Separate C fixtures cover bounded protocol decoding, HTTP wire behavior,
Retry-After parsing, provider-queue versus active-request admission, excess
commands beyond the poll hint, inflight deadline abandonment while unrelated
response delivery is blocked, late-completion rejection, and held-poll
cancellation. A loopback-enabled dynamic OpenAI test build is loaded through the
real `Connector_Server` and Clair Event Loop to prove poll -> MCP dispatch ->
response POST, notification acknowledgement, immediate expiry,
session-termination acknowledgement, transient poll/POST retries, wakeup
progress, and finite shutdown.

The product service adapter in `Sonbal.Connector_Service` owns only common
connector lifecycle: it opens the provider configuration read-only, passes the
startup credential as a borrowed descriptor, initializes the shared Event Loop
and `Connector_Server`, installs SIGTERM/SIGINT shutdown handling, drives bounded
connector progress, and requires shutdown settlement within ten seconds.
`sonbal --connector openai` selects fixed platform paths for the trusted OpenAI
plugin and its non-secret JSON configuration. The credential is never accepted
as a command-line value, YAML value, or generic environment variable; the
startup contract consumes inherited descriptor 3 and closes it during connector
initialization before provider work is admitted.

Platform-specific credential storage, descriptor creation, service identity,
and activation requirements are owned by
[`../deployment-security.md`](../deployment-security.md) and
[`../../workflows/installation.md`](../../workflows/installation.md). The
connector contract begins with the inherited startup descriptor.

The stdio server uses the shared Clair Event Loop with reversible nonblocking
stdin/stdout handling. Request-slot backing storage is allocated once at startup
to `execution.max_work_slots + 1`, so a configured execution ceiling in
`1 .. 64` uses exactly `2 .. 65` request slots. The extra request slot lets a
saturated execution window still produce one bounded overload, lifecycle, or
ordinary response without creating an execution queue. Allocation failure fails
startup rather than reducing the configured capacity. Partial stdout writes are
serialized until the current frame is complete. A delimited
oversized frame is discarded with bounded work and the decoder resumes at the
next frame. EOF with a truncated or still-oversized frame, event-loop failure,
and peer closure lead to deterministic shutdown rather than unbounded retry.

External SIGTERM and SIGINT follow the same ownership rule in stdio mode. One
process-wide minimal signal handler records only an atomic shutdown flag. Because
an Ada runtime helper thread prevents the Linux signalfd contract from
guaranteeing that either process-directed signal is blocked in every process
thread, the stdio owner loop caps an otherwise idle Event Loop wait at 250
milliseconds solely to observe that flag; this is not a process-progress polling
loop. Once observed, new transport admission stops and the existing absolute
five-second process-settlement path cancels and drains every accepted strict-owned
execution before `run` returns. The previous SIGTERM and SIGINT actions are each
restored on every handled return path.

The stdio and connector transports share the same bounded request core.
Connector response completion is accepted only through the connector-host
completion contract; provider delivery remains outside Sonbal's local proof
boundary. A connector request may be abandoned without turning provider request
identity into workspace, job, or execution authority.
