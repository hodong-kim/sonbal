# ChatGPT and OpenAI Client Support Evidence

## Scope

This document owns the evidence boundary for claims about current OpenAI
products and for Sonbal capabilities exposed specifically through ChatGPT or an
OpenAI connector surface.

## Product claims

For claims about OpenAI products, ChatGPT plans, MCP behavior, Secure MCP
Tunnel, permissions, availability, or UI paths, verify current official OpenAI
documentation before recording the claim. Do not present inference, historical
behavior, or an optional protocol feature as current product fact. Repository
documentation that depends on such external facts must record an appropriate
verification date or concrete integration evidence.

## ChatGPT-facing capability gate

A ChatGPT-facing Sonbal MCP capability is supported only when at least one of
these is true:

1. current official OpenAI documentation describes the relevant ChatGPT
   capability; or
2. a real ChatGPT client integration test demonstrates that the capability is
   usable through the intended production path.

The existence of an optional MCP method, extension, schema member, or provider
development proxy is not sufficient ChatGPT-support evidence.

Synthetic protocol tests remain valuable for Sonbal parser, dispatcher,
connector, framing, and failure behavior. They prove those Sonbal contracts,
not the behavior of an external ChatGPT UI or client that was not exercised.

## Acceptance records

When live ChatGPT evidence is part of a release gate, the applicable roadmap may
record the exact candidate, tested surface, date, and non-secret result. Stable
client-independent semantics remain in `design.md`; transient external-product
observations do not become architecture merely because they were needed for one
acceptance cycle.
