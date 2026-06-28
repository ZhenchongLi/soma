---
title: Usage
description: The concrete API for writing code against Soma — start the runtime, register tools, start runs, read events, and cancel.
---

This guide covers the concrete API you need to write code against Soma —
how to start the runtime, register tools, start runs, read events, and cancel.
It does not repeat the architecture (see the Architecture concept) or tool
manifest rules; it covers the parts only readable from source.

## Starting the runtime

```erlang
{ok, _} = application:ensure_all_started(soma_runtime).
```

This starts the full supervision tree: `soma_sup` → `soma_event_store`,
`soma_tool_registry`, `soma_session_sup`, `soma_run_sup`. The five built-in
tools (`echo`, `sleep`, `fail`, `file_read`, `file_write`) are seeded into
the registry automatically.

## Registering a tool

```erlang
ok = soma_tool_registry:register_tool(Manifest).
```

`Manifest` is a map validated through `soma_tool_manifest:normalize/1`. The
`name` field must be an atom; it becomes the key the step's `tool` field
addresses. Two adapter shapes:

```erlang
%% Erlang module tool
#{name => my_tool, effect => reader, idempotent => true,
  timeout_ms => 5000, adapter => erlang_module, module => my_tool_module}

%% External program tool
#{name => my_cli, effect => reader, idempotent => true,
  timeout_ms => 5000, adapter => cli,
  executable => "/absolute/path/to/program",
  argv => ["--flag", "value"]}
```

A malformed manifest is rejected; the registry state is unchanged and the
name does not resolve. `register_tool/1` returns `ok` or `{error, Reason}`.

For `priv`-packaged helpers, resolve the path at runtime:

```erlang
Exe = filename:join([code:priv_dir(my_app), "cli", "my_helper"]).
```

## Session API

```erlang
{ok, SessionPid} = soma_agent_session:start_link(#{}).
Status = soma_agent_session:get_status(SessionPid).
%% => #{session_id => <<"sess-1">>, runs => #{<<"run-1">> => completed, ...}}
```

`get_status/1` returns the session's `session_id` and a map of every run it
has started with its terminal status: `running | completed | failed | timeout
| cancelled`.

## Starting a run

```erlang
{ok, RunId} = soma_agent_session:start_run(SessionPid, Steps).
```

`Steps` is a list of step maps. `RunId` is a binary like `<<"run-1">>`.
Steps run strictly in list order.

### Step map format

```erlang
#{
    id         => step_atom,       %% atom, referenced by from_step; must be unique
    tool       => registered_name, %% atom, must resolve in registry
    args       => ArgsMap,         %% see "Arg resolution" below
    timeout_ms => 5000             %% optional; omit for no per-step limit
}
```

`timeout_ms` in the step map is the per-step wall-clock budget. If it fires
before the tool replies, the run reaches `run.timeout` and the active worker
(and its OS process, for cli tools) is killed. Omitting it means the step
waits indefinitely.

Passing an empty steps list is valid and completes the run immediately with
`run.completed` and no steps in the event trail.

Step `id` atoms must be unique within a run. Duplicate IDs silently overwrite
earlier step outputs in the `from_step` lookup map, so a later step that
references the shared ID gets the second output, not the first, with no error.

### Arg resolution

Before the tool call starts, the run resolves the step's `args` map against
prior step outputs. Two patterns:

**Bare `from_step`** — the entire `args` map is `#{from_step => StepId}`.
The resolved input is the prior step's raw output, not wrapped in a map:

```erlang
%% s2's input = whatever s1's tool returned
#{id => s2, tool => my_tool, args => #{from_step => s1}}
```

**Value-level `from_step`** — one or more values in the `args` map are
`{from_step, StepId}` tuples. Only those values are substituted; the rest
pass through:

```erlang
%% s2 gets #{path => "/tmp/f", content => <s1 output>}
#{id => s2, tool => file_write,
  args => #{path => "/tmp/f", content => {from_step, s1}}}
```

