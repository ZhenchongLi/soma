### Claude

## Verdict
changes-requested

## Real issues

- **A crashed LLM call with `timeout_ms` set gets flipped from `failed` to `timeout`.**
  The crash path runs through the generic `'DOWN'` clause (`soma_actor.erl:309`), which
  records `failed` but never clears the armed call-timeout timer or the `llm_calls` entry.
  If the envelope carried `timeout_ms`, that timer stays live. When it fires,
  `idle(info, {timeout, _, {llm_timeout, LlmCallId}})` (`soma_actor.erl:280`) still finds
  the task in `llm_calls`, overwrites status `failed` → `timeout`, kills the already-dead
  worker, and emits a spurious `llm.timeout`. `get_task_status` then reports `timeout` for a
  call that crashed, plus a bogus event in the store. Criterion 6's crash test passes only
  because it sends no `timeout_ms` — the mock accepts `timeout_ms` on any directive, so a
  caller can trigger this. Fix: the `'DOWN'` clause for an llm worker must clear the timer
  and drop the `llm_calls` entry, the same way the timeout and result paths do.

## Questions

- The worker can send `{llm_result, _, _, {error, Reason}}` (documented in the
  `soma_llm_call.erl` header and the design's reply contract), but the actor has no
  `idle(info, {llm_result, _, _, {error, _}})` clause — it hits the backstop `idle/3` at
  line 327 and gets dropped, leaving the task stuck at `running` forever. No current directive
  returns `{error, _}` from `perform_call/1`, so it's unreachable today. Intentional deferral
  until the error directive lands, or an oversight?
- Timeout and cancel paths leave the `llm_calls` map entry in place (only `monitors` and the
  timer get cleared). Harmless now — `llm_call_id`s are unique-monotonic so no collision — but
  it grows dead entries over an actor's lifetime. Intentional for this slice?
- Prior cycle's two blockers (mutual exclusion not enforced; the pinned mutual-exclusion case
  missing) are fixed: `validate_envelope/1` now rejects both-present at `soma_actor.erl:337`,
  and `both_steps_and_llm_rejected_no_child_started` exists, is in `all/0`, and passes.

## Nits

- `perform_call(#{directive := slow})` and `perform_call(#{directive := hang})` are byte-identical
  (`receive _ -> never end`). Two directive names, one body — fine as documented intent, worth
  a shared clause if it grows.
- `soma_actor.erl` module doc (lines 1-4) still describes the v0.4 "gen_statem shape only"
  skeleton and says later slices add `idle`, config, and `actor.started`. All of that exists now.

## Functional evidence
- Criterion 1 — pass: `soma_llm_call_tests:test_mock_success_returns_configured_output` asserts `perform_call(#{directive => success, output => Output})` returns `{ok, Output}`; `soma_llm_call.erl` opens no socket and links no network library (source-level fact). EUnit 120/0.
- Criterion 2 — pass: `soma_llm_call_SUITE:llm_worker_runs_in_distinct_pid` reads the worker pid off the `llm.started` event and asserts `WorkerPid =/= ActorPid` and `is_pid(WorkerPid)`. CT 10/10.
- Criterion 3 — pass: `get_task_result_holds_llm_output` waits for status `completed`, then asserts `get_task_result/2` returns `{ok, <<"the mock reply">>}`. CT 10/10.
- Criterion 4 — pass: `slow_call_times_out_worker_dead_actor_alive` (slow directive, timeout_ms 50) asserts `is_process_alive(WorkerPid)` false, status `timeout`, `is_process_alive(ActorPid)` true. CT 10/10.
- Criterion 5 — pass: `cancel_in_flight_call_worker_dead_actor_alive` (hang directive) calls `cancel/2`, asserts worker dead, status `cancelled`, actor alive. CT 10/10.
- Criterion 6 — pass: `crash_reaches_actor_as_failed_via_down` (crash directive → `exit(llm_call_crashed)`) asserts status `failed`, worker dead, actor alive and `=/= WorkerPid`; handled by the non-normal `'DOWN'` clause at `soma_actor.erl:309`. CT 10/10. (See Real issues: holds only without `timeout_ms`.)
- Criterion 7 — pass: `status_promptly_while_llm_call_in_flight` (hang directive) times `get_task_status/2` at under 200ms and reads `running`, proving the actor mailbox is not blocked. CT 10/10.
- Criterion 8 — pass: `completed_call_appends_llm_event_with_correlation_id` queries `by_correlation/2` for the envelope's correlation_id and asserts at least one `llm.*` event; `by_correlation/2` filters on the `correlation_id` field (`soma_event_store.erl:55`), which `emit/3` stamps on every `llm.*` event. CT 10/10.
- Criterion 9 — pass: `by_correlation_returns_llm_and_actor_events` asserts both an `actor.*` and an `llm.*` event under one correlation_id from the same query. CT 10/10.
- Criterion 10 — pass: `docs/contracts/v0.5-test-contract.md` exists; `pins_v0_5_test_contract_maps_each_proof` reads it and asserts it names both proving suites and all 10 cases — every named case now exists in the suite and is in `all/0`. CT 10/10.
