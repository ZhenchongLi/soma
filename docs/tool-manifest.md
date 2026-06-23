# The v0.2 tool manifest contract

This document defines the manifest: the written-down shape of a tool entry in
Soma v0.2, including which adapter runs the tool. It is a contract on paper —
this issue writes it down; validation and the adapters themselves land in later
v0.2 work.

## Required metadata keys

Every manifest entry carries these four metadata keys, the same ones the v0.1
tools already emit from `describe/0`:

- `name` — the atom the tool registers under and that a step references to
  invoke it (for example `echo`); it must be unique across the registry.
- `effect` — what kind of effect the tool has on the world, used to reason about
  safety and replay.
- `idempotent` — a boolean saying whether invoking the tool twice with the same
  input is equivalent to invoking it once, which governs whether a call is safe
  to retry.
- `timeout_ms` — the per-call timeout in milliseconds after which the runtime
  abandons the tool call and the run records a timeout.
