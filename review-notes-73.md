### Claude

## Verdict
approve

## Real issues

None.

## Questions

- The contract markdown lists E1–E7 but not the eighth validation case,
  `run_death_after_validation_records_failed`. It is the monitor backstop — the
  one proof that catches a run dying after it passes validation. Criterion 10
  asks for "the new edge-case proofs added by this issue," and that case is one
  of them. Naming it in the contract table would close the gap. Not a blocker:
  the case runs green in the gate and the design marks it as backing criterion
  2's "or reaches terminal failed" wording rather than its own criterion.

## Nits

- docs/usage.md:298-303 splits the steps-validation sentence across five short
  lines mid-clause. Reads fine rendered; the source wrapping is choppy. Optional.

## Functional evidence
- Criterion 1 — pass: `soma_actor_startup_SUITE:actor_only_start_runs_steps_to_terminal` starts only `application:ensure_all_started(soma_actor)` (init_per_testcase, no `ensure_all_started(soma_runtime)`), sends an echo-step envelope, asserts `is_process_alive(Pid)` and `wait_for_task_status(... completed ...)`. `soma_actor.app.src` now lists `soma_runtime` in `applications`, so `soma_run_sup` is up — no `noproc`. CT green.
- Criterion 2 — pass: `soma_actor_validation_SUITE:malformed_steps_rejected_or_failed_not_running` sends a step `#{tool => echo, args => ...}` missing `id`; `validate_steps/1` (soma_actor.erl:248) rejects with `{error, malformed_steps}`, no run started, never `running`. Backstop proven separately by `run_death_after_validation_records_failed`: a valid sleep-step run killed mid-flight (`exit(RunPid, kill)`) lands as `'DOWN'` and is recorded `failed`. CT green.
- Criterion 3 — pass: `soma_actor_validation_SUITE:actor_alive_after_malformed_steps` asserts `is_process_alive(Pid)` after the malformed `send/2`. CT green.
- Criterion 4 — pass: `soma_actor_validation_SUITE:valid_steps_complete_after_malformed` submits the bad envelope then a valid echo-step envelope to the same actor pid, asserts the second task reaches `completed`. CT green.
- Criterion 5 — pass: `soma_actor_validation_SUITE:ask_no_steps_returns_ok_accepted` calls `ask(Pid, NoStepsEnvelope, 5000)`, asserts `{ok, accepted, TaskId}`. soma_actor.erl:118-125 replies the 3-tuple without parking. CT green.
- Criterion 6 — pass: `soma_actor_validation_SUITE:ask_no_steps_parks_no_waiter` reads `#data.waiters` through `sys:get_state(Pid)` (element 8) and asserts `false = maps:is_key(TaskId, Waiters)`. CT green.
- Criterion 7 — pass: `soma_actor_validation_SUITE:send_no_steps_accepted_no_run` asserts `{ok, TaskId}` from `send/2` and `accepted` from `get_task_status`; `maybe_start_run` starts nothing for a no-steps envelope (soma_actor.erl:293-322 falls through to `_ -> Data`). CT green.
- Criterion 8 — pass: docs/release.md "Bundled apps" lists `soma_event_store`, `soma_tools`, `soma_runtime`, `sasl` — identical usort'd set to `rebar.config` relx `{release, {soma, ...}, [...]}` (rebar.config:28-33). `soma_release_app_list_tests` pins the match and that release.md states `soma_actor` is "not yet bundled".
- Criterion 9 — pass: docs/usage.md:296-303 now says the actor validates steps up front — "each step is a map with `id` and `tool`; a step that fails this is rejected with `{error, Reason}` before any run starts" — matching `valid_step/1` (soma_actor.erl:266). `soma_usage_step_validation_doc_tests` pins it.
- Criterion 10 — pass: docs/contracts/v0.4-test-contract.md gains an "Edge-case hardening (#73)" section mapping E1–E7 to `soma_actor_startup_SUITE` / `soma_actor_validation_SUITE` cases. `soma_v04_contract_doc_tests` pins both suites and all seven listed cases.
- Criterion 11 — pass: `rebar3 eunit` → 115 tests, 0 failures; `rebar3 ct` → All 142 tests passed, both at HEAD.
