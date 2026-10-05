# Clair Co-Development Workflow

## Repository roles

Clair is Sonbal's approved shared system-programming foundation for reusable OS,
event, process, signal, time, file-descriptor, file, nonblocking-I/O, logging,
queue, testing, and related primitives.

The public distribution reference is `https://github.com/hodong-kim/clair`.
Dependency artifact ownership, revision provenance, and build-root rules are
owned by
[`../architecture/dependency-builds.md`](../architecture/dependency-builds.md).
Re-verify the consumed license when the recorded Clair revision changes.

## Ownership boundary

Keep reusable system facilities in Clair and Sonbal-specific MCP contracts,
request/process ownership, lifecycle, authorization, audit semantics, and
product orchestration in Sonbal.

Do not create a Sonbal wrapper whose only purpose is to hide Clair. A Sonbal
adapter is justified when it enforces Sonbal-specific policy, ownership,
lifecycle, failure mapping, or another actual product boundary.

If Sonbal exposes a generally reusable missing or insufficient system facility,
identify the required Clair contract and its Sonbal acceptance needs rather than
adding a private duplicate system binding solely to avoid coordinated work.

## Separate work sessions and histories

Clair implementation work occurs in its own repository work session and follows
that repository's `AGENTS.md`. The Sonbal work unit may specify the missing
capability, invariants, failure semantics, and acceptance cases, but it does not
silently modify the Clair repository.

Resume Sonbal integration after the user reports the Clair change committed
locally and the exact Clair commit/diff has been reviewed. Keep the Git histories
and validation records distinct.
