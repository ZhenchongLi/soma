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
the outcome from the run's terminal message. The v0.4 path documented here is the
fixed rule: an envelope that carries `steps` runs them. The **decision layer**
(v0.5) — a mock LLM call, a proposal schema, a policy gate, a per-task budget, and
actor-to-actor messages — is documented in "Agent decision layer (v0.5)" below.

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
rule: present → the actor validates it up front
(each step is a map with `id` and `tool`; a step that fails this is rejected
with `{error, Reason}` before any run starts) and then starts a `soma_run`;
absent → the task is accepted
(`status` stays `accepted`) but no run starts. `StepMap` is exactly the step
format documented above.

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
%% => {ok, Result} | {ok, accepted, TaskId} | {error, Reason} | timeout
```

Blocks the *caller* (not the actor) until the task reaches a terminal state.
`Result` is the run's outputs map, keyed by step id (e.g.
`#{s1 => #{value => <<"hi">>}}`). A failed run returns `{error, Reason}`; if
`TimeoutMs` elapses first the call returns `timeout` and the actor still drives
the task to completion.

A **no-steps envelope** is valid but starts no run, so no terminal event will
ever fire. Rather than block the caller until `TimeoutMs`, `ask/3` returns
immediately with the distinct 3-tuple `{ok, accepted, TaskId}` — accepted, no
run started, here is the id to poll. The shape is deliberately distinct from the
completed-run `{ok, Result}`: `{ok, Result}` keeps its one meaning and a bare
`{ok, TaskId}` never overloads it.

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

### Tracing: render a correlation chain as a readable timeline

`by_correlation/2` hands back raw event maps in append order. To read a chain
without eyeballing maps, `soma_trace:render/2` queries the store for one
`correlation_id` and formats the result as a timeline — one line per event,
ordered by ascending `timestamp`:

```erlang
soma_trace:render(StorePid, CorrelationId).
%% => iodata(), one line per event, e.g.
%% actor.message.received task_id=... correlation_id=...
%% actor.task.accepted    task_id=... correlation_id=...
%% run.started            ...
%% ...
%% actor.task.completed   task_id=... correlation_id=...
```

Each line names the event's `event_type` and appends whichever salient ids the
event carries (`task_id`, `step_id`, and so on); a field the event does not
carry is left off rather than printed empty. A failure line includes its
`reason`, found either as a top-level key (actor events) or inside `payload`
(run events). An unknown `correlation_id` renders empty iodata rather than
crashing.

`soma_trace:timeline/1` is the underlying pure function — pass it a plain list
of event maps to format them without touching the store.

## Agent decision layer (soma_actor, v0.5)

v0.5 adds the agent's decision step in front of execution: instead of an envelope
that already names `steps`, you send an envelope that carries an `llm` directive;
the actor runs a call, gets back a **proposal**, runs the proposal through a
**policy** gate, and only then executes — all under one `correlation_id`, all
recorded as events. Everything here is driven by a **mock LLM**: there is no real
provider yet. The mock is directive-driven, so a test (or a shell session) decides
exactly what the "model" returns.

The whole layer is data-then-execute, mirroring the rest of the runtime: an `llm`
call returns opaque output or a raw proposal; `soma_proposal:normalize/1` turns a
raw proposal into validated data; `soma_policy:check/2` gives that data a verdict;
and only an *approved* proposal causes a `soma_run` to start.

### The `llm` envelope and the mock directive

An envelope carries **either** `steps` (the v0.4 path) **or** `llm` (the v0.5
path) — never both. An envelope with both is rejected up front with
`{error, steps_and_llm_mutually_exclusive}`, before any child starts.

The `llm` field is a directive map read by the mock worker `soma_llm_call`:

