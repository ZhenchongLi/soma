### Claude

## Verdict
approve

## Real issues

None.

## Questions

- The toolless branch sets `status => completed` but the result was already stored as `Task#{result => Proposal}` back at line 276, before the policy gate ran. So a toolless proposal that the policy *rejects* would also have its result pre-stored — only the status flips to `rejected`. Harmless today because `get_task_result` keys off status, but the result map carries a stale proposal on a rejected task. Worth a note if a future caller reads `result` without checking status.
- `soma_policy_SUITE` comments at the `allowed_proposal_status_reads_approved` and `actor_survives_rejected_proposal_takes_next_send` cases still say the task "rests at `approved`", but the assertion now waits for `completed`. The assertion is right; the comment narration is stale. Pure doc drift, not a bug.

## Nits

- `start_owned_run/4` and the old `maybe_start_run/4` body share an identical multi-line monitor-and-track comment block, now duplicated. The factoring is correct; the comment could move to one site.

## Functional evidence
- Criterion 1 — pass: `soma_proposal_exec_SUITE` · `approved_run_steps_completes_with_step_outputs` drives `send/2` with an echo `run_steps` proposal, waits for `completed`, asserts `get_task_result/2` returns `#{<<"s1">> := #{value := <<"a">>}}`. CT green.
- Criterion 2 — pass: `soma_proposal_exec_SUITE` · `approved_run_steps_emits_proposal_executed_with_correlation_id` reads `by_correlation/2`, filters `proposal.executed`, asserts its `correlation_id` matches. Source emits it at soma_actor.erl run branch.
- Criterion 3 — pass: `soma_proposal_exec_SUITE` · `by_correlation_returns_full_approved_run_chain` asserts the trail carries an `actor.*`, an `llm.*`, `proposal.created`, `proposal.approved`, `proposal.executed`, `run.started`, and `run.completed`.
- Criterion 4 — pass: `soma_proposal_exec_SUITE` · `approved_run_steps_runs_in_distinct_pid` catches the live run pid from `soma_run_sup` children, asserts `is_pid(RunPid)` and `RunPid =/= ActorPid`.
- Criterion 5 — pass: `soma_proposal_exec_SUITE` · `rejected_proposal_starts_no_run_status_rejected` uses a `sleep` step outside the `[echo]` allowlist, asserts status `rejected`, trail has `proposal.rejected` and no `run.started`.
- Criterion 6 — pass: `soma_proposal_exec_SUITE` · `approved_reply_proposal_completes_no_run` asserts status `completed`, result `#{kind := reply, text := <<"here is your answer">>}`, no `run.started`.
- Criterion 7 — pass: `soma_proposal_exec_SUITE` · `approved_run_steps_failing_tool_marks_task_failed_actor_alive` runs the `fail` tool in error mode, asserts status `failed` and `is_process_alive(ActorPid)`.
- Criterion 8 — pass: `soma_proposal_exec_SUITE` · `actor_survives_failed_run_takes_next_llm_envelope` sends a failing then an echo proposal on the same pid, asserts the second reaches `completed` with `#{<<"s1">> := #{value := <<"b">>}}`.
- Criterion 9 — pass: `soma_proposal_exec_SUITE` · `direct_steps_completes_no_proposal_event` drives a bare `steps` envelope to `completed`, asserts no `proposal.*`-prefixed event on the trail.
- Criterion 10 — pass: `soma_actor_SUITE` · `no_steps_accepts_and_starts_no_run` (re-pinned, CT green); bare envelope returns `{ok, TaskId}` at status `accepted`, no run.
- Criterion 11 — pass: `docs/contracts/v0.5-test-contract.md` gains a v0.5.4 section mapping all 10 proofs to `soma_proposal_exec_SUITE`/`soma_actor_SUITE` cases.
- Criterion 12 — pass: `soma_llm_call_SUITE` · `pins_v0_5_test_contract_maps_each_proof` extended to require `v0.5.4`, `soma_proposal_exec_SUITE`, and every v0.5.4 case name as substrings; CT green.
- Criterion 13 — pass: `rebar3 eunit` → 132 tests, 0 failures; `rebar3 ct` → All 176 tests passed.
