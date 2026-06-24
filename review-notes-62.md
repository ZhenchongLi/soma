### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `runs` map never drops completed entries. After a run completes the `run_id => task_id` pair stays forever. Monotonic growth, keyed by unique run ids. No user-visible effect in v0.4 scope, but slice 8 (failure/timeout/cancel) will add more writers to this map — decide there whether terminal runs get pruned.

## Nits
- `maybe_start_run` clause head binds `Steps when is_list(Steps)`. A `steps` key holding a non-list (a binary, a map) silently falls to the no-run branch instead of erroring. Matches the design's "present and a list" wording, so intentional. Worth a one-line note that a malformed `steps` is treated as no-steps, not rejected.

## Functional evidence
- Criterion 1 — pass: `run_started_under_run_sup_distinct_pid` sends a valid steps envelope, asserts `{ok, <<"task-run-start">>}`, reads exactly one live run child from `soma_run_sup`, and asserts `RunPid =/= Pid`.
- Criterion 2 — pass: `run_completes_with_run_event_trail` reads `by_run/2` after `run.completed` appears, confirms both `run.started` and `run.completed` present and `StartedIdx < CompletedIdx`.
- Criterion 3 — pass: `actor_run_worker_pids_all_distinct` reads run pid from `soma_run_sup` children and worker pid from the `tool.started` event, asserts `ActorPid`, `RunPid`, `WorkerPid` pairwise distinct.
- Criterion 4 — pass: `result_created_event_carries_ids` waits for `actor.result.created`, asserts it carries `actor_id`, `task_id`, `correlation_id`. Source `soma_actor.erl:65-66` emits it from the `run_completed` info clause.
- Criterion 5 — pass: `task_completed_event_carries_ids` waits for `actor.task.completed`, asserts the three ids. Source `soma_actor.erl:67-68` emits it.
- Criterion 6 — pass: `task_status_completed_after_run` polls the task table through `sys:get_state/1` and reads `completed`. Source `soma_actor.erl:62` sets `status => completed`.
- Criterion 7 — pass: `task_result_holds_outputs_after_run` asserts the stored result equals `#{s1 => #{value => <<"a">>}}`, the echo step's Outputs. Source `soma_actor.erl:62` stores `result => Outputs`.
- Criterion 8 — pass: `send_returns_before_run_completes` uses a 500ms sleep step, asserts `accepted` and `is_process_alive` right after `send/2` returns, then polls to `completed` with the actor still alive.
- Criterion 9 — pass: `second_steps_envelope_starts_second_run` sends two envelopes, reads both run ids from the `runs` map, asserts `RunId1 =/= RunId2`, and waits for the second run's `run.completed`.
- Criterion 10 — pass: `no_steps_accepts_and_starts_no_run` sends a no-steps envelope, asserts `{ok, TaskId}`, zero run children under `soma_run_sup`, and task status still `accepted`.
- Criterion 11 — pass: `rebar3 eunit` = 108 tests, 0 failures; `rebar3 ct` = All 100 tests passed.
