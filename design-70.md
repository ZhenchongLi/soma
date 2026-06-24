# [cc] v0.4: cancel task cancels active run + consolidated recovery (P10, P11)

## Current state

`soma_actor` (`apps/soma_actor/src/soma_actor.erl`) starts runs, records their
outcomes, and survives a run that fails or times out. It handles three terminal
messages as `info` events — `{run_completed, RunId, Outputs}`,
`{run_failed, RunId, Reason}`, and `{run_timeout, RunId}` — looking the run up in
its `runs` map (`run_id => task_id`), flipping the task's status, emitting the
matching `actor.*` event, and replying to a parked `ask` waiter.

Two things are missing.

There is no `cancel/2` entry point. A caller has no way to ask the actor to stop
a task that is in flight.

A `{run_cancelled, RunId}` message has nowhere to land. `soma_run` already sends
it on the cancel path, but in the actor it falls through the
`idle(_EventType, _Event, Data) -> {keep_state, Data}` catch-all at the bottom of
`idle/3` and does nothing. So even if a run were cancelled, the task would stay
`running` forever and an `ask` waiter would hang.

The run side is already done. `soma_run`'s `waiting_tool(info, cancel, ...)`
kills the active worker with a brutal kill, emits `run.cancelled`, moves to the
`cancelled` terminal state, and calls `notify_session_cancelled/1`, which sends
`{run_cancelled, RunId}` to whatever pid is in `session_pid`. The actor sets
`session_pid => self()` when it starts a run, so that message already comes back
to the actor. This is the same shape `soma_agent_session` uses: its
`{cancel_run, RunId}` handler looks up the run pid and sends it `cancel`, and its
`{run_cancelled, RunId}` handler records the cancellation. The out-of-scope note
in the issue confirms `soma_run` needs no change.

The blocker for the actor is that it can't reach the run pid. `maybe_start_run/4`
gets `{ok, RunPid}` back from `soma_run_sup:start_run/1` and binds it to
`_RunPid`, throwing it away. It stores only `run_id => task_id` in the `runs`
map. To send `cancel` to the run, the actor has to keep the run pid.

## Approach

Track the run pid per task, add `cancel/2`, and handle `{run_cancelled, RunId}`.

**Keep the run pid.** Today the task table (`tasks`, `task_id => #{...}`) holds
the per-task fields and the `runs` map holds `run_id => task_id`. The run pid
belongs with the task, because cancel starts from a `task_id`. So `maybe_start_run`
puts `run_id` and `run_pid` into the task map it already updates, and leaves the
`runs` map as `run_id => task_id` untouched. That keeps the completion, failure,
and timeout handlers working unchanged — they still look a run up by `RunId` in
`runs` to find the `TaskId`. Cancel goes the other direction: from `task_id` to
the task map to the `run_pid`. The two lookups don't collide.

**`cancel/2` is a synchronous call.** `cancel(ActorRef, TaskId)` is a
`gen_statem:call` that runs inside `idle/3`, so the actor is never bypassed. The
handler looks up the task. If the task is unknown it replies `{error, not_found}`.
If the task has no live run — already completed, failed, cancelled, or a no-steps
task — it replies `{error, not_running}`. The issue's open question leaves these
atoms to Dev; the criteria only assert `{error, Reason}` and that the actor
survives, so these are the working choices and can change. When there is a live
run, the actor sends the atom `cancel` to the run pid and replies `ok`. The actor
never kills the worker itself — that crosses a process boundary, which is the
whole design. The reply to the cancel caller is `ok` for "cancel requested", not
"cancel finished"; the run reports back later with `{run_cancelled, RunId}`.

