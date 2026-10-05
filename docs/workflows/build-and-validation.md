# Sonbal Build and Validation Workflow

## 1. Repository rules

Repository workflow and Git rules belong to [`development-cycle.md`](development-cycle.md).
Select task-specific documentation through [`../README.md`](../README.md) instead
of reading every document under `docs/`. Implementation-language and library
boundaries belong to
[`../architecture/implementation-boundary.md`](../architecture/implementation-boundary.md).

## 2. Dependency and Clair boundary

Artifact ownership, host/target separation, and cross-compilation are defined in
[`../architecture/dependency-builds.md`](../architecture/dependency-builds.md).
Clair repository coordination is defined in
[`clair-co-development.md`](clair-co-development.md).

Current product, test, and package graphs have no Fasyn dependency. Package
and validation tooling records exact Sonbal/Clair source provenance and re-runs
the applicable Sonbal validation when the dependency revision can affect
behavior, ABI, build metadata, link policy, or runtime semantics. While local
history remains rewriteable before publication, maintained documentation uses
release identities rather than embedding those Git commit identifiers.

## 3. Build

Inspect the resolved build context:

```sh
rake info
```

Build the product and OpenAI connector:

```sh
rake build
```

Build the native test executable without running it:

```sh
rake test-build
```

Product and test outputs are namespaced by target plus the applicable Sonbal and
Clair artifact profiles. Clair artifacts stay under `build/deps/clair`;
Sonbal artifacts stay under Sonbal's `build/obj` and `build/bin`.

Build-only tasks do not execute target programs. Runtime tasks require Clair to
report a native target.

Run the direct stdio service until EOF with:

```sh
rake run
```

## 4. Canonical tests

The canonical native test graph is:

```sh
rake test
```

Because one complete canonical run can exceed an individual remote-tool call
budget, focused tasks may be run separately while preserving the same test
coverage.

### Native and stdio

```sh
rake native-test
rake integration
```

The native suite covers the seven-tool MCP contract, generation-fenced workspace
tokens, bounded jobs, process admission/execution/runtime, `read_file` projection
and response bounds, diagnostics, and security diagnostics.

The stdio integration covers request framing, bounded backpressure, execution
semantics, bounded `read_file` inspection, revision continuity, binary content,
4 GiB+ offsets, workspace-root replacement and symlink refusal, shared capacity,
strict descendant ownership, timeout/cancellation, EOF/broken-output shutdown,
concurrent work, and signal-driven settlement. The signal fixture
includes SIGTERM, SIGINT, SIGKILL owner death, and signal-action restoration.

### Connector host and service

```sh
rake connector-host-integration
rake connector-server-integration
rake connector-service-integration
```

These gates cover ABI validation, dynamic plugin lifecycle, bounded
request/response flow, abandonment, shutdown, and service startup/settlement.

Asynchronous settlement fixtures bound elapsed time with monotonic absolute
deadlines. Do not use a count of `Clair.Event_Loop.iterate` calls as a time
bound: a ready source can make an iteration return immediately. An outer test
harness timeout may guard a wedged fixture, but it must not replace the
fixture-owned phase deadline.

### OpenAI connector

```sh
rake openai-protocol-test
rake openai-connector-integration
rake openai-http-integration
rake openai-transport-integration
rake openai-runtime-integration
```

The production connector uses the fixed OpenAI API origin. Loopback transport
injection is test-only.

### Isolated product-service E2E

Linux provides the isolated PCA acceptance gates:

```sh
rake openai-e2e-integration
rake openai-e2e-failure-integration
rake openai-e2e-stability
```

The E2E fixture exercises `tools/list`, all seven ordinary tools, token/job/cursor
reuse, bounded file inspection, reconnect, replay, cancellation, clean shutdown,
failure handling, and credential redaction. The stability gate repeatedly exercises the real product
service and checks bounded resource recovery.

### Deployment templates

Linux:

```sh
rake linux-deployment-check
```

FreeBSD, on a native FreeBSD host:

```sh
rake freebsd-deployment-check
```

Canonical `rake test` dispatches the native deployment-template checker on
Linux and FreeBSD.

### Review and negative-path coverage

Bug and security review should stay within first-party project paths unless the
user explicitly requests a broader scope; do not traverse `third-party/`.
Prioritize concrete failures in authorization, command/executable/argument
handling, credential redaction, state transitions, ownership/lifetime,
partial I/O, cleanup, cancellation/timeout races, resource bounds,
backpressure, concurrency, retry behavior, backend parity, and preservation of
unrelated working-tree changes.

Risk-relevant changes should exercise both success and applicable failure paths,
including malformed input, denied work, large or binary I/O, slow consumers,
concurrency, resource exhaustion, disconnect/abandonment, restart/shutdown,
and native backend conformance. Do not add test breadth mechanically when a
case cannot affect the changed contract.

## 5. Product contract regression policy

A change to the MCP surface, response bounds, timeout bounds, connector ABI,
package payload, or service lifecycle requires an executable contract check.

`tests/sonbal_source_contract_check.rb` binds the current seven-tool ordering and
major response/timeout limits to source and stable documentation. It also
rejects reintroduction of the retired external ingress source/build/package
paths.

`tests/sonbal_rake_orchestration_check.rb` verifies that product/test/package
builds consume only the supported dependency graph and that connector/deployment
tasks remain part of the canonical orchestration.

