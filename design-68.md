# [cc] v0.4: actor survives run failure + tool crash, stays responsive (P8, P9, P15)

## Current state

`soma_actor` is a `gen_statem` in `state_functions` mode with a single state, `idle`. When a steps envelope arrives through `send/2` or `ask/3`, `maybe_start_run/4` starts a `soma_run` under `soma_run_sup`, records `run_id => task_id` in `#data.runs`, and flips the task to `running`. The run is started under its own supervisor and is not linked to the actor, so a run death never reaches the actor as a signal. The actor learns the outcome from a message.

Today only the success message is handled. `idle(info, {run_completed, RunId, Outputs}, Data)` looks the run up in `#data.runs`, sets the task to `completed` with the outputs, emits `actor.result.created` and `actor.task.completed`, and replies to any parked `ask/3` waiter through `reply_waiter/3`.

`soma_run` already sends the two failure messages. `notify_session_failed/2` sends `{run_failed, RunId, Reason}` and `notify_session_timeout/1` sends `{run_timeout, RunId}` (`soma_run.erl` lines 305-317). Both are emitted from the run's terminal handlers: `fail_run/5` covers an `{error, _}` tool return and a worker-crash `'DOWN'` alike, and the `state_timeout` clause covers a per-step timeout.

The gap is on the actor side. `{run_failed, ...}` and `{run_timeout, ...}` both fall through `idle(_EventType, _Event, Data) -> {keep_state, Data}` and are dropped. The task is left stuck at `running` forever, and a parked `ask/3` `From` is never answered, so the caller hangs until its own `TimeoutMs` fires. The actor stays alive but the failed run leaves the task table and any waiter in a broken state.

## Approach

Add two `info` clauses to `idle/3`, both above the catch-all, both following the exact shape of the existing `run_completed` clause.

`idle(info, {run_failed, RunId, Reason}, Data)`:
- Look `RunId` up in `#data.runs`. An unknown run id keeps state and drops the message, matching the `run_completed` guard.
- Read the task and its `correlation_id`.
- Set the task to `#{status => failed, reason => Reason}`. We do not set a `result` key, so `get_task_result/2` keeps returning `not_ready` for a failed task — there is no result to hand back.
- Emit `actor.task.failed` carrying `actor_id` (added by `emit/3`), `task_id`, `correlation_id`, and `reason`.
- Reply to a parked `ask/3` waiter with `{error, Reason}`, then drop the waiter. A `send/2`-started task has no waiter, so this is a no-op for it.

`idle(info, {run_timeout, RunId}, Data)`:
- Same run lookup and task read.
- Set the task to `#{status => failed, reason => timeout}`.
- Emit `actor.task.failed` with `reason => timeout`.
- Reply to a parked waiter with `{error, timeout}`.

I fold timeout into the same `failed` task status with `reason => timeout` rather than inventing a separate `timedout` status. The criteria ask for an `actor.task.failed` event on timeout and for the task table to read `failed` after a failure; reason is what distinguishes the two. The run keeps its own distinct terminal states (`failed` vs `timeout`) — that distinction lives in the run's event trail, not in the actor's one-line task status.

The waiter reply needs a small refactor. `reply_waiter/3` today hardcodes `{ok, Outputs}`. I generalize it to take the reply term, so the success path passes `{ok, Outputs}` and the two failure paths pass `{error, Reason}` / `{error, timeout}`. The non-timeout failure reply stays `{error, Reason}` to match the existing invalid-envelope reply from `ask/3`. For the open question, I pick `{error, timeout}` (not bare `timeout`) for the parked-waiter timeout reply, so both deferred-failure replies share the `{error, _}` shape; the criterion accepts either.

`reason` is whatever `soma_run` put in the `{run_failed, ...}` message. For the `fail` tool in error mode that is the tool's `Reason` (default the atom `failed`). For crash mode it is the raw crash reason from the worker's `'DOWN'`. The actor stores it as-is and does not interpret it.

No new state, no link to the run, no `try/catch`. The failure arrives as an ordinary mailbox message and is handled in `idle`, which is the whole point of P8/P9: isolation is the process boundary plus the message, not defensive code in the actor.

P15 (the actor stays responsive while a run is in flight) needs no new code — the existing `get_task_status/2` clause already serves reads from `idle` without blocking on the child run. The slice adds a test that pins it for the failure-adjacent case, but the behavior is already there.

## Acceptance criteria → tests

All new tests go in `apps/soma_actor/test/soma_actor_SUITE.erl` and are added to `all/0` and the runtime-booting `init_per_testcase`/`end_per_testcase` clause groups (the same group that boots `soma_runtime` for the existing steps tests). Each enters through the real `soma_actor:send/2` or `soma_actor:ask/3` call with the actor started through `soma_actor_sup:start_actor/1` and sharing the booted runtime's event store, so no layer is bypassed.

