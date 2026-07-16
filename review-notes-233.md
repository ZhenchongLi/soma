### Claude

## Verdict

changes-requested

## Real issues

- `run_steps` stops being non-terminal when the trusted `round_sequence` runs out. `soma_delegate_coordinator:advance_after_round/3` only continues when another fixture entry exists, then falls through to a `succeeded` terminal at `apps/soma_actor/src/soma_delegate_coordinator.erl:711`. A one-entry echo action with `max_rounds => 1` returns `status => succeeded`, `result => undefined`; it never returns `{budget_exceeded, max_rounds}`. This makes fixture length the real loop bound and bypasses the round budget. A model-selected action must request the next decision; the counter gate must decide whether that round can start.

- Prompt usage drops every estimate unless the request declares a context-budget key. `accounted_prompt_tokens/2` returns zero at `apps/soma_actor/src/soma_delegate_coordinator.erl:1222`, so an ordinary completed LLM call with no provider usage reports `prompt_tokens => 0`. The design requires each started call to reserve its estimate and retain it when the provider omits usage. Context-limit configuration cannot switch usage accounting on and off.

- Terminal event shape depends on a result having already set `adaptive_events`. The flag starts false at `apps/soma_actor/src/soma_delegate_coordinator.erl:51`, while `soma_delegate_event:outcome_payload/2` emits `mutation_state` and `unknown_outcome_state` only when that flag is true at `apps/soma_actor/src/soma_delegate_event.erl:54`. A first-round context preflight failure emits only counts, so the documented terminal fields are absent. Deadline and cancellation before a committed model result have the same hole. Every adaptive terminal transition needs the terminal schema.

- A model `reject` becomes `failed`. `execute_admitted_proposal/2` maps a normalized, policy-allowed, capability-allowed reject to `status => failed` at `apps/soma_actor/src/soma_delegate_round_worker.erl:471`. The design defines `reject` as terminal rejection, and the public vocabulary has `rejected` for that outcome. The current result destroys the distinction between model refusal and execution failure.

- The new request normalizer validates safe terms but not the field shapes consumed by the coordinator. `budgets => []` passes `soma_delegate_request:normalize/1`, returns an accepted task, then crashes the coordinator with `{badmap, []}` in `counter_available/3`. A strict production boundary cannot admit data that immediately violates its owner's map assumptions. Validate the normalized `budgets`, capability, artifact, and handle shapes before coordinator creation.

## Questions

None.

## Nits

None.

## Functional evidence

- Criterion 1 — pass: One table-driven boundary test: the normalized production request contains only `request_id`, `correlation_id`, `objective`, `output_contract`, `capability_scope`, `resource_handles`, `artifacts`, `budgets`, and a request carrying any forbidden input class — product conversation history, provider credentials, raw leases, process terms, `round_sequence` — receives a fixed bounded rejection before coordinator creation. Artifact: `soma_delegate_adaptive_SUITE:test_request_boundary_normalizes_allowlist_and_rejects_forbidden_inputs` checks the accepted coordinator request and zero coordinator children for all five forbidden rows.

- Criterion 2 — pass: Each projected prompt conforms to the task-local fields `objective`, `output_contract`, `task_summary`, `pinned_safety_state`, `recent_rounds`, `artifact_excerpts`, `tool_schemas`. Artifact: `soma_delegate_adaptive_SUITE:test_prompt_projection_uses_exact_task_local_fields` captures the projection passed to the fixed responder and compares its exact seven-key set.

- Criterion 3 — pass: One admission-chain test: every model-selected action passes through `soma_proposal:normalize/1`, then `soma_policy:check/2`, then task capability admission, in that order, and a capability-admitted state action reaches the production `soma_run -> soma_tool_call` spine. Artifact: `soma_delegate_adaptive_SUITE:test_model_action_admission_order_and_state_spine` traces the three gates in order and observes distinct round-worker, run, and tool-call pids.

- Criterion 4 — pass: One table-driven denial test: a policy-denied action and a capability-denied action each produce terminal `rejected` task data, and malformed action data produces terminal `failed` task data — all before any `run.started` event. Artifact: `soma_delegate_adaptive_SUITE:test_denied_and_malformed_actions_stop_before_run` asserts all three statuses and no correlated `run.started` event.

- Criterion 5 — pass: One end-to-end spine test: a fixed-response production request completes a `reader -> state -> terminal` sequence with a structured result, each completed action observation appears in the immediately following LLM prompt, and the model-selected state-tool action emits exactly one `tool.started` event. Artifact: `soma_delegate_adaptive_SUITE:test_reader_state_terminal_sequence_threads_observations` records prompts for rounds 1–3 and the correlated tool events.

- Criterion 6 — pass: One failure-observation test: a known tool error and a known tool timeout each appear as bounded observations in the next LLM prompt, and a later model-selected invocation of the same state tool receives a fresh invocation identity in the correlation trail. Artifact: `soma_delegate_adaptive_SUITE:test_failed_and_timed_out_actions_feed_observations_with_fresh_invocations` checks the next-round observations and three unique run and tool-call ids.

