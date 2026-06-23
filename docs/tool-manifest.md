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
  safety and replay. Its allowed values are `identity` (no observable effect),
  `reader` (observes external state without changing it), or `state` (changes
  external state).
- `idempotent` — a boolean saying whether invoking the tool twice with the same
  input is equivalent to invoking it once, which governs whether a call is safe
  to retry.
- `timeout_ms` — the per-call timeout in milliseconds after which the runtime
  abandons the tool call and the run records a timeout.

## Adapter types

A manifest entry names exactly one of two adapter types, which tells the runtime
how to run the tool:

- `erlang_module` — runs an in-BEAM module that implements the `soma_tool`
  behaviour, the same way every v0.1 tool runs today.
- `cli` — runs an external one-shot executable as a separate process, given an
  executable path and an argv list (never a shell command string).
