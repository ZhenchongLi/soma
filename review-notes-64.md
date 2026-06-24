### Claude

## Verdict
approve

## Real issues
None.

## Questions
- The full `rebar3 ct` gate is intermittently red. One run in seven here failed 112/1: `soma_cli_lifecycle_SUITE:test_cli_external_process_dead_after_cancel` at line 176, `{badmatch,true}` on `false = filelib:is_file(Marker)`. The marker file existed when the test expected it gone. That suite is not in this diff — #64 touches only `soma_actor.erl` and the actor suite. The actor suite ran 43/0 in the failing run; the failure sits in pre-existing CLI cancel-marker code, where the marker path looks shared across runs and a leftover trips the assert. Out of scope for #64, but the merge gate runs the whole suite, so a flaky CLI test can block this PR. Flag for whoever owns the CLI suite.
- `waiters` is keyed by `task_id`. Two `ask/3` calls carrying the same explicit `task_id` would overwrite the first waiter, leaving the first caller parked until its `TimeoutMs`. Same collision shape the `send` path already has, outside this slice's criteria — slice 8 territory.
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
- Criterion 14 — pass: `rebar3 eunit` 108 tests, 0 failures. `rebar3 ct` passed 113/113 on 6 of 7 runs here; one run failed 112/1 on `soma_cli_lifecycle_SUITE:test_cli_external_process_dead_after_cancel`, a flaky pre-existing CLI test outside this diff (see Questions). The actor suite itself ran 43/0 every run, including the failing one.
