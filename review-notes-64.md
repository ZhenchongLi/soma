### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `waiters` is keyed by `task_id`. Two `ask/3` calls carrying the same explicit `task_id` would overwrite the first waiter, leaving the first caller parked until its `TimeoutMs`. Same collision shape the `send` path already has, and outside this slice's criteria — slice 8 territory. Flagging it so it isn't forgotten when the failure-reply path lands.
- A waiter on a run that fails or times out stays parked until its own `TimeoutMs` fires (design-64.md §Risks). Reads as a `timeout` even when the run died. Known gap, scoped to slice 8.

## Nits
- `get_task_status/2` returns a map with `correlation_id` for a known task but drops it for `not_found`. Callers can't pattern-match a uniform shape. No criterion needs it; leaving as-is is fine.

## Functional evidence
- Criterion 1 — pass: `ask_returns_run_outputs` asserts `{ok, Result} = ask/3` with `Result = #{s1 => #{value => <<"a">>}}`, the echo step's outputs. soma_actor.erl:127-142 replies `{ok, Outputs}` from the `run_completed` handler.
- Criterion 2 — pass: `ask_caller_and_actor_alive_after_return` asserts `is_process_alive(self())` and `is_process_alive(Pid)` after `{ok, _Result}`.
- Criterion 3 — pass: `ask_reply_matches_completed_run` uses a 300ms sleep step, then after `ask/3` returns asserts `completed = task_status(Pid, TaskId)` and `Result = task_result(Pid, TaskId)`. Reply only leaves the `run_completed` handler (soma_actor.erl:141), the same handler that sets `completed`.
- Criterion 4 — pass: `ask_short_timeout_returns_timeout` 500ms step with `TimeoutMs = 100` asserts `timeout = ask/3`. soma_actor.erl:38-43 catches `exit:{timeout, _}` and returns the atom.
- Criterion 5 — pass: `ask_timeout_actor_survives_and_completes` after the timeout asserts `is_process_alive(Pid)`, then `completed = wait_for_task_status(...)`, then `is_process_alive(Pid)` again.
- Criterion 6 — pass: `ask_invalid_envelope_errors_no_run` passes `<<"not-a-map">>`, asserts `{error, _Reason}`, reads `supervisor:which_children(soma_run_sup)` and asserts `0 = length(RunPids)`. soma_actor.erl:103-104 replies error with no `maybe_start_run`.
- Criterion 7 — pass: `get_task_status_running_before_completion` 500ms step, asserts `running = maps:get(status, Status)` plus `task_id` and `correlation_id` present. soma_actor.erl:178-179 sets `running` when the run starts.
- Criterion 8 — pass: `get_task_status_completed_after_run` polls to completion, asserts `completed = maps:get(status, Status)`.
- Criterion 9 — pass: `get_task_status_queryable_by_send_task_id` sends with no explicit id (minted), then `TaskId = maps:get(task_id, Status)` from the read keyed by `send`'s returned id.
- Criterion 10 — pass: `get_task_result_not_ready_before_completion` 500ms step asserts `not_ready = get_task_result/2`. soma_actor.erl:121-123 returns `not_ready` when no `result` key.
- Criterion 11 — pass: `get_task_result_ok_outputs_after_completion` polls to completion, asserts `{ok, #{s1 => #{value => <<"a">>}}} = get_task_result/2`.
- Criterion 12 — pass: `unknown_task_id_not_found_both_reads_actor_alive` asserts `not_found = maps:get(status, Status)` and `{error, not_found} = get_task_result/2` for an unaccepted id, then `is_process_alive(Pid)`.
- Criterion 13 — pass: `read_returns_while_earlier_run_in_flight` issues `get_task_status/2` against a live 500ms run; the call returns inside the default 5s call timeout with `running`, proving the read is served from `idle` without blocking on the run.
- Criterion 14 — pass: `rebar3 eunit` 108 tests 0 failures; `rebar3 ct` All 113 tests passed.
