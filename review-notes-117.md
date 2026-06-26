### Claude

## Verdict
approve

## Real issues
None.

## Questions
- The repair call re-stages `repair_output` onto its own `llm` map (`maybe_repair/5`, soma_actor.erl:563-565). That's what keeps the malformed-loop alive across rounds for criterion 4 — without it the second repair would read `repair_output => undefined` and stop after one attempt. It works and it's tested, but it's load-bearing test-fixture wiring living inside production code. Node B's real repair call drops `repair_output` entirely and builds the prompt from source plus diagnostics, so this seam disappears then. No change needed now; flagging so the next slice doesn't mistake it for permanent.

## Nits
- `maybe_repair/5` builds `RepairLlm` with both `output => RepairOutput` and `repair_output => RepairOutput` (same value twice). Reads slightly odd until you trace why both are needed. A one-line comment naming the re-stage intent at the map literal would save the next reader the trace.

## Functional evidence
- Criterion 1 — pass: `repaired_reply_reaches_same_terminal_result_as_valid_reply` (soma_actor_lisp_repair_SUITE) sends `(reply (text "hi"` with `repair_output => (reply (text "hi"))`, waits for `completed`, and asserts `get_task_result` returns `#{kind => reply, text => <<"hi">>}` byte-equal to the directly-valid arm's result. CT green.
- Criterion 2 — pass: `successful_repair_emits_proposal_repaired_with_ids` reads `by_correlation/2` and asserts exactly one `proposal.repaired` event carrying the task's `task_id` and `correlation_id`. Emit site is soma_actor.erl:348-357 (fires only when `repair_count > 0`).
- Criterion 3 — pass: `repaired_run_steps_outside_allowlist_is_rejected` repairs to a valid `(run-steps ... (tool file_write) ...)` against an `[echo]` allowlist, waits for `rejected`, and asserts a `proposal.rejected` event. Policy gate runs on the repaired form (soma_actor.erl:365) — repair is not a bypass.
- Criterion 4 — pass: `all_repairs_malformed_fails_after_max_attempts_with_diagnostics` runs `max_repairs => 2` with a malformed `repair_output`; asserts terminal `failed`, reason is a non-empty diagnostics list (not a budget/timeout atom), and exactly 3 `llm.started` (first call + 2 repairs). Loop bound at soma_actor.erl:556.
- Criterion 5 — pass: `actor_alive_after_repair_failure_runs_next_valid_message` drives the criterion-4 failure, asserts `is_process_alive`, then sends a valid `(reply ...)` on the same actor and asserts the second task reaches `completed` with the normalized reply.
- Criterion 6 — pass: `repair_blocked_by_max_llm_calls_fails_budget_exceeded` starts `budget => #{max_llm_calls => 1}`; asserts `failed` with reason `{budget_exceeded, max_llm_calls}` and exactly 1 `llm.started`. `llm_budget_available/2` is checked before the repair worker starts (soma_actor.erl:555, 570).
- Criterion 7 — pass: `strict_mode_fails_malformed_without_repair_call` starts `repair => strict`; asserts `failed` with a diagnostics-list reason, exactly 1 `llm.started`, and zero `proposal.repaired`. Strict branch at soma_actor.erl:554.
- Criterion 8 — pass: `valid_proposal_completes_with_one_llm_started_no_repair` sends a directly-valid `(reply ...)`; asserts `completed`, exactly 1 `llm.started`, zero `proposal.repaired`. `repair_count` stays 0 so the repaired-emit branch never fires.
- Criterion 9 — pass: `docs/contracts/L.5-test-contract.md` maps all 10 proofs to suite/case; `soma_l5_contract_doc_tests:test_doc_names_l5_suites_and_cases` asserts the doc names every suite and every case. EUnit green.
- Criterion 10 — pass: full gate green — `rebar3 eunit` 199 tests / 0 failures, `rebar3 ct` 236 tests / 0 failures. `soma_l5_mock_only_tests` asserts every `directive =>` in the suite is `directive => proposal` and that none of `soma_llm_openai` / `api_key` / `base_url` / `api_base` / `http` / `https` appears. The `proposal` mock returns `output` verbatim with no socket (soma_llm_call.erl:46); the repair call reuses the same directive.
