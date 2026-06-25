### Claude

## Verdict
approve

## Real issues
None.

## Questions
- `soma_policy`'s spec declares `allowed_tools => [atom()]`, but every actor-side case in `soma_policy_SUITE` pins both the allowlist and the step tools to binaries (`<<"echo">>`). The check is a plain value comparison, so binary-vs-binary works and atom-vs-atom (the EUnit module) works — but the spec advertises atoms while the runtime path tests binaries. Design-85 already flags this as a deliberate no-normalization trade-off, so it's not a blocker. Worth deciding in v0.5.4 whether the spec follows the binary reality or `soma_proposal` normalizes tool names to atoms at one point.

## Nits
- `Data0a` as a variable name reads like a typo. It's a fine intermediate-state name, but `Data1`/`Data2` numbering would match the rest of the clause.

## Functional evidence
- Criterion 1 — pass: `soma_policy_tests:run_steps_all_tools_allowed_returns_allow_test` — `check/2` over `[echo, sleep]` steps against `#{allowed_tools => [echo, sleep]}` returns `allow`.
- Criterion 2 — pass: `soma_policy_tests:run_steps_unknown_tool_returns_reject_test` — a step naming `danger` against `[echo, sleep]` returns `{reject, _}`; `soma_policy.erl` builds `{reject, {tools_not_allowed, Disallowed}}`.
- Criterion 3 — pass: `soma_policy_tests:run_steps_all_or_absent_allowlist_returns_allow_test` — `check/2` returns `allow` for both `#{allowed_tools => all}` and `#{}` (the `not is_map_key(allowed_tools, ...)` clause maps `#{}` to `all`).
- Criterion 4 — pass: `soma_policy_tests:toolless_kinds_return_allow_test` — `reply`/`reject`/`ask` return `allow` even under `#{allowed_tools => [echo]}`.
- Criterion 5 — pass: `soma_policy_SUITE:allowed_run_steps_emits_proposal_approved_with_correlation_id` — `by_correlation/2` surfaces one `proposal.approved` event with `correlation_id => <<"corr-policy-approved">>`.
- Criterion 6 — pass: `soma_policy_SUITE:allowed_proposal_starts_no_run` — `by_correlation/2` for the approved task surfaces `[]` `run.started` events.
- Criterion 7 — pass: `soma_policy_SUITE:allowed_proposal_status_reads_approved` — `get_task_status/2` reads `approved`; `soma_actor.erl` sets `status => approved` on the `allow` branch.
- Criterion 8 — pass: `soma_policy_SUITE:rejected_proposal_emits_proposal_rejected_with_reason_and_correlation_id` — event carries `reason => {tools_not_allowed, [<<"forbidden">>]}` and `correlation_id => <<"corr-policy-rejected">>`.
- Criterion 9 — pass: `soma_policy_SUITE:rejected_proposal_starts_no_run` — `by_correlation/2` for the rejected task surfaces `[]` `run.started` events.
- Criterion 10 — pass: `soma_policy_SUITE:rejected_proposal_status_reads_rejected` — `get_task_status/2` reads `rejected`; the `{reject, Reason}` branch sets `status => rejected, reason => Reason`.
- Criterion 11 — pass: `soma_policy_SUITE:actor_survives_rejected_proposal_takes_next_send` — actor pid stays alive after rejection and completes a second `send/2`.
- Criterion 12 — pass: `soma_policy_SUITE:by_correlation_returns_verdict_created_actor_and_llm_events` — one correlation id surfaces the verdict event plus `proposal.created`, `actor.*`, and `llm.*`.
- Criterion 13 — pass: `docs/contracts/v0.5-test-contract.md` gains the "v0.5.3 — policy gate" section mapping all 12 proofs to suite·case; `soma_llm_call_SUITE:pins_v0_5_test_contract_maps_each_proof` asserts `v0.5.3`, `soma_policy_tests`, `soma_policy_SUITE`, and every case name are present.
- Criterion 14 — pass: `rebar3 eunit` → 132 tests, 0 failures; `rebar3 ct` → All 167 tests passed.
