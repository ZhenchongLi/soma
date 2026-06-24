# [cc] v0.4: soma_actor runs a steps envelope through soma_run, records result (P3, P4)

## Current state

After slice 4 (#60, merged) `soma_actor` accepts work but does nothing with it.
`send/2` validates the envelope, mints a `task_id` and `correlation_id`, records
the task in `#data.tasks` with status `accepted`, and emits
`actor.message.received` and `actor.task.accepted` from `idle/3`. Then it stops.
The envelope's `steps` are ignored. No run is ever started.

The run side is already complete and is the thing we want to drive. `soma_run`
runs a step list to a terminal state and, on completion, sends
`{run_completed, RunId, Outputs}` to whatever pid was passed as `session_pid`
(see `notify_session/1` in `soma_run.erl`). `soma_run_sup:start_run/1` starts a
run under a `simple_one_for_one` supervisor from an opts map. `soma_agent_session`
is the only current caller: it mints a `run_id`, sets `session_pid => self()`,
and reads the terminal message in its own `handle_info`.

The actor does not go through `soma_agent_session`. The v0.4 decision is that the
actor owns its runs directly. Nothing in the actor path starts a session today,
and `soma_runtime` has no reference to `soma_actor` (proven by the static scans in
`soma_actor_app_tests`). This slice keeps that one-way dependency.

## Approach

When an accepted envelope carries a `steps` list, the actor starts a `soma_run`
itself and becomes that run's owner. The actor passes `session_pid => self()`, so
the run's existing terminal message lands in the actor's own mailbox. No change to
`soma_run`, `soma_run_sup`, or `soma_agent_session` in this slice.

Run start. In `idle/3`, after recording the task and emitting the two acceptance
events, the actor checks the envelope for `steps`. If present and a list, it mints
a `run_id` the same way `soma_agent_session` does (`run-` plus a monotonic unique
integer) and calls `soma_run_sup:start_run/1` with an opts map carrying:

- `run_id` — the freshly minted id
- `session_id` — set to the actor's `actor_id`
- `session_pid` — `self()`, so the actor receives `{run_completed, ...}`
- `event_store` — the actor's event store
- `steps` — the list from the envelope
- `correlation_id` — the task's correlation id

`soma_run` ignores `correlation_id` today. Passing it is preparation for slice 7,
which will stamp run events without touching this call site. We do not modify
`soma_run` to read it now.

The actor tracks the run so it can map the terminal message back to the task. It
keeps a `run_id => task_id` map in `#data`. `send/2` still replies `{ok, TaskId}`
right away — the run start is fire-and-forget, the actor never blocks on the run.

Completion. The actor handles `{run_completed, RunId, Outputs}` as a `gen_statem`
info event in `idle`. It looks up the `task_id` for `RunId`, stores `Outputs` as
that task's result, sets the task status to `completed`, and emits
`actor.result.created` then `actor.task.completed`. Each event carries `actor_id`,
`task_id`, and `correlation_id`, read from the recorded task.

No steps. An envelope with no `steps` key keeps the slice-4 behavior exactly:
record the task, emit the two acceptance events, start no run. The task stays at
status `accepted`.

Not crashing on failure-path messages. Failure, timeout, and cancel handling is
slice 8. This slice only has to make sure a `run_failed`, `run_timeout`, or
`run_cancelled` message does not crash the actor if one arrives. The `idle/3`
catch-all info clause already returns `{keep_state, Data}` for any unmatched
message, so these fall through untouched. The design keeps that catch-all so a
failure-path terminal message is a no-op, not a `function_clause` crash.

Why `session_id => actor_id`. The run emits its trail (`run.started` …
`run.completed`) scoped to `session_id`. Setting it to the `actor_id` means the
run's events are readable by `by_session(Store, ActorId)`, and the actor's own
events already carry the same `actor_id`. There is no session in the path; the
field is just reused as the run's owner id.

## Acceptance criteria → tests

The actor needs the runtime's `soma_run_sup` and `soma_tool_registry` alive to
start a real run, so the new cases boot `soma_runtime` (for the run side) and
start the actor through `soma_actor_sup:start_actor/1`. They pass the booted
runtime's event store into the actor's opts so the actor and the run write to the
same store. New cases live in `apps/soma_actor/test/soma_actor_SUITE.erl`
alongside the slice-4 cases.

### Criterion 1 — valid steps start a run under soma_run_sup with a distinct pid
- Call chain: soma_actor:send/2 → gen_statem:call → soma_actor:idle/3 ({call,From} clause) → soma_run_sup:start_run/1 → supervisor:start_child → soma_run:start_link
- Test entry: soma_actor:send/2 (the real synchronous entry, no layer bypassed)
- Test: `run_started_under_run_sup_distinct_pid` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 2 — demo steps run to run.completed with the normal event trail
- Call chain: soma_actor:send/2 → soma_actor:idle/3 → soma_run_sup:start_run/1 → soma_run executes steps → emits run.started … run.completed into the event store
- Test entry: soma_actor:send/2; the trail is then read back from the booted runtime's event store with by_run/2
- Test: `run_completes_with_run_event_trail` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 3 — actor pid, run pid, tool-call worker pid are all distinct
- Call chain: soma_actor:send/2 → soma_actor:idle/3 → soma_run_sup:start_run/1 → soma_run → soma_tool_call (spawned worker)
- Test entry: soma_actor:send/2; after the run completes the test reads the run pid from soma_run_sup's children and the worker pid from the tool.started event, then asserts actor pid, run pid, and worker pid are three distinct pids
- Test: `actor_run_worker_pids_all_distinct` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 4 — completion emits actor.result.created with the three ids
- Call chain: soma_run finishes → {run_completed, RunId, Outputs} delivered to actor mailbox → soma_actor:idle/3 (info clause) → emit actor.result.created
- Test entry: soma_actor:send/2 starts the run; the test waits for the actor.result.created event in the store, then asserts it carries actor_id, task_id, correlation_id
- Test: `result_created_event_carries_ids` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 5 — completion emits actor.task.completed with the three ids
- Call chain: soma_run finishes → {run_completed, RunId, Outputs} → soma_actor:idle/3 (info clause) → emit actor.task.completed
- Test entry: soma_actor:send/2 starts the run; the test waits for the actor.task.completed event, then asserts it carries actor_id, task_id, correlation_id
- Test: `task_completed_event_carries_ids` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 6 — task status is completed after the run
- Call chain: soma_run finishes → {run_completed, RunId, Outputs} → soma_actor:idle/3 (info clause) → task status set to completed in #data.tasks
- Test entry: soma_actor:send/2 starts the run; after the actor processes the terminal message the test reads #data.tasks through sys:get_state/1 and asserts the task's status is completed
- Test: `task_status_completed_after_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 7 — task result holds the run Outputs after the run
- Call chain: soma_run finishes → {run_completed, RunId, Outputs} → soma_actor:idle/3 (info clause) → Outputs stored as the task's result in #data.tasks
- Test entry: soma_actor:send/2 starts the run; after the terminal message is processed the test reads #data.tasks through sys:get_state/1 and asserts the task's stored result equals the run's Outputs (the single step's recorded output)
- Test: `task_result_holds_outputs_after_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 8 — send/2 returns before the run completes, actor stays alive
- Call chain: soma_actor:send/2 → soma_actor:idle/3 → soma_run_sup:start_run/1 (returns), reply {ok, TaskId} sent before any {run_completed, ...} arrives
- Test entry: soma_actor:send/2; the test uses a step that sleeps so the run is still running when send/2 returns, asserts the task is still accepted (not yet completed) right after the reply, asserts the actor pid stays alive, then waits and confirms it becomes completed
- Test: `send_returns_before_run_completes` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 9 — a second steps envelope starts a second run
- Call chain: soma_actor:send/2 (first) → run completes → soma_actor:send/2 (second) → soma_actor:idle/3 → soma_run_sup:start_run/1 a second time
- Test entry: soma_actor:send/2 called twice on the same actor; the test waits for the first run to complete, sends a second valid-steps envelope, asserts it returns {ok, TaskId2} and that a second run reaches run.completed for a distinct run id
- Test: `second_steps_envelope_starts_second_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 10 — no steps means accept the task and start no run
- Call chain: soma_actor:send/2 → soma_actor:idle/3 ({call,From} clause, steps absent → no start_run/1 call)
- Test entry: soma_actor:send/2 with an envelope that has no steps; the test asserts {ok, TaskId}, then asserts soma_run_sup has zero run children, and the task stays at status accepted
- Test: `no_steps_accepts_and_starts_no_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 11 — rebar3 eunit && rebar3 ct is green
- Call chain: none (build/test-suite gate)
- Test entry: the full suite run; no single test function — the merge gate runs both
- Test: whole-suite run of `rebar3 eunit && rebar3 ct`

## Risks & trade-offs

The new actor cases depend on the runtime being booted, so the actor suite now
boots `soma_runtime` for these cases. That couples the actor test setup to the
runtime app even though the actor source still has no compile-time dependency on
it. This matches how the run happy-path suite already boots the whole runtime, so
it is the established pattern, but it does mean an actor test failure can now be
caused by a runtime regression.

The completion-path cases are timing-dependent: the run finishes asynchronously
and the actor records the result when the terminal message arrives. The tests poll
the event store and `sys:get_state/1` with a bounded retry, the same
`wait_for_*` pattern the run happy-path suite uses. A poll that is too short would
flake; the bound has to be generous enough for a real run plus message delivery.

Reusing `session_id` to carry the `actor_id` is a small overload of a field named
for a concept that is not in the path. It keeps `soma_run` unchanged and makes the
run's events queryable under the actor's id, but a reader of the run events sees a
`session_id` that is really an actor id. This is a deliberate v0.4 choice, not an
accident, and it is the reason the run trail is readable by `by_session(Store,
ActorId)`.

Passing `correlation_id` into the run opts when `soma_run` ignores it looks like
dead data today. It is forward-prep for slice 7. The cost is one map key that has
no effect yet; the benefit is slice 7 not having to touch the actor's call site.
