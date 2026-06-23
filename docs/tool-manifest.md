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

## CLI adapter schema

A `cli` manifest entry carries the adapter-specific schema that says how to
launch the external process. The schema has two fields:

- `executable` — the path to the program to run, resolved and launched
  directly by the runtime.
- `argv` — a separate list of argument strings passed to that executable, one
  list element per argument, with no shell parsing applied.

The executable and its argv are always kept apart so the runtime spawns the
process directly without a shell. A single shell command string — a `/bin/sh -c`
line, or an `executable` field that smuggles arguments, pipes, or redirection
into one string — is never a valid form for a `cli` entry. There is no shell on
the path between the manifest and the process, so there is nothing to interpret
such a string.

## The v0.1 tools under the contract

The five v0.1 built-in tools stay valid under the manifest contract — nothing
about them needs to change. Each is an in-BEAM module implementing the
`soma_tool` behaviour, so each maps onto the `erlang_module` adapter:

- `echo` — `erlang_module`
- `sleep` — `erlang_module`
- `fail` — `erlang_module`
- `file_read` — `erlang_module`
- `file_write` — `erlang_module`

Their existing `describe/0` metadata already supplies the four required keys, so
each becomes a conforming manifest entry with `erlang_module` as its adapter and
no behavioral change.

## Example: a valid manifest

The following is a complete, valid manifest example for the `file_read` tool,
carrying the four required metadata keys and naming the `erlang_module` adapter:

```erlang
#{
    name => file_read,
    effect => reader,
    idempotent => true,
    timeout_ms => 5000,
    adapter => erlang_module,
    module => soma_tool_file_read
}
```
