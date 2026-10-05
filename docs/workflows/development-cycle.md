# Development Work Unit and Repository Workflow

## Current-state authority

Use the local working tree, local Git history, and repository documents as the
current development authority. Conversation memory, old tool sessions, and
remote branches do not override them.

At the start of a work unit, inspect only what is relevant:

- the root and applicable subtree `AGENTS.md` files;
- `README.md` and `docs/README.md`;
- the specialist documents and active roadmap for the task;
- `git status` and the relevant staged/unstaged diff; and
- recent related local commits when needed to reconstruct intent.

If implementation and documentation appear inconsistent, identify the owning
contract and resolve the discrepancy instead of silently choosing whichever
version is convenient.

## Existing changes

Preserve unrelated user changes. Do not reset, clean, overwrite, reformat, or
include unrelated files in the current commit.

An existing modification in a target file is not automatically a conflict. If
repository state and documentation make it clear that the change is part of the
same unfinished work unit, continue from it without duplicating or replacing it.
If ownership or intent cannot be determined safely, report the ambiguity rather
than guessing.

## Repository and Git boundaries

Current Sonbal work normally stays inside this repository. Other repositories
may be read to understand a public dependency contract, but do not edit them as
a side effect of Sonbal work. Clair-specific coordinated development follows
[`clair-co-development.md`](clair-co-development.md).

Read-only Git inspection is allowed as needed. Unless the user explicitly asks
for the specific operation, do not create branches or pull requests, push,
rebase, amend, reset, or rewrite history.

One stable work unit may be committed locally after validation and full diff
review. Commit only files belonging to that work unit.

## Work sequence

Use this order:

`implementation -> tests/validation -> roadmap update -> diff review -> commit`

1. Confirm current state and the directly applicable contracts.
2. Implement the smallest complete structural change that satisfies them.
3. Run focused validation first, then the wider relevant matrix.
4. If implementation status, acceptance state, remaining work, or the resume
   point changed, update the applicable existing roadmap.
5. Review the complete diff and run `git diff --check` where applicable.
6. Commit only when the work unit is coherent and the relevant validation is
   green.

Do not create checkpoint commits for known-broken or unvalidated states. Do not
edit a roadmap merely to manufacture commit ceremony when current roadmap state
did not change.

## Validation honesty

Do not report tests, builds, target platforms, package acceptance, external
client behavior, or security properties that were not actually exercised.
Record limitations explicitly. A cross build does not prove native runtime
behavior, and a synthetic client does not prove ChatGPT behavior.

## Privilege and destructive-operation boundary

Root privileges, system account/group changes, important host configuration,
activation of system services, or other operator-owned changes require the
user to perform the minimal necessary operation unless the user explicitly
authorizes a different mechanism.

Do not respond to file/ACL problems by forcibly changing ownership or replacing
unrelated user files. Do not broaden credentials or permissions merely to make a
validation step convenient.

## Continuity and result reporting

Before a commit, keep every applicable roadmap current enough that another
conversation can recover completed work, remaining work, validation evidence,
and the exact next step from the repository alone. Git history owns detailed
past implementation chronology; roadmaps own current state.

When direct working-tree modification is available, do not provide a unified
diff by default. Report changed areas, validation, commit identity when one was
created, remaining blockers, and the next resume point.
