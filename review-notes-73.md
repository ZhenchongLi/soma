### Claude

## Verdict
changes-requested

## Real issues

- **The run-pid monitor backstop is missing.** The locked decision is "malformed
  steps → monitor run pid AND validate up front." Only the up-front validator
  shipped. `maybe_start_run` (soma_actor.erl:275) takes `{ok, RunPid}` and never
  calls `erlang:monitor(process, RunPid)`. There is no `'DOWN'` clause —
  `idle(_EventType, _Event, Data)` at soma_actor.erl:223 swallows it. The actor
  learns a run's outcome only from the four terminal messages `soma_run` sends
  (`run_completed | run_failed | run_timeout | run_cancelled`). A run that dies
  without sending one — a crash inside `soma_run` itself, not a tool crash the
  run catches and reports — leaves the task at `running` forever, and any `ask`
  waiter parked on it blocks until its `TimeoutMs`. The up-front validator only
  catches a missing `id`/`tool`; it cannot see any other run death. The design
  named this exact gap (design-73.md:51-65, 197-206) and called for the monitor
  plus a proof that a run dying after passing validation records `failed`.
  Neither shipped. Add the monitor and demonitor on the normal terminal path, a
  `'DOWN'` clause that records `failed`, and a test driving a post-validation run
  death.

## Questions

None.

## Nits

- docs/usage.md:299-304 splits the steps-validation sentence across five short
  lines mid-clause. Reads fine rendered; the source wrapping is choppy. Optional.

## Functional evidence
- Criterion 1 — pass: `soma_actor_startup_SUITE:actor_only_start_runs_steps_to_terminal` starts only `application:ensure_all_started(soma_actor)` (init_per_testcase, no `ensure_all_started(soma_runtime)`), sends an echo-step envelope, asserts `is_process_alive(Pid)` and `wait_for_task_status(... completed ...)`. `soma_actor.app.src` now lists `soma_runtime` in `applications`, so `soma_run_sup` is up — no `noproc`. CT green.
- Criterion 2 — pass: `soma_actor_validation_SUITE:malformed_steps_rejected_or_failed_not_running` sends a step `#{tool => echo, args => ...}` missing `id`; `validate_steps/1` (soma_actor.erl:240) rejects with `{error, malformed_steps}`, no run started, never `running`. CT green.
- Criterion 3 — pass: `soma_actor_validation_SUITE:actor_alive_after_malformed_steps` asserts `is_process_alive(Pid)` after the malformed `send/2`. CT green.
- Criterion 4 — pass: `soma_actor_validation_SUITE:valid_steps_complete_after_malformed` submits the bad envelope then a valid echo-step envelope to the same actor pid, asserts the second task reaches `completed`. CT green.
- Criterion 5 — pass: `soma_actor_validation_SUITE:ask_no_steps_returns_ok_accepted` calls `ask(Pid, NoStepsEnvelope, 5000)`, asserts `{ok, accepted, TaskId}`. soma_actor.erl:118-122 replies the 3-tuple without parking. CT green.
- Criterion 6 — pass: `soma_actor_validation_SUITE:ask_no_steps_parks_no_waiter` reads `#data.waiters` through `sys:get_state(Pid)` (element 8) and asserts `false = maps:is_key(TaskId, Waiters)`. CT green.
- Criterion 7 — pass: `soma_actor_validation_SUITE:send_no_steps_accepted_no_run` asserts `{ok, TaskId}` from `send/2` and `accepted` from `get_task_status`; `maybe_start_run` starts nothing for a no-steps envelope (soma_actor.erl:282). CT green.
- Criterion 8 — pass: docs/release.md "Bundled apps" lists `soma_event_store`, `soma_tools`, `soma_runtime`, `sasl` — identical set and order to `rebar.config` relx `{release, {soma, ...}, [...]}` (rebar.config:28-33). `soma_release_app_list_tests` pins the match. release.md states `soma_actor` is deliberately not yet bundled.
- Criterion 9 — pass: docs/usage.md:296-304 now says the actor validates steps up front — "each step is a map with `id` and `tool`; a step that fails this is rejected with `{error, Reason}` before any run starts" — matching `valid_step/1` (soma_actor.erl:248). `soma_usage_step_validation_doc_tests` pins it.
- Criterion 10 — pass: docs/contracts/v0.4-test-contract.md gains an "Edge-case hardening (#73)" section mapping E1–E7 to `soma_actor_startup_SUITE` / `soma_actor_validation_SUITE` cases. `soma_v04_contract_doc_tests` pins it.
- Criterion 11 — pass: `rebar3 eunit` → 115 tests, 0 failures; `rebar3 ct` → All 141 tests passed, both at HEAD.
