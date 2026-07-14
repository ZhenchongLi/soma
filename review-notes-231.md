### Claude

## Verdict

changes-requested

## Real issues

- Admission errors strand exploration tasks. `admit_explore_steps/2` returns
  policy and descriptor lookup failures, but the result handler only continues
  for `non_reader_tool`; the catch-all at
  `apps/soma_actor/src/soma_actor.erl:388` returns the unchanged running task.
  A fixed-response `file_write` explore reply under an `echo`-only policy
  produced `status => running`, zero `run.started` events, and zero
  `explore.round.completed` events after the worker exited. It never reaches the
  next round or the round budget. Convert every admission rejection into a
  bounded observation and close the round.

- Normal provider failures vanish. `soma_llm_call` sends
  `{llm_result, Id, Pid, {error, Reason}}`, but `soma_actor` only handles the
  `{ok, Output}` form at `apps/soma_actor/src/soma_actor.erl:336`. The generic
  state clause consumes the result, and the worker's normal `DOWN` is ignored.
  A two-round fixed sequence ending in HTTP 500 left the second worker dead and
  the task `running`, with `explore.round.started` but no matching completion.
  The default timer later mislabels this provider failure as `timeout`. Handle
  the error result immediately as failed task data and retire the child.

- Successful rounds keep dead child state. The success path at
  `apps/soma_actor/src/soma_actor.erl:341` cancels the timer and monitor but
  leaves the call in `llm_calls` and leaves `llm_call_id`, `llm_call_pid`,
  `llm_call_mref`, and `llm_timer_ref` on the task. A completed two-round probe
  retained both call IDs and the final dead pid/ref/timer. This leaks one map
  entry per round. It also lets an already-queued timeout for an old call pass
  the lookup at line 544 and kill the current round's worker, because the
  timeout handler ignores its timer ref and reads the task's latest pid. Clear
  all finished-call bookkeeping before starting the next child and accept
  timeout messages only for the active call and timer.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: `soma_actor_explore_SUITE:explore_mode_provider_text_is_parsed_as_round_reply` records the canonical `#{kind => explore, steps => [...]}` reply on the live task after the OpenAI-compatible fixed response.
  - [x] An actor with `model_config` carrying `explore => true` treats provider text as an exploration-round reply.
- Criterion 2 — pass: `soma_actor_call_opts_tests:test_explore_prompt_reuses_policy_filtered_catalog_blocks` pins identical catalog blocks, and `test_explore_prompt_states_protocol_round_and_remaining_allowance` pins round 3 with two rounds remaining.
  - [x] Explore-mode system messages render the same policy-filtered catalog blocks as planning mode, state the round protocol (reader-only `(explore ...)` forms or a terminal proposal), and report the current round number plus the remaining `max_explore_rounds` allowance.
- Criterion 3 — pass: `soma_actor_explore_SUITE:reader_explore_run_and_tool_worker_are_distinct_children` finds the run under `soma_run_sup` and asserts pairwise-distinct actor, run, and live tool-worker pids.
  - [x] A reader `(explore ...)` reply starts an owned `soma_run` child under `soma_run_sup`, and each explore step executes inside a `soma_tool_call` worker distinct from both the owning run pid and the actor pid.
- Criterion 4 — pass: `soma_actor_explore_SUITE:reader_then_terminal_run_steps_carries_observation_and_outputs` inspects the second provider request's assistant/observation transcript and asserts the final `#{finish => #{value => <<"done">>}}` task result.
  - [x] End-to-end loop spine: with a socket-free fixed-response sequence — a reader `(explore ...)` reply, then a terminal `(run-steps ...)` reply — a `soma_actor:send/2` task completes; the explore run's step outputs appear as a structured observation in the second LLM request, and the final run's step outputs land in the task result.
- Criterion 5 — fail: the named test covers an allowed `file_write`, but a headless fixed-response probe with the same non-reader tool under an `echo`-only policy ended `running` with no run and no rejection observation; `apps/soma_actor/src/soma_actor.erl:388` drops `{policy_rejected, _}`.
  - [x] A non-reader `(explore ...)` reply becomes a bounded rejection observation naming the offending tool plus descriptor effect, with no `run.started` event, and the loop continues to the next round.