**Handle `{run_cancelled, RunId}`.** Mirror the three existing terminal-message
handlers. Look the run up in `runs` to get the `TaskId`. If it's not there, keep
state (the same defensive no-op the other three handlers use). Otherwise flip the
task to `cancelled`, emit `actor.task.cancelled` carrying `actor_id`, `task_id`,
and `correlation_id`, and reply to any parked `ask` waiter with `{error, cancelled}`
through the existing `reply_waiter/3`. That last part is what stops a cancelled
`ask` from hanging — the waiter is parked in `idle({call,From},{ask,...})` and
gets answered the same way the completed and failed paths answer it.

The status flip and the worker death are observable through the shared event
store and `sys:get_state/1`, which is what the existing actor tests already lean
on. No new observation machinery is needed.

## Acceptance criteria → tests

### Criterion 1 — cancel drives a parked run to `cancelled` with a `run.cancelled` event
- Call chain: `soma_actor:cancel/2` → `gen_statem:call` → `idle({call,From},{cancel,TaskId})`
  → `RunPid ! cancel` → `soma_run` `waiting_tool(info, cancel, ...)` → emit `run.cancelled`
  → `next_state cancelled`
- Test entry: `soma_actor:cancel/2` (no layer bypassed; runtime booted so the real
  `soma_run_sup` / registry / event store are live, the run parked in `waiting_tool`
  by a `sleep` step)
- Test: `cancel_drives_run_to_cancelled` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 2 — the tool-call worker is actually dead after cancel
- Call chain: `soma_actor:cancel/2` → `idle` cancel handler → `RunPid ! cancel`
  → `soma_run` `waiting_tool(info, cancel, ...)` → brutal kill of the worker pid
  recorded in `tool.started`
- Test entry: `soma_actor:cancel/2`; the test then reads the worker pid from the
  `tool.started` event with the existing `worker_pid_from_tool_started/2` helper and
  asserts `is_process_alive/1` is `false`
- Test: `cancel_kills_tool_call_worker` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 3 — actor emits `actor.task.cancelled` with the three ids
- Call chain: `soma_actor:cancel/2` → `RunPid ! cancel` → `soma_run` sends
  `{run_cancelled, RunId}` back → `idle(info, {run_cancelled, RunId}, ...)` → emit
  `actor.task.cancelled`
- Test entry: `soma_actor:cancel/2`; the test polls the shared store with
  `wait_for_actor_event/3` and asserts the event carries `actor_id`, `task_id`, and
  `correlation_id`
- Test: `cancel_emits_actor_task_cancelled_event` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 4 — cancelled status readable, actor still alive
- Call chain: `soma_actor:cancel/2` → … → `idle(info, {run_cancelled, RunId}, ...)`
  → task status flips to `cancelled`; then `soma_actor:get_task_status/2` →
  `idle({call,From},{get_task_status,TaskId})`
- Test entry: `soma_actor:get_task_status/2` (after the cancel completes); the test
  asserts the status map's `status` is `cancelled` and `is_process_alive(Pid)` is `true`
- Test: `cancel_status_cancelled_and_actor_alive` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 5 — `ask` whose task is cancelled returns `{error, cancelled}`
- Call chain: `soma_actor:ask/3` parks the waiter in `idle({call,From},{ask,...})`;
  a separate `soma_actor:cancel/2` → `RunPid ! cancel` → `{run_cancelled, RunId}` →
  `idle(info, {run_cancelled, RunId}, ...)` → `reply_waiter/3` answers the parked `From`
- Test entry: two calls — `soma_actor:ask/3` (the parked caller, run from a separate
  process so the test process can issue the cancel) and `soma_actor:cancel/2`. The
  `ask` blocks inside its own `gen_statem:call`, so it must run off the test process;
  that's the reason the chain has two entry points rather than one.
- Test: `ask_cancelled_returns_error_cancelled` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 6 — `cancel/2` for an unknown task returns `{error, Reason}`, actor survives
- Call chain: `soma_actor:cancel/2` → `gen_statem:call` → `idle({call,From},{cancel,TaskId})`
  → task lookup misses → reply `{error, not_found}`
- Test entry: `soma_actor:cancel/2`; the test asserts the reply matches `{error, _}`
  and `is_process_alive(Pid)` is `true`
