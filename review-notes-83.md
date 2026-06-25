### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `run_steps_proposal_starts_no_run` proves no `run.started` fires. But the proposal path never calls `start_run` — the absence is structural, not enforced by a guard. If a later slice wires `run_steps` to actually execute, this test keeps passing right up until someone flips that switch on purpose. Fine for v0.5.2; flag it when v0.5.3+ touches the proposal-to-run bridge.
- `valid_step/1` checks only that `id` and `tool` keys exist. A `run_steps` proposal with `tool => 42` or an empty `id` normalizes ok. The criterion only asks for an id+tool shape check, so this matches scope — confirm the real step-shape validation lands in the slice that runs proposed steps.

## Nits
- `proposal_result/1` returns `{opaque, Output}` for any non-proposal map and stores it verbatim, preserving the v0.5.1 contract. The two `Task1`/`Tasks`/`Data1` rebuild blocks in the `{proposal, _}` and `{opaque, _}` branches are near-identical. Not worth a helper now; watch it if a fourth branch appears.

## Functional evidence
- Criterion 1 — pass: `soma_proposal_tests:test_reply_normalizes_ok` asserts `{ok, Proposal}` with `maps:get(kind, Proposal) =:= reply`; `soma_proposal.erl:14`.
- Criterion 2 — pass: `soma_proposal_tests:test_run_steps_normalizes_ok` feeds `[#{id => <<"s1">>, tool => echo}]`, asserts `{ok, Proposal}` with `kind => run_steps`; `soma_proposal.erl:16`.
- Criterion 3 — pass: `soma_proposal_tests:test_reject_normalizes_ok` asserts `{ok, Proposal}` with `kind => reject`; `soma_proposal.erl:26`.
- Criterion 4 — pass: `soma_proposal_tests:test_ask_normalizes_ok` asserts `{ok, Proposal}` with `kind => ask`; `soma_proposal.erl:28`.
- Criterion 5 — pass: `soma_proposal_tests:test_unknown_kind_errors` feeds `kind => some_unknown_kind`, asserts `{error, Diagnostics}` non-empty; `soma_proposal.erl:35` returns `code => unknown_kind`.
- Criterion 6 — pass: `soma_proposal_tests:test_actor_message_kind_errors` feeds `kind => actor_message`, asserts `{error, Diagnostics}` — falls to the `unknown_kind` clause since no `actor_message` head exists.
- Criterion 7 — pass: `soma_proposal_tests:test_reply_missing_text_errors` feeds `#{kind => reply}`, asserts first diagnostic `code => missing_required_field`; `soma_proposal.erl:30`.
- Criterion 8 — pass: `soma_proposal_tests:test_run_steps_bad_step_errors` feeds a steps list with `#{id => <<"s2">>}` (no tool), asserts `{error, Diagnostics}`; `valid_step/1` fails the `lists:all`.
- Criterion 9 — pass: `soma_proposal_SUITE:reply_proposal_stored_as_task_result` drives a real `proposal` llm directive, waits for `completed`, asserts `get_task_result/2` returns the value of `soma_proposal:normalize/1`, not the raw output; `soma_actor.erl` proposal branch stores `result => Proposal`.
- Criterion 10 — pass: `soma_proposal_SUITE:reply_proposal_emits_proposal_created_with_correlation_id` reads `by_correlation/2`, asserts exactly one `proposal.created` event with `correlation_id => <<"corr-proposal-created">>`.
- Criterion 11 — pass: `soma_proposal_SUITE:run_steps_proposal_starts_no_run` drives a run_steps proposal, asserts the correlated trail has zero `run.started` events; the proposal branch records the steps as result and starts no run.
- Criterion 12 — pass: `soma_proposal_SUITE:malformed_proposal_marks_task_failed` sends `#{kind => reply}` (no text), waits for status `failed`; `soma_actor.erl` `{invalid_proposal, _}` branch sets `status => failed`.
- Criterion 13 — pass: `soma_proposal_SUITE:actor_survives_malformed_proposal_takes_next_send` after the failed task asserts `is_process_alive(ActorPid)` and a second `send/2` returns `{ok, TaskId2}`.
- Criterion 14 — pass: `soma_proposal_SUITE:by_correlation_returns_proposal_actor_and_llm_events` asserts the trail holds `[<<"proposal.created">>]` plus `length(ActorEvents) >= 1` and `length(LlmEvents) >= 1` for one correlation id.
- Criterion 15 — pass: `docs/contracts/v0.5-test-contract.md` gains the "v0.5.2 — proposals as validated data, not execution" section mapping all 14 proofs to suite·case; `soma_llm_call_SUITE:pins_v0_5_test_contract_maps_each_proof` asserts `<<"v0.5.2">>`, both suite names, and every case string present in the doc.
- Criterion 16 — pass: `rebar3 eunit` = 128 tests, 0 failures; `rebar3 ct` = All 159 tests passed.