- Criterion 7 — pass: Each LLM prompt contains tool schemas from the intersection of global policy with task capability scope. Artifact: `soma_delegate_adaptive_SUITE:test_prompt_schemas_equal_policy_capability_intersection` compares the captured prompt schemas with the live `echo` catalog entry after applying both allowlists.

- Criterion 8 — fail: One table-driven budget test: `max_rounds`, `max_llm_calls`, and `max_tool_calls` exhaustion each produce their terminal `{budget_exceeded, _}` data before another round-worker / LLM-worker / run start, and a request after budget exhaustion starts with zero round, LLM-call, tool-call, and prompt-token counters. Artifact: a production-path reproduction with one admitted echo action, one trusted response entry, and `max_rounds => 1` returns `#{status => succeeded, result => undefined, usage => #{rounds => 1}}`; `soma_delegate_coordinator:advance_after_round/3` never re-enters the counter gate when the sequence is empty.

- Criterion 9 — pass: The overall task deadline leaves the task-owned LLM/run/tool/external-process set empty after terminal `timeout`. Artifact: `soma_delegate_adaptive_SUITE:test_task_deadline_tears_down_all_owned_execution_children` covers a blocked LLM and a blocked local CLI process, then checks every captured BEAM pid, OS pid, round worker, and run is gone.

- Criterion 10 — pass: One context-budget test: the pre-call projector rejects an estimated prompt above `max_context_tokens - reserved_completion_tokens` with `context_budget_exceeded` before LLM-worker creation, `max_total_prompt_tokens` exhaustion produces terminal `context_budget_exceeded` data before LLM-worker creation, and provider-reported prompt-token usage replaces the estimate for each completed call in task totals. Artifact: `soma_delegate_adaptive_SUITE:test_context_preflight_and_provider_usage_accounting` exercises the per-call, total, and reported-usage rows and observes zero LLM starts for both rejection rows.

- Criterion 11 — pass: One artifact-observation test: an observation above `max_observation_bytes` persists its complete output under an opaque task artifact handle; the next prompt contains only a bounded excerpt, truncation metadata, and the stable handle; the handle stays identical across prompt, audit event, and terminal projection; and a task-local artifact slice returns at most its requested byte count. Artifact: `soma_delegate_adaptive_SUITE:test_oversized_observation_uses_stable_task_artifact_and_bounded_slice` compares the full stored bytes, the 64-byte excerpt, all three handles, and a 13-byte task-scoped slice.

- Criterion 12 — pass: A prompt beyond the recent-round window replaces every older raw observation with one bounded structured summary. Artifact: `soma_delegate_adaptive_SUITE:test_recent_round_window_replaces_old_observations_with_one_summary` proves rounds 1–2 are absent as raw sentinels, rounds 3–4 remain, and one 512-byte-bounded summary carries the evicted counts and reference.

- Criterion 13 — pass: One safety-state test: every projected prompt preserves the exact pinned safety-state map for capability scope, mutation ledger, unknown-outcome ledger, and idempotency state, and pinned safety state above the per-call allowance produces terminal `context_budget_exceeded` data without safety-state truncation. Artifact: `soma_delegate_adaptive_SUITE:test_pinned_safety_state_is_exact_and_never_truncated` compares initial, committed, and oversized pinned maps byte-for-byte as Erlang terms and observes no LLM start for the oversized row.

- Criterion 14 — pass: Across N maximum-sized rounds, cumulative prompt tokens remain at most N times the per-call input allowance. Artifact: `soma_delegate_adaptive_SUITE:test_maximum_round_prompts_obey_cumulative_input_bound` captures four near-limit estimates, checks each against the 16,384-token allowance, and compares their sum with terminal usage.

- Criterion 15 — fail: One table-driven events test: each adaptive decision, action, and terminal transition appends a scrubbed 4096-byte-bounded event carrying its documented fields (round id + action summary + policy/capability verdicts; run id + tool-call ids + observation reference; status + mutation state + unknown-outcome state). Artifact: a first-round `context_budget_exceeded` reproduction emits `delegate.task.terminal` with `#{status, phase, usage_count, mutation_count, unknown_outcome_count}` and omits both required state fields; the successful-only row in `soma_delegate_adaptive_SUITE:test_adaptive_events_are_documented_scrubbed_and_4096_byte_bounded` does not cover this terminal path.

- Criterion 16 — pass: One terminal-projection test: the public terminal status belongs to `succeeded | failed | rejected | timeout | cancelled | in_doubt`, every terminal projection matches the public fields `request_id`, `task_id`, `correlation_id`, `status`, `result`, `artifacts`, `mutations`, `unknown_outcomes`, `usage`, `trace_ref`, and a fixed terminal response matching `output_contract` appears unchanged under the public `result` field. Artifact: `soma_delegate_adaptive_SUITE:test_terminal_projection_has_exact_public_contract` tables all six statuses, exact keys, non-negative usage, trace identity, and the unchanged fixed success result.

- Criterion 17 — pass: The AS.5 contract document maps every criterion to one hermetic test with zero provider network connections. Artifact: `soma_as5_contract_doc_tests:test_as5_contract_maps_every_criterion_to_one_hermetic_test` counts 17 sections, one named proof per section, one hermetic-boundary line, and one zero-network statement.
