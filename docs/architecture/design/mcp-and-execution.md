# MCP and Execution Contract

## Workspace token freshness architecture

Workspace coordination is a bounded application-level freshness mechanism, not
persistent ownership and not an application session. A caller rotates a
workspace token before starting new process work and carries the opaque
`workspace_token` on `run_process` and `start_process`. The token is explicit
application state; it is not derived from an MCP request, connection, transport,
ChatGPT conversation, or client-liveness signal.

A workspace token key is the normalized absolute root supplied to
`rotate_workspace_token`. Sonbal validates that the root names an existing
directory and uses the normalized root as the cwd containment boundary. A
process cwd must resolve at or below that root before shared process admission.
This is coordination metadata, not a filesystem sandbox: the child still has the
host authority of the Sonbal execution identity.

One Sonbal process owns one bounded `Workspace_Tokens` registry. A successful
rotation allocates from a server-lifetime monotonic 64-bit generation counter
that fails closed before wraparound. Each opaque workspace token contains a
random server-instance prefix, its generation, and random bearer material.
Server restart therefore invalidates all prior workspace tokens even if a
numeric generation would otherwise repeat.

Rotation is replay-safe and has no hidden wait queue. Calling
`rotate_workspace_token(root)` without an operation identifier prepares one
bounded server-minted `operation_id` and does not change the current token.
Committing that operation performs one serialized transition. A successful
commit publishes a fresh workspace token and immediately makes every older token
for the same root stale for **new** work admission. Replaying the same committed
operation while its generation remains retained and current returns the same
token instead of allocating another generation. Unknown, evicted, or superseded
operation identifiers return `stale_operation`.

Each successful rotation starts a fixed 1,000 ms monotonic cooldown for that
workspace root. Another prepared operation may exist during the cooldown, but
its commit returns `cooldown` without allocating a generation, changing the
current token, cancelling a process, or creating a hidden retry. The same
prepared operation may be committed after the cooldown expires. The cooldown is
only an anti-thrash bound; correctness comes from generation freshness.

The token registry is capacity-bounded. When every slot is occupied, a slot may
be reused only after its cooldown has expired and its active-work count is zero;
the oldest generation eligible for reuse is selected. Reuse makes that slot's
former token stale. A slot that still attributes admitted work is never reused
for another root. No explicit token-retirement operation is required.

Workspace freshness gates only **new process creation**. Token validation and
cwd containment occur before shared process admission and before child resources
are created. If G1 work is already admitted and G2 is published, the G1 token
becomes stale for later starts but the already accepted G1 process/job is not
cancelled. It remains governed by its existing timeout, explicit cancellation,
strict descendant process ownership, output retention, and shutdown settlement.
This separates stale-client fencing from process lifetime.

Workspace roots are intentionally not a global lock hierarchy. Tokens may cover
overlapping parent/child roots, and independent external processes may modify the
same filesystem. Sonbal does not provide workspace flock semantics, leases,
heartbeats, TTLs, takeover, forced recovery, conversation-death detection, or
host-wide mutual exclusion. In particular, Sonbal cannot distinguish a
legitimate newer caller from a resumed older execution flow when both request a
fresh rotation; the token mechanism fences stale tokens, not execution-flow
identity.

The connector and stdio transports, MCP dispatcher, and shared process runtime
all project the same workspace-token contract. There is no operator-only
workspace recovery path or transport-derived recovery authority. Connector
request identity is therefore not consulted for workspace-token rotation.

Strict process-tree ownership remains a separate execution safety invariant.
Clair's process execution layer must still own and settle descendants across
normal completion, timeout, cancellation, shutdown, and Sonbal owner death.
That process-level ownership is unrelated to the removed workspace-ownership
architecture.

## MCP contract

The supported protocol version is `2026-07-28`.

The current source `tools/list` surface is exactly, in this order:

1. `ping`
2. `rotate_workspace_token`
3. `run_process`
4. `start_process`
5. `poll_process`
6. `cancel_process`
7. `read_file`

