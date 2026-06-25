### Claude

## Verdict
approve

## Real issues

None.

## Questions

- The worker can send `{llm_result, _, _, {error, Reason}}` (documented in the
  `soma_llm_call.erl` header and the design's reply contract), but the actor still has no
  `idle(info, {llm_result, _, _, {error, _}})` clause. An error result hits the backstop at
  `soma_actor.erl:333` and is dropped, leaving the task stuck at `running` forever. No current
  directive returns `{error, _}` from `perform_call/1`, so it's unreachable today. Intentional
  deferral until the error directive lands?
- Timeout (`soma_actor.erl:280`) and cancel (`soma_actor.erl:151`) clear the timer and monitor
  but leave the `llm_calls` map entry in place — only the crash `'DOWN'` path calls
  `clear_llm_call/1`. Harmless now (`llm_call_id`s are unique-monotonic, no collision) but it's
  an asymmetry: three terminal paths, two of them leak the entry. Intentional for this slice?
- The prior cycle's blocker is fixed: the non-normal `'DOWN'` clause (`soma_actor.erl:309`) now
  calls `clear_llm_call/1` (`:321`), which cancels the armed call-timeout timer and drops the
  `llm_calls` entry. A crashing call with `timeout_ms` set stays `failed` and emits no spurious
  `llm.timeout`. Pinned by `crash_with_timeout_ms_stays_failed_no_spurious_timeout`.

## Nits

- `perform_call(#{directive := slow})` and `perform_call(#{directive := hang})` are byte-identical
  (`receive _ -> never end`). Two directive names, one body — fine as documented intent, worth
  a shared clause if it grows.
- `soma_actor.erl` module doc (lines 1-4) still describes the v0.4 "gen_statem shape only"
  skeleton and says later slices add `idle`, config, and `actor.started`. All of that exists now.

## Functional evidence
- Criterion 1 — pass: `soma_llm_call_tests:test_mock_success_returns_configured_output` asserts `perform_call(#{directive => success, output => Output})` returns `{ok, Output}`; `soma_llm_call.erl` opens no socket and links no network library (source-level fact). EUnit 120/0.
- Criterion 2 — pass: `soma_llm_call_SUITE:llm_worker_runs_in_distinct_pid` reads the worker pid off the `llm.started` event and asserts `WorkerPid =/= ActorPid` and `is_pid(WorkerPid)`. CT all green.
- Criterion 3 — pass: `get_task_result_holds_llm_output` waits for status `completed`, then asserts `get_task_result/2` returns `{ok, <<"the mock reply">>}`. CT all green.
- Criterion 4 — pass: `slow_call_times_out_worker_dead_actor_alive` (slow directive, timeout_ms 50) asserts `is_process_alive(WorkerPid)` false, status `timeout`, `is_process_alive(ActorPid)` true. CT all green.
- Criterion 5 — pass: `cancel_in_flight_call_worker_dead_actor_alive` (hang directive) calls `cancel/2`, asserts worker dead, status `cancelled`, actor alive. CT all green.
- Criterion 6 — pass: `crash_reaches_actor_as_failed_via_down` (crash directive → `exit(llm_call_crashed)`) asserts status `failed`, worker dead, actor alive and `=/= WorkerPid`. The crash-with-timeout edge is now pinned separately by `crash_with_timeout_ms_stays_failed_no_spurious_timeout`: status stays `failed` past the timeout window, no `llm.timeout` event in the store. CT all green.
- Criterion 7 — pass: `status_promptly_while_llm_call_in_flight` (hang directive) times `get_task_status/2` at under 200ms and reads `running`, proving the actor mailbox is not blocked. CT all green.
- Criterion 8 — pass: `completed_call_appends_llm_event_with_correlation_id` queries `by_correlation/2` for the envelope's correlation_id and asserts at least one `llm.*` event; every emitted `llm.*` event carries `correlation_id` (`soma_actor.erl:451`, `:269`). CT all green.
- Criterion 9 — pass: `by_correlation_returns_llm_and_actor_events` asserts both an `actor.*` and an `llm.*` event under one correlation_id from the same query. CT all green.
- Criterion 10 — pass: `docs/contracts/v0.5-test-contract.md` exists and maps all 10 cases plus the mutual-exclusion bonus case to their proving suite; `pins_v0_5_test_contract_maps_each_proof` reads it and asserts both suites and every named case are present. CT all green (153 CT total).
