# Product Scope and Trust Boundary

## Scope

Sonbal is a local MCP execution substrate for an AI client on a
user-controlled machine. The design prioritizes bounded resource use, explicit
lifecycle ownership, failure isolation, deterministic cleanup, and reviewable
security boundaries.

The implemented surface provides MCP discovery, health/release identity,
workspace freshness, bounded synchronous and server-owned noninteractive
process execution, and bounded read-only workspace file inspection.

Interactive terminal and PTY execution are not part of the product contract.
The former terminal MCP tools and Sonbal-owned terminal lifecycle are removed.
No noninteractive execution API may silently fall back to a shell or PTY.

## Trust and authority boundary

Starting a Sonbal process intentionally grants the AI the host authority
available to that process. Sonbal is not a sandbox and does not claim
per-command filesystem, network, Git, credential, or other restrictions that it
does not implement.

The safe boundary is explicit resource creation plus bounded transport and
lifecycle control, not an invented command allow-list. Public unauthenticated
exposure and multi-user hosting remain out of scope.

### Hardened production topology

The current native AI-facing deployment uses one unprivileged non-login
`sonbal` identity and one in-process connector service. Connector code executes
inside the Sonbal process and reaches the core directly; there is no mandatory
connector-to-core IPC hop.

Persistent provider credentials remain outside the execution identity's pathname
authority and enter the unprivileged service only through an already-open
read-only descriptor. Platform-specific credential ownership, paths, descriptor
creation, and service identity requirements are defined in
[`../deployment-security.md`](../deployment-security.md).

The service runs without a controlling terminal. A container or FreeBSD jail
may add an outer isolation boundary, but it does not replace the explicit
credential/descriptor/process ownership rules.

### Security deployment preflight

`sonbal --security-check` is a non-MCP preflight command. It reports only the
presence of known credential-bearing environment variables and whether
`/dev/tty` is accessible. It never prints environment-variable values. The
command succeeds only when the checked ambient credentials are absent and the
process is proven to have no controlling terminal; an indeterminate terminal
probe fails closed.

The preflight does not prove OS-identity separation or credential-file
permissions. Those properties require external negative tests as described in
`deployment-security.md`.

### Runtime configuration

Normal MCP service startup reads Sonbal configuration from a native target path
selected at build time: `/etc/sonbal/sonbal.yaml` on Linux and
`/usr/local/etc/sonbal/sonbal.yaml` on FreeBSD. The path selection follows the
same `CLAIR_TARGET_OS` build target used by the rest of the native backend; a
Debian packaging convention must not overwrite the FreeBSD runtime contract. A
missing file selects product defaults; an existing unreadable, malformed,
oversized, unknown-key, or out-of-range configuration fails before MCP work is
served. Configuration input is bounded to 16,384 bytes.

The execution-capacity setting is the single YAML scalar
`execution.max_work_slots`. The configured value is the effective maximum
number of concurrently active Sonbal work executions; there is no separate
active/default work-slot setting. If the setting is omitted, the product
fallback ceiling is 16. The configurable range is `1 .. 64`, with 64 retained
as the compiled fail-closed safety ceiling against runaway admission or
misconfiguration. There is no command-line override and no automatic derivation
from logical CPU count. Configuration changes require restart.
