# L.5 Test Contract — Lisp self-repair (the LLM fixes a malformed Lisp proposal, bounded + re-validated)

This document maps each behavioural proof of the L.5 bounded-repair slice
(issue #117) to the suite and case that proves it, matching the existing
contract-doc format. It is the companion to
[L.3-test-contract.md](L.3-test-contract.md) — the Lisp-proposal slice that
taught the actor to parse a Lisp `proposal` directive actor-side — and to
[v0.5-test-contract.md](v0.5-test-contract.md), whose decision loop
(`soma_llm_call` → `soma_proposal:normalize/1` → `soma_policy:check/2` → budget
→ execute) L.5 reuses unchanged: a repaired proposal re-enters that one path,
never a side path.

Every actor-facing proof asserts **process survival**, not just a return value:
the actor survives a bounded-repair failure, a budget refusal, and a strict-mode
failure, and takes the next envelope afterward.

## What this slice builds

The `{invalid_proposal, Diagnostics}` branch of the actor's `llm_result` clause
becomes the entry of a **bounded repair loop**, error-path only — a valid
proposal never reaches it. Repair is on by default (`repair => auto`, or absent);
`repair => strict` fails a malformed proposal immediately, the v0.5 behaviour.
The attempt cap is a separate opt `max_repairs => N` (default 1); a repair call
is an ordinary owned `soma_llm_call` that re-enters the full pipeline and counts
against `max_llm_calls`, so it is gated by both `max_repairs` and the existing
budget. A repaired form that re-parses successfully emits `proposal.repaired`
carrying the task's `task_id` and `correlation_id`. The mock supplies the
repaired s-expr through a `repair_output` field on the malformed directive's
`llm` map; the slice is mock-only — no real provider, no network socket.

## Proving suites

- **`soma_actor_lisp_repair_SUITE`** — a Common Test suite in
  `apps/soma_actor/test/`, set up like `soma_actor_lisp_proposal_SUITE` (boot
  `soma_runtime` so `soma_run_sup` and the event store are alive, start an actor
  through `soma_actor_sup:start_actor/1`, drive it through the real
  `soma_actor:send/2` with a `proposal` llm directive carrying a malformed Lisp
  proposal and a `repair_output`). Every actor-facing repair proof. Each proof
  reads outcomes back through `get_task_status/2`, `get_task_result/2`, and
  `soma_event_store:by_correlation/2`.
- **`soma_l5_contract_doc_tests`** — an EUnit module in `apps/soma_actor/test/`.
  Pins this contract doc.
- **`soma_l5_mock_only_tests`** — an EUnit module in `apps/soma_actor/test/`. The
  source-level guard that pins the L.5 test sources to the `proposal` mock only.

## Actor-side bounded-repair proofs (criteria 1–8)

| # | Proof | Suite · case | Survival / behaviour assertion |
|---|-------|--------------|--------------------------------|
| 1 | A repaired `(reply ...)` reaches `completed` like a directly-valid reply | `soma_actor_lisp_repair_SUITE` · `repaired_reply_reaches_same_terminal_result_as_valid_reply` | a malformed reply proposal whose repair output is a valid `(reply ...)` reaches `completed` with the same normalized result as a directly-valid reply; the actor pid stays alive |
| 2 | A successful repair emits `proposal.repaired` with `task_id` + `correlation_id` | `soma_actor_lisp_repair_SUITE` · `successful_repair_emits_proposal_repaired_with_ids` | `by_correlation/2` surfaces a `proposal.repaired` event carrying the task's `task_id` and `correlation_id` |
| 3 | A repaired `run_steps` with a disallowed tool reaches `rejected` | `soma_actor_lisp_repair_SUITE` · `repaired_run_steps_outside_allowlist_is_rejected` | the policy gate runs on the repaired form: a repaired `run_steps` naming a tool outside the allowlist emits `proposal.rejected` and rests at `rejected`; the actor pid stays alive |
| 4 | Every repair stays malformed — the task fails after max attempts with diagnostics | `soma_actor_lisp_repair_SUITE` · `all_repairs_malformed_fails_after_max_attempts_with_diagnostics` | when each repair output is itself malformed, the loop runs to `repair_count == max_repairs` and the task reaches `failed` with the parse diagnostics as reason; the actor pid stays alive |
| 5 | After a bounded repair failure the actor takes a following valid message | `soma_actor_lisp_repair_SUITE` · `actor_alive_after_repair_failure_runs_next_valid_message` | after the criterion-4 failure the same live actor accepts a second `send/2` with a valid `(reply ...)` and drives it to its terminal status |
| 6 | A repair attempt that would exceed `max_llm_calls` is not made | `soma_actor_lisp_repair_SUITE` · `repair_blocked_by_max_llm_calls_fails_budget_exceeded` | with `budget => #{max_llm_calls => 1}`, the repair entry sees no budget left, the task fails `{budget_exceeded, max_llm_calls}`, no second `llm.started` appears, and the actor pid stays alive |
| 7 | `strict` mode fails malformed Lisp immediately — no repair call, no `proposal.repaired` | `soma_actor_lisp_repair_SUITE` · `strict_mode_fails_malformed_without_repair_call` | with `repair => strict`, a malformed proposal fails the task with exactly one `llm.started` and no `proposal.repaired` in the trail; the actor pid stays alive |
| 8 | A valid Lisp proposal completes with one `llm.started` and no `proposal.repaired` | `soma_actor_lisp_repair_SUITE` · `valid_proposal_completes_with_one_llm_started_no_repair` | a directly-valid proposal never enters the repair branch: the trail carries exactly one `llm.started` and no `proposal.repaired` |

## Contract doc (this file)

| # | Proof | Test module | Test name |
|---|-------|-------------|-----------|
| 9 | `docs/contracts/` gains an L.5 entry mapping each proof to its suite and case | `soma_l5_contract_doc_tests` | `test_doc_names_l5_suites_and_cases` |

## Mock-only guard (no real LLM, no network socket)

This source-level guard pins the L.5 test sources to the `proposal` mock only:
every `directive =>` in the suite is `directive => proposal`, and no real-provider
marker (`soma_llm_openai`, `api_key`, `base_url`, `api_base`, `http`, `https`)
appears — so the gate (`rebar3 eunit && rebar3 ct`) never opens a real LLM call
or network socket.

| # | Proof | Test module | Test name |
|---|-------|-------------|-----------|
| 10 | Every `llm` directive in the L.5 suite is the `proposal` mock | `soma_l5_mock_only_tests` | `test_every_llm_directive_is_the_proposal_mock` |
| 10 | No real-provider config appears in the L.5 suite | `soma_l5_mock_only_tests` | `test_no_real_provider_config_in_suite` |

## References

- [L.3-test-contract.md](L.3-test-contract.md) — the Lisp-proposal slice the
  repair loop extends
- [v0.5-test-contract.md](v0.5-test-contract.md) — the decision loop a repaired
  proposal re-enters unchanged