This seven-tool surface is the current product contract on both maintained native
targets. Exact release-candidate package, installation, and live-service
acceptance belongs in the packaging roadmaps rather than this stable design
document. External consumers must bind to the documented contract of the exact
Sonbal release they run. Superseded wire contracts remain available in Git
history rather than the current design document.

The current ordinary tool names are the only workspace/process names
dispatchable by the server. Legacy claim/release/takeover/recovery names are not
compatibility aliases and fail closed as unknown or invalid tool calls. Sonbal
exposes no interactive terminal/PTY tool surface.

Backward compatibility of the Sonbal-owned MCP tool API is not a product
requirement across Sonbal releases. The current contract is authoritative: tool
names, input schemas, result shapes, and other Sonbal-owned wire forms may change
when the product contract changes. First-party consumers migrate directly to the
new contract, and superseded names, schemas, wrappers, or legacy wire forms are
removed rather than retained solely for compatibility. Preserve an older form
only when an explicit product requirement requires it.

`ping` is side-effect-free and reports the tracked Sonbal release version and
revision.

`rotate_workspace_token` is the workspace freshness transition. `root` is
required and `operation_id` is optional. With no operation identifier, the
server prepares one bounded replay-safe rotation operation and returns
`prepared` plus a server-minted opaque `operation_id`. Committing that
operation after the fixed 1,000 ms monotonic cooldown permits it returns
`rotated` plus one opaque `workspace_token`. A successful rotation allocates
exactly one new internal generation and makes every older token for the same
normalized workspace root stale for later process admission. Replaying the
committed operation returns the same current token rather than allocating
another generation. `cooldown`, `capacity_exceeded`, and `stale_operation`
are explicit bounded refusals.

The workspace-token layer is an application-level stale-execution boundary.
It is not MCP transport affinity, a lease, filesystem lock, ownership claim,
takeover protocol, heartbeat, TTL, or conversation-liveness detector.

`run_process` performs one synchronous request-owned execution. `start_process`
starts one server-owned execution and returns an opaque job ID plus initial
cursor. `poll_process` reads one bounded non-destructive output increment at a
caller-supplied cursor. `cancel_process` requests cancellation; a terminal poll,
not the cancellation acknowledgement, proves process-tree settlement.

`read_file` performs one synchronous request-owned, bounded byte-range read of
a regular file below a current workspace root. It is implemented by a
strict-owned same-image helper process so filesystem I/O never blocks the Event
Loop owner thread. The helper follows no symbolic links below the workspace
root, reads by byte offset, and exposes optimistic revision metadata so callers
can reject mixed file generations across multiple chunks.

`read_file` is not a write/edit API, directory traversal API, glob/search API,
filesystem snapshot, lock/lease, persistent file-handle service, bulk transfer,
or background file-job facility. A new file capability requires its own
demonstrated need and contract rather than expanding this bounded read surface.

## Process and control input contracts

`run_process` and `start_process` share these required fields:

```text
workspace_token       exactly `w-` + 64 lowercase hexadecimal digits
argv                  1 .. 65 UTF-8 strings
resolution            "exact_path" | "search_path"
cwd                   nonempty absolute UTF-8 path, at most 4,096 bytes
timeout_ms            integer
```

`run_process.timeout_ms` is `1 .. 110_000`. `start_process.timeout_ms` is
`1 .. 3_600_000`. The synchronous ceiling is deliberately shorter than the
maintained ingress deadlines. The one-hour job ceiling is product-owned and
finite; it does not create an infinite background-process facility.

The executable is `argv[0]` and must be nonempty. Other arguments may be empty.
Each argv element may use up to 32,768 UTF-8 bytes, subject to the same
32,768-byte aggregate argv limit. Embedded U+0000 is rejected.

`exact_path` never invokes PATH search. `search_path` uses the Sonbal-owned child
PATH `/usr/local/bin:/usr/bin:/bin`; it does not consult the parent process PATH.
No shell parsing, quoting language, command interpolation, redirection syntax,
environment expansion, or PTY is implicit.