- Criterion 6 — pass: `configured_observation_cap_counts_only_retained_output_bytes` pins a 31-byte retained prefix and external marker; `default_observation_cap_is_16384_bytes` pins the omitted-limit path at 16384 bytes.
  - [x] An observation over configured `max_observation_bytes => N` retains at most N serialized step-output bytes plus a fixed `(truncated true)` marker (envelope and marker outside the count); an omitted `max_observation_bytes` bounds retained data to 16384 bytes.
- Criterion 7 — pass: `failed_explore_run_becomes_next_round_observation`, `timed_out_explore_run_becomes_next_round_observation`, and `invalid_round_reply_becomes_bounded_next_observation` inspect the bounded user observation in the second request and the decremented allowance.
  - [x] A failed or timed-out explore run, and a round reply that parses to neither `(explore ...)` nor a proposal, each become the next round's bounded status/diagnostic observation at one fewer remaining round.
- Criterion 8 — fail: the configured/default and LLM-count tests pass for parse-invalid replies, but the policy-rejected nonterminal probe never completes round 1 and never reaches `{budget_exceeded, max_explore_rounds}` at `N = 1`.
  - [x] A task with `max_explore_rounds => N` (default 5 when omitted) fails after N nonterminal replies with `{budget_exceeded, max_explore_rounds}` before any (N+1)th `llm.started` event, and every exploration round consumes exactly one unit from the existing `max_llm_calls` budget.
- Criterion 9 — pass: `in_loop_llm_crash_is_terminal_failed` proves the second worker dies with failed task data; `in_loop_llm_timeout_is_terminal_timeout` proves the actor-owned 50 ms timer kills the blocked second worker and records timeout data.
  - [x] An LLM worker crash after at least one explore observation becomes terminal `failed` task data, and an owner-enforced LLM timeout becomes terminal `timeout` task data.
- Criterion 10 — pass: `cancel_during_llm_round_kills_worker_and_cancels_task` and `cancel_during_explore_run_kills_tool_worker_and_cancels_task` assert dead active workers, terminal task data, and the matching cancellation events.
  - [x] Cancelling mid-exploration terminates the active child — the `soma_llm_call` worker during an LLM round, or the owned `soma_run` process tree during an explore run — and records terminal `cancelled` task data.
- Criterion 11 — fail: the crash, exhaustion, and cancellation reuse tests pass, but a normal in-loop provider error is never recorded as a failure; the HTTP 500 probe retains a dead worker on a `running` task until the unrelated default timeout fires.
  - [x] After round exhaustion, an in-loop LLM failure, or exploration cancellation, the same actor completes a later task.
- Criterion 12 — pass: the four `terminal_*` Common Test cases assert the proposal event suffix, normalized reply result, policy rejection, max-step failure, and absence or presence of `run.started` at the required boundary.
  - [x] Terminal replies from explore mode re-enter the existing proposal path unchanged: `(run-steps ...)` produces the planning-mode `proposal.created` → `proposal.approved` → `proposal.executed` event suffix; `(reply ...)` completes with normalized proposal data and no `run.started` event; a policy-rejected `(run-steps ...)` ends as `rejected` task data with no `run.started` event; a `(run-steps ...)` over `max_steps` fails with `{budget_exceeded, max_steps}` before any `run.started` event.
- Criterion 13 — fail: `round_events_use_bounded_schema_and_order` proves the happy path, but the policy-rejected reply emits `explore.round.started` without `explore.round.completed`, so the every-round guarantee is false before trace rendering.
  - [x] Every round emits `explore.round.started` before `explore.round.completed` on the task correlation trail; exploration events add only `actor_id`, `task_id`, `correlation_id`, `round`, `remaining_rounds`, `action`, `status`, `observation_bytes`, `truncated` beyond the mandatory keys; `action` is one of `explore | proposal | invalid_reply` and `status` one of `completed | rejected | failed | timeout | cancelled`; and `soma_trace:render/2` prints every exploration round number in order before the terminal proposal/run suffix.
- Criterion 14 — fail: `docs/contracts/AS.3-test-contract.md` names all planned tests, but it calls the incomplete admission, budget, failure, and every-round cases proofs of guarantees that the probes above disprove.
  - [ ] `docs/contracts/AS.3-test-contract.md` maps every guarantee above to its proving test.

Verification roll-up: focused AS.3 Common Test passed 24 cases; focused EUnit passed 27 cases; full `rebar3 eunit` passed 403 tests; full `rebar3 ct` passed 458 cases. The green gate does not exercise the three failed branches above.
