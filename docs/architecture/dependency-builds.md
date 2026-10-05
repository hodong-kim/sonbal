# Dependency Artifacts and Cross-Compilation

## Scope

This document owns Sonbal's dependency-artifact, build-root, and
cross-compilation contract. Current commands and acceptance targets remain in
[`../workflows/build-and-validation.md`](../workflows/build-and-validation.md).

## Artifact ownership

Project-controlled dependency builds and staged artifacts belong under the
consuming repository's `build/deps/`. Sibling repositories are source
authorities only; do not consume or modify their mutable build artifacts.

Keep build-machine tools and target artifacts separate. Incompatible targets,
ABIs, profiles, library kinds, source revisions, toolchains, or sysroots must not
share mutable outputs. Retain a dependency provider's existing internal layout
below `build/deps/` when it already satisfies those constraints; directory-name
uniformity is not itself a reason to rearrange provider artifacts.

Explicitly selected system toolchains, SDKs, sysroots, and installed development
packages do not need to be copied into `build/deps/`.

## One dependency graph

Within one top-level build, reuse compatible dependency artifacts instead of
recursively rebuilding the same dependency. A child build given a prepared
dependency root consumes it read-only and must not rebuild or clean it.

Consume provider-owned public projects, headers, libraries, generated metadata,
and link information. Do not reconstruct a dependency from private object paths,
probe internals, or duplicated transitive link rules.

Source-workspace dependency builds are allowed. Do not add source mirroring,
SDK publication, relocation, staging publishers, revision caches, build locks,
or a generic package framework merely to populate `build/deps/`. Add such a
layer only for a demonstrated independent-consumption requirement that existing
provider build interfaces cannot satisfy.

## Host and target separation

Build-machine tools and target programs are different roles even when they use
the same language or toolchain family. Target compilers, linkers, runtimes,
sysroots, package search paths, and generated ABI data must stay consistent with
the selected target.

Build and test-build entry points must not implicitly execute target programs.
Execute tests only natively or through an explicit compatible runner. Cross-link
success is build evidence, not native runtime acceptance.

Do not substitute host-derived values when target ABI or platform data is
missing. Fail the configuration explicitly instead.

## Sonbal dependency boundary

Clair is Sonbal's approved shared system-programming dependency. Sonbal builds
consumer-owned Clair artifacts below `build/deps/clair` using Clair's public
build-root contract. The sibling Clair checkout remains a source authority.

Every release/package candidate records the exact Clair commit. A dependency
revision change that can affect behavior, ABI, build metadata, link policy, or
runtime semantics requires the applicable Sonbal validation matrix again.

The source, package, and release record must never rely on an unrecorded floating
branch or sibling mutable build output.

## Temporary files

Project-controlled temporary files and directories belong under `build/tmp/`,
not the system `/tmp`. Direct tools that support a temporary-directory override
to `build/tmp/`. If a third-party tool unavoidably hardcodes a system temporary
location and exposes no supported override, document that exception rather than
building Sonbal policy around retained system-temporary state.

For tools that otherwise emit temporary output into the current directory, use
an explicit path under `build/tmp/` where supported.

## Completion criteria

A dependency/build change is complete only when the applicable evidence shows:

- a clean consumer workspace can prepare the dependency and product;
- sibling mutable build artifacts are not required;
- compatible prepared dependency outputs are reused rather than recursively
  rebuilt;
- host tools and target outputs cannot contaminate one another;
- maintained cross targets build without accidental target execution;
- runtime-support claims have separate native or explicit-runner evidence; and
- cleanup is limited to consumer-owned artifacts.