The control-tool inputs are:

```text
rotate_workspace_token root + optional operation_id
                       operation_id: exactly `o-` + 48 lowercase hex digits
poll_process             job_id + cursor
cancel_process           job_id
```

Legacy workspace recovery is not a current control surface.

`read_file` accepts:

```text
workspace_token    exactly `w-` + 64 lowercase hexadecimal digits
path               relative UTF-8 path, 1 .. 4,096 bytes
offset             optional exact integer, default 0
maximum_bytes      optional integer 1 .. 16,384, default 16,384
expected_revision  optional canonical `r1-` + 96 lowercase hex digits
```

`path` must not be absolute and every component must be nonempty and different
from `.` and `..`. Repeated or trailing separators are rejected. The public
file offset and file-size ceiling is `9_007_199_254_740_991`, preserving exact
integer interchange across ordinary JSON implementations. The JSON ceiling is
Sonbal policy; Clair retains its wider native file-offset contract.

A rotation operation ID is exactly `o-` plus 48 lowercase hexadecimal digits. A
job ID is exactly 82 bytes: `j-`, 32 lowercase hexadecimal server-instance
characters, 16 lowercase hexadecimal sequence characters, and 32 lowercase
hexadecimal per-job secret characters. A poll cursor is a canonical opaque
job-prefixed cursor no longer than 94 bytes; detailed cursor
parsing remains server-owned. Unknown members, noncanonical opaque identifiers,
embedded U+0000, and every one-unit bound overflow fail before process creation or
control side effects.

`run_process` and `start_process` start from an empty environment and add only the
fixed product PATH above. `HOME`, credential variables, SSH-agent sockets,
desktop/session state, and other parent variables are absent by default. Remote
environment mutation and stdin payloads are not part of the contract. Stdin is
routed to null/EOF.

On maintained POSIX targets, ordinary server startup sets the process-global
file-creation mask to `0002` before configuration, connector, Event Loop, or
process work begins. This is the final Sonbal-owned creation policy after any
service-manager or privilege-transition setup, so every Sonbal-created child
inherits the same mask. In a correctly provisioned group-shared setgid
workspace, ordinary `0777` directories therefore retain group write as `0775`
and ordinary `0666` files retain group write as `0664`. The setgid workspace
boundary, not umask, selects the inherited group. Sonbal does not create,
rewrite, or depend on filesystem ACL inheritance to establish this contract.

## Execution, retention, and capacity policy

Sonbal configures each process command with these product-owned limits:

```text
maximum additional argument count  64
maximum argument bytes              32_768
maximum environment operations           1
maximum environment operation bytes     32
maximum effective environment bytes     34
maximum single argument text bytes   32_768
maximum cwd bytes                      4_096
stdout capture bytes                 32_768
stderr capture bytes                 32_768
run_process timeout                  1 .. 110_000 ms
start_process timeout                1 .. 3_600_000 ms
timeout graceful period               1_000 ms
shutdown cancellation grace           1_000 ms
termination scope                    Process_Tree
process-tree ownership                Strict_Ownership
output drain timeout                  1_000 ms
stdin route                           Null_Input
stdout route                          Capture_Output
stderr route                          Capture_Output
environment mode                     Empty_Environment
child PATH                            /usr/local/bin:/usr/bin:/bin
POSIX file creation mask             0002
```

A capture limit bounds retained memory only. Clair continues draining bytes after
retention truncation until EOF or bounded cleanup completes.

The public synchronous `run_process` contract accepts at most 110,000 ms of
child execution time. Transport abandonment, shutdown, process failure, or
another documented cancellation path may end request-owned work earlier. Work
expected to outlive one synchronous request belongs on `start_process` and
replay-safe `poll_process`.

