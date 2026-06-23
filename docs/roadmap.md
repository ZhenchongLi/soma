# Roadmap

This document tracks ideas that should wait until the Erlang runtime is solid.
The README intentionally focuses on v0.1 implementation work.

## Sequence

```text
v0.1  Erlang/OTP agent runtime
v0.2  tool manifests and CLI/port adapter hardening
v0.3  LFE DSL -> steps
v0.4  MCP client adapter
v0.5  LLM planner adapter
v0.6  DAG execution
v0.7  persistent resume
```

## Planning Layer

The runtime should not depend on where steps came from.

Future planning inputs can include:

```text
LFE DSL
JSON request
LLM structured output
workflow UI
```

All of them should compile down to the small step format the runtime already
knows how to execute.

## Ecosystem Layer

Soma should connect external ecosystems through adapters instead of copying them
into BEAM.

Candidate adapters:

```text
MCP
HTTP
gRPC
CLI
long-running ports
```

These should stay above the runtime boundary. The runtime should keep enforcing
the same process, timeout, cancellation, and event semantics regardless of the
adapter.

## Rule

Do not add a future layer until the layer below it has test coverage for failure
behavior.