### Criterion 1 — failed run emits actor.task.failed with ids and reason
- Call chain: `soma_actor:send/2` → `idle({call,From},{send,_})` → `maybe_start_run` → `soma_run_sup:start_run` → `soma_run` runs the `fail` (error mode) step → `fail_run` → `notify_session_failed` sends `{run_failed,...}` → `idle(info,{run_failed,...})` → `emit(actor.task.failed)`
- Test entry: `soma_actor:send/2` (no layer bypassed); the event is read back from the shared store
- Test: `failed_run_emits_task_failed_event` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 2 — failed task reads `failed` in the task table
- Call chain: `soma_actor:send/2` → run fails → `{run_failed,...}` → `idle(info,{run_failed,...})` sets task status `failed`
- Test entry: `soma_actor:send/2`; the status is polled from the task table through `sys:get_state/1` (element 6), the same read the existing steps tests use because there is no failed-status read function
- Test: `failed_run_sets_task_status_failed` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 3 — actor pid alive after a run it owns fails
- Call chain: `soma_actor:send/2` → run fails → `{run_failed,...}` → `idle(info,{run_failed,...})`
- Test entry: `soma_actor:send/2`, then `is_process_alive/1` on the actor pid after the task reaches `failed`
- Test: `actor_alive_after_owned_run_fails` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 4 — tool crash reaches the actor as a message, three pids distinct
- Call chain: `soma_actor:send/2` → `soma_run` runs the `fail` (crash mode) step → worker raises → run's worker-monitor `'DOWN'` → `fail_run` → `{run_failed,...}` → `idle(info,{run_failed,...})`
- Test entry: `soma_actor:send/2`. The actor pid is the call target; the run pid is read from `soma_run_sup`'s children and the worker pid from the run's `tool.started` event (reusing `worker_pid_from_tool_started/2`). All three are asserted distinct and the actor pid alive — the crash arrived as a message, not a signal
- Test: `tool_crash_isolated_by_process_boundary` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 5 — ask/3 whose run fails returns `{error, Reason}`, actor alive
- Call chain: `soma_actor:ask/3` → `idle({call,From},{ask,_})` parks `From` → run fails → `{run_failed,...}` → `idle(info,{run_failed,...})` → `reply_waiter` replies `{error,Reason}`
- Test entry: `soma_actor:ask/3` with a `TimeoutMs` long enough that the failure (not the caller timeout) ends the call; then `is_process_alive/1` on the actor pid
- Test: `ask_failed_run_returns_error` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 6 — timed-out run emits actor.task.failed with reason `timeout`
- Call chain: `soma_actor:send/2` → `soma_run` runs a `sleep` step past its per-step `timeout_ms` → `state_timeout` handler → `notify_session_timeout` sends `{run_timeout,...}` → `idle(info,{run_timeout,...})` → `emit(actor.task.failed, reason=>timeout)`
- Test entry: `soma_actor:send/2`; the event is read back from the shared store and its `reason` asserted to be `timeout`
- Test: `timed_out_run_emits_task_failed_timeout` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 7 — ask/3 whose run times out returns `{error, timeout}`, actor alive
- Call chain: `soma_actor:ask/3` parks `From` → run times out → `{run_timeout,...}` → `idle(info,{run_timeout,...})` → `reply_waiter` replies `{error,timeout}`
- Test entry: `soma_actor:ask/3` with a `TimeoutMs` longer than the step's `timeout_ms`, so the run timeout (not the caller timeout) ends the call; then `is_process_alive/1` on the actor pid. (Dev pins `{error, timeout}`; the criterion also accepts bare `timeout`.)
- Test: `ask_timed_out_run_returns_error_timeout` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 8 — get_task_status returns `running` promptly while run in flight
- Call chain: `soma_actor:send/2` (starts a long `sleep` step) → `soma_actor:get_task_status/2` → `idle({call,From},{get_task_status,_})`
- Test entry: `soma_actor:send/2` then `soma_actor:get_task_status/2`. The read returning inside the call's default timeout is the promptness proof; the `running` status confirms the run was still in flight. This overlaps the existing `read_returns_while_earlier_run_in_flight`; the new case states P15 against this slice's failure context but reuses the same read path
- Test: `status_running_promptly_while_run_in_flight` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 9 — after a failed run, a new envelope runs to completed
- Call chain: `soma_actor:send/2` (fail step) → run fails → `{run_failed,...}` recorded → second `soma_actor:send/2` (echo step) → second run → `{run_completed,...}` → task `completed`
- Test entry: two `soma_actor:send/2` calls on the same actor pid; the second run id is read from `#data.runs` by task id (reusing `run_id_for_task/2`) and its trail polled to `run.completed`, then the second task asserted `completed`
- Test: `new_run_completes_after_failed_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 10 — after a timed-out run, a new envelope runs to completed
- Call chain: `soma_actor:send/2` (sleep-past-timeout step) → run times out → `{run_timeout,...}` recorded → second `soma_actor:send/2` (echo step) → second run → `{run_completed,...}` → task `completed`
- Test entry: two `soma_actor:send/2` calls on the same actor pid; same second-run read-and-poll as criterion 9
- Test: `new_run_completes_after_timed_out_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 11 — `rebar3 eunit && rebar3 ct` is green
- Call chain: none (gate run over the whole suite)
- Test entry: the merge gate runs both commands; this is the existing suite plus the ten cases above
- Test: the full `rebar3 eunit && rebar3 ct` run

## Risks & trade-offs

Folding timeout into `status => failed` with `reason => timeout` means a caller reading the task table can't tell a timeout from a tool failure by status alone — it has to look at `reason`. That is a deliberate narrowing: the criteria only ask for `failed` in the table and `timeout` as the event reason, and the run's own event trail keeps the finer `failed`/`timeout` distinction. If a later slice needs a distinct task-level `timedout` status, it adds one then.

The crash-mode `reason` the actor stores is the raw worker crash reason, whose exact shape is set by `soma_run`'s `'DOWN'` handling, not by this slice. The tests assert the actor records *a* reason and stays alive, not a specific crash term, so they don't pin a shape this slice doesn't own.

Slice 9 adds `{run_cancelled, ...}` handling. The two clauses added here sit above the `idle` catch-all and key on their own message tags, so the cancelled clause slots in beside them without conflict. The shared `reply_waiter/3` generalization (taking a reply term) is what slice 9's cancel reply will reuse.
