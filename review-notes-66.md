### Claude

## Verdict
approve

## Real issues
None.

## Questions
None.

## Nits
None.

## Functional evidence
- Criterion 1 — pass: `handle_call({by_correlation, CorrelationId}, ...)` in `apps/soma_event_store/src/soma_event_store.erl:55-57` walks `lists:reverse(Events)` and keeps `maps:get(correlation_id, E, undefined) =:= CorrelationId` — same shape as `by_run/2` at line 49-50, oldest-first. `?MANDATORY_KEYS` (line 64) is untouched. EUnit `test_by_correlation_filters` appends corr_a/corr_b/no-corr/corr_a and asserts the returned types are `[a1, a2]` in order.
- Criterion 2 — pass: EUnit `test_by_correlation_empty_for_unknown_id` appends one corr_a event plus one no-correlation event, asserts `by_correlation(Pid, corr_unknown) =:= []`.
- Criterion 3 — pass: `soma_run` reads `correlation_id` into `#data{}` (`soma_run.erl:42`) and `emit/3` merges the key only when non-undefined (lines 330-340). CT `test_run_stamps_correlation_id_on_every_event` starts a run directly with `correlation_id => <<"corr-run-stamp-1">>`, asserts `by_correlation` returns exactly the run's own trail (`Types = RunTypes`) including run.started and run.completed, and `lists:all` confirms every event carries the id.
- Criterion 4 — pass: CT `test_run_without_correlation_id_emits_normal_trail` starts a run with the opt omitted, asserts the trail reaches run.completed and `false = lists:any(maps:is_key(correlation_id, E))` across all events. `normalize/1` backfills only the eight mandatory keys, so the store never injects `correlation_id => undefined`.
- Criterion 5 — pass: CT `soma_actor_correlation_SUITE:test_chain_retrievable_by_correlation_id` boots `soma_runtime`, drives one echo task through `soma_actor:send/2` with `correlation_id => <<"corr-chain-C">>`, waits for `actor.task.completed`, then asserts `by_correlation(Store, C)` returns all four `actor.*` events plus the six-event run chain (run.started, step.started, tool.started, tool.succeeded, step.succeeded, run.completed), all under one id, length exactly 10. `actor.started` carries no id so it is correctly excluded.
- Criterion 6 — pass: `rebar3 eunit` → `110 tests, 0 failures`; `rebar3 ct` → `All 116 tests passed.`
