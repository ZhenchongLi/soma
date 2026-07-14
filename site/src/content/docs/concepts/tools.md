---
title: Tools
description: The tool behaviour, manifests, and the erlang_module and cli adapters.
---

A tool is an Erlang behaviour. It declares what it is and how to invoke it, and
the runtime calls it across a process boundary.

```erlang
-callback describe() -> soma_tool:spec().
-callback invoke(soma_tool:input(), soma_tool:ctx()) ->
    {ok, soma_tool:output()} | {error, soma_tool:error()}.
```

Tool metadata declares `effect` (`identity` | `reader` | `state`),
`idempotent`, and `timeout_ms`. The built-in v0.1 tools are `echo`, `sleep`,
`fail` (for tests), and `file_read` / `file_write` (sandboxed to a root,
sharing path resolution).

## The manifest contract

A tool also has a **manifest** — its `describe/0` metadata plus an `adapter` and
adapter-specific fields. `soma_tool_manifest:normalize/1` validates and
normalizes a manifest into the descriptor the registry stores, so the registry
holds `name => descriptor` and resolves it with `resolve_descriptor/1`. A
manifest is validated *before* registration.

```erlang
%% An erlang_module tool's manifest is its describe/0 plus the adapter fields.
manifest() ->
    (describe())#{adapter => erlang_module, module => ?MODULE}.
```

## Model-facing catalog

A manifest can add a prose `description` and a declared `params` list as its
model-facing half. soma_tool_registry:catalog/0 provides a model-facing catalog
of described tools using only name, description, and params.

## Config manifests

At daemon boot, `soma_tool_config:load_dir/1` reads each
`~/.soma/tools/*.lisp` file with the Soma Lisp reader, compiles its `(tool ...)`
form to a manifest, and sends it through
`soma_tool_registry:register_tool/1`. That call runs
`soma_tool_manifest:normalize/1` before the normalized descriptor enters the
live registry.

When a config tool omits safety metadata, Soma defaults effect to state,
idempotent to false, and timeout_ms to 30000 ms.

## Two adapters

- **`erlang_module`** — the in-BEAM built-ins. The worker runs
  `Module:invoke/2` directly in the BEAM.
- **`cli`** — a one-shot external executable: `#{adapter => cli, executable,
  argv}`. The worker launches it through a port (`open_port`, executable plus
  argv, **no shell**), captures stdout as the step output, and treats exit 0 as
  success.

`ask_actor` is an actor-owned `erlang_module` tool, registered by the actor
application at boot.

A placeholder such as `"{param}"` occupies one complete `argv` element and
must name an entry in the declared `params` list. Soma replaces that whole
`argv` element with the parameter value; it does not perform substring
interpolation.

The `cli` execution protocol delivers the step input as the **final argv
argument** (Erlang ports cannot half-close stdin), captures stdout as the
output, and gives the child a minimal environment (only `PATH`) and a fixed cwd.

```bash
# External tools always use executable + args, never a shell command string.
soma_sample_upper "some input text"
```

Because `exit(WorkerPid, kill)` is untrappable, the longer-lived `soma_run`
holds the spawned external OS pid and kills the external process on
timeout or cancel, so a hanging cli program cannot outlive its run.
