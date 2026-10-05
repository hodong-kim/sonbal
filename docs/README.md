# Documentation Index

This file is the authoritative router for Sonbal documentation. Read the root
`AGENTS.md` and `README.md` first, identify the current task, then read only the
specialist documents that own that task. Read multiple specialist documents
only when their subjects actually intersect.

## Architecture and stable contracts

### Current product architecture and MCP/runtime behavior

[`architecture/design.md`](architecture/design.md)

Owns the stable Sonbal product contract: trust and authority boundaries,
connector architecture, workspace-token semantics, MCP tool contracts, process
and file-read behavior, capacity, result/wire shapes, timeout/cancellation,
resource diagnostics, failure policy, and security/reliability invariants.

### Engineering and minimum sufficient design

[`architecture/engineering-principles.md`](architecture/engineering-principles.md)

Read for design, implementation, or review work that changes architecture,
ownership, lifecycle, failure handling, security boundaries, or resource use.

### Dependency builds and cross-compilation

[`architecture/dependency-builds.md`](architecture/dependency-builds.md)

Owns consumer-controlled `build/deps/`, host/target separation, dependency
artifact reuse, source-authority boundaries, and build-versus-runtime evidence.

### Implementation language and library boundary

[`architecture/implementation-boundary.md`](architecture/implementation-boundary.md)

Owns Ada-first product implementation, forbidden `GNAT.*` application
dependencies, Clair/system-library preference, project-local binding criteria,
and repository temporary-file placement.

### Deployment security

[`architecture/deployment-security.md`](architecture/deployment-security.md)

Owns credential, service identity, environment, process ownership, logging, and
native deployment-security requirements.

### Architecture-critical review map

[`architecture/review-map.md`](architecture/review-map.md)

Read when reviewing or changing an MCP, connector, execution, scheduling,
configuration, authorization, recovery, or observability boundary.

### ChatGPT/OpenAI client support claims

[`architecture/client-support.md`](architecture/client-support.md)

Owns the evidence required before Sonbal documents or implements a
ChatGPT-facing capability or makes claims about current OpenAI product behavior.

### Coding style

[`architecture/style-guide.md`](architecture/style-guide.md)

Owns the repository's local Ada/C/Ruby/source-formatting conventions. It is a
local authoritative copy of the shared style baseline plus Sonbal-specific
requirements.

## Workflows

### Working-tree changes and commits

[`workflows/development-cycle.md`](workflows/development-cycle.md)

Owns local-state authority, unrelated-change preservation, Git restrictions,
root/operator boundaries, the implementation-to-commit sequence, roadmap
continuity, and result reporting.

### Build, test, package, and acceptance validation

[`workflows/build-and-validation.md`](workflows/build-and-validation.md)

Read when building, testing, running focused integration checks, packaging,
performing platform acceptance, or validating release evidence.

### Installation and activation

[`workflows/installation.md`](workflows/installation.md)

Owns native installation/configuration and explicit service activation
procedures.

### Clair co-development

[`workflows/clair-co-development.md`](workflows/clair-co-development.md)

Read when a Sonbal task exposes a reusable missing Clair capability or changes
the exact Clair dependency revision.

## Roadmaps and current state

[`roadmaps/README.md`](roadmaps/README.md)

The roadmap index records whether unfinished work currently needs persistent
state. Stable behavior belongs in architecture documents and repeatable
procedures belong in workflows. Completed work belongs in Git history rather
than retained specialist roadmaps.

## Selection rule

Do not read every document by default. Start from the smallest authoritative set
for the current task. If two documents appear to define the same rule, identify
the intended owner and remove or narrow the duplicate instead of preserving two
sources of truth.