For configured execution capacity `N`, one shared admission counter bounds the
sum of live synchronous operations, request-owned `read_file` helpers, and live
server-owned jobs to `N`. Capacity exhaustion creates no queue. A `read_file`
helper has a fixed 10,000 ms timeout and captures at most 16,384 content bytes;
it cannot enlarge its budget through short reads or retries. The job registry
has at most `2N` records, retains at most `N` terminal jobs, and retains at most
32,768 bytes per stdout/stderr stream.
Terminal retention is count-based, not time-based. Each registry lifetime mints
one random server-instance identifier; each accepted job receives a nonzero
monotonic 64-bit sequence and independent 128-bit random secret. The sequence
supports bounded missing-result classification but never substitutes for the
full opaque bearer job identifier.

A `poll_process` response copies at most 8,192 bytes from each stream. Running
polls read Clair's append-only retained prefix directly; terminal settlement
copies the final retained prefix into Sonbal-owned bounded storage. A cursor
obtained while running therefore continues over the same byte sequence after
terminal publication.

Polling does not advance a hidden server cursor or progress the process backend.
Repeating a cursor has no read-side effect and never skips already-retained bytes;
a later repeat while the process is still running may additionally observe bytes
that were appended after the earlier call.

These limits bound Sonbal-owned command representation, retained I/O, admission,
job metadata, and execution duration. They do not impose a deterministic
per-execution ceiling on live descendant count, memory, or CPU consumption while
an accepted workload is running. `Strict_Ownership` guarantees attribution and
settlement, not a runtime resource quota.

This is an explicit product boundary rather than a missing portable API. Linux
cgroup controllers, FreeBSD process reapers/RCTL subjects, and Windows Job Object
controls do not expose one equivalent per-execution accounting and enforcement
contract. Sonbal therefore does not claim portable live CPU, memory, or
process-count quotas. A deployment that requires resistance to live resource
exhaustion by attacker-controlled native code must place Sonbal execution inside
an operating-system isolation policy that provides the required guarantees. A
future target-native control requires its own concrete product requirement and
native acceptance; it must not silently change `Strict_Ownership` semantics.

The asynchronous implementation uses caller-owned Clair Event Loop bindings and
does not add a worker thread, Ada task, process-polling loop, unbounded queue, or
mutable package-global execution state.

## Result and wire contracts

`run_process` statuses are:

```text
exited
signaled
timed_out
launch_failed
execution_failed
execution_busy
stale_workspace_token
outside_workspace
```

`exited`, `signaled`, `timed_out`, and `launch_failed` are ordinary observed
process results. `execution_failed`, `execution_busy`, `stale_workspace_token`, and
`outside_workspace` set `isError:true`. A nonzero exit code is not converted into
a protocol/tool error.

Every `run_process` result carries independent stdout and stderr stream objects:

```text
encoding   "utf8" | "base64"
bytes      0 .. 32_768
data       lossless retained data, at most 43,692 serialized data bytes
truncated  boolean
```

A retained stream is represented as `utf8` only when the complete byte sequence
is valid UTF-8 and its deterministic JSON-escaped representation is no larger
than canonical RFC 4648 base64. Otherwise it is canonical base64. `exited` may
include `exit_code`; `launch_failed` may include `launch_stage`; and
`execution_failed` may include `infrastructure_stage` and `ownership_stage`.

The stable stage strings remain:

```text
launch_stage
  executable_resolution
  working_directory
  standard_stream
  environment_construction
  program_execution

infrastructure_stage
  execution_preparation
  process_creation
  process_monitoring
  process_termination
  output_drain
  process_wait
  resource_cleanup

ownership_stage
  setup
  launch
  settlement
```

A primary Clair infrastructure failure supplies its stage directly. If execution
has no primary infrastructure failure but its available result reports a non-OK
cleanup status, Sonbal reports `resource_cleanup`; cleanup failure must not lose
its infrastructure-stage diagnostic merely because the primary execution path
completed. `ownership_stage` is an independent optional provenance field emitted
only when Clair reports a strict-ownership failure. `setup` covers ownership-domain
creation/readiness before payload launch, `launch` covers admitting the payload
into that domain before user code runs, and `settlement` covers later ownership
observation, termination, or teardown. Sonbal does not infer this field from
errno, platform, or the mandatory `Strict_Ownership` policy.

