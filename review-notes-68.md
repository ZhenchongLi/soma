### Claude

## Verdict
approve

## Real issues
None.

## Questions
- The `{run_failed, ...}` and `{run_timeout, ...}` handlers leave the run id in `#data.runs` after the run dies. The success path leaves it too, so this matches existing behavior — the map only ever grows. Not a blocker for this slice, but the runs map is an unbounded leak across an actor's lifetime. Worth a cleanup slice before any long-lived actor ships.

## Nits
- The two new `idle/3` clauses are near-identical copies of `run_completed` (lookup, task read, status write, emit, reply). Three copies of the same shape. A shared `terminal_task/4` helper would cut the duplication, but the design chose copy-for-clarity and the clauses key on distinct tags. Leave it; not worth churn.

## Functional evidence
- Criterion 1 — pass: `failed_run_emits_task_failed_event` sends a `fail` (mode=error, reason=boom) step through `soma_actor:send/2`, reads the `actor.task.failed` event back from the shared store, asserts `actor_id`, `task_id`, `correlation_id`, and `reason => boom`. Source: `soma_actor.erl:143-157` emits with all four fields.
- Criterion 2 — pass: `failed_run_sets_task_status_failed` polls the actor task table (data record element 6) after a `fail` run and asserts status `failed`. Source: `Task#{status => failed, reason => Reason}` at `soma_actor.erl:150`.
- Criterion 3 — pass: `actor_alive_after_owned_run_fails` asserts `is_process_alive(Pid)` is `true` after the owned run reaches `failed`. The failure arrives as a mailbox message, not a link signal.
- Criterion 4 — pass: `tool_crash_isolated_by_process_boundary` captures the run pid from `soma_run_sup` children and the worker pid from the `tool.started` event, asserts all three (`ActorPid`, `RunPid`, `WorkerPid`) distinct and `is_process_alive(ActorPid)` true after a `fail` (crash mode) step. The crash reaches the actor as `{run_failed, ...}`.
- Criterion 5 — pass: `ask_failed_run_returns_error` asserts `soma_actor:ask(Pid, Envelope, 5000)` returns `{error, boom}` and the actor pid stays alive. The parked waiter is answered by `reply_waiter(TaskId, {error, Reason}, Data1)` at `soma_actor.erl:156`.
- Criterion 6 — pass: `timed_out_run_emits_task_failed_timeout` runs a 500ms sleep with a 50ms per-step timeout, reads `actor.task.failed` from the store, asserts `reason => timeout`. Source: `soma_actor.erl:158-171` (`{run_timeout, RunId}` handler).
- Criterion 7 — pass: `ask_timed_out_run_returns_error_timeout` asserts `soma_actor:ask(Pid, Envelope, 5000)` returns `{error, timeout}` (criterion also accepts bare `timeout`) and the actor pid stays alive.
- Criterion 8 — pass: `status_running_promptly_while_run_in_flight` calls `get_task_status/2` while a 500ms sleep run is in flight; the call returns inside the default 5s gen_statem timeout with status `running`, proving the read is served from `idle` without blocking on the child run.
- Criterion 9 — pass: `new_run_completes_after_failed_run` fails a first run, then sends a second `echo` envelope on the same actor pid, polls the second run's trail to `run.completed`, and asserts the second task status `completed`.
- Criterion 10 — pass: `new_run_completes_after_timed_out_run` times out a first run, then runs a second `echo` envelope to `completed` on the same actor pid.
- Criterion 11 — pass: `rebar3 eunit` → 110 tests, 0 failures. `rebar3 ct` → All 126 tests passed.