```erlang
#{
    type    => <<"chat">>,         %% required (envelope field)
    payload => #{...},             %% required (envelope field)
    llm     => #{
        directive  => proposal,    %% proposal | success | slow | crash | hang
        output     => RawProposal, %% for `proposal'/`success': returned verbatim
        timeout_ms => 5000         %% optional; the actor-owned call timeout
    },
    task_id        => <<"task-1">>,  %% optional; minted if absent
    correlation_id => <<"corr-1">>   %% optional; defaults to task_id
}
```

The `directive` selects mock behaviour (this is the single seam
`soma_llm_call:perform_call/1` where a real provider will later slot in):

| `directive` | What the mock does |
|---|---|
| `proposal` | Returns the `output` map verbatim; the actor runs it through `soma_proposal:normalize/1` and the policy gate |
| `success` | Returns the `output` verbatim as **opaque** output (no proposal logic); the task completes with that output as its result |
| `slow` | Blocks past the call timeout — proves the actor's timer (not the worker) enforces the bound; the task reaches `timeout` |
| `hang` | Blocks until killed — models a call in flight when you `cancel/2` it; the task reaches `cancelled` |
| `crash` | Exits abnormally — the crash reaches the actor as the worker monitor's `'DOWN'`; the task reaches `failed` |

`timeout_ms` in the `llm` map is an **actor-owned** call timeout: the actor arms a
timer when it starts the worker and, if the timer fires first, kills the worker
itself (`exit(WorkerPid, kill)` — the bare worker is not a `gen_statem` that can
drive its own teardown). With no `timeout_ms`, no timer is armed and the call
waits indefinitely. The call worker runs in its own process; its pid is reported
on the `llm.started` event as `llm_call_pid` and is distinct from the actor pid.

### Proposals: `soma_proposal:normalize/1`

A proposal is a raw map tagged by a `kind` field. `soma_proposal:normalize/1` is a
pure validate/normalize boundary (like `soma_tool_manifest:normalize/1`) —
no processes, no events:

```erlang
soma_proposal:normalize(Raw).
%% => {ok, Proposal} | {error, [Diagnostic]}
```

The five proposal forms and their required fields:

| `kind` | Required fields | Normalized form |
|---|---|---|
| `reply` | `text` (binary) | `#{kind => reply, text => Text}` |
| `run_steps` | `steps` (list; each step a map with `id` and `tool`) | `#{kind => run_steps, steps => Steps}` |
| `reject` | `reason` (binary) | `#{kind => reject, reason => Reason}` |
| `ask` | `question` (binary) | `#{kind => ask, question => Question}` |
| `actor_message` | `to` (pid), `payload` (map) | `#{kind => actor_message, to => To, payload => Payload}` |

A missing required field, a bad step, or an unknown `kind` returns
`{error, [Diagnostic]}` (each diagnostic a map with `code`, `message`, and the
offending `kind` / `field`). Proposals are **data, not execution** — normalizing a
`run_steps` proposal does not start a run.

When the mock returns a `proposal` directive, the actor decides what to do with
the output:

- a map carrying a `kind` tag is run through `normalize/1`; on success the
  **normalized** proposal becomes the task result and the actor emits
  `proposal.created`; on a normalize error the task is recorded `failed` carrying
  the diagnostics (no `proposal.created`), and the actor stays alive;
- any other output is **opaque** — stored verbatim as the result, no
  `proposal.*` event (this is the `success`-directive contract).

### The policy gate: `tool_policy` / `soma_policy:check/2`

Every normalized proposal gets a verdict from `soma_policy:check/2`, a pure
function over the actor's `tool_policy`:

```erlang
soma_policy:check(Proposal, Policy).
%% => allow | {reject, Reason}
```

The policy is a tool-name allowlist:

