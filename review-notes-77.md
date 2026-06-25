### Claude

## Verdict
changes-requested

## Real issues

1. **Mutual exclusion is documented but not enforced. An envelope with both `steps` and `llm` starts two children.**
   `validate_envelope/1` (soma_actor.erl:330) checks `type` + `payload`, then defers to `validate_steps/1`, which returns `ok` for any list. It never looks at `llm`. So an envelope carrying both a valid `steps` list and an `llm` map passes validation. `idle/3` then runs `maybe_start_run` (steps is a list → starts a `soma_run`) and `maybe_start_llm_call` (llm is a map → starts a `soma_llm_call`). Two children for one task, and the task's run-tracking fields get stomped by the llm writer (run_pid/run_mref still set, llm_call_pid/llm_call_id overwrite status). The design names this exact case as decision 1 and the bonus criterion: "Both present is malformed and rejected up front by `validate_envelope/1` with `{error, _}`, before any child starts." The code does the opposite — it starts both.

2. **The contract pin passes while the proof it pins does not exist.** `v0.5-test-contract.md:80` and the pin test (soma_llm_call_SUITE.erl:315) both name `both_steps_and_llm_rejected_no_child_started`. `pins_v0_5_test_contract_maps_each_proof` only greps the doc for that string, so it goes green. But no such test function exists — it is absent from `all/0` and from the module. The contract claims a process proof that nobody runs. Issue 1 is unproven precisely because this test was never written. Add the test, then add the validation to make it pass.

## Questions

- Cancel of an in-flight llm call (idle/3:163) emits `llm.cancelled` but never calls `reply_waiter`. The run-cancel path does. This slice drives llm through `send/2`, so no waiter is parked today, but when `ask/3` reaches the llm path a cancelled call leaves the caller blocked until its own timeout. Intentional for this slice, or an oversight to fix now?

## Nits

- soma_actor.erl module doc (line 1-4) still describes the v0.4 "gen_statem shape only" skeleton and says later slices add `idle`, config, and `actor.started`. Those all exist now. The doc is three slices stale.
- `perform_call/1` has separate `slow` and `hang` clauses with identical bodies (`receive _ -> never end`). One clause matching both directives would say the same thing; the split only earns its keep through the two comments.

## Functional evidence
- Criterion 1 — pass: `soma_llm_call_tests:test_mock_success_returns_configured_output` asserts `perform_call(#{directive => success, output => Output})` returns `{ok, Output}`; soma_llm_call.erl opens no socket and links no network library (source-level fact). EUnit 120/0.
- Criterion 2 — pass: `soma_llm_call_SUITE:llm_worker_runs_in_distinct_pid` reads the worker pid off the `llm.started` event and asserts `WorkerPid =/= ActorPid` and `is_pid(WorkerPid)`. CT 9/9.
- Criterion 3 — pass: `get_task_result_holds_llm_output` waits for status `completed`, then asserts `get_task_result/2` returns `{ok, <<"the mock reply">>}`. CT 9/9.
- Criterion 4 — pass: `slow_call_times_out_worker_dead_actor_alive` (slow directive, timeout_ms 50) asserts `is_process_alive(WorkerPid)` false, status `timeout`, `is_process_alive(ActorPid)` true. CT 9/9.
- Criterion 5 — pass: `cancel_in_flight_call_worker_dead_actor_alive` (hang directive) calls `cancel/2`, asserts worker dead, status `cancelled`, actor alive. CT 9/9.
- Criterion 6 — pass: `crash_reaches_actor_as_failed_via_down` (crash directive → `exit(llm_call_crashed)`) asserts status `failed`, worker dead, actor alive and `=/= WorkerPid`; handled by the non-normal `'DOWN'` clause at soma_actor.erl:309. CT 9/9.
- Criterion 7 — pass: `status_promptly_while_llm_call_in_flight` (hang directive) times `get_task_status/2` at under 200ms and reads `running`, proving the actor mailbox is not blocked. CT 9/9.
- Criterion 8 — pass: `completed_call_appends_llm_event_with_correlation_id` queries `by_correlation/2` for the envelope's correlation_id and asserts at least one `llm.*` event; `llm.succeeded` carries correlation_id (soma_actor.erl:269). CT 9/9.
- Criterion 9 — pass: `by_correlation_returns_llm_and_actor_events` asserts both an `actor.*` and an `llm.*` event under one correlation_id from the same query. CT 9/9.
- Criterion 10 — fail: `docs/contracts/v0.5-test-contract.md` exists and the pin test passes, but it maps a proof — `both_steps_and_llm_rejected_no_child_started` — that does not exist in the suite. A contract that names an absent case does not honestly "map each process proof to the suite and case that proves it." Either write the case or drop the mapping; right now the doc overstates coverage.