The `root` key in `args` is special: it is lifted out of the tool's input
map and placed in the tool context, so file tools can read their sandbox
root from it without the tool's `invoke/2` seeing it as a regular argument.

## CLI tools: how input reaches the external program

For a `cli` tool, the adapter builds the final argv as:

```
manifest.argv ++ [render_input(ResolvedInput)]
```

`render_input` converts the resolved input to a string:

| Resolved input type | What the program receives as last argv |
|---|---|
| `binary()` | The binary bytes as a string — no quoting or wrapping |
| `list()` | The list bytes as-is |
| Any other term | `io_lib:format("~p", [Term])` — Erlang term repr |

**Consequence**: if a step's `args` map is `#{input => <<"hello">>}` (a
map, not a bare binary), the tool's resolved input is the map
`#{input => <<"hello">>}`, which is term-printed to
`"#{input => <<\"hello\">>}"` and passed as argv. If you want a clean
string, use the bare `from_step` form so the input is the prior step's
binary output directly.

The program's merged stdout/stderr becomes the step's recorded output (as a
binary) when it exits 0. The merged stream is capped at 64 KB; exceeding it
fails the run with `{cli_output_limit_exceeded, 65536}` without buffering the
full stream. Stderr counts against the same cap as stdout.

CLI children run with a minimal environment (only `PATH` from the runtime)
and in an adapter-chosen working directory — not the runtime process's cwd.

## Reading events

Locate the event store and query by run or session:

```erlang
%% Locate the running event store
{soma_event_store, StorePid, _, _} =
    lists:keyfind(soma_event_store, 1, supervisor:which_children(soma_sup)).

%% All events for one run, in emission order
Events = soma_event_store:by_run(StorePid, RunId).

%% All events for one session, in emission order
Events = soma_event_store:by_session(StorePid, SessionId).

%% All events for one correlation_id — the whole actor+run task chain
Events = soma_event_store:by_correlation(StorePid, CorrelationId).

%% All events in the store
Events = soma_event_store:all(StorePid).
```

### Persistent store and restart durability

By default the event store is in-memory: `start_link/0` keeps every event in a
single in-process list, writes nothing to disk, and the trail is gone when the
BEAM stops. The full supervision tree starts the store this way.

For a trail that outlives a restart, start the store with the opt-in
`start_link/1`, passing a log path:

```erlang
{ok, StorePid} = soma_event_store:start_link(#{log => "/var/lib/soma/events.log"}).
```

A store started this way opens a `halt`-type `disk_log` at that path. Each
`append/2` writes the same normalized event map it puts in the in-memory index
to the `disk_log` as well, so what you read back from the file equals what a
query returns. The query API is unchanged — `all/1`, `by_run/2`,
`by_session/2`, and `by_correlation/2` always read the in-memory index, in both
modes.

The durability payoff is on **restart**: when a store is started again with
`start_link/1` at the same path, `init/1` replays the `disk_log` and rebuilds
the index in append order, so every event written before the stop is served
again through the same queries. The log is the source of truth; the index is a
rebuildable cache. An unclean shutdown that leaves a half-written term at the
end of the log does not break the restart — replay treats the corrupt tail as
end-of-log, keeps every intact event read so far, and finishes `init/1`
cleanly, costing you only the last partial event.

The persistent path is opt-in and used by tests; the default release runs the
in-memory store via `start_link/0`.

### Event structure

Every event is a map. The store normalizes it to always include:

```
event_id      binary()         unique ref-based id
timestamp     integer()        erlang:system_time(nanosecond)
session_id    binary() | undef
run_id        binary() | undef
step_id       atom()   | undef  matches the `id' field in the step map
tool_call_id  binary() | undef
event_type    binary()
payload       map()    | undef
```

Missing fields are set to `undefined` rather than omitted, so
`maps:get(step_id, Event)` is always safe.

Actor-layer events additionally carry `actor_id`, `task_id`, and
`correlation_id`, and a `soma_run` started by an actor stamps `correlation_id`
onto its run events too. These are not part of the mandatory 8 — they are
present only when set — which is what lets `by_correlation/2` return an actor's
events and its run's events together. See the Actors concept.

### Event types and their fields

Events are emitted in this order for a successful one-step run:

| event_type | Extra fields present |
|---|---|
| `<<"session.started">>` | `session_id` |
| `<<"run.accepted">>` | `session_id`, `run_id` |
| `<<"run.started">>` | `session_id`, `run_id` |
| `<<"step.started">>` | `step_id`, `tool_call_id` |
| `<<"tool.started">>` | `step_id`, `tool_call_id`, `tool_call_pid` |
| `<<"tool.succeeded">>` | `step_id`, `tool_call_id`, `tool_call_pid` |
| `<<"step.succeeded">>` | `step_id`, `tool_call_id`, `payload => #{output => Output}` |
| `<<"run.completed">>` | — |

For failure, timeout, and cancel the trail diverges after `tool.started`:

| event_type | Extra fields present |
|---|---|
| `<<"tool.failed">>` | `step_id`, `tool_call_id`, `tool_call_pid`, `payload => #{reason => Reason}` |
| `<<"step.failed">>` | `step_id`, `tool_call_id`, `payload => #{reason => Reason}` |
| `<<"run.failed">>` | `payload => #{reason => Reason}` |
| `<<"run.timeout">>` | `step_id`, `tool_call_id` — no `tool_call_pid` |
| `<<"run.cancelled">>` | `step_id`, `tool_call_id` — no `tool_call_pid` |

`tool_call_pid` is the `soma_tool_call` worker process pid — distinct from
`soma_run`'s pid and from the external OS process. It is only present on
`tool.started` and `tool.succeeded`/`tool.failed`, not on timeout or cancel
events (the worker is already killed by the time those are emitted).

Reading the step output from events:

```erlang
[E] = [Ev || Ev <- Events,
             maps:get(event_type, Ev) =:= <<"step.succeeded">>,
             maps:get(step_id, Ev) =:= my_step_id],
Output = maps:get(output, maps:get(payload, E)).
```

## Cancelling a run

Send a message to the session pid:

```erlang
SessionPid ! {cancel_run, RunId}.
```

The session looks up the run pid and forwards `cancel` to it. The run kills
the active worker and, for cli tools, the external OS process. It then
records `run.cancelled` and moves to the `cancelled` terminal state. The
session stays alive.

Cancel only takes effect while the run is in `waiting_tool` (an active step
is in flight). Sending it after the run reaches a terminal state (`completed`,
`failed`, `timeout`, `cancelled`) is a no-op — those states have catch-all
handlers. Sending it during the very brief `executing` window between steps
is unsafe; in practice this window is sub-millisecond but the safe pattern
is to wait for `tool.started` before sending cancel, which guarantees the run
is in `waiting_tool`.

## Failure reasons

When any step fails, the `reason` in `tool.failed`'s payload is one of:

| Reason | Meaning |
|---|---|
| `{unregistered_tool, Name}` | The step's `tool` atom was not registered in the registry |

When a cli step fails, the reason is additionally one of:

| Reason | Meaning |
|---|---|
| `{cli_executable_not_found, Path}` | `executable` path does not exist |
| `{cli_executable_not_executable, Path}` | path exists but has no execute bit |
| `{cli_exit_status, N, Excerpt}` | program exited with status N; `Excerpt` is the captured output (binary, may be empty) |
| `{cli_output_limit_exceeded, 65536}` | stdout/stderr exceeded 64 KB before the program exited |

In the `{cli_exit_status, N, Excerpt}` case, `Excerpt` is never larger than
the 64 KB limit — the worker stops collecting as soon as the limit is hit.