```erlang
#{allowed_tools => [echo, file_read]}   %% only these tools allowed
#{allowed_tools => all}                 %% any tool allowed
#{}                                     %% absent key => same as `all'
```

A `run_steps` proposal is allowed only when **every** step's `tool` is in the
allowlist; otherwise the verdict is `{reject, {tools_not_allowed, Disallowed}}`.
The toolless kinds (`reply`, `reject`, `ask`, `actor_message`) carry no tool and
are always allowed. Matching is a plain value comparison with **no
binary↔atom coercion**: an allowlist of `[echo]` (atom) does not allow a step
whose `tool` is `<<"echo">>` (binary). Use the same representation in both.

On `allow` the actor emits `proposal.approved` and sets the task status
`approved`; on `{reject, Reason}` it emits `proposal.rejected` (carrying the
reason), sets the status terminal `rejected`, and starts nothing.

### The decision loop: what an approved proposal does

`approved` is a transient step only for `run_steps`; for everything else the task
moves straight to a terminal status:

- **`run_steps`** → the actor emits `proposal.executed` and starts a `soma_run`
  under `soma_run_sup` that it owns directly (the same machinery the v0.4 `steps`
  path uses). The task tracks the run's outcome: `completed` (with the run's step
  outputs as the result), `failed`, `timeout`, or `cancelled`.
- **`reply` / `reject` / `ask`** → nothing to run, so the task goes straight to
  `completed` with the normalized proposal as its result.
- **`actor_message`** → the actor delivers the proposal's `payload` to the actor
  named by its `to` pid (see "Actor-to-actor messages" below), then the sender
  task reaches `completed` with the proposal as its result.

The v0.4 direct `steps` path is untouched: it runs straight to a run and emits no
`proposal.*` event.

### New task statuses

v0.5 adds `approved` and `rejected` to the status set. The full set
`get_task_status/2` can report: `accepted`, `running`, `approved`, `rejected`,
`completed`, `failed`, `timeout`, `cancelled` (and `not_found` for an unknown
task). A terminal `failed`, `rejected`, or budget-failed task also carries a
`reason` field in the status map.

### Per-task budget

`start_actor` takes an optional `budget` cap, default unlimited:

```erlang
{ok, A} = soma_actor_sup:start_actor(#{
    actor_id    => <<"a1">>,
    model_config => #{},
    tool_policy => #{allowed_tools => [echo]},
    budget      => #{max_llm_calls => 2, max_steps => 5},
    event_store => Store
}).
```

The cap is checked at the actor's two spend points:

- `max_llm_calls` — before starting a call. Once the task's started-call count is
  at the cap (`max_llm_calls => 0` hits this before the first call), the task is
  failed with reason `{budget_exceeded, max_llm_calls}` and no call is made (no
  `llm.started`).
- `max_steps` — before starting a run for an approved `run_steps` proposal. A
  proposal carrying more steps than the cap fails the task with reason
  `{budget_exceeded, max_steps}` and no run is started (no `run.started`).

An absent `budget` key (or an absent dimension) means no cap on that dimension.
Either exhaustion fails the **task** as data — the **actor stays alive** for the
next envelope — and a parked `ask/3` caller is released with `{error, Reason}`
rather than blocking to its timeout.

### Actor-to-actor messages

An approved `actor_message` proposal delivers an envelope to another actor whose
pid is the proposal's `to`. The sender builds a delivery envelope
`#{type => <<"actor.message">>, payload => Payload, correlation_id => CorrelationId}`
stamped with the **sender's** `correlation_id`, and hands it to the target through
the normal `soma_actor:send/2` entry point (fire-and-forget — the sender does not
wait on the receiver's result). The receiver's new task inherits that
`correlation_id`, so `soma_event_store:by_correlation/2` for that one id returns
**both** actors' events. A delivery to a dead receiver is task data, not a sender
crash: the sender task is marked `failed` and the sender stays alive.

### New events

v0.5 adds two event families, both emitted by the actor (which holds the
event-store handle) and both carrying the task's `correlation_id`:

| event_type | Extra fields |
|---|---|
| `<<"llm.started">>` | `task_id`, `correlation_id`, `llm_call_id`, `llm_call_pid` |
| `<<"llm.succeeded">>` | `task_id`, `correlation_id`, `llm_call_id` |
| `<<"llm.failed">>` | `task_id`, `correlation_id`, `llm_call_id` |
| `<<"llm.timeout">>` | `task_id`, `correlation_id`, `llm_call_id` |
| `<<"llm.cancelled">>` | `task_id`, `correlation_id`, `llm_call_id` |
| `<<"proposal.created">>` | `task_id`, `correlation_id`, `llm_call_id`, `kind` |
| `<<"proposal.approved">>` | `task_id`, `correlation_id`, `llm_call_id`, `kind` |
| `<<"proposal.rejected">>` | `task_id`, `correlation_id`, `llm_call_id`, `reason` |
| `<<"proposal.executed">>` | `task_id`, `correlation_id`, `llm_call_id`, `kind` |

For one `llm` envelope carrying a policy-approved `run_steps` proposal, the whole
chain under one `correlation_id` reads:

```text
actor.message.received -> actor.task.accepted -> llm.started -> llm.succeeded
-> proposal.created -> proposal.approved -> proposal.executed -> run.started
-> step.started -> tool.started -> tool.succeeded -> step.succeeded
-> run.completed -> actor.result.created -> actor.task.completed
```

### End-to-end: drive the decision loop in `rebar3 shell`

Start `rebar3 shell`, then:

```erlang
%% 1. Boot the runtime and the actor app (soma_actor declares soma_runtime, so
%%    this one call brings up soma_run_sup and the event store too).
application:ensure_all_started(soma_actor).

%% 2. Locate the running event store so we can query it.
{soma_event_store, Store, _, _} =
    lists:keyfind(soma_event_store, 1, supervisor:which_children(soma_sup)).

%% 3. Start an actor whose policy allows the `echo' tool.
{ok, A} = soma_actor_sup:start_actor(#{actor_id => <<"a1">>,
                                       model_config => #{},
                                       tool_policy => #{allowed_tools => [echo]},
                                       event_store => Store}).

