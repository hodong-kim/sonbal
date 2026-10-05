# Repository Instructions

## Scope and priority

These instructions apply to the entire repository. More specific `AGENTS.md`
files may refine them for their subtree but must not silently contradict them.
Report a real conflict instead of choosing one rule arbitrarily.

Do not inspect, search, format, edit, or otherwise traverse `third-party/`
unless the user explicitly asks for third-party work.

## Project boundary

Sonbal is a security-sensitive local MCP execution substrate for an AI client on
a user-controlled machine. The authoritative current product contract is
[`docs/architecture/design.md`](docs/architecture/design.md). Do not infer
remote-shell, sandbox, privilege-broker, process-supervisor, session, or PTY
semantics that the documented contract does not provide.

Sonbal API backward compatibility is not a project requirement. When the
current contract is corrected, migrate first-party consumers directly unless
the user explicitly requires compatibility.

A Sonbal-created process carries the host authority available to its execution
identity. Do not claim per-command filesystem, network, Git, credential, or
resource restrictions that Sonbal does not implement and validate.

## Repository invariants

- Treat the local working tree, local Git history, and repository documents as
  the current development authority. Remote state is reference material unless
  the user explicitly asks for remote verification.
- Preserve unrelated user changes. Do not clean, reset, reformat, or commit
  files outside the current work unit.
- Do not create branches or pull requests and do not push. Do not rebase,
  amend, reset, or rewrite history unless the user explicitly requests that
  specific operation.
- Direct working-tree edits, builds, tests, and local commits are allowed when
  required by the task and the work unit is stable.
- Root-required actions, system account/group changes, or important host
  configuration changes remain operator-owned. Stop at that boundary and ask
  the user to perform the minimal required operation.
- Consider performance, safety, reliability, and maintainability under
  large-scale, long-running, failure-prone, resource-constrained, and hostile
  conditions. Prefer structural fixes and minimum sufficient design over
  workaround layers or speculative frameworks.
- Do not convert internal contract violations or failed validation into success,
  and never report a build, platform, integration, or acceptance result that was
  not actually verified.
- Keep credentials and sensitive environment data out of source, logs, fixtures,
  diffs, documentation, and commits.

## Documentation routing

Read this file and `README.md`, then use
[`docs/README.md`](docs/README.md) to select only the documents directly
relevant to the current task. Do **not** preload every file under `docs/`.

In particular:

- product architecture and MCP/runtime contracts: `docs/architecture/design.md`
- engineering and minimum-design rules:
  `docs/architecture/engineering-principles.md`
- dependency builds and cross-compilation:
  `docs/architecture/dependency-builds.md`
- implementation-language and library boundaries:
  `docs/architecture/implementation-boundary.md`
- security deployment and trust boundaries:
  `docs/architecture/deployment-security.md`
- architecture-critical review starting points:
  `docs/architecture/review-map.md`
- ChatGPT/OpenAI-facing support claims:
  `docs/architecture/client-support.md`
- coding style: `docs/architecture/style-guide.md`
- working-tree, validation, roadmap, diff, and commit workflow:
  `docs/workflows/development-cycle.md`
- build/test/package validation: `docs/workflows/build-and-validation.md`
- installation and activation: `docs/workflows/installation.md`
- Clair co-development: `docs/workflows/clair-co-development.md`
- current plans, acceptance debt, and resume points: `docs/roadmaps/README.md`

Documentation is authoritative for its declared scope but may contain defects.
If implementation and documentation appear to conflict, determine the owning
contract and correct the inconsistency rather than silently ignoring it.

## Work unit

Use this order for a stable work unit:

`implementation -> tests/validation -> roadmap update -> diff review -> commit`

Update an applicable roadmap before committing whenever implementation status,
acceptance state, remaining work, or the next resume point changed. Do not add a
roadmap edit merely as ceremony when the work has no roadmap impact.

A local commit is appropriate only after relevant validation passes and the full
diff for that work unit has been reviewed. A later conversation must be able to
resume from the repository and its documentation without depending on chat
history.
