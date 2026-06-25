### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `llm_call_counts` is never reaped for finished tasks, same as `tasks`. The design flags it as pre-existing, out of scope. Confirmed, not a blocker for this slice.

## Nits
- The direct `steps` envelope path stays uncapped by `max_steps`. Design and issue both frame this as intentional. Fine, but a caller who sends a 10000-step direct envelope gets no ceiling. Worth a later criterion.

## Functional evidence
- Criterion 1 — pass: `budget_zero_llm_calls_fails_task_with_reason` asserts `{budget_exceeded, max_llm_calls} = maps:get(reason, Status)` after `send/2` with `budget => #{max_llm_calls => 0}`. `maybe_start_llm_call/4` routes to `fail_task` when `llm_budget_available/2` is false (soma_actor.erl:618-625).
- Criterion 2 — pass: `budget_zero_llm_calls_emits_no_llm_started` asserts `false = lists:member(<<"llm.started">>, Types)` from `by_correlation/2`. The budget check returns before `start_llm_call/4`, which is the only `llm.started` emitter (soma_actor.erl:696).
- Criterion 3 — pass: `budget_max_steps_fails_oversized_proposal_with_reason` sends a 2-step proposal against `max_steps => 1`, asserts `{budget_exceeded, max_steps}`. `steps_budget_available/2` false branch calls `fail_task` (soma_actor.erl:342-355).
- Criterion 4 — pass: `budget_max_steps_oversized_proposal_emits_no_run_started` asserts `false = lists:member(<<"run.started">>, Types)`. The `false` branch returns before `execute_run_steps/6`, which is the only path to `start_owned_run/4`.
- Criterion 5 — pass: `budget_within_max_steps_proposal_completes` sends a 2-step proposal against `max_steps => 3`, asserts `completed = maps:get(status, Status)`.
- Criterion 6 — pass: `budget_failed_task_status_reads_failed` asserts `failed = maps:get(status, Status)` via `get_task_status/2` on the `max_llm_calls => 0` failure.
- Criterion 7 — pass: `actor_survives_budget_failure_takes_next_envelope` budget-fails task 1, asserts actor alive, drives task 2 to `completed` on the same pid.
- Criterion 8 — pass: `parked_ask_on_budget_failed_task_gets_error` asserts `{error, {budget_exceeded, max_llm_calls}} = soma_actor:ask(...)`. `fail_task` releases the parked waiter via `gen_statem:reply/2` (soma_actor.erl:661-666).
- Criterion 9 — pass: `by_correlation_surfaces_budget_failed_event_with_reason` asserts exactly one `actor.task.failed` event with `reason = {budget_exceeded, max_llm_calls}` from `by_correlation/2`.
- Criterion 10 — pass: `no_budget_field_executes_approved_run_steps_to_completed` starts an actor with no `budget` key, drives an approved 2-step proposal to `completed`. `init/1` defaults `budget => #{}`, both checks see unlimited cap.
- Criterion 11 — pass: `docs/contracts/v0.5-test-contract.md` gains the v0.5.5 section mapping all 10 proofs to `soma_actor_budget_SUITE` and named cases; `pins_v0_5_test_contract_maps_each_proof` in `soma_llm_call_SUITE` asserts `<<"v0.5.5">>`, `<<"soma_actor_budget_SUITE">>`, and each new case name.
- Criterion 12 — pass: `rebar3 eunit && rebar3 ct` green — EUnit 132 tests 0 failures, CT 186 tests passed.
