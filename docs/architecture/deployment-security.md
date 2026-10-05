# Sonbal Deployment Security

## Security model

Sonbal intentionally gives AI-triggered process execution the host authority of
the `sonbal` service identity. It is not a sandbox. The deployment contract
therefore focuses on explicit identity, credential, process, descriptor, and
lifecycle boundaries instead of claiming restrictions the product does not
implement.

The current native deployment contains one unprivileged non-login `sonbal`
identity and one in-process connector service. There is no external
nginx/FastCGI/Fasyn/tunnel-client production chain in current source or package
payloads.

## Persistent credential boundary

The OpenAI credential is persistent operator-owned state:

- Linux: `/var/lib/sonbal-openai/credential`, root:root `0600`;
- FreeBSD: `/var/db/sonbal-openai/credential`, root:wheel `0600`.

The containing directory is root-owned mode `0700`. The package does not own
or create the credential file.

The service receives an already-open read-only descriptor 3. Linux uses systemd
`OpenFile=`; FreeBSD opens the file in the root rc.d launcher before
`daemon -u sonbal`. The unprivileged process must not be able to reopen the
persistent credential by pathname.

The connector reads the bounded credential during initialization, rejects empty
or whitespace-bearing values, strips trailing CR/LF, explicitly wipes its
temporary credential buffer before release, and closes the startup descriptor
before provider work is admitted.

Do not pass provider credentials through command-line arguments, Sonbal YAML,
`openai.json`, generic environment variables, logs, or diagnostics.

## Provider configuration

`openai.json` is non-secret. It carries the opaque provider tunnel identifier
and bounded request hints only. The packaged empty tunnel identifier is
intentionally fail-closed.

The production OpenAI connector restricts network requests to the configured
official OpenAI API origin built into the connector. Test builds alone may use
loopback provider endpoints.

## Process identity and terminal policy

The service runs as `sonbal` with no controlling terminal. Interactive
terminal/PTY execution is outside the product contract.

`sonbal --security-check` verifies two local preconditions:

1. known credential-bearing ambient environment variables are absent; and
2. `/dev/tty` is not accessible.

The command never prints secret values and fails closed when terminal state is
indeterminate.

## Child environment

Sonbal process execution uses a product-owned minimal child environment and does
not inherit ambient parent environment state. Executable and arguments remain
separate through the process layer; there is no implicit shell or PTY fallback.

On maintained POSIX targets, the ordinary Sonbal server reasserts file-creation
mask `0002` during single-threaded startup after command-line validation and
before concurrent work begins. Linux systemd `UMask=0002` and the FreeBSD
rc.d launcher's `umask 002` remain defense-in-depth; the runtime setting is the
final product policy after service-manager or privilege-transition behavior.
Children inherit that mask.

The mask preserves group-write bits requested by ordinary build tools but does
not grant filesystem access by itself. A shared work tree must still have the
intended group ownership and setgid directory boundary, or an independently
managed host ACL policy. Sonbal does not install or rewrite workspace ACLs.

This reduces accidental credential propagation but does not make child
execution a sandbox. Filesystem and network authority still follow the OS
identity and surrounding host policy.

## Strict process ownership

Request-owned and server-owned executions must establish strict process-tree
ownership before untrusted payload code runs. Timeout, cancellation, connector
abandonment, EOF, signal-driven shutdown, or service stop must not publish
settlement while owned descendants remain unresolved.

Linux uses the Clair strict-ownership backend and delegated cgroup policy where
required. FreeBSD uses its native strict-ownership backend. Unsupported or
ambiguous ownership transitions fail closed.

## Service lifecycle

The Linux unit and FreeBSD rc.d service use finite startup/shutdown behavior.
The Linux service has an explicit restart bound and finite `TimeoutStopSec`.
The FreeBSD rc.d service keeps verified daemon/child ownership, bounded graceful
settlement, and a final force path for nonresponsive owned children.

Package installation is activation-neutral. It may synchronize service-manager
metadata but does not start, restart, enable, or otherwise activate the OpenAI
service. Service activation remains an explicit operator action.

Package removal must first stop the package-owned OpenAI service and verify
settlement. Persistent operator-owned credential state is not recursively
removed by package lifecycle scripts.

## Logging and diagnostics

Operational diagnostics must remain bounded and non-authoritative. Never log
workspace tokens, job bearer identifiers, provider credentials, command
environment contents, or process output merely for correlation.

Runtime trace behavior and failure semantics are owned by
[`design/runtime-and-failure.md`](design/runtime-and-failure.md); deployment
security adds no second diagnostic lifecycle contract.

## Implementation and review constraints

Treat remote requests, MCP arguments, process input/output, and
configuration-derived process data as untrusted input.

Do not:

- construct executable or shell commands through unsafe string concatenation;
- expose Sonbal directly to the public internet by default;
- silently inject credentials beyond the explicitly selected connector/process
  boundary;
- log API keys, provider credentials, workspace tokens, bearer job identifiers,
  or unredacted sensitive environment values;
- implement cryptography, TLS, X.509 parsing/validation, or equivalent security
  protocol primitives when maintained established implementations exist;
- silently broaden noninteractive process authority or convert a denied
  execution-resource creation into a permissive fallback;
- claim per-command allow-listing, sandboxing, resource isolation, or network
  restriction unless the property is implemented and validated; or
- introduce a hidden interactive shell or PTY fallback.

A Sonbal-created process may execute Git or network operations allowed by its
host identity. Contributor workflow rules do not become runtime enforcement.

## Acceptance requirements

Before claiming a native deployment accepted, verify at minimum:

A read-only running checker may execute outside the service's delegated cgroup
subtree. It therefore verifies systemd delegation metadata, ownership, and
service MainPID membership without attempting to move checker-owned processes
across cgroup delegation boundaries. Linux cgroup v2 containment intentionally
rejects such cross-subtree moves without write access to the nearest common
ancestor's `cgroup.procs`.

Actual strict-ownership cgroup creation, process placement, cancellation, and
kill behavior must be exercised through live MCP process execution inside the
service itself.

On FreeBSD, `daemon(8)` creates the OpenAI supervisor and child PID files as
root:wheel mode `0600`. A checker running as `sonbal` must not weaken or read
that root-only control state. The non-root running checker verifies the PID-file
type/owner/group/mode and confirms that the files remain unreadable, while
independently proving the live root `daemon` -> unprivileged Sonbal topology,
binary identity, singleton service root, absence of independent connector
instances, and short-term process stability. Root-owned rc.d commands retain
responsibility for reading and validating PID-file contents.

- exact package artifact and revision metadata;
- `sonbal` is non-root, non-login, and has the expected primary group;
- persistent credential directory/file ownership and modes;
- the running `sonbal` identity cannot open the credential pathname;
- the service process has no controlling terminal;
- the package-owned process/supervisor identity matches the native service
  manager;
- provider configuration is non-secret and valid;
- live MCP `ping`, workspace-token rotation, and representative process
  execution succeed;
- stop settles the complete owned process domain; and
- the security preflight reports `result=hardened`.

Record only non-secret evidence.
