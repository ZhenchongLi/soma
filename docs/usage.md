# soma usage reference

This document covers the concrete API you need to write code against soma —
how to start the runtime, register tools, start runs, read events, and cancel.
It does not repeat the architecture (see `README.md`) or tool manifest rules
(see `tool-manifest.md`); it covers the parts only readable from source.

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
events and its run's events together. See "Agent actor API" below.

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

## Agent actor API (soma_actor)

`soma_actor` is the agent-entity layer (v0.4) above the session/run core: a
long-lived `gen_statem` that takes a message, creates a task, runs it through
`soma_run`, and returns a result. It starts the run **directly** — owning it as
`session_pid => self()`, with no `soma_agent_session` in its path — and learns
the outcome from the run's terminal message. v0.4 is fixed-rule only: no real
LLM, planner, or policy gate (those are v0.5).

### Starting an actor

```erlang
{ok, _} = application:ensure_all_started(soma_actor).
{ok, Actor} = soma_actor_sup:start_actor(#{
    actor_id     => <<"actor-1">>,
    model_config => #{},
    tool_policy  => #{},
    event_store  => StorePid       %% optional; runs the actor starts share it
}).
```

`event_store` is the pid the actor — and every run it starts — emits into; pass
a store you can query. With no `event_store` the actor still runs but emits
nothing. (`soma_run_sup` must be alive, so start `soma_runtime` too.)

### The message envelope

Work enters only through the mailbox, as an envelope map:

```erlang
#{
    type           => <<"chat">>,      %% required
    payload        => #{...},          %% required
    steps          => [StepMap, ...],  %% optional; present => the actor runs them
    task_id        => <<"task-1">>,    %% optional; minted if absent
    correlation_id => <<"corr-1">>     %% optional; defaults to task_id
}
```

`type` and `payload` are required — an envelope missing either, or one that is
not a map, is rejected with `{error, Reason}`. A `steps` list is the v0.4 fixed
rule: present → the actor validates it and starts a `soma_run`; absent → the
task is accepted (`status` stays `accepted`) but no run starts. `StepMap` is
exactly the step format documented above.

### send/2 — fire and get a task id

```erlang
{ok, TaskId} = soma_actor:send(Actor, Envelope).   %% or {error, Reason}
```

Returns as soon as the task is accepted and its run is started; the result is
recorded asynchronously when the run finishes. The actor never blocks on the
run.

### ask/3 — block for the result

```erlang
soma_actor:ask(Actor, Envelope, TimeoutMs).
%% => {ok, Result} | {error, Reason} | timeout
```

Blocks the *caller* (not the actor) until the task reaches a terminal state.
`Result` is the run's outputs map, keyed by step id (e.g.
`#{s1 => #{value => <<"hi">>}}`). A failed run returns `{error, Reason}`; if
`TimeoutMs` elapses first the call returns `timeout` and the actor still drives
the task to completion.

### Polling: status and result

```erlang
soma_actor:get_task_status(Actor, TaskId).
%% known   => #{task_id => T, correlation_id => C, status => S}
%% unknown => #{task_id => T, status => not_found}

soma_actor:get_task_result(Actor, TaskId).
%% => {ok, Result} | not_ready | {error, not_found}
```

`status` is `accepted` (a no-steps task), `running`, `completed`, `failed`, or
`cancelled`.

### cancel/2

```erlang
soma_actor:cancel(Actor, TaskId).
%% => ok | {error, not_found} | {error, not_running}
```

`ok` means *cancel requested*: the actor sends `cancel` to the run it owns,
which kills the active tool worker for real (and a cli tool's external OS
process) and reports back; the task then reaches `cancelled`. Only a task whose
run is in flight (`running`) is cancellable — anything else is `{error,
not_running}`. Cancellation targets an in-flight tool step (the run's
`waiting_tool` state), the same window as run-level cancel above.

### Actor events

Actor-layer events extend the 8-field event with `actor_id`, `task_id`, and
`correlation_id`. A successful task emits, in order:

| event_type | |
|---|---|
| `<<"actor.started">>` | on actor start (`actor_id`) |
| `<<"actor.message.received">>` | `actor_id`, `task_id`, `correlation_id` |
| `<<"actor.task.accepted">>` | same ids |
| `<<"actor.result.created">>` | same ids (after the run completes) |
| `<<"actor.task.completed">>` | same ids |

A failed or timed-out task emits `<<"actor.task.failed">>` (payload carries
`reason`); a cancelled one emits `<<"actor.task.cancelled">>`. The run's own
`run.*` / `step.*` / `tool.*` events appear between accept and result, each
stamped with the same `correlation_id`.

### The whole task chain by correlation_id

Because the run inherits the task's `correlation_id`, one query returns the
actor.* and run.* events together — the event stream is the source of truth,
and `ask`/polling are convenience reads over it:

```erlang
soma_event_store:by_correlation(StorePid, CorrelationId).
%% actor.message.received -> actor.task.accepted -> run.started -> step.started
%% -> tool.started -> tool.succeeded -> step.succeeded -> run.completed
%% -> actor.result.created -> actor.task.completed
```

A runnable walkthrough of all of the above — `ask`, `send` + polling, the
correlation chain, real cancel, and surviving a failure — is in
`examples/soma_actor_demo.erl` (`c("examples/soma_actor_demo").` in `rebar3
shell`).

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
