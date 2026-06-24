### Claude

## Verdict
approve

## Real issues

None.

## Questions

None.

## Nits

- `idle(info, {run_cancelled, RunId}, ...)` reads `maps:get(correlation_id, Task)` with no default. Safe today — every task gets `correlation_id` set at accept time in `idle({call,From},{send/ask,...})` — so this is fine, not a bug. Just flagging the one unguarded `maps:get` so a future refactor that lets a task exist without `correlation_id` doesn't crash the cancel handler.

## Functional evidence
- Criterion 1 — pass: `cancel_drives_run_to_cancelled` (soma_actor_SUITE.erl:1709) parks the run on a 500ms `sleep`, calls `soma_actor:cancel/2`, polls the shared store for `run.cancelled` keyed by the actor's run id, then asserts `sys:get_state(RunPid)` is `{cancelled, _}`.
- Criterion 2 — pass: `cancel_kills_tool_call_worker` (soma_actor_SUITE.erl:1747) reads the worker pid from the `tool.started` event with `worker_pid_from_tool_started/2` and asserts `is_process_alive(WorkerPid) =:= false`.
- Criterion 3 — pass: `cancel_emits_actor_task_cancelled_event` (soma_actor_SUITE.erl:1782) waits for `actor.task.cancelled` and asserts the event's `actor_id`, `task_id`, `correlation_id` equal the recorded task's ids. `emit/3` merges `actor_id` into every event base.
- Criterion 4 — pass: `cancel_status_cancelled_and_actor_alive` (soma_actor_SUITE.erl:1820) polls the task table to `cancelled`, reads `get_task_status/2` status `cancelled`, asserts `is_process_alive(Pid)`.
- Criterion 5 — pass: `ask_cancelled_returns_error_cancelled` (soma_actor_SUITE.erl:1857) issues `ask/3` off-process, cancels, and asserts the relayed reply is `{error, cancelled}` with the actor pid still alive.
- Criterion 6 — pass: `cancel_unknown_task_returns_error` (soma_actor_SUITE.erl:1893) cancels an unaccepted task id, asserts `{error, _}` and `is_process_alive(Pid)`. Handler returns `{error, not_found}` on the task-lookup miss.
- Criterion 7 — pass: `cancel_completed_task_returns_error` (soma_actor_SUITE.erl:1915) runs a fast `echo` to `completed`, cancels, asserts `{error, _}` and actor alive. Handler returns `{error, not_running}` for a task with no live run pid.
- Criterion 8 — pass: `new_run_completes_after_cancelled_run` (soma_actor_SUITE.erl:1948) cancels the first task, sends a second `echo` envelope, polls its run to `run.completed` and the second task to `completed`.
- Criterion 9 — pass: `new_run_completes_after_failed_run` (soma_actor_SUITE.erl:1638) — pre-existing P9 case, runs a `fail` step then a recovery `echo` to `completed`.
- Criterion 10 — pass: `new_run_completes_after_timed_out_run` (soma_actor_SUITE.erl:1680) — pre-existing P9 case, times out a `sleep` then runs a recovery `echo` to `completed`.
- Criterion 11 — pass: `rebar3 eunit` = 110 tests, 0 failures; `rebar3 ct` = All 134 tests passed.
