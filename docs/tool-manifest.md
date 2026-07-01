# Tool manifest

A tool manifest is a plain Erlang map that describes a tool and tells the
runtime how to run it. `soma_tool_manifest:normalize/1` validates and
normalizes the map; a manifest that fails validation is never stored in the
registry. `soma_tool_registry:register_tool/1` calls `normalize/1` before
accepting a manifest, so the registry always holds clean descriptors.

## Required fields

Every manifest carries five shared fields:

- `name` — the atom the tool registers under and that steps reference
  (e.g. `echo`). Must be unique across the registry.
- `effect` — one of `identity` (no observable effect), `reader` (reads
  external state without changing it), or `state` (changes external state).
- `idempotent` — `true` or `false`. Governs whether a call is safe to retry.
- `timeout_ms` — positive integer. Per-call millisecond limit; the runtime
  kills the worker and fails the step if this expires.
- `adapter` — one of `erlang_module` or `cli` (see below).

## Optional model-facing fields

A manifest may also carry a model-facing half — the part of the tool's
self-description a planning model reads to decide what to call and how
(`docs/tool-abstraction.md` §3). Both fields are optional and additive: a
manifest without them normalizes to exactly the descriptor it produced
before these fields existed, with no new keys.

- `description` — a binary; one-paragraph prose for the model. A non-binary
  value is rejected with `{error, {invalid_description, Value}}`.
- `params` — a list of param specs, each
  `#{name := binary(), type := string | integer | boolean, required := boolean()}`
  plus an optional `doc` binary. Param `name` is a binary, not an atom —
  param names arrive from external manifests and must not mint atoms. Any
  malformed `params` value — a non-list (including an improper list tail), a
  spec that is not a map, a spec missing `name`/`type`/`required`, a `type`
  outside the closed set, or a non-binary `doc` — is rejected with
  `{error, {invalid_params, Offending}}` carrying the offending value.

Tools that declare a `description` appear in `soma_tool_registry:catalog/0`,
which returns exactly the model-facing half per tool —
`#{name, description, params}` with `params` defaulting to `[]` — and never
exposes runtime-facing fields (`module`, `executable`, `argv`, `effect`,
`idempotent`, `timeout_ms`). A tool without a `description` stays resolvable
but is absent from the catalog.

## `erlang_module` adapter

Runs a module that implements the `soma_tool` behaviour in-BEAM. One
additional field is required:

- `module` — the module atom (e.g. `soma_tool_echo`).

At runtime `soma_tool_call` calls `Module:invoke(Input, Ctx)` in its own
worker process. A crash in `invoke/2` is absorbed by the run as a monitor
`'DOWN'` — it fails the step, not the session.

In-BEAM tools expose a `manifest/0` that builds on `describe/0`:

```erlang
manifest() ->
    (describe())#{adapter => erlang_module, module => ?MODULE}.
```

## `cli` adapter

Runs an external one-shot executable in its own worker process. Two
additional fields are required:

- `executable` — bare path to the program. Must not contain whitespace;
  arguments belong in `argv`, not embedded in the executable string.
- `argv` — list of argument strings passed to the program. Each list element
  is one literal argument — no shell parsing is applied.

Example:

```erlang
#{
    name => upper,
    effect => identity,
    idempotent => true,
    timeout_ms => 5000,
    adapter => cli,
    executable => "/usr/local/bin/soma_sample_upper",
    argv => []
}
```

## CLI execution protocol

### Input

The step's resolved input is appended as the **final argv argument**:
`executable argv... <input>`. Stdin is not used — an Erlang port cannot
half-close the child's stdin, so the input travels positionally.

### Output

The program's merged stdout+stderr is captured. On exit status 0 the
captured bytes become the step output (a binary). The output is bounded
to 65 536 bytes; a program that exceeds this limit is stopped.

### Exit status

Exit 0 = success. Any other exit status fails the step.

### OS pid handoff

Once the port is open the worker sends the child's OS pid to the run
(`{tool_started_os_pid, ToolCallId, WorkerPid, OsPid}`) before blocking on
output. The run holds the OS pid for the lifetime of the step; on timeout or
cancel it kills the external process directly (via `kill`), not just the BEAM
worker, so a hanging program cannot outlive its run.

### Environment

The child receives a minimal environment: only `PATH` is kept (taken from the
runtime's own `PATH` so shell helpers can find standard programs); every other
inherited variable is cleared.

### Working directory

The child runs in an adapter-chosen stable directory
(`filename:basedir(user_cache, "soma_cli")`), not whatever directory the BEAM
process inherited. This is fixed adapter-level policy — there is no per-tool
override.

## CLI failure modes

All CLI failures are named, bounded `{error, Reason}` terms that fail the
step and leave the session alive:

| Reason | Cause |
|--------|-------|
| `{cli_executable_not_found, Path}` | `executable` path does not exist |
| `{cli_executable_not_executable, Path}` | path exists but cannot be spawned |
| `{cli_exit_status, N, Excerpt}` | program exited with non-zero status `N` |
| `{cli_output_limit_exceeded, 65536}` | program emitted more than 65 536 bytes |

## Built-in tools

The five built-in tools seed the registry at startup via their `manifest/0`
callbacks. All use the `erlang_module` adapter.

| Name | Effect | Idempotent | Notes |
|------|--------|------------|-------|
| `echo` | `identity` | `true` | returns input unchanged |
| `sleep` | `identity` | `true` | sleeps for `ms` in input |
| `fail` | `identity` | `true` | for tests — error and crash modes |
| `file_read` | `reader` | `true` | reads a file under a sandboxed `root` |
| `file_write` | `state` | `false` | writes a file under a sandboxed `root` |

## Registering a custom tool

```erlang
soma_tool_registry:register_tool(#{
    name => my_tool,
    effect => reader,
    idempotent => true,
    timeout_ms => 3000,
    adapter => erlang_module,
    module => my_tool_module
}).
```

`register_tool/1` returns `ok` or `{error, Reason}` — a malformed manifest is
rejected and never lands in the registry.