%% 4. Send an `llm' envelope whose mock returns a `run_steps' proposal.
Proposal = #{kind => run_steps,
             steps => [#{id => <<"s1">>, tool => echo,
                         args => #{value => <<"hi">>}}]},
Env = #{type => <<"chat">>, payload => #{text => <<"do it">>},
        task_id => <<"t1">>, correlation_id => <<"c1">>,
        llm => #{directive => proposal, output => Proposal}},
{ok, <<"t1">>} = soma_actor:send(A, Env).

%% 5. The decision loop runs asynchronously. Poll status, then read the result.
soma_actor:get_task_status(A, <<"t1">>).
%% => #{task_id => <<"t1">>, correlation_id => <<"c1">>, status => completed}
soma_actor:get_task_result(A, <<"t1">>).
%% => {ok, #{<<"s1">> => #{value => <<"hi">>}}}   (the run's step outputs)

%% 6. The whole chain, actor + llm + proposal + run events, under one id:
[maps:get(event_type, E) || E <- soma_event_store:by_correlation(Store, <<"c1">>)].
%% => [<<"actor.message.received">>, <<"actor.task.accepted">>, <<"llm.started">>,
%%     <<"llm.succeeded">>, <<"proposal.created">>, <<"proposal.approved">>,
%%     <<"proposal.executed">>, <<"run.started">>, ..., <<"run.completed">>,
%%     <<"actor.result.created">>, <<"actor.task.completed">>]
```

**Policy-reject variant.** Propose a step whose tool is not in the allowlist; the
task ends `rejected` and starts no run:

```erlang
Reject = #{kind => run_steps,
           steps => [#{id => <<"s1">>, tool => sleep, args => #{ms => 1}}]},
REnv = #{type => <<"chat">>, payload => #{text => <<"do it">>},
         task_id => <<"t2">>, correlation_id => <<"c2">>,
         llm => #{directive => proposal, output => Reject}},
{ok, <<"t2">>} = soma_actor:send(A, REnv).
soma_actor:get_task_status(A, <<"t2">>).
%% => #{..., status => rejected, reason => {tools_not_allowed, [sleep]}}
```

**Budget-exceeded variant.** Start an actor with `max_llm_calls => 0`; the `llm`
envelope's task fails before any call is made, and the actor stays alive:

```erlang
{ok, B} = soma_actor_sup:start_actor(#{actor_id => <<"a2">>,
                                       model_config => #{},
                                       tool_policy => #{allowed_tools => [echo]},
                                       budget => #{max_llm_calls => 0},
                                       event_store => Store}).
BEnv = #{type => <<"chat">>, payload => #{text => <<"do it">>},
         task_id => <<"t3">>, correlation_id => <<"c3">>,
         llm => #{directive => proposal,
                  output => #{kind => reply, text => <<"hi">>}}},
{ok, <<"t3">>} = soma_actor:send(B, BEnv).
soma_actor:get_task_status(B, <<"t3">>).
%% => #{..., status => failed, reason => {budget_exceeded, max_llm_calls}}
true = is_process_alive(B).
```

The full v0.5 process-behaviour proofs — each property mapped to the suite and
case that proves it — are in
[contracts/v0.5-test-contract.md](contracts/v0.5-test-contract.md).

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