## 6. Capacity and long-running work

The public synchronous execution timeout is fixed by the current architecture
contract. Do not enlarge it merely to mask client/UI delivery limits.

Work expected to outlive one synchronous request belongs on:

1. `start_process`;
2. replay-safe `poll_process`; and
3. explicit `cancel_process` when cancellation is required.

Synchronous executions, request-owned `read_file` helpers, and server-owned jobs
share one configured capacity ceiling. Capacity exhaustion creates no hidden
execution queue.


## 7. Security validation

Run:

```sh
sonbal --security-check
```

The security properties validated by this command and the native service
checkers are owned by
[`deployment-security.md`](../architecture/deployment-security.md).

Linux:

```sh
sudo -u sonbal rake linux-openai-service-running-check
sudo -u sonbal rake linux-openai-service-stopped-check
```

FreeBSD:

```sh
sudo -u sonbal rake freebsd-openai-service-running-check
sudo -u sonbal rake freebsd-openai-service-stopped-check
```

These checks are read-only with respect to service state. Start/stop transitions
remain operator-controlled. Strict-ownership behavior that requires service
authority is exercised through live MCP execution as required by the deployment
security contract.

## 8. Native package loop

Package work must converge on the installation users will actually receive.

Common sequence:

```text
implementation
-> focused/canonical source validation
-> roadmap update
-> diff review
-> stable commit
-> exact package build/check
-> reproducibility where required
-> operator-owned installation
-> installed-state check
-> explicit service start
-> live MCP acceptance
-> explicit service stop
-> stopped-state check
```

Debian:

```sh
rake debian-package
rake debian-package-check
rake debian-installed-check
```

FreeBSD:

```sh
rake freebsd-package
rake freebsd-package-check
rake freebsd-package-reproducibility-check
sudo -u sonbal rake freebsd-installed-check
```

Package tasks materialize clean committed Sonbal/Clair snapshots and record exact
revision metadata. Package creation therefore requires a clean committed Sonbal
candidate. Package checks also require the shared install-time disclaimer:
Debian must carry and display the canonical notice without prompting, and the
FreeBSD manifest must expose the same text as its package message.

The repository `build/` and `build/tmp/` package-workspace boundary is
group-writable setgid state. The setgid boundary preserves the shared group;
ordinary Sonbal server execution uses POSIX file-creation mask `0002` so newly
created build directories and files preserve requested group-write bits. These
are complementary responsibilities; Sonbal does not use recursive ACL rewriting
as a substitute for either one. A missing boundary may be bootstrapped; an
invalid existing boundary fails closed. Validate it directly with:

```sh
rake package-workspace-check
```

Release product links suppress automatic GPRbuild RUNPATH and package staging
removes non-runtime path-dependent ELF metadata where required. Artifact checks
reject temporary package snapshot paths and unrecorded dependency provenance.

FreeBSD package payload mtimes are normalized to the exact Sonbal source commit
timestamp and the package records exact installed curl provenance.

FreeBSD service acceptance is intentionally split by authority. Root-owned
rc.d start/stop/status paths may read their root:wheel `0600` PID files. The
external acceptance checker runs as `sonbal`; it must leave those files
root-only, verify their metadata and non-readability, and establish running
service identity from the observed root `daemon` -> Sonbal process topology.
Do not make PID files group-readable merely to make the checker pass.

## 9. Cross-platform acceptance

Before claiming a cross-platform checkpoint, run the applicable current matrix
on both Debian/Linux and native FreeBSD against the exact candidate.

Record at minimum in generated acceptance/provenance output:

- Sonbal source provenance and release identity;
- Clair source provenance and license verification state;
- target, target OS, and build profile;
- policy/build result;
- native suite/case/assertion result;
- stdio and connector integration results;
- native deployment-template result;
- package artifact/reproducibility result;
- installed-package result; and
- live/stopped OpenAI service plus representative MCP result.

Do not claim a result that was not actually run.

## 10. Diagnostics

`SONBAL_DIAGNOSTIC_TRACE=1` enables the bounded diagnostic trace defined in
[`runtime-and-failure.md`](../architecture/design/runtime-and-failure.md).
Use it only for development diagnosis.

## 11. Publication discipline

Stable current behavior belongs in
[`../architecture/design.md`](../architecture/design.md). Reusable procedures
belong in this workflow, [`installation.md`](installation.md), and the
[`deployment-security.md`](../architecture/deployment-security.md) contract.
Chronological debugging,
rejected candidates, and superseded internal deployment layouts belong in Git
history or the relevant roadmap only while they remain active work.

Before external publication, verify all user-facing examples and package paths
against the exact accepted release candidate. Pre-publication source validation
may intentionally retain detailed local history while that history materially
helps failure localization. Such a run is diagnostic evidence, not final package
provenance.

Once the candidate source is green, build final packages only from the clean
committed publication candidate so package provenance records the actual
published commit. If a fix changes the source tree after a release-identity
bump, bump the identity again and repeat the applicable validation before
publication.

Only after the final cross-platform gate passes, update the root README and any
other user-facing pre-publication status text to describe the accepted public
release and its actual `.deb`/`.pkg` installation path. Do not advertise a final
package identity or public-distribution state before that evidence exists.
