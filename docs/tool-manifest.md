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

## CLI execution protocol

The `executable` + `argv` schema says *what* to launch; this section says *how*
the runtime runs it and turns one process invocation into one step result.

- **Input channel — the final argv argument.** A step's resolved input is
  delivered to the process as the final argv argument: the runtime launches the
  executable with `argv` followed by the input value appended as the last
  argument. Input is not written to the process's stdin — an Erlang port cannot
  half-close the child's stdin, so the input is passed positionally as the final
  argv argument instead.
- **Output capture — stdout becomes the step output.** The runtime captures
  everything the process writes to stdout and records that captured stdout as the
  step output, the value later steps read through `from_step`.
- **Exit status — 0 means success.** The runtime waits for the process to exit.
  Exit status 0 means success: the captured stdout is recorded as the step output
  and the step succeeds. Any non-zero exit status is a failure of the step.

## CLI adapter defaults: environment and working directory

Beyond *what* to launch and *how* to run it, the `cli` adapter applies two fixed
defaults to every external process. These are adapter-level policy, the same for
every `cli` tool; they are not manifest fields, and per-tool overrides are out of
scope for v0.2.

- **Default environment policy — a minimal environment, `PATH` only.** The child
  process does not inherit the runtime's whole environment. The adapter passes a
  minimal environment that keeps only `PATH` (taken from the runtime's own `PATH`
  so an external `#!/bin/sh` helper can still find common programs) and clears
  every other named runtime variable. A variable set in the runtime's
  environment but not on the allowed set — for v0.2 that set is just `PATH` — is
  absent in the child.
- **Default working-directory policy — an adapter-chosen stable directory.** The
  child process runs in a fixed, adapter-chosen directory. That directory is
  **not the runtime process cwd**: the adapter sets the child's working directory
  rather than letting the child inherit whatever directory the runtime happens to
  sit in, so the child's working directory is stable and controlled by the
  adapter.

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

## Example: an invalid manifest

The following is an invalid manifest example for a hypothetical `grep` tool. It
declares the `cli` adapter but folds the executable and its arguments into a
single shell command string:

```erlang
#{
    name => grep,
    effect => reader,
    idempotent => true,
    timeout_ms => 5000,
    adapter => cli,
    executable => "/bin/sh -c 'grep -n foo *.txt | head'"
}
```

This entry is **rejected** because the `cli` adapter schema requires a bare
`executable` path plus a separate `argv` list, and a shell command string is
never a valid form. Here the `executable` field smuggles arguments, a glob, and
a pipe into one string and the required `argv` list is missing, so the runtime
has no way to launch the process directly without a shell.

## Non-goals

The v0.2 manifest contract is deliberately narrow. The following are explicitly
out of scope for this work:

- No MCP adapter — the manifest defines only the `erlang_module` and `cli`
  adapter types; an MCP adapter is not part of v0.2.
- No LLM planner — the manifest describes tools, not how a run's steps are
  chosen; planning a step list with an LLM stays out of scope.
- No LFE DSL — manifests are plain Erlang maps; there is no Lisp-flavoured
  Erlang surface syntax for authoring them.
- No DAG execution — the runtime stays strictly sequential; the manifest adds no
  branching, fan-out, or dependency-graph execution.
- No long-running port pool — a `cli` tool is a one-shot external process per
  call; there is no persistent pool of warm ports to reuse.
- No OS sandbox beyond the adapter safety rules defined here — the only sandbox
  guarantees are the no-shell `executable` + `argv` rule for `cli` and the
  in-BEAM `erlang_module` boundary; no container, seccomp, or namespace
  isolation is introduced.
