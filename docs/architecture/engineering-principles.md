# Engineering Principles

Performance, safety, reliability, and maintainability under large-scale and
extreme conditions are the primary criteria for evaluating all designs,
architectures, implementations, and operational decisions.

## Security implementation boundary

Sonbal does not implement cryptographic algorithms, TLS, X.509 parsing or
certificate-chain validation, or equivalent security protocol primitives when a
maintained established implementation exists. Security-critical protocol
machinery belongs to reviewed libraries and system components with their own
security-update ecosystem.

Sonbal may implement the product policy around those components: target
authorization, principal-to-target mapping, capability ownership, fencing,
bounded admission, lifecycle, and fail-closed error handling. A thin Ada binding
or event-loop adapter is acceptable only when it delegates the security
primitive itself to the established implementation and does not recreate it.

Do not weaken a library's verification defaults merely to simplify integration.
Custom certificate parsing, cipher implementation, TLS record handling, or
home-grown message authentication is outside the product design.

## Minimum Sufficient Design

A minimum sufficient design is the smallest design that fully satisfies the
defined goal and the engineering properties required to make that goal sound.
It is not the design with the fewest components, abstractions, checks, or lines
of code.

The defined goal includes its documented contracts, acceptance criteria, and
known prerequisites. It does not implicitly expand to unrelated or hypothetical
future goals.

For a goal A, retain every structure, invariant, boundary, or capability needed
to achieve A with the required correctness, performance, safety, reliability,
maintainability, and testability under the intended operating conditions. If
removing an element makes A brittle, weakens those properties, creates a known
architectural dead end, or forces avoidable redesign of a boundary already
known to be required to complete, operate, or safely evolve A, that removal is
underdesign rather than simplification.

Do not add generality solely for hypothetical future goals B or C. Extensibility
is part of maintainability when it is necessary to complete, operate, or safely
evolve A without violating A's contracts or invariants. Speculative extension
points, generic frameworks, and abstractions without such a requirement shall
be deferred until a demonstrated need exists.

Distinguish required structure from a particular implementation mechanism.
Required ownership, lifecycle, concurrency, failure, persistence, isolation,
or extension boundaries may need to be established up front, while the
concrete mechanism should remain undecided until constraints, evidence, or
implementation work justify choosing it.

When deciding whether an element belongs in the design, ask whether omitting it
would compromise correctness, performance, safety, reliability,
maintainability, testability, or the ability to evolve A in a way already
required by A's documented constraints. If so, retain it. If its only
justification is an uncertain future requirement unrelated to completing,
operating, or safely evolving A, defer it.
