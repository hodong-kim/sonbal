# Implementation Language and Library Boundary

## First-party product language

Sonbal core and its native product runtime are implemented in Ada. The
versioned connector ABI is an explicit language boundary: first-party
connector/provider integration may use C where that ABI and its existing
build/test contract require it. Adding another first-party product
implementation language or moving core/runtime logic out of Ada requires
explicit user approval. Build/test support and packaging scripts retain their
existing non-product roles.

## Ada library boundary

First-party source must not directly depend on implementation-specific Ada
library units whose expanded names begin with `GNAT.`. Do not `with`, `use`,
instantiate, rename, or wrap a `GNAT.*` unit as an application dependency.

This restriction does not prohibit using the GNAT compiler toolchain to compile
standards-conforming Ada. Build tools and runtime profiles are reviewed
separately for licensing, target, and redistribution requirements.

Prefer predefined Ada language and standard-library facilities. When an
operating-system facility is not available there, use Clair when its reusable
contract fits. A small Sonbal-owned binding is appropriate only when the
boundary is Sonbal-specific or cannot reasonably belong to Clair. Any other
external dependency requires an explicit need and documented license, ownership,
failure, and platform boundaries.

Dependency and release review must verify that forbidden `GNAT.*` application
dependencies have not entered first-party source and that generated, vendored,
or transitive implementation details have not silently become part of Sonbal's
application-level API surface.

## Shell and process boundaries

Sonbal product APIs must not smuggle an interactive shell, PTY, or implicit
command language into noninteractive execution. Shell use in repository
workflows is a development-tool choice and does not change the MCP product
contract.

Compiler, test, build, and Git operations remain ordinary process work unless a
demonstrated product requirement justifies a dedicated Sonbal API. Do not add
operation-specific product wrappers merely because a development workflow uses
the command frequently.

## Related documents

Dependency artifact ownership and temporary-file placement are specified in
[`dependency-builds.md`](dependency-builds.md). Product authority and execution
semantics belong to [`design.md`](design.md).