- Test: `cancel_unknown_task_returns_error` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 7 — `cancel/2` for an already-completed task returns `{error, Reason}`, actor survives
- Call chain: `soma_actor:send/2` runs a fast step to completion → `{run_completed,...}`
  flips the task to `completed`; then `soma_actor:cancel/2` →
  `idle({call,From},{cancel,TaskId})` → task found but no live run → reply `{error, not_running}`
- Test entry: `soma_actor:cancel/2` (after the first run completes, confirmed by
  polling status to `completed`); the test asserts the reply matches `{error, _}` and
  `is_process_alive(Pid)` is `true`
- Test: `cancel_completed_task_returns_error` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 8 — new envelope runs to `completed` after a cancelled task
- Call chain: cancel a first task (`soma_actor:cancel/2` → … → `cancelled`), then
  `soma_actor:send/2` for a second echo task → `maybe_start_run/4` → `soma_run_sup:start_run/1`
  → `{run_completed,...}` → task `completed`
- Test entry: `soma_actor:send/2` for the second envelope (after the first task reaches
  `cancelled`); the test polls the second run to `run.completed` and the second task to
  `completed`
- Test: `new_run_completes_after_cancelled_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 9 — new envelope runs to `completed` after a failed task
- Call chain: `soma_actor:send/2` with a `fail` step → `{run_failed,...}` → task `failed`;
  then `soma_actor:send/2` with an echo step → `{run_completed,...}` → task `completed`
- Test entry: `soma_actor:send/2` for the second envelope (after the first task reaches
  `failed`). This proof already exists from the P9 slice and stays as the failed-recovery
  case in the consolidated set.
- Test: `new_run_completes_after_failed_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 10 — new envelope runs to `completed` after a timed-out task
- Call chain: `soma_actor:send/2` with a `sleep` step whose `timeout_ms` is shorter than
  the sleep → `{run_timeout,...}` → task `failed`; then `soma_actor:send/2` with an echo
  step → `{run_completed,...}` → task `completed`
- Test entry: `soma_actor:send/2` for the second envelope (after the first task reaches
  `failed` from the timeout). This proof already exists from the P9 slice and stays as the
  timed-out-recovery case in the consolidated set.
- Test: `new_run_completes_after_timed_out_run` in `apps/soma_actor/test/soma_actor_SUITE.erl`

### Criterion 11 — `rebar3 eunit && rebar3 ct` is green
- Call chain: none (build/gate command)
- Test entry: the relay merge gate runs the full EUnit and CT suites
- Test: the whole `apps/soma_actor` suite plus the existing runtime/tools/event-store suites

## Risks & trade-offs

Storing the run pid in the task map changes the actor data record's shape, and the
test helpers read that record by position with `element/2`. `run_id_for_task/2` and
`actor_run_id/1` in `soma_actor_SUITE.erl` walk `element(7, Data)` (the `runs` map)
expecting `{RunId, TaskId}` pairs, and `task_status/2` reads `element(6, Data)` (the
`tasks` map). Keeping `runs` as `run_id => task_id` and adding the run pid into the
existing `tasks` entries leaves both helpers valid — the `runs` shape is unchanged and
the `tasks` map just carries an extra key. If Dev instead reshapes `runs` to hold the
pid, those helpers and every test that uses them break. The cheaper path is to leave
`runs` alone and put `run_pid` on the task; this design assumes that.

`cancel/2` replies `ok` before the run is actually cancelled — the kill and the
`run.cancelled` event happen after the reply, when `{run_cancelled, RunId}` comes back.
A caller that reads status immediately after `ok` can still see `running`. That's the
honest cost of keeping the kill on the far side of the process boundary; tests assert
the cancelled state by polling, not by reading once.

The `{error, Reason}` atoms (`not_found`, `not_running`) are this design's reading of
the issue's open question, not a fixed contract. The criteria check only the
`{error, _}` shape and actor survival, so Dev can rename them.
