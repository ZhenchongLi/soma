# [cc] v0.4: soma_actor ask/reply + task status/result polling (P5, P6)

## Current state

After slice p3/p4 (#62, merged) the actor runs a steps envelope to completion but
gives the caller no way to read the answer back.

`send/2` is the only entry point. It validates the envelope, records the task in
`#data.tasks` at status `accepted`, emits the two acceptance events, and for a
steps envelope starts a `soma_run` owned by the actor (`session_pid => self()`).
It replies `{ok, TaskId}` right away and does not wait for the run.

When the run finishes, `{run_completed, RunId, Outputs}` lands in the actor
mailbox and is handled by the `idle(info, ...)` clause. The actor looks up the
task for that run, sets the task to `status => completed, result => Outputs`, and
emits `actor.result.created` then `actor.task.completed`.

So the result already lives in `#data.tasks` keyed by `task_id`. What is missing:

- The caller has the `task_id` from `send/2` but no function to read the task by
  it. The CT suite reaches into the task table with `sys:get_state/1` and pokes
  `element(6, Data)`. That is a test crutch, not an API.
- A steps task reads `accepted` for its whole run. `maybe_start_run` records
  `accepted` and never moves it to a running state, so a poller cannot tell a
  task that is still working from a no-steps task that will never run.
- There is no synchronous "submit and get the answer" call. `send/2` is the only
  way in, and it always returns before the run completes.

## Approach

Add three read functions over the task table the actor already keeps. None of
them changes how runs execute, and none bypasses the actor — all three enter
through the actor mailbox or read state the actor owns.

### `ask/3` — submit and block for the result

`ask(ActorRef, Envelope, TimeoutMs) -> {ok, Result} | {error, Reason} | timeout`.

`ask` is a `gen_statem:call` carrying `{ask, Envelope}` with the caller's
`TimeoutMs`. The actor handles it in `idle` almost like `send`: validate the
envelope, record the task, emit the acceptance events, start the run for a steps
envelope. The one difference is the reply is deferred. Instead of replying
`{ok, TaskId}` straight away, the actor stashes the caller's `From` against the
task and returns `keep_state` with no reply. The caller stays parked inside its
`gen_statem:call`.

Storing `From`: a parallel map in `#data` keyed by `task_id` (call it `waiters`).
Keeping it out of the task entry means the task map stays the plain
`#{correlation_id, status, result}` shape the existing tests read by position.

When `{run_completed, RunId, Outputs}` arrives, the actor does what it does today
(record the result, emit the two events) and then, if a `From` is waiting on that
task, replies `{ok, Outputs}` to it and drops the waiter. A `send`-started task
has no waiter, so that branch is skipped and `send` behaves exactly as before.

The actor never blocks. `ask` blocks the *caller* through its `gen_statem:call`.
The actor records `From`, starts the run, and goes back to its mailbox, so a
second `send`, a second `ask`, or a `get_task_status` is served while the first
run is still going.

Caller timeout. `TimeoutMs` is the `gen_statem:call` timeout. If it fires before
the run completes, the call returns `timeout` on the caller side. The actor is
unaware — it still has the parked `From` and still finishes the task. When the
run finally completes the actor replies to a `From` whose caller has already given
up. A reply to a dead `gen_statem:call` reference is dropped by the runtime, so
the late reply is harmless and the actor stays alive.

An invalid envelope under `ask` replies `{error, Reason}` straight away, the same
rejection `send` does, and starts no run and parks no waiter.

This slice covers the completion path only. A run that fails, times out, or is
cancelled is slice 8 — if such a terminal message arrives, the actor still must
not crash, and the `idle` catch-all info clause already absorbs it. A waiter
parked on a task whose run fails stays parked until its `TimeoutMs` fires and the
call returns `timeout`. That is acceptable for this slice; slice 8 wires the
failure reply.

### Task moves to `running` when its run starts

`maybe_start_run` records the task at `accepted` and then starts the run. This
slice sets the task to `status => running` at the point the run is started, so a
steps task reads `running` between acceptance and completion. A no-steps envelope
starts no run, so its task stays `accepted`. The acceptance events still carry the
moment of acceptance; the status field is what moves to `running`.

### Polling reads

`get_task_status(ActorRef, TaskId)` is a `gen_statem:call` returning a map with
`task_id`, `correlation_id`, and `status`. For a known task it reads the entry
from `#data.tasks` and shapes the map. For an unknown `task_id` it returns the
not-found shape below.

`get_task_result(ActorRef, TaskId) -> {ok, Result} | not_ready | {error, not_found}`.
A completed task returns `{ok, Result}` from its stored `result`. A task that has
not completed returns `not_ready`. An unknown task returns the not-found shape.

Not-found shape. The issue's open question leaves the exact term to the
implementer and only requires both reads agree. The choice here:
`get_task_result/2` returns `{error, not_found}` and `get_task_status/2` returns a
map with `status => not_found` (keeping its map return type stable for known and
unknown tasks alike). The test asserts both reads report not-found for the same
unknown id and that the actor survives the pair of calls; it does not pin the two
to an identical term, since their return types already differ for the found case.

Both polling calls and `ask` enter through the actor mailbox. The actor handles
them in `idle` and replies in the same callback, so they never wait on a run and
return promptly even while another task's run is in flight.

## Acceptance criteria → tests

All new cases live in `apps/soma_actor/test/soma_actor_SUITE.erl`. The steps cases
boot `soma_runtime` (for `soma_run_sup` and `soma_tool_registry`) and start the
actor through `soma_actor_sup:start_actor/1` with the booted runtime's event
store, the same fixture the slice p3/p4 cases use. A fast `echo` step proves
completion; a `sleep` step holds a task in `running` for the "before it completes"
reads.

### Criterion 1 — ask returns the run's outputs
- Call chain: caller → `soma_actor:ask/3` → `gen_statem:call({ask, Envelope})` →
  `soma_actor:idle({call, From}, {ask, _}, _)` → `maybe_start_run` →
  `soma_run_sup:start_run` → run executes → `{run_completed, RunId, Outputs}` →
  `soma_actor:idle(info, {run_completed, ...}, _)` → reply `{ok, Outputs}` to the
  parked `From`
- Test entry: `soma_actor:ask/3` (no layer bypassed)
- Test: `ask_returns_run_outputs` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 2 — caller and actor both alive after ask
- Call chain: same as criterion 1, then `is_process_alive/1` on the caller (self)
  and the actor pid
- Test entry: `soma_actor:ask/3` (no layer bypassed)
- Test: `ask_caller_and_actor_alive_after_return` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 3 — ask reply arrives only after the run completes
- Call chain: same as criterion 1, with a `sleep` step so the run is in flight
  when `ask` is issued; the reply cannot arrive before `{run_completed, ...}`
- Test entry: `soma_actor:ask/3` (no layer bypassed)
- Test: `ask_reply_matches_completed_run` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 4 — short timeout returns timeout
- Call chain: caller → `soma_actor:ask/3` with `TimeoutMs` shorter than the
  `sleep` step → `gen_statem:call` times out on the caller side → returns
  `timeout`
- Test entry: `soma_actor:ask/3` (no layer bypassed)
- Test: `ask_short_timeout_returns_timeout` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 5 — actor survives the timeout and still completes the task
- Call chain: criterion 4's timed-out `ask`, then poll the task table until the
  `sleep` run completes and the task reaches `completed`; `is_process_alive/1` on
  the actor pid throughout
- Test entry: `soma_actor:ask/3` then `soma_actor:get_task_status/2` (no layer
  bypassed)
- Test: `ask_timeout_actor_survives_and_completes` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 6 — invalid envelope returns error and starts no run
- Call chain: caller → `soma_actor:ask/3` with an invalid envelope →
  `soma_actor:idle({call, From}, {ask, _}, _)` → `validate_envelope` fails →
  reply `{error, Reason}`; then read `soma_run_sup` children to confirm zero runs
- Test entry: `soma_actor:ask/3` (no layer bypassed)
- Test: `ask_invalid_envelope_errors_no_run` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 7 — status is running while the run is in flight
- Call chain: caller → `soma_actor:send/2` with a `sleep` step → run started,
  task set to `running`; then caller → `soma_actor:get_task_status/2` →
  `soma_actor:idle({call, From}, {get_task_status, _}, _)` → reply map with
  `status => running`
- Test entry: `soma_actor:get_task_status/2` (no layer bypassed)
- Test: `get_task_status_running_before_completion` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 8 — status is completed after run_completed
- Call chain: caller → `soma_actor:send/2` with an `echo` step → run reaches
  `{run_completed, ...}` → task set to `completed`; then
  `soma_actor:get_task_status/2` → reply map with `status => completed`
- Test entry: `soma_actor:get_task_status/2` (no layer bypassed)
- Test: `get_task_status_completed_after_run` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 9 — a send-started task is queryable by its returned task_id
- Call chain: caller → `soma_actor:send/2` returns `{ok, TaskId}`; then
  `soma_actor:get_task_status/2` with that exact `TaskId` →
  `soma_actor:idle({call, From}, {get_task_status, _}, _)` → reply map carrying
  the same `task_id`
- Test entry: `soma_actor:get_task_status/2` (no layer bypassed)
- Test: `get_task_status_queryable_by_send_task_id` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 10 — get_task_result is not_ready before completion
- Call chain: caller → `soma_actor:send/2` with a `sleep` step → run in flight;
  then `soma_actor:get_task_result/2` →
  `soma_actor:idle({call, From}, {get_task_result, _}, _)` → reply `not_ready`
- Test entry: `soma_actor:get_task_result/2` (no layer bypassed)
- Test: `get_task_result_not_ready_before_completion` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 11 — get_task_result returns the outputs after completion
- Call chain: caller → `soma_actor:send/2` with an `echo` step → run reaches
  `{run_completed, RunId, Outputs}` → result stored; then
  `soma_actor:get_task_result/2` → reply `{ok, Outputs}`
- Test entry: `soma_actor:get_task_result/2` (no layer bypassed)
- Test: `get_task_result_ok_outputs_after_completion` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 12 — both reads agree on not-found for an unknown id, actor survives
- Call chain: caller → `soma_actor:get_task_status/2` and
  `soma_actor:get_task_result/2` with an id that was never accepted → each replies
  its not-found shape; `is_process_alive/1` on the actor pid after the pair
- Test entry: `soma_actor:get_task_status/2` and `soma_actor:get_task_result/2`
  (no layer bypassed)
- Test: `unknown_task_id_not_found_both_reads_actor_alive` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 13 — a second read returns promptly while an earlier run is in flight
- Call chain: caller → `soma_actor:send/2` with a `sleep` step → run in flight;
  then caller → `soma_actor:get_task_status/2` (or a second `send/2`) →
  `soma_actor:idle` replies in the same callback without waiting on the run
- Test entry: `soma_actor:get_task_status/2` (no layer bypassed); the test asserts
  the call returns while the first task is still `running`
- Test: `read_returns_while_earlier_run_in_flight` in
  `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 14 — eunit and ct green
- Call chain: none (build gate)
- Test entry: `rebar3 eunit && rebar3 ct`
- Test: the full suite run, not a single case

## Risks & trade-offs

A waiter parked on a task whose run fails or times out is not replied to in this
slice — it sits until the caller's `TimeoutMs` fires and the call returns
`timeout`. That reads as a timeout even though the cause was a failed run. Slice 8
adds the failure reply; until then a failed-run `ask` cannot distinguish a slow
run from a dead one. This slice's criteria only cover the completion path, so the
gap is in scope to leave open, but it is a real rough edge.

The two not-found return types differ on purpose: `get_task_status/2` keeps a map
return for known and unknown ids, while `get_task_result/2` returns
`{error, not_found}` to match its `{ok, Result} | not_ready` shape. They agree
that the id is unknown but they do not return an identical term. The test asserts
agreement on the not-found fact, not term equality. If a caller wants one literal
term from both, this choice does not give it.

A late reply to a timed-out `ask` relies on the BEAM dropping a reply to a stale
`gen_statem:call` reference. That is standard `gen_statem` behaviour, not a trick,
but it does mean the actor sends a reply into the void after a timeout. It costs
one message send and nothing else.