`start_process` returns `running` with `job_id` and `cursor`, or
`execution_busy`, `stale_workspace_token`, `outside_workspace`, or
`execution_failed`. Only `running` is non-error.

`poll_process` returns one of:

```text
running
exited
signaled
timed_out
launch_failed
cancelled
execution_failed
expired
stale_instance
not_found
invalid_cursor
```

`running` and terminal process states include stdout/stderr increments and
`next_cursor`. Each stream has at most 8,192 retained bytes in one response and
at most 10,924 bytes in canonical base64. Terminal results may additionally carry
`exit_code`, `launch_stage`, `infrastructure_stage`, or `ownership_stage`.
`expired`, `stale_instance`, `not_found`, `invalid_cursor`, and execution-failure
states are errors; ordinary process terminal states, including `cancelled`, are
not. `expired` means the current registry lifetime issued the sequence but its
bounded retained record has rotated out. `stale_instance` means the identifier
belongs to another server/agent lifetime. `not_found` covers a current-instance
future/zero sequence or a retained sequence whose bearer secret does not match.

`cancel_process` returns `cancelling`, `already_terminal`, `expired`,
`stale_instance`, `not_found`, or `execution_failed`. `cancelling` and
`already_terminal` are non-error acknowledgements; terminal `poll_process`
remains the settlement authority.

`read_file` returns one of:

```text
ok
stale_workspace_token
execution_busy
path_refused
not_found
access_denied
not_regular_file
file_too_large
offset_out_of_range
revision_mismatch
file_changed
timed_out
read_failed
execution_failed
```

Only `ok` is non-error. A successful result returns one opaque 99-byte revision,
exact file size, requested offset, next offset, EOF flag, and one lossless
`utf8` or canonical-base64 content object containing at most 16,384 raw bytes.
The revision is derived from descriptor filesystem/object identity, size, mtime,
and ctime. It is an optimistic change detector, not a content digest, lock,
lease, namespace snapshot, or authorization token. The helper queries metadata
before and after its bounded positional-read loop and publishes bytes only when
both observations match. A supplied `expected_revision` must match the opened
file before any bytes are published.

Workspace-token result mapping is conservative. `rotate_workspace_token`
returns `prepared` or `rotated` as ordinary non-error outcomes; `cooldown`,
`capacity_exceeded`, `stale_operation`, and infrastructure failure are explicit
errors. Process `stale_workspace_token`, outside-workspace, busy, and capacity
outcomes are surfaced rather than silently retried or queued.

All successful tool responses use the compact MCP tool-result envelope with one
TextContent status string and authoritative `structuredContent`. Native errno,
signal numbers, PIDs, process groups, handles, cgroup paths, process descriptors,
and backend-private values never cross the MCP contract.

### Exact response bounds

For `run_process`, field order and stream serialization remain deterministic. At
the 32,768-byte capture limit, canonical base64 is exactly 43,692 bytes. With the
maximum 256-byte preserved request-ID spelling, the maximum serialized
`run_process` response remains exactly **88,129 bytes**, excluding the newline
frame delimiter. One additional serializer byte fails instead of truncating.

The maximum serialized `read_file` response is exactly **22,609 bytes**. The
complete seven-tool `tools/list` response with the maximum preserved request ID
is exactly **9,164 bytes**. The global bounded MCP response storage remains
88,129 bytes because `run_process` is still the largest response shape.

Tool annotations are frozen as follows:

- process start/run: `readOnlyHint:false`, `destructiveHint:true`,
  `idempotentHint:false`, `openWorldHint:true`;
- workspace-token rotation: mutating, non-destructive, non-idempotent, closed-world;
- poll: read-only, non-destructive, idempotent in the no-side-effect sense,
  closed-world; and
- cancel: destructive, idempotent while cancellation is pending/terminal,
  closed-world; and
- file read: read-only, non-destructive, idempotent in the no-side-effect sense,
  closed-world.
